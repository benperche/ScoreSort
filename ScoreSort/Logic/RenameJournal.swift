//
//  RenameJournal.swift
//  ScoreSort
//
//  Undoing the last rename (#19). Renaming is the one thing ScoreSort does to the user's
//  original files, and with Sort into Folders it moves them too — so every rename path (the
//  Score Order Sorter, Bulk Part Rename, and the command line, which an AI assistant may be
//  driving) records what it moved here, and `undoLastRename` puts it back.
//
//  The journal is one small file in Application Support, so undo survives quitting and
//  covers renames made by the command line. Only the last rename (or the last batch of
//  folders) is kept.
//

import Foundation

/// What the last rename moved, and the folders it had to make.
nonisolated struct RenameJournal: Codable, Equatable, Sendable {
    struct Move: Codable, Equatable, Sendable {
        let from: String
        let to: String
    }

    var date: Date
    var moves: [Move]
    /// Folders the rename created (Sort into Folders' Woodwind, Brass…), removed again by an
    /// undo if they're left empty.
    var createdFolders: [String]

    /// `last-rename.json` in the app's Application Support folder — **nil under tests**, so a
    /// test can never write the user's real journal (tests that need one pass a URL).
    static var defaultURL: URL? {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ScoreSort", isDirectory: true)
            .appendingPathComponent("last-rename.json")
    }

    static func load(from url: URL?) -> RenameJournal? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let journal = try? decoder.decode(RenameJournal.self, from: data), !journal.moves.isEmpty else { return nil }
        return journal
    }

    func save(to url: URL?) {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func clear(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// True when there's a rename to undo.
func canUndoLastRename(journalAt url: URL? = RenameJournal.defaultURL) -> Bool {
    RenameJournal.load(from: url) != nil
}

/// Records a rename. Nothing moved leaves the previous journal alone (a rename that failed
/// outright shouldn't lose the undo for the one before it). `append` adds to the journal
/// instead of starting a new one — the later folders of a batch, so one undo covers them all.
func recordRenames(_ moves: [(from: URL, to: URL)], createdFolders: [URL], append: Bool = false,
                   journalAt url: URL? = RenameJournal.defaultURL) {
    guard !moves.isEmpty else { return }
    var journal = (append ? RenameJournal.load(from: url) : nil)
        ?? RenameJournal(date: Date(), moves: [], createdFolders: [])
    journal.date = Date()
    journal.moves += moves.map { RenameJournal.Move(from: $0.from.standardizedFileURL.path, to: $0.to.standardizedFileURL.path) }
    journal.createdFolders += createdFolders.map(\.standardizedFileURL.path)
    journal.save(to: url)
}

/// Makes `folder` and any missing folders above it, adding the ones it made to `created`
/// (outermost first), so an undo can take them away again.
func createFolderRecording(_ folder: URL, into created: inout [URL]) throws {
    let fm = FileManager.default
    var missing: [URL] = []
    var step = folder.standardizedFileURL
    while !fm.fileExists(atPath: step.path) {
        missing.insert(step, at: 0)
        let parent = step.deletingLastPathComponent()
        if parent.path == step.path { break }
        step = parent
    }
    guard !missing.isEmpty else { return }
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    created += missing
}

/// What undoing did, or would do.
struct UndoRenameReport {
    /// Files put back (or, when planning, that would be): where each is now → its old place.
    var restored: [(from: URL, to: URL)] = []
    /// Files that couldn't be put back, and why.
    var problems: [(name: String, reason: String)] = []
    /// Folders the rename made that were removed, now empty.
    var removedFolders: [URL] = []
    /// There was no rename to undo.
    var nothingToUndo = false
    /// When the rename being undone happened.
    var renameDate: Date?
}

/// Puts the last rename back. With `apply` false it only plans. A file is moved back only if
/// it's still where the rename left it and its old name is free; anything else is reported
/// and left alone. Folders the rename made are removed when they're left empty. Afterwards
/// the journal keeps only what couldn't be undone, so a second undo can try those again.
func undoLastRename(apply: Bool, journalAt url: URL? = RenameJournal.defaultURL) -> UndoRenameReport {
    var report = UndoRenameReport()
    guard let journal = RenameJournal.load(from: url) else {
        report.nothingToUndo = true
        return report
    }
    report.renameDate = journal.date
    let fm = FileManager.default
    var stillToUndo: [RenameJournal.Move] = []

    for move in journal.moves.reversed() {
        let now = URL(fileURLWithPath: move.to)
        let old = URL(fileURLWithPath: move.from)
        guard fm.fileExists(atPath: now.path) else {
            report.problems.append((now.lastPathComponent, "it isn't at \(now.path) any more — moved or deleted since"))
            stillToUndo.append(move)
            continue
        }
        // A different file has the old name. (The same file, as when only the case changed, is fine.)
        if fm.fileExists(atPath: old.path) && !isSameFile(old, now) {
            report.problems.append((now.lastPathComponent, "another file is now called “\(old.lastPathComponent)”"))
            stillToUndo.append(move)
            continue
        }
        if apply {
            do {
                try fm.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: now, to: old)
            } catch {
                report.problems.append((now.lastPathComponent, error.localizedDescription))
                stillToUndo.append(move)
                continue
            }
        }
        report.restored.append((now, old))
    }

    guard apply else { return report }

    // Folders the rename made, innermost first, if nothing but Finder's .DS_Store is left.
    var keptFolders: [String] = []
    for path in journal.createdFolders.sorted(by: { $0.count > $1.count }) {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
        if items.allSatisfy({ $0 == ".DS_Store" }), (try? fm.removeItem(at: folder)) != nil {
            report.removedFolders.append(folder)
        } else {
            keptFolders.append(path)
        }
    }

    if stillToUndo.isEmpty {
        RenameJournal.clear(at: url)
    } else {
        RenameJournal(date: journal.date, moves: stillToUndo.reversed(), createdFolders: keptFolders).save(to: url)
    }
    return report
}

/// A sentence for the user about an undo that was carried out.
func undoRenameSummary(_ report: UndoRenameReport) -> (title: String, message: String, isError: Bool) {
    if report.nothingToUndo {
        return ("Nothing to Undo", "There's no rename to undo.", false)
    }
    let n = report.restored.count
    var message = "Put back \(n) file\(n == 1 ? "" : "s") under \(n == 1 ? "its" : "their") old name\(n == 1 ? "" : "s")."
    if !report.removedFolders.isEmpty {
        message += " Removed the empty folder\(report.removedFolders.count == 1 ? "" : "s") the rename had made: "
            + report.removedFolders.map(\.lastPathComponent).joined(separator: ", ") + "."
    }
    guard !report.problems.isEmpty else { return ("Rename Undone", message, false) }
    let shown = report.problems.prefix(8).map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
    message += "\n\n\(report.problems.count) couldn't be put back:\n" + shown
    if report.problems.count > 8 { message += "\n…and \(report.problems.count - 8) more" }
    return (n == 0 ? "Couldn\u{2019}t Undo the Rename" : "Rename Partly Undone", message, true)
}
