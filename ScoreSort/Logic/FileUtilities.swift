//
//  FileUtilities.swift
//  ScoreSort
//
//  Shared file-path and validation utilities used across every tab — default output
//  directory, PDF filename validation, read-only/permission detection, and page-range
//  formatting. No view state; unit-tested directly.
//

import Foundation

// MARK: - Output paths, filename validation & permissions

/// Shared validation used by SplitNamingStageView and SplitFileNamingRow.
/// The folder a save/open output dialog should default to: the folder containing the
/// file the user loaded, so output lands next to the source rather than the last-used
/// location. Returns nil when there's no known source (the panel then keeps its default).
/// Applied app-wide to every output dialog (combiner, splitter, rotator).
func outputDirectory(forSourceFile url: URL?) -> URL? {
    url?.deletingLastPathComponent()
}

/// Expands a mixed list of file and folder URLs into a flat, name-sorted list of files whose
/// extension is in `extensions` (lowercase, no dot). Folders are enumerated **recursively**;
/// anything else is ignored. Shared by every drop/open path that accepts folders — the
/// Combine tab (PDFs + images) and the Stamp tab (PDFs only) — so dropping a folder behaves
/// the same everywhere.
func expandToFiles(_ urls: [URL], extensions: Set<String>) -> [URL] {
    var result: [URL] = []
    let fm = FileManager.default
    for url in urls {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
        if isDir.boolValue {
            guard let enumerator = fm.enumerator(at: url,
                                                 includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let fileURL as URL in enumerator
            where extensions.contains(fileURL.pathExtension.lowercased()) {
                result.append(fileURL)
            }
        } else if extensions.contains(url.pathExtension.lowercased()) {
            result.append(url)
        }
    }
    return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func pdfFilenameError(for text: String) -> String? {
    guard !text.isEmpty else { return nil }
    let illegal = CharacterSet(charactersIn: "/:\\\0")
    if text.unicodeScalars.contains(where: { illegal.contains($0) }) {
        return "Cannot contain / : or \\"
    }
    return nil
}

/// Returns the distinct parent directories of `urls` that the app cannot write to.
/// Renaming is a move *within* a directory, so it needs write access to that directory.
/// Read-only volumes, locked folders, and cloud-sync placeholders (Dropbox, Google Drive,
/// iCloud) are commonly readable but not writable — files list fine but every rename fails.
/// An empty result means every destination directory is writable.
func nonWritableParentDirectories(of urls: [URL]) -> [URL] {
    var seenPaths = Set<String>()
    var result: [URL] = []
    for url in urls {
        let dir = url.deletingLastPathComponent()
        guard seenPaths.insert(dir.path).inserted else { continue }
        if !FileManager.default.isWritableFile(atPath: dir.path) {
            result.append(dir)
        }
    }
    return result
}

/// Detects whether a thrown file-system error is a permission / read-only-location problem
/// (as opposed to, say, a name collision). Used to decide when to show the friendly
/// "this location is read-only" guidance instead of a raw system error string.
func isFilePermissionError(_ error: Error) -> Bool {
    let ns = error as NSError
    func isReadOnlyPOSIX(_ code: Int) -> Bool {
        return code == Int(EACCES) || code == Int(EPERM) || code == Int(EROFS)
    }
    if ns.domain == NSCocoaErrorDomain {
        if ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           isReadOnlyPOSIX(underlying.code) {
            return true
        }
    }
    if ns.domain == NSPOSIXErrorDomain, isReadOnlyPOSIX(ns.code) {
        return true
    }
    return false
}

/// Standard, actionable message shown when files can't be renamed because the location is
/// read-only — most often a cloud-synced folder (Dropbox, Google Drive, iCloud) or a
/// locked / read-only folder.
func readOnlyLocationMessage(folderName: String?) -> String {
    let place = folderName.map { "“\($0)”" } ?? "this location"
    return """
    ScoreSort doesn’t have permission to rename files in \(place).

    This usually happens with cloud-synced folders (Dropbox, Google Drive, iCloud) or folders that are locked or read-only.

    To fix it, try either:
    • Copy the files into your Documents or Desktop folder, then drag them in from there, or
    • In Finder, select the folder, choose File ▸ Get Info, make sure “Locked” is off, and under Sharing & Permissions set your user to “Read & Write”.
    """
}

/// Formats a set of 0-based page indices into a compact human-readable range string.
/// E.g. {0,1,2,6,7,8,9} → "pp.1–3, 7–10"
func formatSkippedPageRanges(_ pages: Set<Int>) -> String {
    guard !pages.isEmpty else { return "" }
    let sorted = pages.sorted()
    var ranges: [(Int, Int)] = []
    var start = sorted[0], end = sorted[0]
    for p in sorted.dropFirst() {
        if p == end + 1 { end = p }
        else { ranges.append((start, end)); start = p; end = p }
    }
    ranges.append((start, end))
    return ranges.map { s, e in s == e ? "p.\(s+1)" : "pp.\(s+1)–\(e+1)" }.joined(separator: ", ")
}
