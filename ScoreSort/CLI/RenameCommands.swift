//
//  RenameCommands.swift
//  ScoreSort
//
//  `rename` — the Rename tab's Score Order Sorter: number a folder of parts in score
//  order ("00 - Score.pdf", "01 - Flute 1.pdf", …). Plans by default; `--apply` renames.
//  Same planner and same file moves as the app (Logic/RenameLogic.swift).
//

import Foundation

extension ScoreSortCLI {

    static var renameCommand: CommandSpec {
        CommandSpec(
            name: "rename",
            summary: "Number a folder of parts in score order (00 - Score, 01 - Flute…); plans unless --apply",
            help: """
            Usage: ScoreSort rename <folder | files…> --ensemble band|jazz|orchestra
                                    [--number "FILE=NN"]… [--exclude FILE]… [--recursive]
                                    [--rescan] [--separator TEXT] [--folders section|instrument]
                                    [--folder "FILE=FOLDER"]… [--apply] [--json]

            The Rename tab's Score Order Sorter. Each file's name is checked for an
            instrument from the ensemble's order (your custom order from ScoreSort's
            settings); the score becomes 00, then 01, 02… in score order, e.g.
            "Flute 1.pdf" → "01 - Flute 1.pdf". The rest of each name is kept.

            Without --apply nothing is renamed: you get the plan. Check it, then run the
            same command with --apply.

              --ensemble    band, jazz or orchestra.
              --number      Give a file a number yourself, e.g. --number "Bass Guitar.pdf=14"
                            (for parts with no recognisable instrument, or a different
                            place). Other files are numbered around it.
              --exclude     Leave a file alone.
              --recursive   Include files in subfolders.
              --rescan      Re-number files that already have a number prefix (for
                            when parts were added or the order changed). Without it,
                            already-numbered files are left alone — unless some parts
                            are numbered and some aren't, when everything is renumbered
                            anyway (numbering only the new ones would repeat numbers).
              --separator   Between the number and the name (default: the app's setting, " - ").
              --folders     Also move each numbered part into a folder beside it, so each
                            group of players can be given just their folder. section:
                            Woodwind, Brass (a band's piano and basses too), Percussion,
                            Strings, and Rhythm for an orchestra (jazz: Saxophones, Trumpets,
                            Trombones, Rhythm); numbered ("2 Brass") if ScoreSort's settings
                            say so. instrument: Flute, Clarinet…
                            Parts already numbered move too. The score and unrecognised
                            files stay put. A piece already sorted this way (its parts in
                            Woodwind, Brass… inside the folder) is numbered as one, and
                            --folders off gathers its parts back into the folder. Without
                            --folders, parts stay in whatever folder they're in.
              --folder      With --folders: put a file in a folder of your choosing where
                            ScoreSort's guess is wrong, e.g. --folder "Bass.pdf=Rhythm".
                            An empty folder ("Bass.pdf=") leaves it at the top.
              --apply       Rename the files.

            Files whose names contain no instrument are listed as "not recognised" and left
            alone — rename them so they contain one (e.g. "Trumpet 1"), or use --number.

            Example:
              ScoreSort rename "Holst Parts" --ensemble band
              ScoreSort rename "Holst Parts" --ensemble band --number "Euph TC.pdf=12" --apply
            """,
            valueOptions: ["ensemble", "number", "exclude", "separator", "folders", "folder"],
            flagOptions: ["recursive", "rescan", "apply"],
            run: { args in
                guard !args.positionals.isEmpty else { throw CommandError("Give the folder of parts (or the files) to rename.") }
                var overrides: [String: Int] = [:]
                for spec in args.all("number") {
                    guard let eq = spec.lastIndex(of: "="), let n = Int(spec[spec.index(after: eq)...]),
                          (0...99).contains(n) else {
                        throw CommandError("--number needs FILE=NN with NN from 0 to 99, e.g. \"Bass Guitar.pdf=14\" (got “\(spec)”).")
                    }
                    overrides[String(spec[..<eq])] = n
                }
                var folderOverrides: [String: String] = [:]
                for spec in args.all("folder") {
                    guard let eq = spec.lastIndex(of: "=") else {
                        throw CommandError("--folder needs FILE=FOLDER, e.g. \"Bass.pdf=Rhythm\" (got “\(spec)”).")
                    }
                    let folder = spec[spec.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if !folder.isEmpty, let problem = partFolderNameError(folder) { throw CommandError(problem) }
                    folderOverrides[String(spec[..<eq])] = folder
                }
                return try runRename(paths: args.positionals,
                                     ensemble: parseEnsemble(args.required("ensemble")),
                                     overrides: overrides,
                                     excluded: Set(args.all("exclude")),
                                     recursive: args.has("recursive"),
                                     rescan: args.has("rescan"),
                                     separator: args.value("separator"),
                                     folders: try args.value("folders").map { try parsePartFolderMode($0) },
                                     folderOverrides: folderOverrides,
                                     apply: args.has("apply"))
            })
    }

    static func runRename(paths: [String], ensemble: EnsembleType, overrides: [String: Int] = [:],
                          excluded: Set<String> = [], recursive: Bool = false, rescan: Bool = false,
                          separator: String? = nil, folders: PartFolderMode? = nil,
                          folderOverrides: [String: String] = [:], apply: Bool) throws -> CommandResult {
        // The files: one folder, or files given one by one.
        let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        var files: [URL]
        // A folder's part folders (Woodwind, Brass…) come with it; with --folders the plan
        // works from that folder, so parts can move between them or back out.
        var root: URL? = nil
        if urls.count == 1, urlIsDirectory(urls[0]) {
            files = renamerJobFiles(in: urls[0], recursive: recursive)
            if folders != nil { root = urls[0] }
        } else {
            for url in urls where !FileManager.default.fileExists(atPath: url.path) {
                throw CommandError("No file at \(url.path).")
            }
            files = urls.filter(isRenamableFile).sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        guard !files.isEmpty else { throw CommandError("No PDFs or images to rename there.") }

        let names = Set(files.map(\.lastPathComponent))
        for name in Set(overrides.keys).union(excluded).union(folderOverrides.keys) where !names.contains(name) {
            throw CommandError("“\(name)” isn't one of the files (use the file name exactly, with .pdf).")
        }

        InstrumentOrders.setup()
        // As the Score Order Sorter does: a mix of numbered and unnumbered parts is renumbered.
        let renumberedAutomatically = !rescan
            && scoreOrderNeedsRenumbering(files: files, order: InstrumentOrders.getOrder(for: ensemble),
                                          numberedByHand: Set(overrides.keys))
        let rescan = rescan || renumberedAutomatically
        let operations = planScoreOrderRename(
            files: files, order: InstrumentOrders.getOrder(for: ensemble),
            separator: separator ?? UserDefaults.standard.string(forKey: "prefixSeparator") ?? " - ",
            rescan: rescan, manualOverrides: overrides, excluded: excluded,
            folderMode: folders ?? .off, ensemble: ensemble, folderOverrides: folderOverrides, root: root,
            numberedFolders: PartFolderMode.numbersSections)

        var report = RenameReport()
        if apply { report = performRenames(operations) }
        if report.blockedReadOnly {
            throw CommandError("The files are in a read-only place (a cloud-sync folder, locked, or a read-only drive), so they can't be renamed there. " + readOnlyLocationMessage(folderName: nil))
        }
        let renamedFrom = Set(report.renamed.map(\.from.standardizedFileURL))

        func status(_ op: RenameOperation) -> String {
            switch op.type {
            case .rename where op.newName == op.originalName:
                return op.folder == nil ? "move out of folder" : "move into folder"
            case .rename, .manual: return "rename"
            case .correct: return "correct"
            case .skip: return op.statusOverride == "Target exists" ? "target exists" : "already correct"
            case .alreadyPrefixed: return "already numbered"
            case .undetected: return "not recognised"
            case .excluded: return "excluded"
            }
        }
        let moves = operations.filter { $0.type == .rename || $0.type == .correct || $0.type == .manual }
        let entries: [[String: Any]] = operations.map { op in
            var entry: [String: Any] = ["file": op.originalName, "status": status(op)]
            if !op.newName.isEmpty { entry["newName"] = op.newName }
            if let folder = op.folder { entry["folder"] = folder }
            if apply && op.newURL != nil { entry["renamed"] = renamedFrom.contains(op.originalURL.standardizedFileURL) }
            return entry
        }
        let unrecognised = operations.filter { $0.type == .undetected }.map(\.originalName)

        var lines: [String] = []
        for op in operations {
            switch op.type {
            case .rename, .correct, .manual:
                lines.append("  \(op.originalName) → \(op.newPathForDisplay)" + (op.type == .manual ? "  (your number)" : ""))
            case .undetected:
                lines.append("  \(op.originalName): not recognised — left alone")
            default:
                lines.append("  \(op.originalName): \(status(op))" + (op.newName.isEmpty ? "" : " (\(op.newName))"))
            }
        }
        var text = apply
            ? "Renamed \(report.renamed.count) of \(moves.count) \(moves.count == 1 ? "file" : "files") (\(ensemble.rawValue.lowercased()) order):"
            : "Plan (\(ensemble.rawValue.lowercased()) order) — nothing renamed yet; add --apply to rename:"
        text += "\n" + lines.joined(separator: "\n")
        if renumberedAutomatically {
            text += "\nRenumbering every file: some were already numbered and some weren't, or an already-numbered file was given a --number (otherwise numbers would repeat, or yours would be ignored)."
        }
        if !unrecognised.isEmpty {
            text += "\nNot recognised: rename these to include an instrument, or give each a number with --number \"FILE=NN\"."
        }
        if !report.errors.isEmpty { text += "\n" + report.errors.map { "Failed: " + $0 }.joined(separator: "\n") }

        let ok = report.errors.isEmpty
        return CommandResult(text: text,
                             json: ["ok": ok, "applied": apply, "ensemble": ensemble.rawValue.lowercased(),
                                    "renumberedAll": rescan, "renumberedAutomatically": renumberedAutomatically,
                                    "files": entries, "unrecognised": unrecognised, "errors": report.errors],
                             exitCode: ok ? 0 : 1)
    }
}
