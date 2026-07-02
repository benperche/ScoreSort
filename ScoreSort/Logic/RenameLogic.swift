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
