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
    var filesForPart: [String: [UUID]] = [:]
    var partOrder: [String] = []
    var partsByName: [String: PresetPart] = [:]
    for file in files {
        let filename = normalizeRomanNumerals(file.name.lowercased())
        if let match = sortedParts.first(where: {
            presetPartMatches(part: normalizeRomanNumerals($0.name.lowercased()), in: filename)
        }) {
            if filesForPart[match.name] == nil { partOrder.append(match.name) }
            filesForPart[match.name, default: []].append(file.id)
            partsByName[match.name] = match
            matchedPartNames.insert(match.name)
        } else {
            result.unmatchedFileIds.insert(file.id)
        }
    }

    for name in partOrder {
        guard let ids = filesForPart[name], let part = partsByName[name] else { continue }
        result.matchedCount += ids.count
        guard ids.count > 1 else {
            result.copies.append((ids[0], part.copies))
            continue
        }
        // Files were gathered in list order, so the remainder goes to the lower-numbered parts.
        let shares = splitPresetCopies(part.copies, across: ids.count)
        for (offset, id) in ids.enumerated() {
            result.copies.append((id, shares[offset]))
            result.splitFileIds.insert(id)
        }
    }

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
        result.unmatchedFileIds.remove(fileId)
        result.matchedCount += 1
        for part in group { matchedPartNames.insert(part.name) }
    }

    result.unmatchedPartNames = Set(parts.map(\.name)).subtracting(matchedPartNames)
    return result
}
