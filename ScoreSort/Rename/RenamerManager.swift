//
//  RenamerManager.swift
//  ScoreSort
//
//  Rename Files tab view model (RenamerManager) plus its supporting types and the
//  built-in instrument-order defaults (band/jazz/orchestra). The order arrays are also
//  read by the splitter's naming suggestions via getOrder(for:).
//

import SwiftUI
@preconcurrency import PDFKit
import UniformTypeIdentifiers
import Combine

// MARK: - Renamer Manager

class RenamerManager: ObservableObject {
    @Published var folderURL: URL?
    /// Files loaded directly (when the user drags in individual PDFs rather than a folder).
    @Published private(set) var directFiles: [URL] = []
    @Published var operations: [RenameOperation] = []
    /// Filenames the user has explicitly excluded from renaming.
    /// Excluded files still appear in operations with type .excluded, sorted to the bottom.
    @Published private(set) var excludedNames: Set<String> = []
    @Published var ensembleType: EnsembleType = .band {
        didSet {
            if !hasCustomOrder {
                // Flagged, because the assignment below lands in customInstrumentOrder's own
                // didSet. Without this it set hasCustomOrder itself, so the *first* ensemble
                // switch locked the list: every switch after it updated the picker while
                // detection carried on using whichever order had loaded first.
                isLoadingPresetOrder = true
                customInstrumentOrder = InstrumentOrders.getOrder(for: ensembleType)
                isLoadingPresetOrder = false
            }
            if hasContent {
                scanFolder()
            }
        }
    }
    @Published var customInstrumentOrder: [String] = InstrumentOrders.getOrder(for: .band) {
        didSet {
            // Only a change the *user* made counts as customising. A preset being loaded for a
            // newly chosen ensemble is not, and the rescan is left to ensembleType's didSet so
            // one ensemble change doesn't scan the folder twice.
            guard !isLoadingPresetOrder else { return }
            hasCustomOrder = true
            if hasContent {
                scanFolder()
            }
        }
    }

    /// Separator inserted between the numeric prefix and the filename,
    /// e.g. " - " gives "01 - Flute.pdf".  Persisted in UserDefaults.
    @Published var prefixSeparator: String = UserDefaults.standard.string(forKey: "prefixSeparator") ?? " - " {
        didSet {
            UserDefaults.standard.set(prefixSeparator, forKey: "prefixSeparator")
            if hasContent { scanFolder() }
        }
    }

    /// "Sort into folders": each numbered part also moves into its section or instrument folder
    /// beside it. One remembered setting (`PartFolderMode.defaultsKey`), shared with Split, Bulk
    /// Rename and Settings ▸ Renamer, so it stays as last chosen.
    @Published var partFolderMode: PartFolderMode = PartFolderMode.savedDefault {
        didSet {
            guard partFolderMode != oldValue else { return }
            if !isTesting { UserDefaults.standard.set(partFolderMode.rawValue, forKey: PartFolderMode.defaultsKey) }
            if hasContent { scanFolder() }
        }
    }
    /// "Number section folders" ("1 Woodwind", "2 Brass"…), from Settings ▸ Renamer.
    @Published var numberedFolders: Bool = PartFolderMode.numbersSections {
        didSet { if numberedFolders != oldValue && hasContent { scanFolder() } }
    }
    /// Under the test runner a manager's choice stays in memory, so tests never change the
    /// person's own setting.
    private let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// True when there is either a folder loaded or direct files loaded.
    var hasContent: Bool { folderURL != nil || !directFiles.isEmpty }

    private var hasCustomOrder = false
    /// True only while an ensemble's preset order is being loaded into `customInstrumentOrder`.
    private var isLoadingPresetOrder = false
    var manualOverrides: [String: Int] = [:]
    /// Folders chosen by hand with "Move to Folder" (file name → folder, "" for the top level),
    /// where ScoreSort's guess was wrong. Used while sorting into folders.
    @Published private(set) var folderOverrides: [String: String] = [:]
    @Published private(set) var isRescanMode = false
    /// "Renumber prefixed files" as the person last set it. It stays for every folder after
    /// (until ScoreSort quits); ScoreSort only ever adds to it, for a folder that needs it.
    private var rescanChosen = false
    /// The folder the files were loaded from, kept when more files are added: parts in its
    /// Woodwind, Brass… folders belong to it, and with folders off are gathered back into it.
    private var rootFolder: URL?
    /// "Renumber prefixed files" was turned on by ScoreSort, because the files mix numbered and
    /// unnumbered parts or a numbered file was given a number by hand
    /// (`scoreOrderNeedsRenumbering`); cleared when the person sets it.
    @Published private(set) var renumberedAutomatically = false
    
    var statusText: String {
        let total = operations.count
        let willRename = renameCount
        let willSkip = operations.filter { $0.type == .skip || $0.type == .alreadyPrefixed }.count
        let corrections = operations.filter { $0.type == .correct }.count
        
        let counts: String
        if isRescanMode && corrections > 0 {
            counts = "Found \(total) PDFs: \(corrections) need correction, \(willRename - corrections) will be renamed, \(willSkip) are correct/will be skipped"
        } else {
            counts = "Found \(total) PDFs: \(willRename) will be renamed, \(willSkip) will be skipped"
        }
        return renumberedAutomatically
            ? counts + ". Renumbering them all, so no number is used twice."
            : counts
    }
    
    var renameCount: Int {
        operations.filter { $0.type == .rename || $0.type == .correct || $0.type == .manual }.count
    }
    
    func loadFolder(url: URL) {
        self.folderURL = url
        self.rootFolder = url
        self.directFiles = []
        self.manualOverrides = [:]
        self.folderOverrides = [:]
        self.excludedNames = []
        renumberIfMixed(reset: true)
        scanFolder()
    }

    /// Turns renumbering on when the files mix numbered and unnumbered parts — numbering only
    /// the new ones would repeat numbers. `reset` (a fresh load) also turns it off otherwise.
    private func renumberIfMixed(reset: Bool) {
        let mixed = scoreOrderNeedsRenumbering(files: currentFiles(), order: customInstrumentOrder,
                                               numberedByHand: Set(manualOverrides.keys))
        if mixed && !isRescanMode {
            isRescanMode = true
            renumberedAutomatically = true
        } else if reset {
            isRescanMode = rescanChosen || mixed
            renumberedAutomatically = mixed && !rescanChosen
        }
    }

    /// The files being renamed: those loaded one by one, or the folder's.
    private func currentFiles() -> [URL] {
        if !directFiles.isEmpty { return directFiles }
        guard let folderURL else { return [] }
        return renamerJobFiles(in: folderURL, recursive: UserDefaults.standard.bool(forKey: "renamerSearchRecursively"))
    }

    /// Load individual files directly (no enclosing folder required). Accepts PDFs and images.
    func loadFiles(urls: [URL]) {
        self.folderURL = nil
        self.rootFolder = nil
        self.directFiles = urls.filter(isRenamableFile)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        self.manualOverrides = [:]
        self.folderOverrides = [:]
        self.excludedNames = []
        renumberIfMixed(reset: true)
        scanFolder()
    }

    /// Adds more PDF files to the current list, deduplicating against whatever
    /// is already loaded.  If the manager is currently in folder mode, it
    /// expands the folder's contents into `directFiles` first (so the user can
    /// see and manipulate the full list) before merging the new URLs in.
    func addFiles(urls: [URL]) {
        let newPDFs = urls.filter(isRenamableFile)
        guard !newPDFs.isEmpty else { return }

        if folderURL != nil {
            // Expand folder mode → direct-files mode, then append new files.
            let existing = currentFiles()
            folderURL = nil
            let existingSet = Set(existing.map { $0.standardizedFileURL })
            let toAdd = newPDFs.filter { !existingSet.contains($0.standardizedFileURL) }
            directFiles = (existing + toAdd).sorted { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            let existingSet = Set(directFiles.map { $0.standardizedFileURL })
            let toAdd = newPDFs.filter { !existingSet.contains($0.standardizedFileURL) }
            guard !toAdd.isEmpty else { return }
            directFiles = (directFiles + toAdd).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        renumberIfMixed(reset: false)
        scanFolder()
    }

    /// Puts these files in `folder` ("" for the top level), or back to ScoreSort's own choice
    /// with nil.
    func setFolder(_ folder: String?, for names: Set<String>) {
        for name in names {
            if let folder { folderOverrides[name] = folder.trimmingCharacters(in: .whitespaces) }
            else { folderOverrides.removeValue(forKey: name) }
        }
        if hasContent { scanFolder() }
    }

    /// Marks the given filenames as excluded (won't rename) or restores them.
    /// Excluded files remain visible in the list, sorted to the bottom in red.
    func setExcluded(_ names: Set<String>, excluded: Bool) {
        if excluded {
            excludedNames.formUnion(names)
        } else {
            excludedNames.subtract(names)
        }
        scanFolder()
    }

    func clearFolder() {
        self.folderURL = nil
        self.directFiles = []
        self.operations = []
        self.manualOverrides = [:]
        self.folderOverrides = [:]
        self.excludedNames = []
        self.rootFolder = nil
        self.isRescanMode = rescanChosen
        self.renumberedAutomatically = false
    }

    func setRescanMode(_ enabled: Bool) {
        rescanChosen = enabled
        isRescanMode = enabled
        renumberedAutomatically = false
        if enabled { manualOverrides = [:] }
        if hasContent { scanFolder() }
    }
    
    func setManualOverride(for filename: String, number: Int) {
        // Build the set of numbers currently in use by everything except this file's
        // existing override (so re-assigning the same file doesn't falsely conflict).
        var takenNumbers = Set(getExistingNumbers())
        if let currentNumber = manualOverrides[filename] {
            takenNumbers.remove(currentNumber)
        }

        if takenNumbers.contains(number) {
            // Shift all manual overrides at >= number up by 1 to make room.
            // Auto-detected numbers will be re-derived by scanFolder() afterward.
            var updatedOverrides: [String: Int] = [:]
            for (key, value) in manualOverrides {
                if key == filename { continue }
                updatedOverrides[key] = value >= number ? value + 1 : value
            }
            manualOverrides = updatedOverrides
        }

        // Assigning a manual number always un-excludes the file.
        excludedNames.remove(filename)
        manualOverrides[filename] = number
        // A number for a file that's already numbered only takes effect by renumbering.
        renumberIfMixed(reset: false)
        scanFolder()
    }
    
    func getExistingNumbers() -> [Int] {
        var numbers: [Int] = []
        
        // Add manual override numbers
        numbers.append(contentsOf: manualOverrides.values)
        
        // Add auto-detected numbers by scanning current operations — including files already
        // numbered correctly while renumbering, which get renumbered around a manual number too.
        for operation in operations {
            let name: String
            switch operation.type {
            case .rename, .correct: name = operation.newName
            case .skip where isRescanMode && operation.newName.isEmpty: name = operation.originalName
            default: continue
            }
            if let match = name.range(of: "^(\\d{2})", options: .regularExpression),
               let number = Int(name[match]) {
                numbers.append(number)
            }
        }
        
        return Array(Set(numbers)).sorted()
    }
    
    func scanFolder() {
        operations = []

        // Build the list of files to process: either directly-supplied URLs or everything
        // in the chosen folder.
        let pdfFiles: [URL]
        if !directFiles.isEmpty {
            pdfFiles = directFiles
        } else if let folderURL = folderURL {
            pdfFiles = renamerJobFiles(in: folderURL,
                                       recursive: UserDefaults.standard.bool(forKey: "renamerSearchRecursively"))
        } else {
            return
        }

        // The numbering itself is shared with the command line (Logic/RenameLogic.swift).
        operations = planScoreOrderRename(files: pdfFiles,
                                          order: customInstrumentOrder,
                                          separator: prefixSeparator,
                                          rescan: isRescanMode,
                                          manualOverrides: manualOverrides,
                                          excluded: excludedNames,
                                          folderMode: partFolderMode,
                                          ensemble: ensembleType,
                                          folderOverrides: folderOverrides,
                                          root: rootFolder,
                                          numberedFolders: numberedFolders)
    }

    func detectInstrument(in filename: String) -> (Int, String)? {
        detectScoreOrderInstrument(in: filename, order: customInstrumentOrder)
    }

    /// `appendToJournal`: add to the undo journal rather than replace it — the later folders
    /// of a batch, so Undo Rename puts the whole batch back.
    func executeRename(
        appendToJournal: Bool = false,
        completion: ((_ folderURL: URL?, _ renamedNames: [String]) -> Void)? = nil
    ) {
        let toRename = operations.filter { $0.type == .rename || $0.type == .correct || $0.type == .manual }

        guard !toRename.isEmpty else { return }

        // The moves are shared with the command line; the alerts stay here.
        let report = performRenames(toRename, appendToJournal: appendToJournal)
        if report.blockedReadOnly {
            // The destination is read-only (cloud-sync placeholder, locked, read-only
            // volume): actionable guidance instead of a wall of failures.
            let alert = NSAlert()
            alert.messageText = "Can’t Rename Files Here"
            alert.informativeText = readOnlyLocationMessage(folderName: folderURL?.lastPathComponent)
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        let successCount = report.renamed.count
        // A part sorted into a folder shows as "Woodwind/01 - Flute.pdf".
        let renamedNames = report.renamed.map { from, to in
            to.deletingLastPathComponent() == from.deletingLastPathComponent()
                ? to.lastPathComponent
                : "\(to.deletingLastPathComponent().lastPathComponent)/\(to.lastPathComponent)"
        }
        let errors = report.errors
        let sawPermissionError = report.sawPermissionError

        if !errors.isEmpty {
            let errorAlert = NSAlert()
            if sawPermissionError && successCount == 0 {
                // All failures were permission-related — show the friendly guidance.
                errorAlert.messageText = "Can’t Rename Files Here"
                errorAlert.informativeText = readOnlyLocationMessage(folderName: folderURL?.lastPathComponent)
            } else {
                errorAlert.messageText = "Partial Success"
                let errorList = errors.prefix(5).joined(separator: "\n")
                var message = "Renamed \(successCount) file(s), but \(errors.count) failed:\n\n\(errorList)"
                if errors.count > 5 { message += "\n... and \(errors.count - 5) more" }
                if sawPermissionError {
                    message += "\n\nSome files are in a read-only location (e.g. Dropbox, Google Drive, iCloud, or a locked folder)."
                }
                errorAlert.informativeText = message
            }
            errorAlert.alertStyle = .warning
            errorAlert.runModal()
        }

        // If a completion handler is provided, let the caller show the summary
        // screen before rescanning (so we don't immediately wipe the result).
        if let completion {
            completion(folderURL, renamedNames)
        } else {
            scanFolder()
        }
    }
}

// MARK: - Supporting Types for Renamer
enum EnsembleType: String, CaseIterable {
    case band = "Band"
    case jazz = "Jazz"
    case orchestra = "Orchestra"
}

struct InstrumentOrders {

    // MARK: - External file location
    // Users can edit this file to customise instrument ordering.
    // Changes take effect the next time the app is launched.
    static var fileURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = appSupport.appendingPathComponent("ScoreSort", isDirectory: true)
        return dir.appendingPathComponent("instrument-orders.json")
    }

    // Bump this whenever the built-in defaults change. Existing files are then *merged*, not
    // replaced (`prepareFile`): an order the user never changed takes the new one as it is,
    // and an edited one keeps the edits and gains the new instruments in their places.
    static let defaultsVersion = 9

    /// The built-in order for each ensemble, by its key in the file.
    static var defaultOrders: [String: [String]] {
        ["band": bandDefault, "jazz": jazzDefault, "orchestra": orchestraDefault]
    }

    /// `saved` with every instrument of `defaults` it lacks put back in: each one after the
    /// nearest instrument before it in `defaults` that `saved` has (or first, if none), so it
    /// lands in score order wherever the user moved things. Nothing in `saved` moves, and
    /// nothing is removed. Compared without case.
    static func merged(_ saved: [String], with defaults: [String]) -> [String] {
        var result = saved
        var present = Set(saved.map { $0.lowercased() })
        for (i, name) in defaults.enumerated() where !present.contains(name.lowercased()) {
            var insertAt = 0
            for j in stride(from: i - 1, through: 0, by: -1) {
                if let k = result.firstIndex(where: { $0.lowercased() == defaults[j].lowercased() }) {
                    insertAt = k + 1
                    break
                }
            }
            result.insert(name, at: insertAt)
            present.insert(name.lowercased())
        }
        return result
    }

    /// The file's contents after a defaults update: per ensemble, the new built-in order if the
    /// saved one is the built-in order it was last written from (`_base_<ensemble>`, so it was
    /// never edited), else the saved order with the new instruments merged in.
    static func updated(_ file: [String: [String]]) -> [String: [String]] {
        var out: [String: [String]] = ["_version": [String(defaultsVersion)]]
        for (key, newDefault) in defaultOrders {
            let saved = file[key]
            if let saved, file["_base_\(key)"].map({ $0 != saved }) ?? true {
                out[key] = merged(saved, with: newDefault)     // edited (or written before bases): keep it
            } else {
                out[key] = newDefault                          // missing, or never edited: take the new one
            }
            out["_base_\(key)"] = newDefault
        }
        return out
    }

    // MARK: - Loaded state (populated by setup())
    private static var loaded: [String: [String]] = [:]

    // MARK: - Public accessors
    static var band:      [String] { loaded["band"]      ?? bandDefault      }
    static var jazz:      [String] { loaded["jazz"]      ?? jazzDefault      }
    static var orchestra: [String] { loaded["orchestra"] ?? orchestraDefault }

    static func getOrder(for type: EnsembleType) -> [String] {
        switch type {
        case .band:      return band
        case .jazz:      return jazz
        case .orchestra: return orchestra
        }
    }

    // MARK: - Setup (call once at launch from AppDelegate)
    static func setup() {
        guard let url = fileURL else { return }
        if let notice = prepareFile(at: url) {
            launchNotice = notice
            NotificationCenter.default.post(name: launchNoticeChanged, object: nil)
        }
        load(from: url)
    }

    /// Set by `setup()` when the file on disk couldn't be read and was set aside. Shown once by
    /// `SavedFileNoticeBar`, which clears it when dismissed.
    static var launchNotice: SavedFileNotice?
    static let launchNoticeChanged = Notification.Name("InstrumentOrdersLaunchNoticeChanged")

    /// Makes sure a current instrument-orders file is at `url`, without touching the loaded
    /// orders (so tests can call it on a temporary file).
    ///
    /// - Missing: the defaults are written.
    /// - Readable but written by an older version (or with no `_version`): **updated**
    ///   (`updated(_:)`): new built-in instruments reach existing users without wiping an order
    ///   they edited. (Before version 9 the file was overwritten with the defaults.)
    /// - There but unreadable, typically a hand edit that broke the JSON: moved aside under
    ///   a dated name *before* the defaults are written, so the user's edits survive. This case
    ///   used to be overwritten silently. Returns a notice saying where the file went.
    static func prepareFile(at url: URL, today: Date = Date()) -> SavedFileNotice? {
        // Create the Application Support directory if needed
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: url.path) else {
            writeDefaults(to: url)
            return nil
        }

        // _version is stored as ["2"] so the file stays as [String: [String]].
        if let data = try? Data(contentsOf: url),
           let dict = try? JSONDecoder().decode([String: [String]].self, from: data) {
            if let versionStr = dict["_version"]?.first,
               let version = Int(versionStr),
               version >= defaultsVersion {
                return nil
            }
            write(updated(dict), to: url)
            return nil
        }

        let title = "Your instrument order file couldn't be read"
        switch setFileAside(url, today: today) {
        case .success(let copy):
            writeDefaults(to: url)
            return SavedFileNotice(
                title: title,
                message: "ScoreSort has gone back to its built-in instrument order. Nothing was deleted: your file is kept as “\(copy.lastPathComponent)”, so any changes you made to it can be copied across.",
                fileURL: copy)
        case .failure(let error):
            // Leave it exactly as it is rather than write over it; the built-in order is used.
            return SavedFileNotice(
                title: title,
                message: "ScoreSort is using its built-in instrument order for now. It couldn't move “\(url.lastPathComponent)” out of the way (\(error.reason)), so it has left the file as it is. Fix or remove it and the app will use it the next time it opens.",
                fileURL: url)
        }
    }

    // MARK: - Private helpers
    private static func load(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return }
        // Strip the bookkeeping (`_version`, `_base_…`) so it doesn't appear as an instrument order
        loaded = dict.filter { !$0.key.hasPrefix("_") }
    }

    private static func writeDefaults(to url: URL) {
        write(updated([:]), to: url)
    }

    /// _version (and each `_base_…`, the built-in order the file was written from) are string
    /// lists, so the file stays [String: [String]] and remains hand-editable.
    private static func write(_ file: [String: [String]], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Built-in defaults (used as fallback if the file is missing or unreadable)
    private static let bandDefault = [
        "score",
        "conductor",
        "instrumentation",
        "program notes",
        "vocal",
        "vocals",
        "voice",
        "choir",
        "lead sheet",
        "part 1",
        "part 2",
        "part 3",
        "part 4",
        "part 5",
        "piccolo",
        "flute",
        "alto flute",
        "bass flute",
        "oboe",
        "oboe d'amore",
        "cor anglais",
        "english horn",
        "bassoon",
        "contrabassoon",
        "eb clarinet",
        "eflat clarinet",
        "clarinet",
        "alto clarinet",
        "bass clarinet",
        "contra alto clarinet",
        "contra-alto clarinet",
        "contralto clarinet",
        "contrabass clarinet",
        "contra bass clarinet",
        "soprano sax",
        "sop sax",
        "sop saxophone",
        "soprano saxophone",
        "special alto saxophone",
        "special alto sax",
        "alto saxophone",
        "saxophone alto",
        "alto sax",
        "sax alto",
        "alto",
        "tenor sax",
        "tenor saxophone",
        "saxophone tenor",
        "sax tenor",
        "tenor",
        "bari sax",
        "baritone sax",
        "baritone saxophone",
        "bari saxophone",
        "sax bari",
        "saxophone bari",
        "sax baritone",
        "bari",
        "bass sax",
        "bass saxophone",
        "cornet",
        "trumpet",
        "flugelhorn",
        "horn",
        "trombone",
        "bass trombone",
        "trombone bass",
        "baritone b.c.",
        "baritone bass clef",
        "baritone bc",
        "baritone t.c.",
        "baritone treble clef",
        "baritone tc",
        "baritone",
        "euphonium b.c.",
        "euphonium bass clef",
        "euphonium bc",
        "euphonium t.c.",
        "euphonium treble clef",
        "euphonium tc",
        "euphonium",
        "eupho",
        "trombone baritone bassoon",
        "tuba",
        "sousaphone",
        "guitar",
        "electric guitar",
        "keyboard",
        "synthesizer",
        "synth",
        "piano",
        "harp",
        "violin",
        "viola",
        "cello",
        "string bass",
        "bass",
        "basses",
        "double bass",
        "bass guitar",
        "electric bass",
        "timpani",
        "mallet percussion",
        "mallet",
        "mallets",
        "bells",
        "chimes",
        "glockenspiel",
        "glock",
        "xylophone",
        "xylo",
        "vibraphone",
        "vibes",
        "marimba",
        "drums",
        "drum set",
        "drumset",
        "drum kit",
        "drumkit",
        "percussion",
        "snare drum",
        "bass drum",
        "cymbals",
        "crash cymbals",
        "suspended cymbal",
        "tambourine",
        "auxiliary",
        "aux percussion",
    ]

    private static let jazzDefault = [
        "score",
        "conductor",
        "instrumentation",
        "voice",
        "vocal",
        "vocals",
        "lead sheet",
        "solo alto sax",
        "solo alto saxophone",
        "solo saxophone alto",
        "solo eb",
        "solo eflat",
        "solo e flat",
        "solo tenor sax",
        "solo tenor saxophone",
        "solo bari sax",
        "solo baritone sax",
        "solo bb",
        "solo b flat",
        "solo bflat",
        "solo trumpet",
        "solo trombone",
        "solo",
        "soli",
        "alto saxophone",
        "saxophone alto",
        "alto sax",
        "sax alto",
        "alto",
        "tenor sax",
        "sax tenor",
        "tenor saxophone",
        "saxophone tenor",
        "tenor",
        "bari sax",
        "baritone sax",
        "bari saxophone",
        "sax bari",
        "saxophone bari",
        "sax baritone",
        "baritone saxophone",
        "baritone",
        "bari",
        "trumpet",
        "cornet",
        "flugelhorn",
        "trombone",
        "bass trombone",
        "trombone bass",
        "guitar",
        "guitar chords",
        "guitar chord",
        "chords",
        "piano",
        "keyboard",
        "synthesizer",
        "synth",
        "bass",
        "string bass",
        "electric bass",
        "bass guitar",
        "double bass",
        "drums",
        "drum set",
        "drum kit",
        "drumkit",
        "aux percussion",
        "auxiliary percussion",
        "congas",
        "bongos",
        "percussion",
        "mallet percussion",
        "mallets",
        "vibraphone",
        "vibes",
        "flute",
        "clarinet",
        "horn",
        "baritone horn",
        "eupho",
        "euphonium",
        "tuba",
    ]

    private static let orchestraDefault = [
        "score",
        "conductor",
        "instrumentation",
        "part 1",
        "part 2",
        "part 3",
        "part 4",
        "part 5",
        "piccolo",
        "flute",
        "oboe",
        "oboe d'amore",
        "cor anglais",
        "english horn",
        "eb clarinet",
        "eflat clarinet",
        "clarinet",
        "clarinet in Bb",
        "clarinet in A",
        "bass clarinet",
        "contra alto clarinet",
        "contralto clarinet",
        "bassoon",
        "contrabassoon",
        "soprano sax",
        "sop sax",
        "sop saxophone",
        "soprano saxophone",
        "alto saxophone",
        "alto sax",
        "sax alto",
        "tenor sax",
        "tenor saxophone",
        "sax tenor",
        "bari sax",
        "baritone sax",
        "bari saxophone",
        "sax bari",
        "saxophone bari",
        "sax baritone",
        "bass sax",
        "bass saxophone",
        "horn",
        "trumpet",
        "cornet",
        "trombone",
        "bass trombone",
        "trombone bass",
        "euphonium bass clef",
        "euphonium b.c.",
        "euphonium bc",
        "euphonium treble clef",
        "euphonium t.c.",
        "euphonium tc",
        "euphonium",
        "eupho",
        "baritone",
        "tuba",
        "sousaphone",
        "timpani",
        "mallet percussion",
        "mallet",
        "mallets",
        "percussion",
        "drums",
        "guitar",
        "organ",
        "keyboard",
        "synthesizer",
        "synth",
        "piano",
        "celeste",
        "celesta",
        "harp",
        "vocal",
        "vocals",
        "voice",
        "choir",
        "violin",
        "viola",
        "cello",
        "double bass",
        "string bass",
        "bass",
    ]
}

// `nonisolated` so its (implicit) Equatable conformance isn't main-actor-isolated under
// the target's default MainActor isolation — otherwise comparing `.type` from a
// nonisolated context (e.g. the test target) warns and would error in Swift 6.
nonisolated enum RenameOperationType {
    case rename
    case skip
    case alreadyPrefixed
    case undetected
    case correct
    case manual
    case excluded   // User-excluded from renaming; shown in red section at bottom
}

struct RenameOperation: Identifiable {
    /// Stable across re-scans: uses the standardized URL path so that
    /// selectedIDs remain valid after scanFolder() regenerates operations.
    let id: String
    /// Distinct identity for use in the excluded-section ForEach so SwiftUI
    /// creates a fresh view rather than reusing the detected-section view.
    var excludedSectionID: String { "excluded_\(id)" }
    let originalURL: URL
    let originalName: String
    let newName: String
    var newURL: URL?
    let type: RenameOperationType
    var statusOverride: String?
    var oldPrefix: String?
    /// The section or instrument folder it ends up in ("Sort into folders"); nil when it's in
    /// the piece's own folder.
    var folder: String?
    /// The section or instrument folder it moves out of, when it does.
    var fromFolder: String?

    init(originalURL: URL, originalName: String, newName: String, newURL: URL? = nil,
         type: RenameOperationType, statusOverride: String? = nil, oldPrefix: String? = nil, folder: String? = nil,
         fromFolder: String? = nil) {
        self.id = originalURL.standardizedFileURL.path
        self.originalURL = originalURL
        self.originalName = originalName
        self.newName = newName
        self.newURL = newURL
        self.type = type
        self.statusOverride = statusOverride
        self.oldPrefix = oldPrefix
        self.folder = folder
        self.fromFolder = fromFolder
    }

    /// The new name as shown, with its folder: "Woodwind/01 - Flute.pdf", or
    /// "01 - Flute.pdf (out of Woodwind)" for a part gathered back into the piece's folder.
    var newPathForDisplay: String {
        if let folder { return "\(folder)/\(newName)" }
        if let fromFolder { return "\(newName) (out of \(fromFolder))" }
        return newName
    }
    
    var statusText: String {
        if let override = statusOverride {
            return override
        }
        
        switch type {
        case .rename:
            return "Will rename"
        case .skip:
            return "Already correct"
        case .alreadyPrefixed:
            return "Already prefixed"
        case .undetected:
            return "No instrument found (double-click to assign)"
        case .correct:
            if let old = oldPrefix {
                let new = String(newName.prefix(2))
                return "Will correct (\(old) → \(new))"
            }
            return "Will correct"
        case .manual:
            return "Will rename (manual)"
        case .excluded:
            return "Won't be renamed"
        }
    }

    var color: Color {
        switch type {
        case .rename:
            return Color.green
        case .skip, .alreadyPrefixed:
            return Color.secondary
        case .undetected:
            return Color.secondary
        case .correct:
            return Color.orange
        case .manual:
            return Color.blue
        case .excluded:
            return Color.red
        }
    }
}
