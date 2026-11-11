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
    
    var statusText: String {
        let total = operations.count
        let willRename = renameCount
        let willSkip = operations.filter { $0.type == .skip || $0.type == .alreadyPrefixed }.count
        let corrections = operations.filter { $0.type == .correct }.count
        
        if isRescanMode && corrections > 0 {
            return "Found \(total) PDFs: \(corrections) need correction, \(willRename - corrections) will be renamed, \(willSkip) are correct/will be skipped"
        } else {
            return "Found \(total) PDFs: \(willRename) will be renamed, \(willSkip) will be skipped"
        }
    }
    
    var renameCount: Int {
        operations.filter { $0.type == .rename || $0.type == .correct || $0.type == .manual }.count
    }
    
    func loadFolder(url: URL) {
        self.folderURL = url
        self.directFiles = []
        self.manualOverrides = [:]
        self.folderOverrides = [:]
        self.excludedNames = []
        self.isRescanMode = false
        scanFolder()
    }

    /// Load individual files directly (no enclosing folder required). Accepts PDFs and images.
    func loadFiles(urls: [URL]) {
        self.folderURL = nil
        self.directFiles = urls.filter(isRenamableFile)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        self.manualOverrides = [:]
        self.folderOverrides = [:]
        self.excludedNames = []
        self.isRescanMode = false
        scanFolder()
    }

    /// Adds more PDF files to the current list, deduplicating against whatever
    /// is already loaded.  If the manager is currently in folder mode, it
    /// expands the folder's contents into `directFiles` first (so the user can
    /// see and manipulate the full list) before merging the new URLs in.
    func addFiles(urls: [URL]) {
        let newPDFs = urls.filter(isRenamableFile)
        guard !newPDFs.isEmpty else { return }

        if let folder = folderURL {
            // Expand folder mode → direct-files mode, then append new files.
            let existing = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ))?.filter(isRenamableFile)
              .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
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
        scanFolder()
    }

    /// Marks the given filenames as excluded (won't rename) or restores them.
    /// Excluded files remain visible in the list, sorted to the bottom in red.
    /// Puts these files in `folder` ("" for the top level), or back to ScoreSort's own choice
    /// with nil.
    func setFolder(_ folder: String?, for names: Set<String>) {
        for name in names {
            if let folder { folderOverrides[name] = folder.trimmingCharacters(in: .whitespaces) }
            else { folderOverrides.removeValue(forKey: name) }
        }
        if hasContent { scanFolder() }
    }

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
        self.isRescanMode = false
    }

    func setRescanMode(_ enabled: Bool) {
        isRescanMode = enabled
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
            pdfFiles = renamableFiles(in: folderURL,
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
                                          folderOverrides: folderOverrides)
    }

    func detectInstrument(in filename: String) -> (Int, String)? {
        detectScoreOrderInstrument(in: filename, order: customInstrumentOrder)
    }

    func executeRename(
        completion: ((_ folderURL: URL?, _ renamedNames: [String]) -> Void)? = nil
    ) {
        let toRename = operations.filter { $0.type == .rename || $0.type == .correct || $0.type == .manual }

        guard !toRename.isEmpty else { return }

        // The moves are shared with the command line; the alerts stay here.
        let report = performRenames(toRename)
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

    // Bump this whenever the built-in defaults change so existing JSON files
    // are automatically regenerated on next launch.
    private static let defaultsVersion = 8

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

        // Create the Application Support directory if needed
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Rewrite defaults if the file is missing OR was built with an older version.
        // _version is stored as ["2"] so the file stays as [String: [String]].
        let needsRewrite: Bool
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let dict = try? JSONDecoder().decode([String: [String]].self, from: data),
           let versionStr = dict["_version"]?.first,
           let version = Int(versionStr),
           version >= defaultsVersion {
            needsRewrite = false
        } else {
            needsRewrite = true
        }

        if needsRewrite {
            writeDefaults(to: url)
        }

        load(from: url)
    }

    // MARK: - Private helpers
    private static func load(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return }
        // Strip the version sentinel so it doesn't appear as an instrument order
        loaded = dict.filter { $0.key != "_version" }
    }

    private static func writeDefaults(to url: URL) {
        // _version is written as a string list with a single sentinel entry so the
        // file stays as [String: [String]] and remains hand-editable.
        let defaults: [String: [String]] = [
            "_version":  [String(defaultsVersion)],
            "band":      bandDefault,
            "jazz":      jazzDefault,
            "orchestra": orchestraDefault,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(defaults) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Built-in defaults (used as fallback if the file is missing or unreadable)
    private static let bandDefault = [
        "score",
        "instrumentation",
        "program notes",
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
        "contrabass clarinet",
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
        "guitar",
        "electric guitar",
        "keyboard",
        "piano",
        "harp",
        "violin",
        "viola",
        "cello",
        "string bass",
        "bass",
        "basses",
        "double bass",
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
        "instrumentation",
        "voice",
        "vocal",
        "vocals",
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
        "bass",
        "string bass",
        "electric bass",
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
        "instrumentation",
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
        "timpani",
        "mallet percussion",
        "mallet",
        "mallets",
        "percussion",
        "drums",
        "guitar",
        "organ",
        "keyboard",
        "piano",
        "celeste",
        "celesta",
        "harp",
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
    /// The section or instrument folder it moves into ("Sort into folders"); nil when it stays put.
    var folder: String?

    init(originalURL: URL, originalName: String, newName: String, newURL: URL? = nil,
         type: RenameOperationType, statusOverride: String? = nil, oldPrefix: String? = nil, folder: String? = nil) {
        self.id = originalURL.standardizedFileURL.path
        self.originalURL = originalURL
        self.originalName = originalName
        self.newName = newName
        self.newURL = newURL
        self.type = type
        self.statusOverride = statusOverride
        self.oldPrefix = oldPrefix
        self.folder = folder
    }

    /// The new name as shown, with its folder: "Woodwind/01 - Flute.pdf".
    var newPathForDisplay: String {
        guard let folder else { return newName }
        return "\(folder)/\(newName)"
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
