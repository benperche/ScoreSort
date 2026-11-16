//
//  SavedListFile.swift
//  ScoreSort
//
//  Reading and writing the lists the app keeps in Application Support — ensemble presets
//  (`ensemble-presets.json`) and stamp designs (`stamps.json`) — without ever losing them.
//
//  Both used to decode the whole array with `try?` and come up empty if anything failed; the
//  next save then wrote that emptiness over the user's file. One damaged byte, or one entry
//  this version couldn't decode, destroyed every preset. So:
//
//  - reading tells **missing** (first run) from **loaded** from **unreadable**;
//  - entries are decoded one at a time, so a bad one doesn't take the others with it;
//  - a file that can't be read is moved aside under a dated name *before* anything can save
//    over it, and a file with some bad entries is copied aside whole before it is rewritten;
//  - if the file can't be put out of harm's way, saving is refused rather than risked;
//  - a save that fails says so.
//
//  The format on disk stays a bare JSON array: older versions of the app and the command
//  line (`savedPresets`, `savedStamps`) read the same files.
//

import Foundation

// MARK: - Reading

/// What reading a saved list found.
enum SavedListRead<Entry> {
    /// No file — a first run. Not an error.
    case missing
    /// The entries that could be read, and how many in the file could not.
    case loaded(entries: [Entry], unreadableEntries: Int)
    /// A file is there but nothing could be read from it. `reason` finishes the sentence
    /// "ScoreSort couldn't read it: …".
    case unreadable(reason: String)
}

/// Reads a saved list without changing anything on disk. This is all the command line needs;
/// the stores go through `SavedListFile`, which also protects what couldn't be read.
func readSavedList<Entry: Decodable>(_ type: Entry.Type = Entry.self, at url: URL) -> SavedListRead<Entry> {
    guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError { return .missing }
        return .unreadable(reason: isFilePermissionError(error)
            ? "macOS didn't let ScoreSort open the file"
            : error.localizedDescription)
    }
    guard let slots = try? JSONDecoder().decode([LossyEntry<Entry>].self, from: data) else {
        return .unreadable(reason: data.isEmpty
            ? "the file is empty"
            : "the file is damaged, or isn't a list ScoreSort recognises")
    }
    let entries = slots.compactMap(\.value)
    if entries.isEmpty && !slots.isEmpty {
        return .unreadable(reason: "none of the \(slots.count) entries in the file could be read")
    }
    return .loaded(entries: entries, unreadableEntries: slots.count - entries.count)
}

/// One slot of the array: the entry, or nil if it wouldn't decode. Never throws, so the
/// array keeps going past a bad entry.
private struct LossyEntry<Entry: Decodable>: Decodable {
    let value: Entry?
    init(from decoder: Decoder) throws { value = try? Entry(from: decoder) }
}

// MARK: - Writing

/// Writes `entries` to `url` as a bare JSON array, creating the folder if needed. Returns
/// `nil` on success, or the reason it failed.
func writeSavedList<Entry: Encodable>(_ entries: [Entry], to url: URL) -> String? {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        try encoder.encode(entries).write(to: url, options: .atomic)
        return nil
    } catch {
        return error.localizedDescription
    }
}

// MARK: - Setting a file aside

/// Where a file that couldn't be read is kept: beside the original, named with the date —
/// `ensemble-presets (unreadable 2026-11-16).json` — and numbered if that name is taken, so
/// an earlier set-aside copy is never replaced.
func setAsideURL(for url: URL, today: Date = Date()) -> URL {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let folder = url.deletingLastPathComponent()
    let base = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    func candidate(_ n: Int) -> URL {
        let name = "\(base) (unreadable \(formatter.string(from: today))\(n > 1 ? " \(n)" : ""))"
        return folder.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
    }
    var n = 1
    while FileManager.default.fileExists(atPath: candidate(n).path) { n += 1 }
    return candidate(n)
}

/// Moves (or, with `keepingOriginal`, copies) a file to its set-aside name. Returns where it
/// went, or the reason it couldn't be done.
func setFileAside(_ url: URL, keepingOriginal: Bool = false, today: Date = Date()) -> Result<URL, SavedFileError> {
    let destination = setAsideURL(for: url, today: today)
    do {
        if keepingOriginal {
            try FileManager.default.copyItem(at: url, to: destination)
        } else {
            try FileManager.default.moveItem(at: url, to: destination)
        }
        return .success(destination)
    } catch {
        return .failure(SavedFileError(reason: error.localizedDescription))
    }
}

struct SavedFileError: Error, Equatable {
    let reason: String
}

// MARK: - Telling the user

/// Something the user should be told about one of their saved files. The stores publish
/// these and a view shows them (`SavedFileNoticeBanner`) — never an alert from the store.
struct SavedFileNotice: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    /// The file to show in Finder: the set-aside copy, or the file that needs attention.
    var fileURL: URL?
}

/// The words for what a list holds, so messages read naturally ("2 presets", "1 stamp").
struct SavedListKind: Equatable {
    let singular: String
    let plural: String

    static let presets = SavedListKind(singular: "preset", plural: "presets")
    static let stamps = SavedListKind(singular: "stamp", plural: "stamps")

    func counted(_ n: Int) -> String { "\(n) \(n == 1 ? singular : plural)" }
}

// MARK: - A store's file

/// One store's file: loads it safely and saves it honestly. `url` is injectable so tests
/// work in a temporary folder; `nil` keeps the list in memory only.
struct SavedListFile<Entry: Codable> {
    let url: URL?
    let kind: SavedListKind

    /// True while a file that couldn't be read (in whole or part) is still in place because
    /// it couldn't be moved or copied aside. Saving then would destroy it, so `save` refuses.
    private(set) var savingBlocked = false
    /// So a run of failing saves (one per keystroke in the stamp editor) is reported once.
    private var lastSaveFailed = false

    init(url: URL?, kind: SavedListKind) {
        self.url = url
        self.kind = kind
    }

    /// Reads the list. Anything unreadable is set aside first; the notices say what happened
    /// and where the copy is. A missing file gives an empty list and no notice.
    mutating func load(today: Date = Date()) -> (entries: [Entry], notices: [SavedFileNotice]) {
        guard let url else { return ([], []) }
        switch readSavedList(Entry.self, at: url) {
        case .missing:
            return ([], [])

        case .loaded(let entries, 0):
            return (entries, [])

        case .loaded(let entries, let bad):
            // Some entries wouldn't decode. Keep the whole original file — the bad entries
            // are in it, byte for byte — then rewrite the list with the ones that loaded, so
            // this is reported once rather than at every launch.
            let rest = "The other \(kind.counted(entries.count)) loaded normally."
            let title = "\(bad) saved \(bad == 1 ? kind.singular : kind.plural) couldn't be read"
            switch setFileAside(url, keepingOriginal: true, today: today) {
            case .success(let copy):
                var notices = [SavedFileNotice(
                    title: title,
                    message: "\(rest) Nothing was deleted: a copy of the file as it was is kept as “\(copy.lastPathComponent)”.",
                    fileURL: copy)]
                if let failure = save(entries) { notices.append(failure) }
                return (entries, notices)
            case .failure(let error):
                savingBlocked = true
                return (entries, [SavedFileNotice(
                    title: title,
                    message: "\(rest) ScoreSort couldn't keep a copy of the file as it was (\(error.reason)), so to protect what's in it, changes to your \(kind.plural) won't be saved until “\(url.lastPathComponent)” is moved somewhere safe.",
                    fileURL: url)])
            }

        case .unreadable(let reason):
            let title = "Your saved \(kind.plural) couldn't be read"
            switch setFileAside(url, today: today) {
            case .success(let copy):
                return ([], [SavedFileNotice(
                    title: title,
                    message: "ScoreSort couldn't read the file they're kept in (\(reason)), so it has started a new list. Nothing was deleted: the old file is kept as “\(copy.lastPathComponent)”.",
                    fileURL: copy)])
            case .failure(let error):
                savingBlocked = true
                return ([], [SavedFileNotice(
                    title: title,
                    message: "ScoreSort couldn't read the file they're kept in (\(reason)), and couldn't move it out of the way (\(error.reason)). To protect it, changes to your \(kind.plural) won't be saved until “\(url.lastPathComponent)” is moved somewhere safe.",
                    fileURL: url)])
            }
        }
    }

    /// Writes the list. Returns a notice when the user needs telling: the first time saving
    /// fails (again after it has worked in between). `nil` otherwise — including while
    /// saving is blocked, which `load` has already explained.
    mutating func save(_ entries: [Entry]) -> SavedFileNotice? {
        guard let url, !savingBlocked else { return nil }
        guard let reason = writeSavedList(entries, to: url) else {
            lastSaveFailed = false
            return nil
        }
        defer { lastSaveFailed = true }
        guard !lastSaveFailed else { return nil }
        return SavedFileNotice(
            title: "Your \(kind.plural) couldn't be saved",
            message: "Changes you make to them won't be kept until this is fixed. \(reason)",
            fileURL: nil)
    }
}

/// The app's own folder in Application Support, where the saved lists live. Not created
/// here — `writeSavedList` creates it when there is something to write.
func scoreSortSupportFile(_ name: String) -> URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("ScoreSort", isDirectory: true)
        .appendingPathComponent(name)
}
