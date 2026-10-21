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
func expandToRenameJobFolders(_ folders: [URL]) -> [URL] {
    var jobs: [URL] = []
    func collect(_ folder: URL) {
        if folderHasDirectRenamableFiles(folder) { jobs.append(folder) }
        let subs = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        for sub in subs where urlIsDirectory(sub) { collect(sub) }
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
