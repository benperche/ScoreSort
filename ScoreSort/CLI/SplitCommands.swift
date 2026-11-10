//
//  SplitCommands.swift
//  ScoreSort
//
//  `split` (a PDF into named part files — the Split tab's Steps 1–3) and `split-scans`
//  (cutting two-page scans into single pages — "Split Double Pages").
//
//  Both go through the same functions as the app — `writeSplitFiles`,
//  `scoreOrderSorted`/`scoreOrderFileNames`, `analyseScanSources`/`splitScans` — so a
//  file split here is identical to one split in the window.
//

import Foundation
import PDFKit

extension ScoreSortCLI {

    // MARK: - split

    static var splitCommand: CommandSpec {
        CommandSpec(
            name: "split",
            summary: "Split a PDF into named part files, optionally numbered in score order and stamped",
            help: """
            Usage: ScoreSort split <file.pdf> --out <folder> (--part PAGES=NAME … | --bookmarks)
                                   [--base NAME] [--separator TEXT] [--skip PAGES]
                                   [--score-order band|jazz|orchestra] [--prefix-separator TEXT]
                                   [--stamp NAME] [--stamp-scope first|every]
                                   [--folders section|instrument] [--ensemble band|jazz|orchestra]
                                   [--dry-run] [--overwrite] [--json]

            Splits a PDF into one file per part — the Split tab's Steps 1–3.

            Choosing the parts (one way or the other):
              --part "PAGES=NAME"   One part: its pages and its name. Repeat for each part.
                                    Pages are 1-based: 1-2, or 3,5 for pages that aren't
                                    next to each other. e.g. --part "1-2=Flute 1"
              --bookmarks           Use the PDF's bookmarks as the parts, named from their
                                    titles (see `info`). --bookmark-names title uses each
                                    title whole instead of "piece name + part".
            Pages in no part, or listed in --skip, aren't saved (and are reported).

            Naming — each file is "<base><separator><part name>.pdf":
              --base         Shared start of every name, usually the piece (e.g. "Holst - First Suite").
                             Leave it out to name files by the part alone.
              --separator    Between base and part name (default: the app's setting, " - ").

            Score order (the Split tab's Step 3):
              --score-order  Number the files in score order for a band, jazz band or
                             orchestra: the score is 00, then 01, 02… in the ensemble's
                             instrument order (your custom order from ScoreSort's settings).
                             Parts whose names match no instrument are numbered last and
                             reported, so you can rename them.
              --prefix-separator  Between the number and the name (default " - ").

            Stamping:
              --stamp        Stamp a saved stamp design onto each part (see `stamps`).
              --stamp-scope  first (default): each part's first page; every: every page.

            Sorting into folders (so each group of players can be given just their folder):
              --folders      section: Woodwind, Brass, Percussion, Strings, Rhythm (piano,
                             guitar, bass guitar) — for a jazz band Saxophones, Trumpets,
                             Trombones, Rhythm. instrument: Flute, Clarinet, Alto Saxophone…
                             Folders are made inside --out; the score and unrecognised
                             parts stay at the top. off (the default) puts every file in --out.
              --ensemble     The ensemble the sections follow (default: --score-order's, else band).

              --dry-run      Show the files that would be written; write nothing.
              --overwrite    Replace files that already exist (otherwise it stops).

            Examples:
              ScoreSort split "Band.pdf" --out Parts --base "Holst - First Suite" \\
                  --part "1-4=Score" --part "5-6=Flute 1" --part "7-8=Clarinet 1" \\
                  --score-order band --dry-run
              ScoreSort split "Combined.pdf" --out Parts --bookmarks
            """,
            valueOptions: ["out", "part", "base", "separator", "skip", "score-order", "prefix-separator",
                           "stamp", "stamp-scope", "bookmark-names", "folders", "ensemble"],
            flagOptions: ["bookmarks", "dry-run", "overwrite"],
            run: { args in
                guard let path = args.positionals.first else { throw CommandError("Give the PDF to split.") }
                return try runSplit(file: existingFile(path), options: SplitOptions(args))
            })
    }

    struct SplitOptions {
        var out: String
        /// (pages text, name) per part, in the order given.
        var parts: [(pages: String, name: String)] = []
        var useBookmarks = false
        var bookmarkStyle: BookmarkNameStyle = .pieceAndTitle
        var base: String? = nil
        var separator: String? = nil
        var skip: String? = nil
        var scoreOrder: EnsembleType? = nil
        var prefixSeparator: String? = nil
        var stamp: String? = nil
        var stampScope: StampScope = .firstPageOfEachPart
        var folders: PartFolderMode = .off
        var ensemble: EnsembleType? = nil
        var dryRun = false
        var overwrite = false

        init(out: String) { self.out = out }

        init(_ args: CommandArguments) throws {
            out = try args.required("out")
            for spec in args.all("part") {
                guard let eq = spec.firstIndex(of: "=") else {
                    throw CommandError("--part needs PAGES=NAME, e.g. \"1-2=Flute 1\" (got “\(spec)”).")
                }
                let pages = spec[..<eq].trimmingCharacters(in: .whitespaces)
                let name = spec[spec.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                parts.append((pages, name))
            }
            useBookmarks = args.has("bookmarks")
            if let style = args.value("bookmark-names") {
                switch style {
                case "piece": bookmarkStyle = .pieceAndTitle
                case "title": bookmarkStyle = .titleOnly
                default: throw CommandError("--bookmark-names is piece or title.")
                }
            }
            base = args.value("base")
            separator = args.value("separator")
            skip = args.value("skip")
            if let ensemble = args.value("score-order") { scoreOrder = try parseEnsemble(ensemble) }
            prefixSeparator = args.value("prefix-separator")
            stamp = args.value("stamp")
            stampScope = try parseStampScope(args.value("stamp-scope"), default: .firstPageOfEachPart)
            folders = try parsePartFolderMode(args.value("folders"))
            if let ensemble = args.value("ensemble") { self.ensemble = try parseEnsemble(ensemble) }
            dryRun = args.has("dry-run")
            overwrite = args.has("overwrite")
        }
    }

    static func runSplit(file: URL, options: SplitOptions) throws -> CommandResult {
        let doc = try openPDFDocument(file)
        let folder = try outputFolder(options.out, create: !options.dryRun)
        let separator = options.separator
            ?? UserDefaults.standard.string(forKey: "filenameSeparator") ?? " - "
        var warnings: [String] = []

        // 1. The parts: pages and names.
        var base = fileNameSafe(options.base ?? "")
        var parts: [(pages: [Int], name: String)] = []
        if options.useBookmarks {
            guard options.parts.isEmpty else { throw CommandError("Use --part or --bookmarks, not both.") }
            guard let sections = bookmarkSections(in: doc) else {
                throw CommandError("\(file.lastPathComponent) has no bookmarks to split at — use --part instead.")
            }
            let names = bookmarkSplitNames(titles: sections.map(\.title),
                                           fallbackBaseName: file.deletingPathExtension().lastPathComponent,
                                           style: options.bookmarkStyle)
            if options.base == nil { base = names.baseName }
            parts = sections.enumerated().map { i, s in
                (Array(s.startPage..<(s.startPage + s.pageCount)), names.suffixes[i])
            }
        } else {
            guard !options.parts.isEmpty else {
                throw CommandError("Say what the parts are: --part \"PAGES=NAME\" for each, or --bookmarks.")
            }
            parts = try options.parts.map { part in
                let pages = try parsePageList(part.pages, pageCount: doc.pageCount)
                guard !pages.isEmpty else { throw CommandError("Part “\(part.name)” has no pages.") }
                return (pages, fileNameSafe(part.name))
            }
        }
        let skipped = Set(try options.skip.map { try parsePageList($0, pageCount: doc.pageCount) } ?? [])

        // 2. Names, exactly as the Split tab composes them.
        var items = parts.enumerated().map { i, part in
            PrefixItem(id: i,
                       proposedName: splitOutputFileName(base: base, separator: separator, suffix: part.name, fileIndex: i,
                                                         onlyFile: parts.count == 1),
                       page: nil)
        }
        var finalNames = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.proposedName) })
        if let ensemble = options.scoreOrder {
            InstrumentOrders.setup()
            let order = InstrumentOrders.getOrder(for: ensemble)
            let unmatched = scoreOrderUnmatchedIds(items, by: order)
            items = scoreOrderSorted(items, by: order)
            let prefixSeparator = options.prefixSeparator
                ?? UserDefaults.standard.string(forKey: "prefixSeparator") ?? " - "
            finalNames = scoreOrderFileNames(forOrderedItems: items, separator: prefixSeparator)
            for item in items where unmatched.contains(item.id) {
                warnings.append("“\(parts[item.id].name)” matches no \(ensemble.rawValue.lowercased()) instrument, so it's numbered after the others. Rename the part (e.g. \"Flute 2\", \"Trumpet 1\") if it should sit in score order.")
            }
        }

        // 3. The files, with the problems an AI should hear about before writing. Sorting
        // into folders puts each name in its folder ("Brass/03 - Trumpet 1.pdf").
        let folderEnsemble = options.ensemble ?? options.scoreOrder ?? .band
        let plans = items.map { item in
            SplitFilePlan(name: partFolderPath(finalNames[item.id] ?? item.proposedName,
                                               folder: partFolderName(partName: parts[item.id].name,
                                                                      fileName: item.proposedName,
                                                                      mode: options.folders, ensemble: folderEnsemble)),
                          pages: parts[item.id].pages.filter { !skipped.contains($0) })
        }
        let empty = plans.filter { $0.pages.isEmpty }.map(\.name)
        if !empty.isEmpty { warnings.append("Every page of \(empty.joined(separator: ", ")) is skipped, so it won't be saved.") }
        let writable = plans.filter { !$0.pages.isEmpty }

        var duplicates: [String] = []
        var seenNames = Set<String>()
        for plan in writable where !seenNames.insert(plan.name.lowercased()).inserted { duplicates.append(plan.name) }
        if !duplicates.isEmpty {
            throw CommandError("Two parts would get the same file name: \(duplicates.joined(separator: ", ")). Give them different names.")
        }

        var pageUse: [Int: Int] = [:]
        for part in parts { for p in part.pages { pageUse[p, default: 0] += 1 } }
        let unassigned = (0..<doc.pageCount).filter { pageUse[$0] == nil && !skipped.contains($0) }
        if !unassigned.isEmpty { warnings.append("Pages \(describePages(unassigned)) aren't in any part, so they won't be saved.") }
        let shared = pageUse.filter { $0.value > 1 }.map(\.key)
        if !shared.isEmpty { warnings.append("Pages \(describePages(shared)) are in more than one part.") }

        let existing = writable.map(\.name).filter {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        if !existing.isEmpty && !options.overwrite && !options.dryRun {
            throw CommandError("These files already exist in \(folder.path): \(existing.joined(separator: ", ")). Add --overwrite to replace them, or choose another --out folder.")
        }

        let stampJob = try options.stamp.map { try stampJob(named: $0, scope: options.stampScope) }

        // 4. Write (or just describe).
        var report = SplitWriteReport()
        if !options.dryRun {
            report = writeSplitFiles(writable, from: doc, to: folder, stampJob: stampJob)
        }

        let fileEntries: [[String: Any]] = writable.map { plan in
            var entry: [String: Any] = ["name": plan.name, "path": folder.appendingPathComponent(plan.name).path,
                                        "pages": describePages(plan.pages), "pageCount": plan.pages.count]
            if !options.dryRun { entry["written"] = report.written.contains(plan.name) }
            if existing.contains(plan.name) { entry["replacesExistingFile"] = true }
            return entry
        }
        let failures = report.failures.map { ["name": $0.name, "reason": $0.reason] }
        let ok = report.failures.isEmpty
        var json: [String: Any] = ["ok": ok, "dryRun": options.dryRun, "folder": folder.path,
                                   "files": fileEntries, "warnings": warnings, "failures": failures]
        if let stampJob { json["stamp"] = stampJob.stamp.name }

        var text = options.dryRun
            ? "Would write \(writable.count) \(writable.count == 1 ? "file" : "files") to \(folder.path):"
            : "Wrote \(report.written.count) of \(writable.count) \(writable.count == 1 ? "file" : "files") to \(folder.path):"
        text += "\n" + writable.map { "  \($0.name)  (pages \(describePages($0.pages)))" }.joined(separator: "\n")
        if let stampJob { text += "\nStamped with “\(stampJob.stamp.name)” (\(stampJob.scope == .everyPage ? "every page" : "first page of each part"))." }
        if !warnings.isEmpty { text += "\n" + warnings.map { "Note: " + $0 }.joined(separator: "\n") }
        if !failures.isEmpty { text += "\n" + report.failures.map { "Failed: \($0.name) — \($0.reason)" }.joined(separator: "\n") }
        return CommandResult(text: text, json: json, exitCode: ok ? 0 : 1)
    }

    static func parsePartFolderMode(_ text: String?) throws -> PartFolderMode {
        guard let text else { return .off }
        guard let mode = PartFolderMode(rawValue: text.lowercased()) else {
            throw CommandError("--folders is section, instrument or off (got “\(text)”).")
        }
        return mode
    }

    // MARK: - split-scans

    static var splitScansCommand: CommandSpec {
        CommandSpec(
            name: "split-scans",
            summary: "Cut scans of double pages (A3, or a book scanner's spreads) into single pages",
            help: """
            Usage: ScoreSort split-scans <file.pdf> --out <new.pdf>
                                         [--same-cut | --cut FRACTION | --per-scan]
                                         [--first left|right] [--drop-blanks]
                                         [--dry-run] [--overwrite] [--json]

            "Split Double Pages" from the command line. Each scan with two pages side by side
            is cut into two pages; single pages are left whole. The scan images are only
            cropped, never re-compressed.

            Where the cut goes:
              (default)     As the app does: the same cut down the middle of every page when
                            every page is the same landscape sheet (a flatbed A3 scan);
                            otherwise each scan is cut at the gap between its pages, or where
                            the black scanner background starts.
              --same-cut    Cut every scan down the middle.
              --cut F       Cut every scan at fraction F of its width (0.5 = middle).
              --per-scan    Find each scan's own cut, even for identical sheets.

              --first       Which side of a two-page scan comes first (default left).
              --drop-blanks Leave out pieces that are black (scanner background) or empty.
                            Without it they're kept, and listed under "suggestedSkip" —
                            pass that list to `split --skip`.

            The report lists each scan's pages in the new PDF, so you can then `preview`
            and `split` the result.

            Example:
              ScoreSort split-scans "Scans.pdf" --out "Scans (pages).pdf" --json
            """,
            valueOptions: ["out", "cut", "first"],
            flagOptions: ["same-cut", "per-scan", "drop-blanks", "dry-run", "overwrite"],
            run: { args in
                guard let path = args.positionals.first else { throw CommandError("Give the scanned PDF.") }
                var mode = ScanCutMode.automatic
                let chosen = [args.has("same-cut"), args.value("cut") != nil, args.has("per-scan")].filter { $0 }.count
                guard chosen <= 1 else { throw CommandError("Use only one of --same-cut, --cut and --per-scan.") }
                if args.has("same-cut") { mode = .same(0.5) }
                if let cut = try args.double("cut") {
                    guard cut > 0.03 && cut < 0.97 else { throw CommandError("--cut is a fraction of the width, between 0.03 and 0.97.") }
                    mode = .same(cut)
                }
                if args.has("per-scan") { mode = .perScan }
                let first = args.value("first") ?? "left"
                guard ["left", "right"].contains(first) else { throw CommandError("--first is left or right.") }
                return try runSplitScans(file: existingFile(path), out: args.required("out"), mode: mode,
                                         leftFirst: first == "left", dropBlanks: args.has("drop-blanks"),
                                         dryRun: args.has("dry-run"), overwrite: args.has("overwrite"))
            })
    }

    enum ScanCutMode: Equatable {
        case automatic
        case same(Double)
        case perScan
    }

    static func runSplitScans(file: URL, out: String, mode: ScanCutMode, leftFirst: Bool,
                              dropBlanks: Bool, dryRun: Bool, overwrite: Bool) throws -> CommandResult {
        let doc = try openPDFDocument(file)
        var outURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath).standardizedFileURL
        if outURL.pathExtension.lowercased() != "pdf" { outURL.appendPathExtension("pdf") }
        guard outURL != file.standardizedFileURL else {
            throw CommandError("--out must be a new file, not the scan itself.")
        }
        if FileManager.default.fileExists(atPath: outURL.path) && !overwrite && !dryRun {
            throw CommandError("\(outURL.path) already exists. Add --overwrite to replace it.")
        }

        // Same detection as the review sheet.
        let shared: Double? = {
            switch mode {
            case .same(let f): return f
            case .perScan: return nil
            case .automatic: return isUniformSheetScan(doc) ? 0.5 : nil
            }
        }()
        let sources = (0..<doc.pageCount).map { doc.page(at: $0)?.scanRenderSource }
        let present = sources.compactMap { $0 }
        var analysed = analyseScanSources(present).makeIterator()
        var layouts: [ScanLayout] = []
        var blanks: [[BlankKind?]] = []
        var reasons: [CutReason] = []
        for source in sources {
            let scan: AnalysedScan? = source != nil ? (analysed.next() ?? nil) : nil
            guard let scan else {
                layouts.append(shared.map { .split(at: $0) } ?? .single)
                blanks.append(Array(repeating: nil, count: shared == nil ? 1 : 2))
                reasons.append(.none)
                continue
            }
            if let shared {
                let layout = ScanLayout.split(at: shared)
                layouts.append(layout)
                blanks.append(blankPieces(scan.gray, layout: layout))
                reasons.append(.middle)
            } else {
                layouts.append(scan.analysis.layout)
                blanks.append(scan.blanks)
                reasons.append(scan.analysis.reason)
            }
        }

        // Output page numbers, and which pieces are blank.
        let indices = scanPieceOutputIndices(layouts: layouts, leftFirst: leftFirst)
        var blankOutputPages = Set<Int>()
        for (pieces, kinds) in zip(indices, blanks) {
            for (k, page) in pieces.enumerated() where k < kinds.count && kinds[k] != nil { blankOutputPages.insert(page) }
        }

        var split = splitScans(doc, layouts: layouts, leftFirst: leftFirst)
        let totalPieces = split.pageCount
        // Renumber after dropping, so the report matches the file written.
        var newNumber: [Int: Int] = [:]
        if dropBlanks && !blankOutputPages.isEmpty {
            let kept = PDFDocument()
            for i in 0..<split.pageCount where !blankOutputPages.contains(i) {
                if let page = split.page(at: i) {
                    newNumber[i] = kept.pageCount
                    kept.insert(page, at: kept.pageCount)
                }
            }
            split = kept
        } else {
            for i in 0..<split.pageCount { newNumber[i] = i }
        }

        var scanEntries: [[String: Any]] = []
        var lines: [String] = []
        for (n, layout) in layouts.enumerated() {
            let kinds = blanks[n]
            var pieces: [[String: Any]] = []
            var pieceText: [String] = []
            for (k, outIndex) in indices[n].enumerated() {
                let side = layout.pieceCount == 1 ? "whole" : (k == 0 ? "left" : "right")
                let blank = k < kinds.count ? kinds[k] : nil
                var piece: [String: Any] = ["side": side]
                if let page = newNumber[outIndex] { piece["page"] = page + 1 }
                if let blank { piece["blank"] = blank == .black ? "black" : "empty" }
                pieces.append(piece)
                let pageText = newNumber[outIndex].map { "p\($0 + 1)" } ?? "dropped"
                pieceText.append(blank == nil ? pageText : "\(pageText) (\(blank == .black ? "black" : "empty"))")
            }
            var entry: [String: Any] = ["scan": n + 1, "pieces": pieces]
            if case .split(let f) = layout {
                entry["cut"] = rounded(f, places: 3)
                entry["cutAt"] = { switch reasons[n] {
                    case .gutter: return "gutter"
                    case .scannerBed: return "scanner background edge"
                    case .leastInk: return "least ink near the middle"
                    case .middle, .none: return "middle"
                } }()
            }
            scanEntries.append(entry)
            lines.append("  scan \(n + 1): " + (layout.pieceCount == 1 ? "kept whole → " : "cut → ") + pieceText.joined(separator: ", "))
        }

        let suggestedSkip = dropBlanks ? [] : blankOutputPages.sorted()
        var problem: String? = nil
        if !dryRun {
            try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let reason = savePDFDocument(split, to: outURL) { problem = reason }
        }

        let ok = problem == nil
        var json: [String: Any] = ["ok": ok, "dryRun": dryRun, "file": outURL.path, "scans": scanEntries,
                                   "pageCount": split.pageCount,
                                   "sameCut": shared.map { rounded($0, places: 3) as Any } ?? NSNull(),
                                   "suggestedSkip": suggestedSkip.isEmpty ? "" : describePages(suggestedSkip),
                                   "dropped": dropBlanks ? blankOutputPages.count : 0]
        if let problem { json["error"] = problem }

        var text = dryRun ? "Would write" : (ok ? "Wrote" : "Couldn't write")
        text += " \(outURL.lastPathComponent): \(doc.pageCount) scans → \(split.pageCount) pages"
        if dropBlanks && totalPieces != split.pageCount { text += " (\(totalPieces - split.pageCount) blank dropped)" }
        if let shared { text += ", every scan cut at \(Int((shared * 100).rounded()))%" }
        text += "\n" + lines.joined(separator: "\n")
        if !suggestedSkip.isEmpty {
            text += "\nBlack or empty pages to skip: \(describePages(suggestedSkip)) (pass to `split --skip`, or rerun with --drop-blanks)."
        }
        if let problem { text += "\nProblem: \(problem)" }
        return CommandResult(text: text, json: json, exitCode: ok ? 0 : 1)
    }

    // MARK: - Shared option parsing

    static func parseEnsemble(_ text: String) throws -> EnsembleType {
        guard let ensemble = EnsembleType.allCases.first(where: { $0.rawValue.lowercased() == text.lowercased() }) else {
            throw CommandError("The ensemble is band, jazz or orchestra (got “\(text)”).")
        }
        return ensemble
    }

    static func parseStampScope(_ text: String?, default fallback: StampScope) throws -> StampScope {
        switch text?.lowercased() {
        case nil: return fallback
        case "first": return .firstPageOfEachPart
        case "every": return .everyPage
        default: throw CommandError("The stamp scope is first or every.")
        }
    }

    /// A saved stamp design by name (case-insensitive; a unique partial match also works).
    static func stampJob(named name: String, scope: StampScope) throws -> StampJob {
        let stamps = savedStamps()
        let lower = name.lowercased()
        let exact = stamps.filter { $0.name.lowercased() == lower }
        let partial = stamps.filter { $0.name.lowercased().contains(lower) }
        guard let stamp = exact.first ?? (partial.count == 1 ? partial.first : nil) else {
            let available = stamps.map { "“\($0.name)”" }.joined(separator: ", ")
            throw CommandError(stamps.isEmpty
                ? "There are no saved stamps — design one in ScoreSort's Stamp tab first."
                : "No single stamp called “\(name)”. Saved stamps: \(available).")
        }
        guard stamp.isDrawable else { throw CommandError("The stamp “\(stamp.name)” has nothing to draw.") }
        return StampJob(stamp: stamp, scope: scope)
    }

    /// The stamp designs saved in the app (stamps.json) — not the placeholder the app shows
    /// when there are none.
    static func savedStamps() -> [Stamp] {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: dir.appendingPathComponent("ScoreSort/stamps.json")),
              let stamps = try? JSONDecoder().decode([Stamp].self, from: data) else { return [] }
        return stamps
    }
}
