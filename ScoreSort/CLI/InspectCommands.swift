//
//  InspectCommands.swift
//  ScoreSort
//
//  `info` and `preview` — looking at a PDF before deciding what to do with it.
//
//  ScoreSort doesn't read text off pages, so an AI assistant reads the part names
//  itself from `preview` images (the top of each page is enough: that's where the
//  instrument name is).
//

import Foundation
import PDFKit
import AppKit
import ImageIO
import UniformTypeIdentifiers

extension ScoreSortCLI {

    // MARK: - info

    static var infoCommand: CommandSpec {
        CommandSpec(
            name: "info",
            summary: "Describe a PDF: pages, sizes, bookmarks, whether it's a double-page scan",
            help: """
            Usage: ScoreSort info <file.pdf> [--json]

            Describes a PDF before you split it:
              • page count, and each page's size (points) and rotation
              • bookmarks, as the parts they'd split into, with the file names ScoreSort
                would suggest from them (split --bookmarks uses these)
              • whether it looks like a scan of double pages — two pages side by side —
                which should go through `split-scans` first

            Example:
              ScoreSort info "Band Parts.pdf" --json
            """,
            valueOptions: [],
            flagOptions: [],
            run: { args in
                guard let path = args.positionals.first else { throw CommandError("Give the PDF to describe.") }
                return try runInfo(file: existingFile(path))
            })
    }

    static func runInfo(file: URL) throws -> CommandResult {
        let doc = try openPDFDocument(file)
        var pages: [[String: Any]] = []
        var lines: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox)
            let rotation = ((page.rotation % 360) + 360) % 360
            let size = rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
            let orientation = size.width > size.height ? "landscape" : "portrait"
            pages.append(["page": i + 1,
                          "width": rounded(size.width), "height": rounded(size.height),
                          "rotation": rotation, "orientation": orientation])
            lines.append("  \(i + 1): \(Int(size.width.rounded()))×\(Int(size.height.rounded())) pt, \(orientation)"
                         + (rotation == 0 ? "" : ", rotated \(rotation)°"))
        }

        let doublePages = isA3Landscape(doc) || looksLikeDoublePageScan(doc)
        let uniform = isUniformSheetScan(doc)
        var json: [String: Any] = [
            "ok": true,
            "file": file.path,
            "pageCount": doc.pageCount,
            "pages": pages,
            "looksLikeDoublePageScan": doublePages,
            "uniformSheets": uniform,
        ]

        var text = "\(file.lastPathComponent) — \(doc.pageCount) \(doc.pageCount == 1 ? "page" : "pages")\n" + lines.joined(separator: "\n")

        let baseName = file.deletingPathExtension().lastPathComponent
        if let sections = bookmarkSections(in: doc) {
            let names = bookmarkSplitNames(titles: sections.map(\.title), fallbackBaseName: baseName, style: .pieceAndTitle)
            json["bookmarks"] = sections.enumerated().map { i, s -> [String: Any] in
                ["title": s.title,
                 "pages": describePages(Array(s.startPage..<(s.startPage + s.pageCount))),
                 "firstPage": s.startPage + 1,
                 "pageCount": s.pageCount,
                 "suggestedName": names.suffixes[i]]
            }
            json["suggestedBaseName"] = names.baseName
            text += "\n\nBookmarks (\(sections.count) parts; base name “\(names.baseName)”):\n"
            text += sections.enumerated().map { i, s in
                "  pages \(describePages(Array(s.startPage..<(s.startPage + s.pageCount)))): \(s.title.isEmpty ? "(untitled)" : s.title) → \(names.suffixes[i].isEmpty ? "#\(i + 1)" : names.suffixes[i])"
            }.joined(separator: "\n")
        } else {
            json["bookmarks"] = [Any]()
            text += "\n\nNo bookmarks."
        }

        var hints: [String] = []
        if doublePages {
            hints.append(uniform
                ? "Every page is the same landscape sheet (e.g. A3 with two pages side by side): run `split-scans --same-cut` to cut them all down the middle."
                : "This looks like a scan of double pages: run `split-scans` first to cut them into single pages.")
        }
        if bookmarkSections(in: doc) != nil {
            hints.append("It has bookmarks: `split --bookmarks` splits and names the parts from them.")
        } else {
            hints.append("To find the parts, look at the tops of the pages: `preview --top`.")
        }
        json["hints"] = hints
        text += "\n\n" + hints.map { "→ " + $0 }.joined(separator: "\n")
        return CommandResult(text: text, json: json)
    }

    // MARK: - preview

    static var previewCommand: CommandSpec {
        CommandSpec(
            name: "preview",
            summary: "Save page images — the top of each page is enough to read the part name",
            help: """
            Usage: ScoreSort preview <file.pdf> --out <folder> [--pages 1-8] [--top] [--sheet]
                                     [--width 900] [--format jpg|png] [--json]

            Saves an image of each page so you can see what's on it — ScoreSort doesn't
            read text, so this is how to find out which part each page belongs to.

              --out      Folder for the images (created if needed).
              --pages    Which pages, e.g. 1-3,7 or 5- (default: all).
              --top      Only the top third of each page — where the instrument name
                         and title are. Much smaller, and usually all you need.
              --sheet    Put the pages side by side in one labelled image (a contact
                         sheet; several if there are many pages) instead of one image
                         per page — the quickest way to look through a whole PDF.
                         Best with --top.
              --width    Image width in pixels (default 900; with --sheet, each page's
                         width in the sheet, default 600 with --top and 400 without).
              --format   jpg (default, smaller) or png.

            Images are named <file>-p001.jpg, <file>-p002.jpg, … (with -top for --top);
            sheets <file>-sheet1.jpg, <file>-sheet2.jpg, ….

            Example:
              ScoreSort preview "Band Parts.pdf" --top --sheet --out /tmp/previews
            """,
            valueOptions: ["out", "pages", "width", "format"],
            flagOptions: ["top", "sheet", "overwrite"],
            run: { args in
                guard let path = args.positionals.first else { throw CommandError("Give the PDF to preview.") }
                let format = args.value("format") ?? "jpg"
                guard ["jpg", "jpeg", "png"].contains(format) else { throw CommandError("--format is jpg or png.") }
                return try runPreview(file: existingFile(path),
                                      folder: outputFolder(args.required("out")),
                                      pages: args.value("pages"),
                                      topOnly: args.has("top"),
                                      sheet: args.has("sheet"),
                                      width: args.int("width") ?? (args.has("sheet") ? (args.has("top") ? 600 : 400) : 900),
                                      png: format == "png")
            })
    }

    /// The share of a page's height `--top` keeps.
    static let topFraction: CGFloat = 1.0 / 3.0

    static func runPreview(file: URL, folder: URL, pages pageList: String?, topOnly: Bool,
                           sheet: Bool = false, width: Int, png: Bool) throws -> CommandResult {
        guard (100...4000).contains(width) else { throw CommandError("--width must be between 100 and 4000.") }
        let doc = try openPDFDocument(file)
        let pages = try parsePageList(pageList ?? "all", pageCount: doc.pageCount)
        guard !pages.isEmpty else { throw CommandError("No pages to preview.") }

        // Render off the main actor, in parallel; a page PDFKit built in memory (no
        // Core Graphics page) falls back to a PDFKit thumbnail.
        let sources = pages.map { doc.page(at: $0)?.scanRenderSource }
        let rendered = renderScans(sources.compactMap { $0 }, width: { _ in width })
        var renderedIterator = rendered.makeIterator()

        let base = file.deletingPathExtension().lastPathComponent
        let ext = png ? "png" : "jpg"
        var written: [URL] = []
        var entries: [[String: Any]] = []
        var problems: [String] = []
        var tiles: [(page: Int, image: CGImage)] = []
        for (k, pageIndex) in pages.enumerated() {
            var image: CGImage?
            if sources[k] != nil {
                image = renderedIterator.next() ?? nil
            } else if let page = doc.page(at: pageIndex) {
                image = page.thumbnail(of: NSSize(width: width, height: width * 4), for: .cropBox)
                    .cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            guard var final = image else { problems.append("Page \(pageIndex + 1) couldn't be rendered."); continue }
            if topOnly {
                // A third of the page — but never taller than half its width, so a narrow
                // strip (a sliver of scanner background) doesn't come out as a tall tile.
                let h = Int(min(CGFloat(final.height) * topFraction, CGFloat(final.width) * 0.5).rounded())
                if let cropped = final.cropping(to: CGRect(x: 0, y: 0, width: final.width, height: max(1, h))) {
                    final = cropped
                }
            }
            if sheet {
                tiles.append((pageIndex, final))
                continue
            }
            let name = String(format: "%@-p%03d%@.%@", base, pageIndex + 1, topOnly ? "-top" : "", ext)
            let url = folder.appendingPathComponent(name)
            do {
                try writeImage(final, to: url, png: png)
                written.append(url)
                entries.append(["page": pageIndex + 1, "file": url.path])
            } catch {
                problems.append("Page \(pageIndex + 1): \((error as? CommandError)?.message ?? error.localizedDescription)")
            }
        }

        if sheet {
            // A handful of rows per sheet keeps each image readable at a glance.
            let perSheet = topOnly ? 24 : 12
            let chunks = stride(from: 0, to: tiles.count, by: perSheet).map { Array(tiles[$0..<min($0 + perSheet, tiles.count)]) }
            for (n, chunk) in chunks.enumerated() {
                guard let image = contactSheet(chunk, columns: topOnly ? 3 : 4) else {
                    problems.append("Sheet \(n + 1) couldn't be drawn."); continue
                }
                let url = folder.appendingPathComponent("\(base)-sheet\(n + 1).\(ext)")
                do {
                    try writeImage(image, to: url, png: png)
                    written.append(url)
                    entries.append(["pages": describePages(chunk.map(\.page)), "file": url.path])
                } catch {
                    problems.append("Sheet \(n + 1): \((error as? CommandError)?.message ?? error.localizedDescription)")
                }
            }
        }

        var text = "Saved \(written.count) \(written.count == 1 ? "image" : "images") of \(file.lastPathComponent) to \(folder.path)"
        if !problems.isEmpty { text += "\n" + problems.map { "Problem: " + $0 }.joined(separator: "\n") }
        let ok = problems.isEmpty
        return CommandResult(text: text,
                             json: ["ok": ok, "images": entries, "problems": problems, "folder": folder.path],
                             exitCode: ok ? 0 : 1,
                             images: written)
    }

    /// Page images side by side in rows, each under a large "p12" label, on grey — one
    /// image an AI (or a person) can scan for part names.
    static func contactSheet(_ tiles: [(page: Int, image: CGImage)], columns: Int) -> CGImage? {
        guard !tiles.isEmpty else { return nil }
        let gap = 12, label = 34
        let tileWidth = tiles.map(\.image.width).max() ?? 0
        let rows = stride(from: 0, to: tiles.count, by: columns).map { Array(tiles[$0..<min($0 + columns, tiles.count)]) }
        let rowHeights = rows.map { ($0.map(\.image.height).max() ?? 0) + label }
        let width = gap + min(columns, tiles.count) * (tileWidth + gap)
        let height = gap + rowHeights.reduce(0) { $0 + $1 + gap }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.82, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        defer { NSGraphicsContext.current = previous }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 24),
            .foregroundColor: NSColor(calibratedRed: 0.75, green: 0, blue: 0, alpha: 1),
        ]
        var top = height - gap   // Core Graphics counts up from the bottom
        for (r, row) in rows.enumerated() {
            for (c, tile) in row.enumerated() {
                let x = gap + c * (tileWidth + gap)
                NSAttributedString(string: "p\(tile.page + 1)", attributes: attributes)
                    .draw(at: CGPoint(x: x + 2, y: top - label + 3))
                let imageTop = top - label
                ctx.draw(tile.image, in: CGRect(x: x, y: imageTop - tile.image.height,
                                                width: tile.image.width, height: tile.image.height))
            }
            top -= rowHeights[r] + gap
        }
        return ctx.makeImage()
    }

    static func writeImage(_ image: CGImage, to url: URL, png: Bool) throws {
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw CommandError("Couldn't create \(url.path).")
        }
        let props: [CFString: Any] = png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CommandError("Couldn't write \(url.path).") }
    }
}
