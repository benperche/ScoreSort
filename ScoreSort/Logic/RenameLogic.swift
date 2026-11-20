//
//  RenameLogic.swift
//  ScoreSort
//
//  Pure helpers behind the Rename Files tab — which files/folders are renamable,
//  expanding a drop into per-folder jobs, disambiguating folder names, collecting
//  dropped URLs, and score-order numbering shared with the splitter's prefix step.
//  No view state; unit-tested directly.
//

import Foundation
import PDFKit

// MARK: - Renamable files & folder-job expansion

/// File types the renamer picks up and renames: PDFs plus common image formats — some
/// libraries store sheet music as scans (JPG/PNG/etc.) rather than PDFs. Renaming only
/// prepends a prefix to the existing filename, so the original extension is preserved.
let renamableFileExtensions: Set<String> = ["pdf", "jpg", "jpeg", "png", "tif", "tiff", "heic", "bmp", "gif"]

func isRenamableFile(_ url: URL) -> Bool {
    renamableFileExtensions.contains(url.pathExtension.lowercased())
}

func urlIsDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
}

func folderHasDirectRenamableFiles(_ url: URL) -> Bool {
    let items = (try? FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
    return items.contains(where: isRenamableFile)
}

/// Turns dropped folders into batch rename jobs by walking each one recursively: every
/// directory at any depth that directly contains renamable files becomes a job. A folder
/// of PDFs is one job; a (nested) parent folder of piece folders batches them all.
/// Result is sorted by full path so siblings group together.
/// A piece's part folders (Woodwind, Brass… from "Sort into folders") belong to the piece's
/// job rather than being jobs of their own, so its parts are numbered together.
func expandToRenameJobFolders(_ folders: [URL]) -> [URL] {
    var jobs: [URL] = []
    func collect(_ folder: URL) {
        let parts = Set(partSubfolders(of: folder).map(\.standardizedFileURL))
        if folderHasDirectRenamableFiles(folder) || !parts.isEmpty { jobs.append(folder) }
        let subs = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        for sub in subs where urlIsDirectory(sub) && !parts.contains(sub.standardizedFileURL) { collect(sub) }
    }
    for folder in folders { collect(folder) }
    return jobs.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
}

/// Resolves file URLs from dropped `NSItemProvider`s and calls `completion` on the main
/// queue once all have loaded. `loadObject` callbacks fire on arbitrary threads, so the
/// appends are serialised with a lock — safe for any number of dropped items.
func collectDroppedFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
    var collected: [URL] = []
    let lock = NSLock()
    let group = DispatchGroup()
    for provider in providers {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { lock.lock(); collected.append(url); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) { completion(collected) }
}

/// A concise, disambiguating display name for `url` relative to the deepest directory
/// shared by every folder in `among` — e.g. "Concert Band › Symphony 5". Lets the batch
/// queue/summary tell apart same-named folders in different parts of a nested tree.
/// Falls back to the last path component when there's only one folder.
func qualifiedFolderName(for url: URL, among all: [URL]) -> String {
    guard all.count > 1 else { return url.lastPathComponent }
    let target = url.standardizedFileURL.pathComponents
    var common = target.count
    for other in all where other.standardizedFileURL != url.standardizedFileURL {
        let comps = other.standardizedFileURL.pathComponents
        var i = 0
        while i < common && i < comps.count && comps[i] == target[i] { i += 1 }
        common = i
    }
    let tail = Array(target.dropFirst(common))
    return tail.isEmpty ? url.lastPathComponent : tail.joined(separator: " › ")
}

// MARK: - Score-order numbering

/// A single item flowing through the Prefix Order step.
/// For the Splitter, `originalURL` is nil (file not on disk yet).
/// For Bulk Rename, `originalURL` is the current URL of the file to rename.
struct PrefixItem: Identifiable {
    let id: Int              // original zero-based index (stable across reordering)
    let proposedName: String // full filename incl. .pdf, e.g. "Beethoven - Flute.pdf"
    let page: PDFPage?
    var originalURL: URL? = nil
    /// True when the proposed name matched the score (instrument rank 0) — pinned to "00".
    var isScore: Bool = false
    /// Forced number (renamer-style override). Reserved, so auto-numbered items reflow around it.
    var manualNumber: Int? = nil
    /// Excluded from output and from numbering.
    var isSkipped: Bool = false
    /// The folder it's saved into while sorting into folders (Split's Step 3 sets this when
    /// it hands the items back); nil = beside the others.
    var folder: String? = nil
}

/// Items sorted into score order, as Step 3 (and the command line's `--score-order`) shows
/// them: the score (instrument rank 0) pinned first so it gets 00, then matched parts in
/// instrument order, then anything unrecognised last — left for the user to place, never
/// displacing the score.
func scoreOrderSorted(_ items: [PrefixItem], by order: [String]) -> [PrefixItem] {
    var score:     [PrefixItem] = []
    var matched:   [(rank: Int, item: PrefixItem)] = []
    var unmatched: [PrefixItem] = []
    for var item in items {
        if let rank = matchInstrumentOrder(in: item.proposedName, order: order) {
            if rank == 0 { item.isScore = true; score.append(item) }
            else { item.isScore = false; matched.append((rank, item)) }
        } else {
            item.isScore = false
            unmatched.append(item)
        }
    }
    return score + matched.sorted { $0.rank < $1.rank }.map(\.item) + unmatched
}

/// IDs of items whose proposed names don't match any instrument in `order`.
func scoreOrderUnmatchedIds(_ items: [PrefixItem], by order: [String]) -> Set<Int> {
    Set(items.filter { matchInstrumentOrder(in: $0.proposedName, order: order) == nil }.map(\.id))
}

/// The final file names for ordered items — `"01 - Piece - Flute.pdf"` — keyed by item id.
/// Skipped items get none. The one place a score-order prefix is put on a split file's name.
func scoreOrderFileNames(forOrderedItems items: [PrefixItem], separator: String) -> [Int: String] {
    let numbers = scoreOrderNumbers(forOrderedItems: items)
    var names: [Int: String] = [:]
    for item in items {
        guard let number = numbers[item.id] else { continue }
        names[item.id] = "\(String(format: "%02d", number))\(separator)\(item.proposedName)"
    }
    return names
}


/// Score-order numbers for an ordered item list, mirroring the Score Order Sorter
/// (`scanFolder`): the score → 0, manually-numbered items keep their number (reserved),
/// everything else auto-numbers from 1 up, skipping reserved numbers. `00` is therefore
/// always reserved for the score even when no score is present. Returns `item.id → number`;
/// skipped items are omitted.
func scoreOrderNumbers(forOrderedItems items: [PrefixItem]) -> [Int: Int] {
    let active = items.filter { !$0.isSkipped }
    let reserved = Set(active.compactMap { $0.manualNumber })
    var result: [Int: Int] = [:]
    var next = 1
    for item in active {
        if item.isScore {
            result[item.id] = 0
        } else if let manual = item.manualNumber {
            result[item.id] = manual
        } else {
            while reserved.contains(next) { next += 1 }
            result[item.id] = next
            next += 1
        }
    }
    return result
}

// MARK: - Score Order Sorter (the Rename tab), shared with the command line

/// The renamable files in `folder`, sorted by name: its immediate children, or everything
/// inside it with `recursive`.
/// A rename job's files: those in `folder` (and every subfolder when `recursive`), plus — a
/// piece sorted into folders being one job — those in its part folders (Woodwind, Brass…).
func renamerJobFiles(in folder: URL, recursive: Bool) -> [URL] {
    guard !recursive else { return renamableFiles(in: folder, recursive: true) }
    return (renamableFiles(in: folder, recursive: false)
            + partSubfolders(of: folder).flatMap { renamableFiles(in: $0, recursive: false) })
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func renamableFiles(in folder: URL, recursive: Bool) -> [URL] {
    let fileManager = FileManager.default
    var files: [URL] = []
    if recursive {
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        for case let fileURL as URL in enumerator where isRenamableFile(fileURL) { files.append(fileURL) }
    } else {
        let contents = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                             options: [.skipsHiddenFiles])) ?? []
        files = contents.filter(isRenamableFile)
    }
    return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

/// The instrument a file name names, as (its position in `order`, the instrument): the
/// *leftmost* match, longest names tried first so "bass clarinet" beats "clarinet".
func detectScoreOrderInstrument(in filename: String, order: [String]) -> (Int, String)? {
    let lowerFilename = filename.lowercased()
    let sortedInstruments = order.enumerated().map { ($0.offset, $0.element) }.sorted { $0.1.count > $1.1.count }
    var matches: [(index: Int, instrument: String, position: Int)] = []
    for (originalIndex, instrument) in sortedInstruments {
        if let range = lowerFilename.range(of: instrument.lowercased()) {
            let position = lowerFilename.distance(from: lowerFilename.startIndex, to: range.lowerBound)
            matches.append((originalIndex, instrument, position))
        }
    }
    // Leftmost wins: "Baritone BC Bassoon" is a baritone, not a bassoon.
    guard let first = matches.min(by: { $0.position < $1.position }) else { return nil }
    return (first.index, first.instrument)
}

/// True when the whole folder has to be renumbered rather than only its unnumbered files:
/// • some files are already numbered ("01 - Flute.pdf") and some recognised parts aren't —
///   numbering only the new ones would start again from 01 and repeat numbers; or
/// • a file that's already numbered was given a number by hand (`numberedByHand`) — outside
///   renumbering it would be left as it is, so the number would be ignored.
/// The Score Order Sorter and `rename` then renumber everything.
func scoreOrderNeedsRenumbering(files: [URL], order: [String], numberedByHand: Set<String> = []) -> Bool {
    func isNumbered(_ name: String) -> Bool { name.range(of: "^\\d{2}[-_\\s]", options: .regularExpression) != nil }
    if numberedByHand.contains(where: isNumbered) { return true }
    var numbered = false, unnumbered = false
    for url in files {
        let name = url.lastPathComponent
        if isNumbered(name) {
            numbered = true
        } else if detectScoreOrderInstrument(in: name, order: order) != nil {
            unnumbered = true
        }
        if numbered && unnumbered { return true }
    }
    return false
}

/// In rescan mode, an existing `NN - ` / `NN_` / `NN ` prefix split off: the clean name and
/// the old two-digit prefix. Otherwise the name unchanged and no prefix.
func stripScoreOrderPrefix(from filename: String, rescan: Bool) -> (clean: String, oldPrefix: String?) {
    if rescan, let match = filename.range(of: "^(\\d{2})", options: .regularExpression) {
        let oldPrefix = String(filename[match])
        let clean = String(filename[match.upperBound...])
            .replacingOccurrences(of: "^[-_\\s]+", with: "", options: .regularExpression)
        return (clean, oldPrefix)
    }
    return (filename, nil)
}

/// The Score Order Sorter's plan for `files`: the score → 00, recognised parts 01, 02… in
/// `order`, manual numbers kept (and skipped over by the auto numbers), unrecognised files
/// left alone and listed first, excluded files last. A rename whose target already exists
/// is skipped ("Target exists"). With `rescan`, existing prefixes are re-done and only
/// wrong ones change. With `folderMode`, each numbered part also moves into its section or
/// instrument folder beside it (`partFolderDestination`) — including parts already numbered,
/// which then only move. `folderOverrides` (original file name → folder, "" for none) are the
/// person's own choices where ScoreSort guessed wrong; they apply only with `folderMode` on.
/// Nothing is touched on disk.
func planScoreOrderRename(files: [URL], order: [String], separator: String, rescan: Bool = false,
                          manualOverrides: [String: Int] = [:], excluded: Set<String> = [],
                          folderMode: PartFolderMode = .off, ensemble: EnsembleType = .band,
                          folderOverrides: [String: String] = [:], root: URL? = nil,
                          numberedFolders: Bool = false) -> [RenameOperation] {
    var operations: [RenameOperation] = []
    var detectedFiles: [(order: Int, url: URL, originalName: String)] = []
    var scoreFiles: [(url: URL, originalName: String)] = []
    var undetectedFiles: [(url: URL, originalName: String)] = []
    var manuallyAssigned: [(number: Int, url: URL, originalName: String)] = []

    /// The piece folder a file belongs to (`root` for one already in a part folder in it).
    func home(_ url: URL) -> URL { partPieceFolder(of: url, root: root) }
    func samePlace(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.path == b.standardizedFileURL.path }

    /// Where the file at `url` goes once named `name`: its folder — the person's choice, else
    /// ScoreSort's — when sorting into folders; with folders off, its piece folder (so parts
    /// in Woodwind, Brass… are gathered back into it).
    func destination(_ url: URL, _ name: String) -> URL {
        let renamed = home(url).appendingPathComponent(name)
        guard folderMode != .off else { return renamed }
        if let chosen = folderOverrides[url.lastPathComponent] {
            return partFolderDestination(for: renamed, folder: chosen)
        }
        return partFolderDestination(for: renamed, mode: folderMode, ensemble: ensemble, numbered: numberedFolders)
    }

    /// The part folder `destination` puts it in, for showing; nil when it goes in the piece's
    /// own folder.
    func folderName(_ url: URL, _ destination: URL) -> String? {
        let folder = destination.deletingLastPathComponent()
        return samePlace(folder, home(url)) ? nil : folder.lastPathComponent
    }

    /// The part folder it leaves, when it moves out of one.
    func leaving(_ url: URL, _ destination: URL) -> String? {
        let from = url.deletingLastPathComponent()
        guard !samePlace(from, home(url)), !samePlace(from, destination.deletingLastPathComponent()) else { return nil }
        return from.lastPathComponent
    }

    /// A file whose name stays as it is but which moves into its folder (or back out of one);
    /// nil when it doesn't move.
    func movedIntoFolder(_ url: URL) -> RenameOperation? {
        let target = destination(url, url.lastPathComponent)
        guard !samePlace(target, url) else { return nil }
        let name = url.lastPathComponent
        if FileManager.default.fileExists(atPath: target.path) {
            return RenameOperation(originalURL: url, originalName: name, newName: name, type: .skip,
                                   statusOverride: "Target exists", folder: folderName(url, target))
        }
        return RenameOperation(originalURL: url, originalName: name, newName: name, newURL: target, type: .rename,
                               folder: folderName(url, target), fromFolder: leaving(url, target))
    }

    /// A file that stays where it is: shown in the part folder it's already in.
    func staying(_ url: URL, _ name: String, _ type: RenameOperationType) -> RenameOperation {
        RenameOperation(originalURL: url, originalName: name, newName: "", type: type, folder: folderName(url, url))
    }

    for fileURL in files {
        let filename = fileURL.lastPathComponent

        if excluded.contains(filename) {
            operations.append(RenameOperation(originalURL: fileURL, originalName: filename, newName: "", type: .excluded))
            continue
        }

        let filenameWithoutPrefix: String
        if rescan, let match = filename.range(of: "^\\d{2}[-_\\s]", options: .regularExpression) {
            filenameWithoutPrefix = String(filename[match.upperBound...])
        } else {
            filenameWithoutPrefix = filename
        }

        // Already numbered: left alone outside rescan mode (but moved into its folder).
        if !rescan, filename.range(of: "^\\d{2}[-_\\s]", options: .regularExpression) != nil {
            operations.append(movedIntoFolder(fileURL) ?? staying(fileURL, filename, .alreadyPrefixed))
            continue
        }

        if let manualNumber = manualOverrides[filename] {
            manuallyAssigned.append((manualNumber, fileURL, filename))
            continue
        }

        if let (rank, instrument) = detectScoreOrderInstrument(in: filenameWithoutPrefix, order: order) {
            if instrument == "score" {
                scoreFiles.append((fileURL, filename))
            } else {
                detectedFiles.append((rank, fileURL, filename))
            }
        } else {
            undetectedFiles.append((fileURL, filename))
        }
    }

    // Score order, then parts of one instrument by their names without any old number, in
    // natural order — so "Trombone 2" comes before "Trombone 3" (and "Trumpet 10" after
    // "Trumpet 9") even if they were numbered the other way round before.
    func partName(_ name: String) -> String { stripScoreOrderPrefix(from: name, rescan: rescan).clean }
    detectedFiles.sort {
        if $0.order != $1.order { return $0.order < $1.order }
        return partName($0.originalName).localizedStandardCompare(partName($1.originalName)) == .orderedAscending
    }
    let fileManager = FileManager.default

    /// One numbered rename, or a skip when it's already right or the target is taken.
    func numbered(_ url: URL, _ originalName: String, prefix: String) -> RenameOperation {
        let (cleanName, oldPrefix) = stripScoreOrderPrefix(from: originalName, rescan: rescan)
        let newFilename = "\(prefix)\(separator)\(cleanName)"
        let newURL = destination(url, newFilename)
        let folder = folderName(url, newURL)
        if oldPrefix == prefix {
            return movedIntoFolder(url) ?? staying(url, originalName, .skip)
        } else if fileManager.fileExists(atPath: newURL.path) && !samePlace(newURL, url) {
            return RenameOperation(originalURL: url, originalName: originalName, newName: newFilename,
                                   type: .skip, statusOverride: "Target exists", folder: folder)
        } else {
            return RenameOperation(originalURL: url, originalName: originalName, newName: newFilename, newURL: newURL,
                                   type: oldPrefix != nil ? .correct : .rename, oldPrefix: oldPrefix, folder: folder,
                                   fromFolder: leaving(url, newURL))
        }
    }

    // The score (every score file) gets 00.
    for (url, originalName) in scoreFiles {
        operations.append(numbered(url, originalName, prefix: "00"))
    }

    // Recognised parts from 01, skipping numbers reserved by manual overrides.
    let reservedNumbers = Set(manualOverrides.values)
    var nextNumber = 1
    for (_, url, originalName) in detectedFiles {
        while reservedNumbers.contains(nextNumber) && nextNumber < 100 { nextNumber += 1 }
        let prefix = String(format: "%02d", nextNumber)
        nextNumber += 1
        operations.append(numbered(url, originalName, prefix: prefix))
    }

    // Manual numbers, as given.
    manuallyAssigned.sort { $0.number < $1.number }
    for (number, url, originalName) in manuallyAssigned {
        let prefix = String(format: "%02d", number)
        let (cleanName, _) = stripScoreOrderPrefix(from: originalName, rescan: rescan)
        let newFilename = "\(prefix)\(separator)\(cleanName)"
        let newURL = destination(url, newFilename)
        let folder = folderName(url, newURL)
        if fileManager.fileExists(atPath: newURL.path) && !samePlace(newURL, url) {
            operations.append(RenameOperation(originalURL: url, originalName: originalName, newName: newFilename,
                                              type: .skip, statusOverride: "Target exists", folder: folder))
        } else {
            operations.append(RenameOperation(originalURL: url, originalName: originalName, newName: newFilename,
                                              newURL: newURL, type: .manual, folder: folder,
                                              fromFolder: leaving(url, newURL)))
        }
    }

    for (url, originalName) in undetectedFiles {
        operations.append(RenameOperation(originalURL: url, originalName: originalName, newName: "", type: .undetected))
    }

    // Excluded last, unrecognised first (so they're seen), then by new name.
    operations.sort { op1, op2 in
        let e1 = op1.type == .excluded, e2 = op2.type == .excluded
        if e1 && !e2 { return false }
        if !e1 && e2 { return true }
        let u1 = op1.type == .undetected, u2 = op2.type == .undetected
        if u1 && !u2 { return true }
        if !u1 && u2 { return false }
        if op1.newName.isEmpty && op2.newName.isEmpty { return op1.originalName < op2.originalName }
        if op1.newName.isEmpty { return false }
        if op2.newName.isEmpty { return true }
        return op1.newName < op2.newName
    }
    return operations
}

/// What renaming did.
struct RenameReport {
    var renamed: [(from: URL, to: URL)] = []
    var errors: [String] = []
    var sawPermissionError = false
    /// Nothing was tried: the folder is read-only (a cloud-sync placeholder, locked, or a
    /// read-only volume), where every move would fail.
    var blockedReadOnly = false
}

/// Carries out the planned renames that move a file (`.rename`, `.correct`, `.manual`), and
/// records them so they can be undone (`RenameJournal`; `append` adds to the journal, for the
/// later folders of a batch).
@discardableResult
func performRenames(_ operations: [RenameOperation], appendToJournal: Bool = false,
                    journalAt journalURL: URL? = RenameJournal.defaultURL) -> RenameReport {
    var report = RenameReport()
    let toRename = operations.filter { $0.type == .rename || $0.type == .correct || $0.type == .manual }
    guard !toRename.isEmpty else { return report }
    // The folder each file is in (its section folder may not exist yet, and is made in it).
    if !nonWritableParentDirectories(of: toRename.map { $0.originalURL }).isEmpty {
        report.blockedReadOnly = true
        return report
    }
    var createdFolders: [URL] = []
    defer { recordRenames(report.renamed, createdFolders: createdFolders, append: appendToJournal, journalAt: journalURL) }
    for operation in toRename {
        guard let newURL = operation.newURL else { continue }
        do {
            // Sorting into folders: the section/instrument folder may not exist yet.
            try createFolderRecording(newURL.deletingLastPathComponent(), into: &createdFolders)
            try FileManager.default.moveItem(at: operation.originalURL, to: newURL)
            report.renamed.append((operation.originalURL, newURL))
        } catch {
            if isFilePermissionError(error) { report.sawPermissionError = true }
            report.errors.append("\(operation.originalName): \(error.localizedDescription)")
        }
    }
    removeEmptiedPartFolders(report.renamed.map { $0.from.deletingLastPathComponent() })
    return report
}

/// Part folders (Woodwind, Brass…) left empty once their parts have moved out are removed,
/// so gathering parts back doesn't leave a trail of empty folders. Only folders with nothing
/// in them but Finder's own `.DS_Store`.
func removeEmptiedPartFolders(_ folders: [URL]) {
    let fm = FileManager.default
    for folder in Set(folders.map(\.standardizedFileURL)) where isPartFolderName(folder.lastPathComponent) {
        guard let items = try? fm.contentsOfDirectory(atPath: folder.path),
              items.allSatisfy({ $0 == ".DS_Store" }) else { continue }
        try? fm.removeItem(at: folder)
    }
}
