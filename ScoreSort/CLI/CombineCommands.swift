//
//  CombineCommands.swift
//  ScoreSort
//
//  `stamps` / `stamp` (the Stamp tab) and `presets` / `combine` (the Combine tab), from the
//  command line. Combine goes through `CombineManager.createCombinedPDF` and the shared
//  preset matcher, so a combined PDF here is the one the app would make — copies,
//  table of contents, booklet imposition, stamp and all.
//

import Foundation
import PDFKit

extension ScoreSortCLI {

    // MARK: - stamps

    static var stampsCommand: CommandSpec {
        CommandSpec(
            name: "stamps",
            summary: "List the stamp designs saved in ScoreSort",
            help: """
            Usage: ScoreSort stamps [--json]

            Lists the stamp designs saved in ScoreSort's Stamp tab (a school or ensemble
            name, a copyright line, …). Use a name with `stamp`, or with --stamp on
            `split` and `combine`. New designs are made in the app.
            """,
            valueOptions: [], flagOptions: [],
            run: { _ in runStamps() })
    }

    static func runStamps() -> CommandResult {
        let stamps = savedStamps()
        let entries: [[String: Any]] = stamps.map { ["name": $0.name, "text": $0.text] }
        let text = stamps.isEmpty
            ? "No saved stamps. Design one in ScoreSort's Stamp tab."
            : "Saved stamps:\n" + stamps.map { "  \($0.name)" + ($0.text.isEmpty ? "" : " — “\($0.text.replacingOccurrences(of: "\n", with: " / "))”") }.joined(separator: "\n")
        return CommandResult(text: text, json: ["ok": true, "stamps": entries])
    }

    // MARK: - stamp

    static var stampCommand: CommandSpec {
        CommandSpec(
            name: "stamp",
            summary: "Stamp a saved design onto PDFs (or images), as new copies",
            help: """
            Usage: ScoreSort stamp <files…> --stamp NAME --out <folder> [--scope first|every]
                                   [--dry-run] [--overwrite] [--json]

            The Stamp tab: stamps a saved design (see `stamps`) onto each file and saves a
            copy in --out with the same name (images become PDFs). The originals are
            never changed — to replace them, use the app.

              --scope   first: only each file's first page; every (default): every page.

            Example:
              ScoreSort stamp Parts/*.pdf --stamp "Sydney Youth Band" --out Stamped
            """,
            valueOptions: ["stamp", "out", "scope"],
            flagOptions: ["dry-run", "overwrite"],
            run: { args in
                guard !args.positionals.isEmpty else { throw CommandError("Give the files to stamp.") }
                return try runStamp(files: args.positionals.map(existingFile),
                                    stamp: args.required("stamp"),
                                    scope: parseStampScope(args.value("scope"), default: .everyPage),
                                    out: args.required("out"),
                                    dryRun: args.has("dry-run"), overwrite: args.has("overwrite"))
            })
    }

    static func runStamp(files: [URL], stamp: String, scope: StampScope, out: String,
                         dryRun: Bool, overwrite: Bool) throws -> CommandResult {
        let folder = try outputFolder(out, create: !dryRun)
        let targets = files.map { folder.appendingPathComponent($0.deletingPathExtension().lastPathComponent + ".pdf") }
        if Set(targets.map(\.lastPathComponent)).count != targets.count {
            throw CommandError("Two of the files would be saved under the same name in \(folder.path).")
        }
        for (source, target) in zip(files, targets) where isSameFile(target, source) {
            throw CommandError("--out is the folder \(source.lastPathComponent) is in, so its stamped copy would replace it. Choose another folder (to replace originals, use the app).")
        }
        let existing = targets.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
        if !existing.isEmpty && !overwrite && !dryRun {
            throw CommandError("These already exist in \(folder.path): \(existing.joined(separator: ", ")). Add --overwrite to replace them.")
        }
        let job = try stampJob(named: stamp, scope: scope)

        var entries: [[String: Any]] = []
        var problems: [String] = []
        for (source, target) in zip(files, targets) {
            var entry: [String: Any] = ["file": source.path, "output": target.path]
            if !dryRun {
                if let doc = pdfDocument(forFileAt: source) {
                    let stamped = applyingStamp(job, to: doc, partFirstPages: [0])
                    if let reason = savePDFDocument(stamped, to: target) {
                        problems.append("\(source.lastPathComponent): \(reason)")
                        entry["error"] = reason
                    } else {
                        entry["written"] = true
                    }
                } else {
                    problems.append("\(source.lastPathComponent) couldn't be opened.")
                    entry["error"] = "couldn't be opened"
                }
            }
            entries.append(entry)
        }
        let ok = problems.isEmpty
        var text = dryRun ? "Would stamp" : "Stamped"
        text += " \(files.count) \(files.count == 1 ? "file" : "files") with “\(job.stamp.name)” (\(scope == .everyPage ? "every page" : "first page")) into \(folder.path)"
        if !problems.isEmpty { text += "\n" + problems.map { "Problem: " + $0 }.joined(separator: "\n") }
        return CommandResult(text: text, json: ["ok": ok, "dryRun": dryRun, "stamp": job.stamp.name,
                                                "files": entries, "problems": problems],
                             exitCode: ok ? 0 : 1)
    }

    // MARK: - presets

    static var presetsCommand: CommandSpec {
        CommandSpec(
            name: "presets",
            summary: "List the ensemble presets (parts and copy counts) saved in ScoreSort",
            help: """
            Usage: ScoreSort presets [--json]

            Lists the Combine tab's ensemble presets: each ensemble's part names and how
            many copies of each it needs, and its stamp if it has one. Use a preset's name
            with `combine --preset`. Presets are made and edited in the app.
            """,
            valueOptions: [], flagOptions: [],
            run: { _ in runPresets() })
    }

    static func savedPresets() -> [EnsemblePreset] {
        // Read-only, and entry by entry: one preset this version can't decode doesn't hide the rest.
        guard let url = EnsemblePresetStore.defaultFileURL,
              case .loaded(let presets, _) = readSavedList(EnsemblePreset.self, at: url) else { return [] }
        return presets
    }

    static func runPresets() -> CommandResult {
        let presets = savedPresets()
        let stamps = savedStamps()
        let entries: [[String: Any]] = presets.map { preset in
            var entry: [String: Any] = ["name": preset.name,
                                        "players": preset.parts.reduce(0) { $0 + $1.copies },
                                        "parts": preset.parts.map { ["name": $0.name, "copies": $0.copies] }]
            if let id = preset.stampId, let stamp = stamps.first(where: { $0.id == id }) { entry["stamp"] = stamp.name }
            return entry
        }
        let text = presets.isEmpty
            ? "No saved presets. Make one in ScoreSort's Combine tab."
            : presets.map { preset in
                "\(preset.name) (\(preset.parts.reduce(0) { $0 + $1.copies }) players):\n" + preset.parts.map { "  \($0.name) × \($0.copies)" }.joined(separator: "\n")
            }.joined(separator: "\n\n")
        return CommandResult(text: text, json: ["ok": true, "presets": entries])
    }

    // MARK: - combine

    static var combineCommand: CommandSpec {
        CommandSpec(
            name: "combine",
            summary: "Combine parts into one PDF, with copies per part (from a preset), booklets and stamp",
            help: """
            Usage: ScoreSort combine <files… | folder> --out <file.pdf>
                                     [--preset NAME] [--allocate "PART=FILE[:N]"]… [--copies "FILE=N"]…
                                     [--booklet] [--sheet double|fit-a4] [--blank-pages]
                                     [--stamp NAME] [--stamp-scope first|every]
                                     [--dry-run] [--overwrite] [--json]

            The Combine tab: puts parts into one PDF to print, each part repeated for the
            number of players, with a bookmark (table of contents entry) for each copy.
            Files are combined in the order given; a folder gives its PDFs in name order
            (so score-ordered names come out in score order).

              --preset      Set copies from a saved ensemble preset (see `presets`). Each
                            file takes the part whose name it contains. Files matching no
                            part keep 1 copy and are reported, as are parts with no file;
                            the preset's stamp is used unless --stamp is given.
              --allocate    Decide who plays what, as in `allocate` (run that first to see
                            the plan): "Bass Guitar=Tuba" gives that preset group's players
                            the Tuba part; "Clarinet=Clarinet 1:11" gives 11 of them Clarinet 1.
              --copies      Set one file's total copies, e.g. --copies "Flute 1=3" — the file
                            name or a part of it that picks out one file. Applied last, so it
                            can correct anything; 0 leaves the file out.
              --booklet     Impose each part as a fold-and-staple booklet.
              --sheet       Booklet paper: double (two A4 pages on A3, default) or fit-a4
                            (an A5 booklet on A4).
              --blank-pages Booklet: add blank pages so every part starts on a fresh sheet.
              --stamp       Stamp a saved design (see `stamps`); --stamp-scope first (default)
                            or every.
              --dry-run     Show each part and its copies, and the page total; write nothing.

            Example:
              ScoreSort combine "Holst Parts" --preset "Concert Band" --out "Holst to print.pdf" --dry-run
            """,
            valueOptions: ["out", "preset", "allocate", "copies", "sheet", "stamp", "stamp-scope"],
            flagOptions: ["booklet", "blank-pages", "dry-run", "overwrite"],
            run: { args in
                guard !args.positionals.isEmpty else { throw CommandError("Give the parts to combine (files or a folder).") }
                var options = CombineOutputOptions()
                if args.has("booklet") { options.layout = .booklet }
                switch args.value("sheet") ?? "double" {
                case "double": options.sheetSize = .doubleSize
                case "fit-a4": options.sheetSize = .fitA4Landscape
                default: throw CommandError("--sheet is double or fit-a4.")
                }
                options.addBlankPages = args.has("blank-pages")
                return try runCombine(paths: args.positionals, out: args.required("out"),
                                      preset: args.value("preset"), copies: args.all("copies"),
                                      allocations: args.all("allocate").map { try AllocationChoice($0) },
                                      options: options, stamp: args.value("stamp"),
                                      stampScope: parseStampScope(args.value("stamp-scope"), default: .firstPageOfEachPart),
                                      dryRun: args.has("dry-run"), overwrite: args.has("overwrite"))
            })
    }

    static func runCombine(paths: [String], out: String, preset presetName: String?, copies: [String],
                           allocations: [AllocationChoice] = [],
                           options: CombineOutputOptions, stamp: String?, stampScope: StampScope,
                           dryRun: Bool, overwrite: Bool) throws -> CommandResult {
        var outURL = URL(fileURLWithPath: (out as NSString).expandingTildeInPath).standardizedFileURL
        if outURL.pathExtension.lowercased() != "pdf" { outURL.appendPathExtension("pdf") }
        let files = try collectPartFiles(paths, excluding: outURL)   // not a previous run's output
        if FileManager.default.fileExists(atPath: outURL.path) && !overwrite && !dryRun {
            throw CommandError("\(outURL.path) already exists. Add --overwrite to replace it.")
        }

        let manager = CombineManager()
        manager.addFiles(urls: files, undoManager: nil)
        let added = Set(manager.files.map(\.url.standardizedFileURL))
        let unreadable = files.filter { !added.contains($0.standardizedFileURL) }
        if !unreadable.isEmpty {
            throw CommandError("Couldn't open: \(unreadable.map(\.lastPathComponent).joined(separator: ", ")).")
        }

        // Copies: the same allocation `allocate` shows — the preset, --allocate, then --copies.
        let allocationFiles = manager.files.map { AllocationFile(id: $0.id, name: $0.name, pages: $0.pageCount) }
        let preset = try presetName.map { try Self.preset(named: $0) }
        let allocation = try buildAllocation(files: allocationFiles, preset: preset,
                                             choices: allocations, copies: copies)
        let described = describeAllocation(allocation, files: allocationFiles)
        let warnings = described.toDecide + described.notes
        let leftOut = Set(manager.files.filter { (allocation.copies[$0.id] ?? 1) == 0 }.map(\.id))
        for file in manager.files where !leftOut.contains(file.id) {
            manager.updateCopies(for: file.id, copies: allocation.copies[file.id] ?? 1, undoManager: nil)
        }
        if !leftOut.isEmpty { manager.removeFiles(ids: leftOut, undoManager: nil) }
        guard !manager.files.isEmpty else { throw CommandError("Every file is left out (0 copies) — nothing to combine.") }

        var stampName = stamp
        let presetUsed = preset?.name
        if stampName == nil, let id = preset?.stampId, let s = savedStamps().first(where: { $0.id == id }) {
            stampName = s.name
        }

        let job = try stampName.map { try stampJob(named: $0, scope: stampScope) }
        let partEntries: [[String: Any]] = manager.files.map { ["file": $0.name, "pages": $0.pageCount, "copies": $0.copies] }
        let totalPages = manager.files.reduce(0) { $0 + $1.pageCount * $1.copies }

        var problem: String? = nil
        if !dryRun {
            try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            manager.createCombinedPDF(to: outURL, options: options, stampJob: job) { title, message, isError in
                if isError { problem = "\(title): \(message)" }
            }
        }

        let ok = problem == nil
        var json: [String: Any] = ["ok": ok, "dryRun": dryRun, "file": outURL.path, "parts": partEntries,
                                   "readingPages": totalPages, "warnings": warnings,
                                   "layout": options.layout == .booklet ? "booklet" : "single pages"]
        if preset != nil { json["allocation"] = described.json }
        if let presetUsed { json["preset"] = presetUsed }
        if let job { json["stamp"] = job.stamp.name }
        if let problem { json["error"] = problem }
        if !dryRun, ok, let written = PDFDocument(url: outURL) { json["pageCount"] = written.pageCount }

        var text = dryRun ? "Would combine" : (ok ? "Combined" : "Couldn't combine")
        text += " \(manager.files.count) \(manager.files.count == 1 ? "part" : "parts") into \(outURL.lastPathComponent)"
        if let presetUsed { text += " using “\(presetUsed)”" }
        text += ":\n" + manager.files.map { "  \($0.name) × \($0.copies)  (\($0.pageCount) \($0.pageCount == 1 ? "page" : "pages"))" }.joined(separator: "\n")
        text += "\n\(totalPages) pages of music" + (options.layout == .booklet ? ", as booklets" : "")
        if let job { text += ", stamped with “\(job.stamp.name)”" }
        text += "."
        if !warnings.isEmpty { text += "\n" + warnings.map { "Note: " + $0 }.joined(separator: "\n") }
        if let problem { text += "\nProblem: \(problem)" }
        return CommandResult(text: text, json: json, exitCode: ok ? 0 : 1)
    }
}
