//
//  InstrumentNames.swift
//  ScoreSort
//
//  All instrument-name intelligence, extracted from the single-file app body:
//    • preset-to-file matching (Combine tab)
//    • instrument-name suggestions, display names & detection (Split tab)
//  Pure functions only (no view state), so they are unit-tested directly.
//

import Foundation

// MARK: - Preset matching helpers

/// Converts a trailing roman numeral part number (I/II/III/IV) to arabic (1/2/3/4).
/// Input must already be lowercased. Checks longest suffix first to avoid IV→I collision.
/// Only matches when preceded by a space, preventing false hits on words like "celli".
func normalizeRomanNumerals(_ s: String) -> String {
    let pairs: [(String, String)] = [(" iv", " 4"), (" iii", " 3"), (" ii", " 2"), (" i", " 1")]
    for (roman, arabic) in pairs {
        if s.hasSuffix(roman) { return String(s.dropLast(roman.count)) + arabic }
    }
    return s
}

/// Returns the base name (lowercased) if the name ends with a trailing part number
/// (arabic or roman numeral), otherwise nil.
/// E.g. "Violin II" → "violin",  "Flute 1" → "flute",  "Tuba" → nil
func numberedBase(of name: String) -> String? {
    let normalized = normalizeRomanNumerals(name.lowercased())
    let words = normalized.split(separator: " ")
    guard words.count >= 2, let lastWord = words.last, Int(String(lastWord)) != nil else { return nil }
    return words.dropLast().joined(separator: " ")
}

/// Register/size words that turn a root instrument into a *distinct* instrument when they
/// immediately precede it — "bass clarinet" is not a clarinet, "alto saxophone" is not a
/// plain saxophone, "english horn" is not a horn. Used to stop a generic preset part
/// ("Clarinet") from matching a more specific file ("Bass Clarinet") and vice-versa.
let instrumentQualifierWords: Set<String> = [
    "bass", "alto", "contra", "contrabass", "sopranino", "soprano",
    "tenor", "baritone", "piccolo", "english"
]

/// The set of filename phrases that mean the same *part to print* as a preset instrument.
/// This is the Combine tab's own alias table, reusing the splitter's instrument knowledge
/// (saxophone abbreviations **and reversed word order**, "French Horn" = "Horn", "Vln" =
/// "Violin", "Bb Clarinet" = "Clarinet", …) — but, unlike the splitter's
/// `instrumentIdentityKey`, it keeps the euphonium/baritone **BC vs TC clef distinct**,
/// because for printing it matters which clef the player is handed. `base` must be
/// lowercased with any trailing part number already stripped. Returns [] for a name we
/// don't recognise (the caller then matches it literally).
func instrumentAliasPhrases(forBase base: String) -> [String] {
    // Saxophone family — any spelling or word order (register needle found anywhere).
    if base.contains("sax") {
        let registers: [(needle: String, phrases: [String])] = [
            ("sop",   ["soprano saxophone", "soprano sax", "sax soprano"]),
            ("alto",  ["alto saxophone", "alto sax", "sax alto"]),
            ("tenor", ["tenor saxophone", "tenor sax", "sax tenor"]),
            ("bari",  ["baritone saxophone", "baritone sax", "bari sax", "bari saxophone", "sax baritone"]),
            ("bass",  ["bass saxophone", "bass sax", "sax bass"]),
        ]
        for (needle, phrases) in registers where base.contains(needle) { return phrases }
        return ["saxophone", "sax"]   // a bare "sax" with no register
    }
    // Euphonium / baritone horn (NOT baritone *sax* — handled above). Same instrument,
    // but the clef is kept distinct so a BC player never receives the TC part, and a bare
    // "Euphonium" preset entry (no clef) still matches either clef's file.
    if base.contains("euphonium") || base.contains("baritone") {
        let bc = ["euphonium bc", "euphonium b.c.", "euphonium bass clef",
                  "euph bc", "baritone bc", "baritone b.c.", "baritone bass clef"]
        let tc = ["euphonium tc", "euphonium t.c.", "euphonium treble clef",
                  "euph tc", "baritone tc", "baritone t.c.", "baritone treble clef"]
        if base.contains("treble") || base.contains("t.c") || base.hasSuffix(" tc") { return tc }
        if base.contains("bass")   || base.contains("b.c") || base.hasSuffix(" bc") { return bc }
        return ["euphonium", "euph", "baritone"]   // bare — matches either clef's file
    }
    // Other common aliases (mirrors the splitter's group-key table, minus sax/euph).
    // Each group is a set of interchangeable spellings: matched on the *exact* clean base
    // (so a qualified variant like "Alto Clarinet" never falls through to the plain root),
    // and the same list is what we search the filename for.
    let aliasGroups: [[String]] = [
        ["contrabass clarinet", "contra bass clarinet", "contra clarinet"],
        ["bass clarinet", "bass clar"],
        ["clarinet", "bb clarinet", "b-flat clarinet", "clarinet in bb"],
        ["bass trombone", "bass tbn"],
        ["trombone", "tenor trombone"],
        ["trumpet", "bb trumpet", "trumpet in bb", "b-flat trumpet"],
        ["english horn", "cor anglais"],
        ["horn", "french horn", "horn in f", "f horn"],
        ["double bass", "string bass", "contrabass"],
        ["violin", "vln"],
        ["viola", "vla"],
        ["cello", "violoncello", "vlc"],
    ]
    return aliasGroups.first { $0.contains(base) } ?? []
}

/// Every filename phrase that should count as a match for preset `part` — the instrument's
/// aliases (see `instrumentAliasPhrases`) with any trailing part number re-attached, plus
/// the literal base as a fallback for custom/unrecognised names. `part` must already be
/// lowercased and roman-normalised.
func presetMatchPhrases(for part: String) -> [String] {
    let base = splitSuggestionBaseName(part)          // strips a trailing integer
    let words = part.split(separator: " ")
    let number = (words.count >= 2 && Int(words.last!) != nil) ? String(words.last!) : nil

    var phrases = instrumentAliasPhrases(forBase: base)
    if !phrases.contains(base) { phrases.append(base) }   // custom names match themselves
    guard let n = number else { return phrases }
    return phrases.map { "\($0) \(n)" }
}

/// True when `phrase` occurs in `filename` and isn't merely the tail of a more specific
/// instrument name — a preceding qualifier word the phrase itself lacks ("bass", "alto",
/// "english"…) means a different instrument, so the match is rejected. Both arguments must
/// be lowercased and roman-normalised.
func phraseOccurs(_ phrase: String, in filename: String) -> Bool {
    guard !phrase.isEmpty, let range = filename.range(of: phrase) else { return false }
    let before = filename[..<range.lowerBound]
    guard let lastWord = before.split(whereSeparator: { !$0.isLetter }).last else { return true }
    let qualifier = String(lastWord)
    if instrumentQualifierWords.contains(qualifier) && !phrase.hasPrefix(qualifier) {
        return false
    }
    return true
}

/// True when preset `part` should be assigned to a file named `filename`. Expands the part
/// into its equivalent instrument phrases (abbreviations, reversed sax order, aliases,
/// clef-preserved euphonium/baritone) and checks each against the filename with the
/// qualifier guard, so "Alto Sax" matches "Alto Saxophone", "Euphonium BC" matches a bass-
/// clef file but never the treble-clef one, and "Clarinet" never matches "Bass Clarinet".
/// Both arguments must already be lowercased and roman-normalised.
func presetPartMatches(part: String, in filename: String) -> Bool {
    for phrase in presetMatchPhrases(for: part) where phraseOccurs(phrase, in: filename) {
        return true
    }
    return false
}

/// After removing a part, strips the trailing number/numeral from any sibling that is now
/// the sole survivor of its base name.
/// E.g. delete "Horn 2" → "Horn 1" becomes "Horn"; delete "Violin II" → "Violin I" becomes "Violin".
func renumberAfterDeletion(_ parts: [PresetPart]) -> [PresetPart] {
    // Count remaining parts per base name (using normalised comparison)
    var baseCounts: [String: Int] = [:]
    for part in parts {
        if let base = numberedBase(of: part.name) {
            baseCounts[base, default: 0] += 1
        }
    }
    // Strip the trailing word (the number or numeral) from solo survivors
    return parts.map { part in
        if let base = numberedBase(of: part.name), baseCounts[base] == 1 {
            var renamed = part
            // Drop the last word from the *original* name to preserve capitalisation
            let words = part.name.split(separator: " ", omittingEmptySubsequences: true)
            renamed.name = words.dropLast().joined(separator: " ")
            return renamed
        }
        return part
    }
}

// MARK: - Split suggestion & instrument-name helpers

/// Returns the base name of an instrument by stripping a trailing integer.
/// "Flute 1" → "Flute", "Horn in F 3" → "Horn in F", "Score" → "Score"
private func splitSuggestionBaseName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    let parts = trimmed.components(separatedBy: " ")
    if parts.count >= 2, let last = parts.last, Int(last) != nil {
        return parts.dropLast().joined(separator: " ")
    }
    return trimmed
}

/// Normalises an instrument name to a canonical group key for alias matching.
/// "Alto Sax", "Alto Saxophone", "Alto" → "alto saxophone"
private func splitSuggestionGroupKey(_ name: String) -> String {
    let base = splitSuggestionBaseName(name).lowercased()
    let aliases: [(Set<String>, String)] = [
        (["alto sax", "alto saxophone", "alto"], "alto saxophone"),
        (["tenor sax", "tenor saxophone", "tenor"], "tenor saxophone"),
        (["soprano sax", "soprano saxophone"], "soprano saxophone"),
        (["baritone sax", "bari sax", "baritone saxophone", "bari"], "baritone saxophone"),
        (["bb clarinet", "b-flat clarinet", "clarinet in bb"], "clarinet"),
        (["bass clar", "bass clarinet"], "bass clarinet"),
        (["contra clarinet", "contrabass clarinet", "contra bass clarinet"], "contrabass clarinet"),
        (["bb trumpet", "trumpet in bb", "b-flat trumpet"], "trumpet"),
        (["french horn", "horn in f", "f horn"], "horn"),
        (["trombone", "tenor trombone"], "trombone"),
        (["bass tbn", "bass trombone"], "bass trombone"),
        (["string bass", "double bass", "contrabass"], "double bass"),
        (["vln", "violin"], "violin"),
        (["vla", "viola"], "viola"),
        (["vlc", "cello", "violoncello"], "cello"),
        // Euphonium and baritone are the *same* instrument (euphonium = baritone horn),
        // so all clef variants collapse to one identity — after a baritone, suggestions
        // roll on to tuba rather than offering euphonium separately. (They still display
        // as written, e.g. "Baritone BC", since display uses preferredInstrumentDisplayName.)
        (["euphonium treble clef", "euphonium t.c.", "euphonium tc",
          "euphonium bass clef",   "euphonium b.c.", "euphonium bc",
          "euphonium", "eupho",
          "baritone treble clef",  "baritone t.c.",  "baritone tc",
          "baritone bass clef",    "baritone b.c.",  "baritone bc",
          "baritone"], "euphonium"),
    ]
    for (variants, canonical) in aliases {
        if variants.contains(base) { return canonical }
    }
    return base
}

/// The companion clef for a baritone/euphonium part — "Baritone BC" ↔ "Baritone TC"
/// (any input spelling). Returns `nil` for anything that isn't a clef-paired instrument.
/// Built on `preferredInstrumentDisplayName`, which canonicalises every clef spelling.
func clefCompanion(for name: String) -> String? {
    let canonical = preferredInstrumentDisplayName(name)
    if canonical.hasSuffix(" BC") { return canonical.dropLast(2) + "TC" }
    if canonical.hasSuffix(" TC") { return canonical.dropLast(2) + "BC" }
    return nil
}

/// The preferred display/suggestion name for an instrument. The saxophone family is
/// canonicalised to its full name (any spelling/order of "Alto Sax", "Sax Alto",
/// "Special Alto Sax" → "Alto Saxophone") so suggestions read in full. Detection is
/// unaffected — it still matches the abbreviations in the instrument-order arrays.
/// Everything that isn't a saxophone is returned unchanged.
func preferredInstrumentDisplayName(_ name: String) -> String {
    let lower = name.lowercased()
    // Saxophone family → full name (any spelling/order).
    if lower.contains("sax") {
        let registers: [(needle: String, full: String)] = [
            ("sop",    "Soprano Saxophone"),
            ("alto",   "Alto Saxophone"),
            ("tenor",  "Tenor Saxophone"),
            ("bari",   "Baritone Saxophone"),   // "bari" or "baritone"
            ("bass",   "Bass Saxophone"),
        ]
        for (needle, full) in registers where lower.contains(needle) { return full }
        return name   // a bare "sax" with no register — leave as written
    }
    // Euphonium / baritone (the low brass — not the sax). Canonicalise the clef
    // variants to "X BC" / "X TC" (no full stops, so they read cleanly before ".pdf");
    // a bare name stays bare.
    if lower.contains("euphonium") || lower.contains("baritone") {
        let family = lower.contains("euphonium") ? "Euphonium" : "Baritone"
        if lower.contains("treble") || lower.contains("t.c") || lower.contains("tc") {
            return "\(family) TC"
        }
        if lower.contains("bass") || lower.contains("b.c") || lower.contains("bc") {
            return "\(family) BC"
        }
        return family
    }
    return name
}

/// A canonical key identifying *which instrument* a name is, collapsing all aliases —
/// including reversed word orders the group-key table misses (e.g. "Sax Alto" / "Alto
/// Sax" / "Alto Saxophone" all → "alto saxophone"). Used to skip same-instrument aliases
/// when finding the next distinct instrument for a suggestion.
func instrumentIdentityKey(_ name: String) -> String {
    let preferred = preferredInstrumentDisplayName(name)
    if preferred.lowercased().hasSuffix("saxophone") { return preferred.lowercased() }
    return splitSuggestionGroupKey(splitSuggestionBaseName(name))
}

/// Index of the next *distinct* instrument after `prev` in `order` — skips aliases of
/// `prev` (so "Tenor Saxophone" rolls to the next instrument, not another tenor spelling).
/// nil when `prev` isn't a recognised instrument.
func nextDistinctInstrumentIndex(after prev: String, in order: [String]) -> Int? {
    let prevKey = instrumentIdentityKey(prev)
    guard let idx = order.firstIndex(where: { instrumentIdentityKey($0) == prevKey }) else { return nil }
    var next = idx + 1
    while next < order.count, instrumentIdentityKey(order[next]) == prevKey { next += 1 }
    return min(next, order.count - 1)
}

/// Like `nextDistinctInstrumentIndex`, but first offers a not-yet-used bassoon after a
/// bass clarinet (some band part sets group the bassoon with the low reeds). Drives the
/// autocomplete dropdown's starting position.
func nextSuggestionIndex(after prev: String, in order: [String], usedKeys: Set<String>) -> Int? {
    if instrumentIdentityKey(prev) == "bass clarinet", !usedKeys.contains("bassoon"),
       let bsn = order.firstIndex(where: { instrumentIdentityKey($0) == "bassoon" }) {
        return bsn
    }
    return nextDistinctInstrumentIndex(after: prev, in: order)
}

/// Typical number of parts for common instrument families, **per ensemble** (used to
/// decide when a suggestion should cross to the next instrument). Band (concert/wind
/// band) is the base; jazz (big band) and orchestra override where they differ —
/// e.g. a band has 1 tenor sax and 3 trumpets, a big band has 2 tenors and 4 trumpets.
func splitSuggestionTypicalPartCount(_ baseName: String, ensemble: EnsembleType = .band) -> Int {
    let key = instrumentIdentityKey(baseName)
    let band: [String: Int] = [
        "flute": 2, "piccolo": 1, "oboe": 2, "english horn": 1, "bassoon": 2,
        "eb clarinet": 1, "clarinet": 3, "alto clarinet": 1, "bass clarinet": 1, "contrabass clarinet": 1,
        "soprano saxophone": 1, "alto saxophone": 2, "tenor saxophone": 1, "baritone saxophone": 1,
        "cornet": 3, "trumpet": 3, "horn": 4, "trombone": 3, "bass trombone": 1,
        "euphonium": 1, "baritone": 1, "tuba": 1,
        "percussion": 4, "timpani": 1,
    ]
    let jazz: [String: Int] = [   // big band
        "soprano saxophone": 1, "alto saxophone": 2, "tenor saxophone": 2, "baritone saxophone": 1,
        "cornet": 4, "trumpet": 4, "trombone": 4, "bass trombone": 1,
    ]
    let orchestra: [String: Int] = [
        "clarinet": 2, "trumpet": 2, "trombone": 3,
        "violin": 2, "viola": 1, "cello": 1, "double bass": 1,
    ]
    switch ensemble {
    case .band:      return band[key] ?? 2
    case .jazz:      return jazz[key] ?? band[key] ?? 2
    case .orchestra: return orchestra[key] ?? band[key] ?? 2
    }
}

/// If the previous suffix's number equals the typical part count for that family,
/// returns "NextInstrument 1" as a cross-boundary numbered suggestion.
/// E.g. after "Flute 2" (typical=2) → "Oboe 1" if Oboe follows Flute in the list.
func splitSuggestionStartingNumberedName(
    prevSuffix: String,
    instrumentNames: [String],
    ensemble: EnsembleType = .band
) -> String? {
    let prev = prevSuffix.trimmingCharacters(in: .whitespaces)
    guard !prev.isEmpty else { return nil }
    let parts = prev.components(separatedBy: " ")
    guard parts.count >= 2,
          let last = parts.last, let n = Int(last), n > 0
    else { return nil }
    let basePart = parts.dropLast().joined(separator: " ")
    let typical = splitSuggestionTypicalPartCount(basePart, ensemble: ensemble)
    guard n >= typical else { return nil }
    // The next distinct instrument after this one (shared with the dropdown logic).
    guard let nextIdx = nextDistinctInstrumentIndex(after: basePart, in: instrumentNames) else { return nil }
    let rawNextName = splitSuggestionBaseName(instrumentNames[nextIdx])
    let nextName = preferredInstrumentDisplayName(rawNextName)   // full name, e.g. "Tenor Saxophone"
    // Append "1" only when the next instrument typically has more than one part;
    // single-part instruments (Bass Trombone, Tuba, …) stay bare.
    return splitSuggestionTypicalPartCount(rawNextName, ensemble: ensemble) > 1 ? "\(nextName) 1" : nextName
}

/// Deduplicates a list by collapsing numbered variants to their base name.
/// ["Flute 1", "Flute 2", "Oboe", "Oboe 1"] → ["Flute", "Oboe"]
func splitSuggestionDisplayNames(_ names: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for name in names {
        // Canonicalise to the preferred display name first, so the abbreviated sax
        // variants ("Alto Sax", "Sax Alto") collapse into one full "Alto Saxophone".
        let base = preferredInstrumentDisplayName(splitSuggestionBaseName(name))
        let key = base.lowercased()
        if seen.insert(key).inserted {
            result.append(base)
        }
    }
    return result
}

/// Infers the most likely ensemble type from the first suffix the user types.
/// Returns nil if no confident match is found.
/// Infers the ensemble type from the part names entered so far, **in file order**, but
/// only on a high-confidence signal — otherwise nil, leaving the user's sticky choice
/// untouched rather than guessing wrong:
///  • a bowed string anywhere (violin / viola / cello) → orchestra. Those never appear in
///    band or jazz. (Double/string bass are excluded — jazz uses an upright "string bass".)
///  • the first named part is a saxophone → jazz. Band and orchestra always lead with
///    flute/piccolo and never put a sax first; jazz score order starts with the saxes.
///    (Saxes *elsewhere* in the list aren't a signal — wind bands have them too.)
/// Deliberately makes no band-vs-jazz call from otherwise-shared instruments (rhythm,
/// drum set, electric bass all appear in modern wind bands).
func inferredSplitSuggestionEnsemble(_ orderedSuffixes: [String]) -> EnsembleType? {
    let lowered = orderedSuffixes.map { $0.lowercased() }
    let stringKeywords = ["violin", "viola", "cello"]
    for suffix in lowered {
        for kw in stringKeywords where suffix.contains(kw) { return .orchestra }
    }
    if let firstNamed = lowered.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
       firstNamed.contains("sax") {
        return .jazz
    }
    return nil
}

// MARK: - Instrument detection (order-list matching)

/// Matches the best instrument name in `filename` against `order`, returning the
/// order-list index (0-based) or nil.  Mirrors RenamerManager.detectInstrument but
/// works as a free function so it can be used by PrefixOrderStepView without a manager.
func matchInstrumentOrder(in filename: String, order: [String]) -> Int? {
    let lower = filename.lowercased()
    let sorted = order.enumerated()
        .map { ($0.offset, $0.element) }
        .sorted { $0.1.count > $1.1.count }   // longest first → "bass clarinet" beats "clarinet"
    var matches: [(index: Int, position: Int)] = []
    for (idx, instrument) in sorted {
        if let range = lower.range(of: instrument.lowercased()) {
            let pos = lower.distance(from: lower.startIndex, to: range.lowerBound)
            matches.append((idx, pos))
        }
    }
    return matches.min(by: { $0.position < $1.position })?.index
}
