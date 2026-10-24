//
//  AllocationCommands.swift
//  ScoreSort
//
//  `allocate` — who plays what. Given a folder of parts and an ensemble preset ("Flute × 12,
//  Clarinet × 19, Bass Guitar × 2, …"), shows each group of players and the part(s) they'll be
//  given, the players left with no part, and the parts with no players. An AI assistant (or a
//  person) can then settle those with `--allocate "Bass Guitar=Tuba"` — the same options
//  `combine` takes, so the plan it checked is the PDF it gets.
//
//  The starting point is the Combine tab's own preset matching (`matchPreset`); `--allocate`
//  replaces a group's automatic choice, and `--copies` sets a file's total last of all.
//

import Foundation

/// One `--allocate` decision: a preset group's players (or `copies` of them) get `file`.
struct AllocationChoice {
    let part: String
    let file: String
    let copies: Int?

    /// Parses `PART=FILE` or `PART=FILE:N`.
    init(_ spec: String) throws {
        guard let eq = spec.firstIndex(of: "=") else {
            throw CommandError("--allocate needs PART=FILE or PART=FILE:N, e.g. \"Bass Guitar=Tuba\" (got “\(spec)”).")
        }
        part = spec[..<eq].trimmingCharacters(in: .whitespaces)
        var rest = String(spec[spec.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        var n: Int? = nil
        if let colon = rest.lastIndex(of: ":"), let value = Int(rest[rest.index(after: colon)...]) {
            guard (0...99).contains(value) else { throw CommandError("--allocate copies go from 0 to 99 (got \(value)).") }
            n = value
            rest = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
        }
        guard !part.isEmpty, !rest.isEmpty else { throw CommandError("--allocate needs both a preset part and a file (got “\(spec)”).") }
        file = rest
        copies = n
    }
}

/// A file in the job: what the allocation works with.
struct AllocationFile {
    let id: UUID
    let name: String
    let pages: Int
}

/// Who gets which part, and how many copies each file needs.
struct EnsembleAllocation {
    struct Group {
        let part: String
        let players: Int
        /// The files these players are given, and how many copies of each.
        var given: [(fileId: UUID, copies: Int)]
        /// True when `--allocate` decided it rather than the automatic matching.
        var chosen: Bool
        var allocated: Int { given.reduce(0) { $0 + $1.copies } }
    }

    var presetName: String?
    var groups: [Group] = []
    /// Final copies per file; 0 = left out.
    var copies: [UUID: Int] = [:]
    /// Files whose total was set with `--copies`.
    var setDirectly: Set<UUID> = []
    /// Files no group was given (with a preset): kept at 1 copy unless `--copies` says otherwise.
    var withoutPlayers: Set<UUID> = []

    var totalPlayers: Int { groups.reduce(0) { $0 + $1.players } }
}

extension ScoreSortCLI {

    // MARK: - Shared lookups

    /// The files to work with: each path as given, or a folder's PDFs and images in name
    /// order (so score-ordered names come out in score order). `excluding` drops a previous
    /// output sitting in the same folder.
    static func collectPartFiles(_ paths: [String], excluding: URL? = nil) throws -> [URL] {
        var files: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            if urlIsDirectory(url) {
                files += ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                         options: [.skipsHiddenFiles])) ?? [])
                    .filter { pageableFileExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else {
                guard FileManager.default.fileExists(atPath: url.path) else { throw CommandError("No file at \(url.path).") }
                files.append(url)
            }
        }
        if let excluding { files.removeAll { $0 == excluding } }
        guard !files.isEmpty else { throw CommandError("No PDFs or images there.") }
        return files
    }

    /// A saved preset by name (case-insensitive; a unique partial match also works).
    static func preset(named name: String) throws -> EnsemblePreset {
        let presets = savedPresets()
        let lower = name.lowercased()
        let exact = presets.filter { $0.name.lowercased() == lower }
        let partial = presets.filter { $0.name.lowercased().contains(lower) }
        guard let preset = exact.first ?? (partial.count == 1 ? partial.first : nil) else {
            throw CommandError(presets.isEmpty
                ? "There are no saved presets — make one in ScoreSort's Combine tab."
                : "No single preset called “\(name)”. Saved presets: \(presets.map { "“\($0.name)”" }.joined(separator: ", ")).")
        }
        return preset
    }

    /// One of the files, by its name (with or without the extension) or a part of the name
    /// that picks out just one.
    static func file(matching key: String, in files: [AllocationFile]) throws -> AllocationFile {
        let lower = key.trimmingCharacters(in: .whitespaces).lowercased()
        let exact = files.filter {
            $0.name.lowercased() == lower || ($0.name as NSString).deletingPathExtension.lowercased() == lower
        }
        let partial = files.filter { $0.name.lowercased().contains(lower) }
        if let file = exact.first ?? (partial.count == 1 ? partial.first : nil) { return file }
        throw CommandError(partial.count > 1
            ? "“\(key)” matches several files (\(partial.map(\.name).joined(separator: ", "))) — use more of the name."
            : "No file matches “\(key)”. The files are: \(files.map(\.name).joined(separator: ", ")).")
    }

    // MARK: - Building the allocation

    static func buildAllocation(files: [AllocationFile], preset: EnsemblePreset?,
                                choices: [AllocationChoice], copies: [String]) throws -> EnsembleAllocation {
        var allocation = EnsembleAllocation(presetName: preset?.name)

        if let preset {
            // 1. The Combine tab's own matching.
            let auto = matchPreset(parts: preset.parts, files: files.map { ($0.id, $0.name) })
            allocation.groups = preset.parts.map { part in
                EnsembleAllocation.Group(part: part.name, players: part.copies,
                                         given: auto.assignments.filter { $0.part == part.name }.map { ($0.fileId, $0.copies) },
                                         chosen: false)
            }

            // 2. --allocate replaces a group's automatic choice.
            var byGroup: [Int: [(file: AllocationFile, copies: Int?)]] = [:]
            for choice in choices {
                let lower = choice.part.lowercased()
                let exact = allocation.groups.indices.filter { allocation.groups[$0].part.lowercased() == lower }
                let partial = allocation.groups.indices.filter { allocation.groups[$0].part.lowercased().contains(lower) }
                guard let index = exact.first ?? (partial.count == 1 ? partial.first : nil) else {
                    throw CommandError("“\(choice.part)” isn't one of \(preset.name)'s parts: \(preset.parts.map(\.name).joined(separator: ", ")).")
                }
                byGroup[index, default: []].append((try file(matching: choice.file, in: files), choice.copies))
            }
            for (index, picks) in byGroup {
                let players = allocation.groups[index].players
                let fixed = picks.compactMap(\.copies).reduce(0, +)
                let open = picks.filter { $0.copies == nil }
                // Picks without a number share the players not already placed, evenly.
                let shares = open.isEmpty ? [] : splitPresetCopies(max(0, players - fixed), across: open.count)
                var shareIterator = shares.makeIterator()
                allocation.groups[index].given = picks.map { pick in
                    (pick.file.id, pick.copies ?? (shareIterator.next() ?? 0))
                }
                allocation.groups[index].chosen = true
            }

            // 3. Copies per file: the sum of what each group was given.
            for group in allocation.groups {
                for (id, n) in group.given { allocation.copies[id, default: 0] += n }
            }
            for file in files where allocation.copies[file.id] == nil {
                allocation.copies[file.id] = 1
                allocation.withoutPlayers.insert(file.id)
            }
        } else {
            guard choices.isEmpty else { throw CommandError("--allocate needs a --preset to allocate from.") }
            for file in files { allocation.copies[file.id] = 1 }
        }

        // 4. --copies sets a file's total, last of all (0 leaves it out).
        for spec in copies {
            guard let eq = spec.lastIndex(of: "="), let n = Int(spec[spec.index(after: eq)...]), (0...99).contains(n) else {
                throw CommandError("--copies needs FILE=N with N from 0 to 99, e.g. \"Flute 1=3\" (got “\(spec)”).")
            }
            let target = try file(matching: String(spec[..<eq]), in: files)
            allocation.copies[target.id] = n
            allocation.setDirectly.insert(target.id)
        }
        return allocation
    }

    /// The allocation as text and JSON, plus the problems worth deciding about.
    /// `toDecide`: players left without (enough) parts — settle these. `notes`: defaults
    /// worth a glance (even splits, files nobody in the preset plays).
    static func describeAllocation(_ allocation: EnsembleAllocation, files: [AllocationFile])
        -> (text: String, json: [String: Any], toDecide: [String], notes: [String]) {
        let byId = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        var toDecide: [String] = []
        var notes: [String] = []
        var lines: [String] = []
        var groupEntries: [[String: Any]] = []

        for group in allocation.groups {
            let given = group.given.filter { $0.copies > 0 }
            let status: String
            if group.allocated == 0 {
                status = "no part"
                toDecide.append("No part for \(group.part) (\(group.players) \(group.players == 1 ? "player" : "players")). Give them the closest part with --allocate \"\(group.part)=FILE\".")
            } else if group.allocated < group.players {
                status = "short"
                toDecide.append("\(group.part) has \(group.players) players but only \(group.allocated) copies.")
            } else if group.allocated > group.players {
                status = "extra"
            } else {
                status = given.count > 1 ? "shared" : "ok"
            }
            if !group.chosen && given.count > 1 {
                notes.append("\(group.part)'s \(group.players) players are shared across \(given.compactMap { byId[$0.fileId]?.name }.joined(separator: ", ")) (\(given.map { String($0.copies) }.joined(separator: " + "))) — change with --allocate if a different split suits the players.")
            }
            groupEntries.append([
                "part": group.part, "players": group.players, "allocated": group.allocated,
                "status": status, "decidedBy": group.chosen ? "--allocate" : "preset matching",
                "files": given.map { ["file": byId[$0.fileId]?.name ?? "?", "copies": $0.copies] },
            ])
            let target = given.isEmpty ? "— no part" : given.map { "\(byId[$0.fileId]?.name ?? "?") × \($0.copies)" }.joined(separator: ", ")
            lines.append("  \(group.part) (\(group.players)) → \(target)" + (group.chosen ? "  [your choice]" : ""))
        }

        var fileEntries: [[String: Any]] = []
        var fileLines: [String] = []
        for file in files {
            let n = allocation.copies[file.id] ?? 0
            let from = allocation.groups.flatMap { group in
                group.given.filter { $0.fileId == file.id && $0.copies > 0 }.map { ["part": group.part, "copies": $0.copies] as [String: Any] }
            }
            let status: String
            if n == 0 { status = "left out" }
            else if allocation.setDirectly.contains(file.id) { status = "set with --copies" }
            else if allocation.withoutPlayers.contains(file.id) { status = "not in the preset" }
            else { status = "allocated" }
            fileEntries.append(["file": file.name, "pages": file.pages, "copies": n, "status": status, "players": from])
            fileLines.append("  \(file.name) × \(n)" + (status == "allocated" ? "" : "  (\(status))"))
        }
        let unallocated = files.filter { allocation.withoutPlayers.contains($0.id) && !allocation.setDirectly.contains($0.id) }
        if !unallocated.isEmpty {
            notes.append("No players in the preset for \(unallocated.map(\.name).joined(separator: ", ")), so 1 copy each (a spare, or for the conductor). Set with --copies \"FILE=N\"; 0 leaves a file out.")
        }

        let totalCopies = files.reduce(0) { $0 + (allocation.copies[$1.id] ?? 0) }
        let totalPages = files.reduce(0) { $0 + (allocation.copies[$1.id] ?? 0) * $1.pages }
        var json: [String: Any] = ["files": fileEntries, "totalCopies": totalCopies, "readingPages": totalPages]
        var text = ""
        if let name = allocation.presetName {
            json["preset"] = name
            json["players"] = allocation.totalPlayers
            json["groups"] = groupEntries
            text = "“\(name)” — \(allocation.totalPlayers) players:\n" + lines.joined(separator: "\n") + "\n\nFiles:\n"
        } else {
            text = "Files:\n"
        }
        text += fileLines.joined(separator: "\n") + "\n\(totalCopies) copies, \(totalPages) pages of music."
        return (text, json, toDecide, notes)
    }

    // MARK: - allocate

    static var allocateCommand: CommandSpec {
        CommandSpec(
            name: "allocate",
            summary: "Plan who plays what: an ensemble preset's players matched to a folder of parts",
            help: """
            Usage: ScoreSort allocate <files… | folder> --preset NAME
                                      [--allocate "PART=FILE[:N]"]… [--copies "FILE=N"]… [--json]

            Shows how an ensemble preset's players (see `presets`) would be given the parts in
            a folder — each group ("Flute, 12 players") and the file(s) they get — before
            anything is combined. Writes nothing. Then `combine` with the same options makes it.

            Starts from ScoreSort's own matching (each file takes the preset part its name
            contains). It reports:
              • groups with no part (players who'd get nothing) — give them the closest part;
              • groups shared across numbered parts (Clarinet × 19 over Clarinet 1 and 2);
              • files no group plays (1 copy each by default).

              --allocate  A decision: a group's players get a file. "PART=FILE" gives all of
                          that group's players the file; "PART=FILE:N" gives N of them. Several
                          for one group split its players (any without :N share the rest
                          evenly). Replaces that group's automatic choice. PART is a preset part
                          name, FILE a file name or a part of it that picks out one file.
              --copies    A file's total copies, set last of all; 0 leaves the file out.

            Examples:
              ScoreSort allocate "Holst Parts" --preset "Junior Band"
              ScoreSort allocate "Holst Parts" --preset "Junior Band" \\
                  --allocate "Bass Guitar=Tuba" \\
                  --allocate "Clarinet=Clarinet 1:11" --allocate "Clarinet=Clarinet 2"
            """,
            valueOptions: ["preset", "allocate", "copies"],
            flagOptions: [],
            run: { args in
                guard !args.positionals.isEmpty else { throw CommandError("Give the folder of parts (or the files).") }
                return try runAllocate(paths: args.positionals, preset: args.required("preset"),
                                       allocations: args.all("allocate").map(AllocationChoice.init),
                                       copies: args.all("copies"))
            })
    }

    static func runAllocate(paths: [String], preset presetName: String, allocations: [AllocationChoice],
                            copies: [String]) throws -> CommandResult {
        let urls = try collectPartFiles(paths)
        let manager = CombineManager()
        manager.addFiles(urls: urls, undoManager: nil)
        let added = Set(manager.files.map(\.url.standardizedFileURL))
        let unreadable = urls.filter { !added.contains($0.standardizedFileURL) }
        if !unreadable.isEmpty { throw CommandError("Couldn't open: \(unreadable.map(\.lastPathComponent).joined(separator: ", ")).") }

        let files = manager.files.map { AllocationFile(id: $0.id, name: $0.name, pages: $0.pageCount) }
        let allocation = try buildAllocation(files: files, preset: preset(named: presetName),
                                             choices: allocations, copies: copies)
        let described = describeAllocation(allocation, files: files)
        var json = described.json
        json["ok"] = true
        json["toDecide"] = described.toDecide
        json["notes"] = described.notes
        var text = described.text
        if !described.toDecide.isEmpty { text += "\n\n" + described.toDecide.map { "To decide: " + $0 }.joined(separator: "\n") }
        if !described.notes.isEmpty { text += "\n\n" + described.notes.map { "Note: " + $0 }.joined(separator: "\n") }
        text += "\n\nNothing written. `combine` with the same --preset, --allocate and --copies makes the PDF."
        return CommandResult(text: text, json: json)
    }
}
