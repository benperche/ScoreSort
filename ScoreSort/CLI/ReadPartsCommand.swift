//
//  ReadPartsCommand.swift
//  ScoreSort
//
//  `read-parts` — the part names read off the tops of a PDF's pages, and where the parts
//  start (#17): Suggest Splits for the command line and AI assistants. Read-only. The reading
//  is `Logic/PartRecognition.swift`, the same as the Split tab's.
//

import Foundation
import PDFKit

extension ScoreSortCLI {

    static var readPartsCommand: CommandSpec {
        CommandSpec(
            name: "read-parts",
            summary: "Read the part names at the tops of a PDF's pages, and suggest where the parts start",
            help: """
            Usage: ScoreSort read-parts <file.pdf> [--pages 1-8] [--ensemble band|jazz|orchestra] [--json]

            Reads the top of each page with the Mac's own text recognition (nothing is sent
            anywhere) and reports:
              • each page's part name ("Score" for a page of a score), and the text read
                at its top;
              • the parts it suggests: where each starts and its name, ready for `split`.
                When the piece's title is repeated at the start of each part, parts start
                on those pages, even where the name couldn't be read (shown as "").

            Recognition can be wrong, especially on handwritten or poor scans: check the
            names with `preview --top --sheet` before splitting. Pages that can't be read
            are reported; with too few read, nothing is suggested.

              --pages     Only read these pages, e.g. 1-3,7 (no parts are suggested then).
              --ensemble  Whose instrument names to read the parts as (default band; it
                          matters for "Baritone": a saxophone in jazz).

            Example:
              ScoreSort read-parts "Band Parts.pdf" --ensemble jazz --json
            """,
            valueOptions: ["pages", "ensemble"],
            flagOptions: [],
            run: { args in
                guard let path = args.positionals.first else { throw CommandError("Give the PDF to read.") }
                let ensemble = try args.value("ensemble").map(parseEnsemble) ?? .band
                InstrumentOrders.setup()
                return try runReadParts(file: existingFile(path), pages: args.value("pages"),
                                        order: InstrumentOrders.getOrder(for: ensemble))
            })
    }

    /// Reads `file`'s pages (all, or `pageList`) and reports what `readParts` makes of them.
    /// `recognise` reads the pages; tests pass their own lines.
    static func runReadParts(file: URL, pages pageList: String?, order: [String],
                             recognise: ([ScanRenderSource?]) -> [[RecognizedLine]?] = { recognizePages($0) }) throws -> CommandResult {
        let doc = try openPDFDocument(file)
        let pages = try parsePageList(pageList ?? "all", pageCount: doc.pageCount)
        guard !pages.isEmpty else { throw CommandError("No pages to read.") }
        let lines = recognise(pages.map { doc.page(at: $0)?.scanRenderSource })
        let reading = readParts(lines, order: order)
        let whole = pageList == nil

        var pageEntries: [[String: Any]] = []
        var text = "\(file.lastPathComponent) — read \(reading.pagesRead) of \(pages.count) \(pages.count == 1 ? "page" : "pages")\n"
        for (k, pageIndex) in pages.enumerated() {
            var entry: [String: Any] = ["page": pageIndex + 1, "read": lines[k] != nil]
            let name = reading.pageNames[k]
            entry["partName"] = name ?? NSNull()
            let top = (lines[k] ?? []).filter { $0.box.minY < 0.25 && $0.confidence >= 0.3 }
                .sorted { $0.box.minY < $1.box.minY }.prefix(6).map(\.text)
            entry["topText"] = Array(top)
            pageEntries.append(entry)
            let shown = lines[k] == nil ? "(couldn't be read)" : (name ?? "—")
            text += "  p\(pageIndex + 1): \(shown)" + (top.isEmpty ? "" : "   [\(top.joined(separator: " · "))]") + "\n"
        }

        var json: [String: Any] = ["ok": true, "file": file.path, "pageCount": doc.pageCount,
                                   "pagesRead": reading.pagesRead, "pages": pageEntries]
        var hints: [String] = []
        if !whole {
            hints.append("Only some pages were read, so no parts are suggested. Leave out --pages to suggest parts.")
        } else if let problem = reading.problem {
            json["problem"] = problem
            text += "\n" + problem + "\n"
            hints.append("Look at the tops of the pages instead: `preview --top --sheet`.")
        } else {
            let starts = reading.parts.map(\.startPage)
            let ends = starts.dropFirst().map { $0 } + [pages.count]
            let parts: [[String: Any]] = zip(reading.parts, ends).map { part, end in
                ["pages": describePages(Array(part.startPage..<end)), "firstPage": part.startPage + 1,
                 "pageCount": end - part.startPage, "name": part.name]
            }
            json["parts"] = parts
            json["foundBy"] = reading.method == "titles" ? "titles" : "names"
            if reading.parts.count == 1 {
                text += "\nIt looks like a single part" + (reading.parts[0].name.isEmpty ? "." : ": \(reading.parts[0].name).") + "\n"
            } else {
                text += "\nSuggested parts (\(reading.parts.count)), found by "
                    + (reading.method == "titles" ? "the title at the start of each part" : "where the name changes") + ":\n"
                text += zip(reading.parts, parts).map { part, entry in
                    "  pages \(entry["pages"] as? String ?? ""): \(part.name.isEmpty ? "(name not read)" : part.name)"
                }.joined(separator: "\n") + "\n"
            }
            if reading.parts.contains(where: { $0.name.isEmpty }) {
                hints.append("Some names couldn't be read: look at those pages with `preview --pages … --top`.")
            }
            hints.append("Names are read by text recognition and can be wrong: check them with `preview --top --sheet` before `split`.")
        }
        json["hints"] = hints
        text += "\n" + hints.map { "→ " + $0 }.joined(separator: "\n")
        return CommandResult(text: text, json: json)
    }
}
