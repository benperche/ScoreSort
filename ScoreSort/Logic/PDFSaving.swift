//
//  PDFSaving.swift
//  ScoreSort
//
//  Saving a PDF, and saying *why* when it can't be done.
//
//  `PDFDocument.write(to:)` answers only true or false, so a failure used to surface as a bare
//  "Failed to create PDF" — whether a source file had gone missing, macOS had refused to let the
//  app read it, or the destination wouldn't take the file. These helpers keep the real reason.
//

import PDFKit

/// Writes `doc` to `url`. Returns `nil` on success, or a message saying what went wrong.
func savePDFDocument(_ doc: PDFDocument, to url: URL) -> String? {
    // An empty document can't be written at all, and would otherwise fail with no explanation.
    guard doc.pageCount > 0 else { return "There were no pages to save." }
    guard let data = doc.dataRepresentation() else {
        return "ScoreSort couldn't put the pages together into a PDF. One of the files may be damaged — try opening each one in Preview to find it."
    }
    do {
        try data.write(to: url, options: .atomic)
        return nil
    } catch {
        // An atomic write saves a temporary copy beside the destination and renames it into
        // place. Some cloud folders refuse the rename but accept a plain write.
        if (try? data.write(to: url)) != nil { return nil }
        return saveFailureMessage(for: error, at: url)
    }
}

/// A message for a destination that wouldn't accept the file.
func saveFailureMessage(for error: Error, at url: URL) -> String {
    let folder = url.deletingLastPathComponent().lastPathComponent
    if isFilePermissionError(error) {
        return """
        ScoreSort isn't allowed to save into “\(folder)”.

        This usually means the folder is read-only for you — common with shared cloud folders. Save to your Desktop or Documents folder instead, then move the file across in Finder.
        """
    }
    return "ScoreSort couldn't save “\(url.lastPathComponent)” in “\(folder)”.\n\n\(error.localizedDescription)"
}

/// Why an input file that opened fine when it was added can't be read now — measured by reading
/// it again, so the message carries macOS's own reason rather than a guess.
func unreadableFileReason(_ url: URL) -> String {
    do {
        let data = try Data(contentsOf: url)
        if url.pathExtension.lowercased() == "pdf", PDFDocument(data: data) == nil {
            return "it isn't a PDF ScoreSort can open — it may be damaged"
        }
        return "it couldn't be opened"
    } catch {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError {
            return "it isn't there any more — it may have been moved, renamed or deleted since you added it"
        }
        if isFilePermissionError(error) {
            return "macOS didn't let ScoreSort read it"
        }
        return error.localizedDescription
    }
}

/// The message shown when some input files couldn't be read while building the output. Nothing
/// is saved in that case: a set of parts with some silently missing is worse than no file.
func unreadableFilesMessage(_ urls: [URL]) -> String {
    let shown = 8
    var lines = urls.prefix(shown).map { "• \($0.lastPathComponent): \(unreadableFileReason($0))." }
    if urls.count > shown { lines.append("…and \(urls.count - shown) more.") }
    let them = urls.count == 1 ? "it" : "them"
    var message = """
    ScoreSort couldn't read \(urls.count == 1 ? "this file" : "these files"), so nothing was created:

    \(lines.joined(separator: "\n"))

    Remove \(them) from the list, or add \(them) again from where \(urls.count == 1 ? "it is" : "they are") now.
    """
    if urls.contains(where: { $0.path.contains("/Library/CloudStorage/") }) {
        message += " Files in Google Drive, OneDrive or Dropbox are read again when you save, so check the folder is still syncing and available on this Mac."
    }
    return message
}
