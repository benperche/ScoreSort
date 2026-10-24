//
//  FindCommands.swift
//  ScoreSort
//
//  `find` — locating the files someone means. People talk about "the Holst scan in my
//  Downloads", not paths, and an AI chat app can't hand ScoreSort a dropped file's path
//  (dragging a PDF into the chat uploads its contents). So ScoreSort looks for PDFs, images
//  and folders by name in the usual places — Downloads, Desktop, Documents — newest first.
//

import Foundation
import PDFKit

extension ScoreSortCLI {

    static var findCommand: CommandSpec {
        CommandSpec(
            name: "find",
            summary: "Find PDFs, images or folders by name in Downloads, Desktop and Documents",
            help: """
            Usage: ScoreSort find [WORDS…] [--in FOLDER]… [--kind pdf|image|folder|any]
                                  [--limit N] [--json]

            Finds the files someone is talking about — "the Holst scan", "my Junior Band
            parts folder" — so you have a path to work with. Every word must appear in the
            name (in any order, ignoring case and punctuation). Newest first. With no words,
            lists the most recent PDFs.

              --in      Where to look (repeatable). Default: Downloads, Desktop, Documents.
              --kind    pdf (default), image (photos and scans as pictures), folder, or any.
              --limit   How many results (default 20).

            Folders show how many PDFs they hold; PDFs show their page count. Looks a few
            levels deep and skips app, system and developer folders, so it stays quick.

            Examples:
              ScoreSort find holst scan
              ScoreSort find junior band --kind folder
              ScoreSort find --in ~/Music/Scans
            """,
            valueOptions: ["in", "kind", "limit"],
            flagOptions: [],
            run: { args in
                let kind = args.value("kind") ?? "pdf"
                guard ["pdf", "image", "folder", "any"].contains(kind) else {
                    throw CommandError("--kind is pdf, image, folder or any.")
                }
                return try runFind(words: args.positionals, folders: args.all("in"), kind: kind,
                                   limit: args.int("limit") ?? 20)
            })
    }

    /// Folders searched when none are given.
    static var defaultSearchFolders: [URL] {
        let fm = FileManager.default
        return [FileManager.SearchPathDirectory.downloadsDirectory, .desktopDirectory, .documentDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
    }

    /// Folder names never worth descending into when looking for music.
    private static let skippedFolders: Set<String> = [
        "node_modules", "DerivedData", "Library", "Pods", "build", ".build", "venv", ".venv",
    ]

    /// Lower-cased words, with punctuation (`_`, `-`, `.`, …) treated as spaces.
    static func searchWords(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// True when every query word appears in `name` (as the start of one of its words, or
    /// anywhere inside it for words of 4+ letters — "clar" finds "Clarinet", "sax" "Saxes").
    static func nameMatches(_ name: String, words query: [String]) -> Bool {
        guard !query.isEmpty else { return true }
        let nameWords = searchWords(name)
        let joined = nameWords.joined(separator: " ")
        return query.allSatisfy { word in
            nameWords.contains { $0.hasPrefix(word) } || (word.count >= 4 && joined.contains(word))
        }
    }

    /// True for a file kept only in the cloud (iCloud Drive's optimised storage, Google Drive,
    /// Dropbox…): it's listed, but reading it would download it first.
    static func isCloudOnly(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & 0x4000_0000 != 0   // SF_DATALESS
    }

    static func runFind(words: [String], folders: [String], kind: String, limit: Int,
                        timeLimit: TimeInterval = 4) throws -> CommandResult {
        guard (1...200).contains(limit) else { throw CommandError("--limit is between 1 and 200.") }
        let query = words.flatMap(searchWords)
        let roots: [URL] = folders.isEmpty ? defaultSearchFolders : try folders.map { path in
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            guard urlIsDirectory(url) else { throw CommandError("\(url.path) isn't a folder.") }
            return url
        }

        let wantFolders = kind == "folder" || kind == "any"
        let wantPDFs = kind == "pdf" || kind == "any"
        let wantImages = kind == "image" || kind == "any"
        let deadline = Date().addingTimeInterval(timeLimit)
        var found: [(url: URL, isFolder: Bool, modified: Date)] = []
        var timedOut = false
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .creationDateKey]
        let now = Date()
        /// The modification date — unless it's in the future (some files carry dates decades
        /// ahead, which would put them first forever), then the creation date.
        func sortDate(_ values: URLResourceValues?) -> Date {
            let limit = now.addingTimeInterval(86_400)
            if let modified = values?.contentModificationDate, modified <= limit { return modified }
            if let created = values?.creationDate, created <= limit { return created }
            return .distantPast
        }

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if Date() > deadline { timedOut = true; break }
                let values = try? url.resourceValues(forKeys: Set(keys))
                let isFolder = values?.isDirectory == true && values?.isPackage != true
                if isFolder {
                    if enumerator.level >= 5 || skippedFolders.contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    if wantFolders && nameMatches(url.lastPathComponent, words: query) {
                        found.append((url, true, sortDate(values)))
                    }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                let isPDF = ext == "pdf"
                let isImage = supportedImageExtensions.contains(ext)
                guard (isPDF && wantPDFs) || (isImage && wantImages) else { continue }
                guard nameMatches(url.deletingPathExtension().lastPathComponent, words: query) else { continue }
                found.append((url, false, sortDate(values)))
            }
            if timedOut { break }
        }

        found.sort { $0.modified > $1.modified }
        let shown = found.prefix(limit)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        var entries: [[String: Any]] = []
        var lines: [String] = []
        for item in shown {
            var entry: [String: Any] = ["path": item.url.path, "name": item.url.lastPathComponent,
                                        "modified": formatter.string(from: item.modified)]
            var detail: String
            if item.isFolder {
                let pdfs = ((try? FileManager.default.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil,
                                                                           options: [.skipsHiddenFiles])) ?? [])
                    .filter { pageableFileExtensions.contains($0.pathExtension.lowercased()) }.count
                entry["kind"] = "folder"
                entry["files"] = pdfs
                detail = "folder, \(pdfs) \(pdfs == 1 ? "file" : "files")"
            } else if isCloudOnly(item.url) {
                // Opening it would make macOS download it from iCloud or Google Drive first.
                entry["kind"] = item.url.pathExtension.lowercased() == "pdf" ? "pdf" : "image"
                entry["inCloudOnly"] = true
                detail = "in the cloud, not downloaded"
            } else if item.url.pathExtension.lowercased() == "pdf" {
                let pages = PDFDocument(url: item.url)?.pageCount ?? 0
                entry["kind"] = "pdf"
                entry["pages"] = pages
                detail = "\(pages) \(pages == 1 ? "page" : "pages")"
            } else {
                entry["kind"] = "image"
                detail = "image"
            }
            entries.append(entry)
            lines.append("  \(item.url.path)  (\(detail), \(formatter.string(from: item.modified)))")
        }

        let place = folders.isEmpty ? "Downloads, Desktop and Documents" : roots.map(\.path).joined(separator: ", ")
        var text: String
        if shown.isEmpty {
            text = "Nothing matching “\(words.joined(separator: " "))” in \(place)."
            text += query.isEmpty ? "" : " Try fewer words, --kind any, or --in another folder."
        } else {
            text = "\(found.count) found in \(place)" + (found.count > shown.count ? " (newest \(shown.count) shown)" : "") + ":\n"
            text += lines.joined(separator: "\n")
        }
        if timedOut { text += "\n(Stopped looking after \(Int(timeLimit)) seconds — give --in a narrower folder to look further.)" }
        return CommandResult(text: text, json: ["ok": true, "results": entries, "total": found.count,
                                                "searched": roots.map(\.path), "stoppedEarly": timedOut])
    }
}
