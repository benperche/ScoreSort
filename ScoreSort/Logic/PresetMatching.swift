//
//  PresetMatching.swift
//  ScoreSort
//
//  Applying an ensemble preset (part names + copy counts) to the files in a Combine job:
//  which file gets how many copies, which files match no part (the app highlights them
//  orange), and which parts matched no file. Shared by the Combine tab and the command line.
//
//  No view state; unit-tested directly.
//

import Foundation

struct PresetMatchResult {
    /// Copies to set, per file, in the order to set them.
    var copies: [(fileId: UUID, copies: Int)] = []
    /// Files that match no part — left as they are, for the user to sort out.
    var unmatchedFileIds: Set<UUID> = []
    /// Files that share one preset entry's copies with other files (e.g. "Trumpet: 7"
    /// over Trumpet 1 and Trumpet 2) — the app marks these, since the split is its guess.
    var splitFileIds: Set<UUID> = []
    /// How many files were matched to a part.
    var matchedCount = 0
    /// Preset parts that matched no file.
    var unmatchedPartNames: Set<String> = []
    /// Who gets what: each preset part's players and the file (and copies) they were given.
    /// One part can feed several files (a shared entry), and several parts one file
    /// (consolidation). The copies per file are the sums of these.
    var assignments: [(part: String, fileId: UUID, copies: Int)] = []
}

/// Matches a preset's parts to files by name, in two phases:
/// 1. Direct: each file takes the longest part name it contains ("Bass Clarinet" beats
///    "Clarinet"), with roman numerals normalised. One entry matching several files has its
///    copies spread over them (`splitPresetCopies`) rather than given to each in full.
/// 2. Consolidation: when every numbered part of a base name ("Horn 1", "Horn 2") went
///    unmatched and exactly one file has that base name ("Horns"), it gets their sum.
/// Anything more complicated is left unmatched on purpose — real ensembles have irregular
/// parts that a person assigns better by hand.
func matchPreset(parts: [PresetPart], files: [(id: UUID, name: String)]) -> PresetMatchResult {
    var result = PresetMatchResult()
    let sortedParts = parts.sorted { $0.name.count > $1.name.count }
    var matchedPartNames: Set<String> = []

    // Phase 1. Matches are gathered per *part* before any copies are set, because one entry
    // can match several files — applying its full count to each would print two players'
    // worth of paper for every one the preset asked for.
    //
    // A file can name several preset entries: a combined part such as "Flute Oboe" or
    // "Flute/Piccolo". Files naming one entry are placed first. A combined file then
    // takes every entry it names that has no file of its own — its copies are their total —
    // and falls back to its longest-named entry, shared as before, only if all of them do.
    func normalised(_ name: String) -> String { normalizeRomanNumerals(name.lowercased()) }
    var filesForPart: [String: [UUID]] = [:]
    var partOrder: [String] = []
    var partsByName: [String: PresetPart] = [:]
    func add(_ file: UUID, to part: PresetPart) {
        if filesForPart[part.name] == nil { partOrder.append(part.name) }
        filesForPart[part.name, default: []].append(file)
        partsByName[part.name] = part
        matchedPartNames.insert(part.name)
    }
    let named: [(id: UUID, parts: [PresetPart])] = files.map { file in
        let filename = normalised(file.name)
        return (file.id, sortedParts.filter { presetPartMatches(part: normalised($0.name), in: filename) })
    }
    for file in named where file.parts.count == 1 { add(file.id, to: file.parts[0]) }
    let coveredBySingles = matchedPartNames
    var combinedFiles: Set<UUID> = []
    for file in named where file.parts.count > 1 {
        let own = file.parts.filter { !coveredBySingles.contains($0.name) }
        if own.isEmpty {
            add(file.id, to: file.parts[0])
        } else {
            for part in own { add(file.id, to: part) }
            if own.count > 1 { combinedFiles.insert(file.id) }
        }
    }
    let matchedFiles = Set(named.filter { !$0.parts.isEmpty }.map(\.id))
    result.unmatchedFileIds = Set(files.map(\.id)).subtracting(matchedFiles)
    result.matchedCount = matchedFiles.count

    // Copies: each entry's players shared across its files, then summed per file (a combined
    // part gets every entry it covers), in the order files first appear.
    var copiesByFile: [UUID: Int] = [:]
    var fileOrder: [UUID] = []
    for name in partOrder {
        guard let ids = filesForPart[name], let part = partsByName[name] else { continue }
        let shares = ids.count > 1 ? splitPresetCopies(part.copies, across: ids.count) : [part.copies]
        for (offset, id) in ids.enumerated() {
            if copiesByFile[id] == nil { fileOrder.append(id) }
            copiesByFile[id, default: 0] += shares[offset]
            result.assignments.append((part.name, id, shares[offset]))
            if ids.count > 1 { result.splitFileIds.insert(id) }
        }
    }
    // A combined part's total is the app's call too: mark it like a split.
    result.splitFileIds.formUnion(combinedFiles)
    result.copies = fileOrder.map { ($0, copiesByFile[$0] ?? 0) }

    // Phase 2.
    let unmatchedParts = parts.filter { !matchedPartNames.contains($0.name) }
    var baseGroups: [String: [PresetPart]] = [:]
    var baseOrder: [String] = []
    for part in unmatchedParts {
        if let base = numberedBase(of: part.name) {
            if baseGroups[base] == nil { baseOrder.append(base) }
            baseGroups[base, default: []].append(part)
        }
    }
    for base in baseOrder {
        guard let group = baseGroups[base] else { continue }
        // Every preset part with this base must be unmatched.
        let allWithBase = parts.filter { numberedBase(of: $0.name) == base }
        guard group.count == allWithBase.count else { continue }
        let candidates = files.filter {
            result.unmatchedFileIds.contains($0.id)
                && presetPartMatches(part: base, in: normalizeRomanNumerals($0.name.lowercased()))
        }
        guard candidates.count == 1, let fileId = candidates.first?.id else { continue }
        result.copies.append((fileId, group.reduce(0) { $0 + $1.copies }))
        for part in group { result.assignments.append((part.name, fileId, part.copies)) }
        result.unmatchedFileIds.remove(fileId)
        result.matchedCount += 1
        for part in group { matchedPartNames.insert(part.name) }
    }

    result.unmatchedPartNames = Set(parts.map(\.name)).subtracting(matchedPartNames)
    return result
}
