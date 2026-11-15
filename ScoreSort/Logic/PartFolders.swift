//
//  PartFolders.swift
//  ScoreSort
//
//  "Sort into folders": saving split parts, or renaming them, into one folder per section
//  (Woodwind, Brass, Percussion…) or per instrument (Flute, Clarinet…), so each group of
//  players can be given just their own folder rather than every part.
//
//  Shared by Split (Steps 2–3), the Rename tab's two panels and the command line. The folder
//  comes from the file name alone: the leftmost instrument it names (as the Score Order Sorter
//  does), with the longest phrase winning a tie so "Bass Clarinet" beats "Bass". The score and
//  anything unrecognised stay at the top level.
//

import Foundation

nonisolated enum PartFolderMode: String, CaseIterable, Sendable {
    case off
    case section
    case instrument

    var title: String {
        switch self {
        case .off:        return "Off"
        case .section:    return "By Section"
        case .instrument: return "By Instrument"
        }
    }

    /// The remembered setting — Settings ▸ Renamer and every "Sort into folders" menu show and
    /// change this one value.
    static let defaultsKey = "partFolderDefault"

    static var savedDefault: PartFolderMode {
        PartFolderMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .off
    }

    /// Settings ▸ Renamer ▸ "Number section folders" ("1 Woodwind", "2 Brass"…).
    static let numberedDefaultsKey = "partFolderNumbered"

    /// That setting — always off under the test runner, so tests never depend on it.
    static var numbersSections: Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
        return UserDefaults.standard.bool(forKey: numberedDefaultsKey)
    }
}

/// What kind of instrument a phrase names — enough to place it in a section for any ensemble.
private enum PartFamily {
    case score
    case woodwind, saxophone
    case trumpet, horn, lowBrass
    case percussion, drumKit
    case keyboard, guitar, bassGuitar
    case strings, stringBass
    case voice
}

private struct PartFolderEntry {
    let phrases: [String]
    let family: PartFamily
    /// The folder "By Instrument" uses.
    let instrument: String
}

/// Phrases are lowercase whole words, as file names read once punctuation becomes spaces.
private let partFolderEntries: [PartFolderEntry] = [
    PartFolderEntry(phrases: ["score", "full score", "conductor", "conductor score", "conductors score",
                              "conductor s score"], family: .score, instrument: ""),

    // Woodwind
    PartFolderEntry(phrases: ["piccolo", "picc"], family: .woodwind, instrument: "Piccolo"),
    PartFolderEntry(phrases: ["flute", "flutes", "fl", "alto flute"], family: .woodwind, instrument: "Flute"),
    PartFolderEntry(phrases: ["oboe", "oboes", "ob", "oboe d amore"], family: .woodwind, instrument: "Oboe"),
    PartFolderEntry(phrases: ["english horn", "cor anglais"], family: .woodwind, instrument: "English Horn"),
    PartFolderEntry(phrases: ["bassoon", "bassoons", "bsn", "contrabassoon"], family: .woodwind, instrument: "Bassoon"),
    PartFolderEntry(phrases: ["clarinet", "clarinets", "cl", "clar", "eb clarinet", "e flat clarinet",
                              "bb clarinet", "b flat clarinet", "clarinet in bb", "clarinet in a"],
                    family: .woodwind, instrument: "Clarinet"),
    PartFolderEntry(phrases: ["bass clarinet", "bass clarinets"], family: .woodwind, instrument: "Bass Clarinet"),
    PartFolderEntry(phrases: ["alto clarinet"], family: .woodwind, instrument: "Alto Clarinet"),
    PartFolderEntry(phrases: ["contrabass clarinet", "contra alto clarinet", "contralto clarinet"],
                    family: .woodwind, instrument: "Contrabass Clarinet"),
    PartFolderEntry(phrases: ["recorder", "recorders"], family: .woodwind, instrument: "Recorder"),

    // Saxophones
    PartFolderEntry(phrases: ["soprano sax", "soprano saxophone", "sop sax", "sop saxophone", "sax soprano",
                              "saxophone soprano"], family: .saxophone, instrument: "Soprano Saxophone"),
    PartFolderEntry(phrases: ["alto sax", "alto saxophone", "alto saxes", "alto saxophones", "sax alto",
                              "saxophone alto", "alto", "altos", "asax"], family: .saxophone, instrument: "Alto Saxophone"),
    PartFolderEntry(phrases: ["tenor sax", "tenor saxophone", "tenor saxes", "sax tenor", "saxophone tenor",
                              "tenor", "tenors", "tsax"], family: .saxophone, instrument: "Tenor Saxophone"),
    PartFolderEntry(phrases: ["bari sax", "bari saxophone", "baritone sax", "baritone saxophone", "sax bari",
                              "sax baritone", "saxophone bari", "saxophone baritone", "bari", "bsax"],
                    family: .saxophone, instrument: "Baritone Saxophone"),
    PartFolderEntry(phrases: ["bass sax", "bass saxophone"], family: .saxophone, instrument: "Bass Saxophone"),
    PartFolderEntry(phrases: ["sax", "saxophone", "saxes", "saxophones"], family: .saxophone, instrument: "Saxophone"),

    // Brass
    PartFolderEntry(phrases: ["trumpet", "trumpets", "tpt", "trp", "piccolo trumpet"], family: .trumpet, instrument: "Trumpet"),
    PartFolderEntry(phrases: ["cornet", "cornets"], family: .trumpet, instrument: "Cornet"),
    PartFolderEntry(phrases: ["flugelhorn", "flugelhorns", "flugel", "flugel horn"], family: .trumpet, instrument: "Flugelhorn"),
    PartFolderEntry(phrases: ["horn", "horns", "french horn", "french horns", "horn in f", "f horn", "hn"],
                    family: .horn, instrument: "Horn"),
    PartFolderEntry(phrases: ["tenor horn"], family: .horn, instrument: "Tenor Horn"),
    PartFolderEntry(phrases: ["trombone", "trombones", "tbn", "trb", "tenor trombone"], family: .lowBrass, instrument: "Trombone"),
    PartFolderEntry(phrases: ["bass trombone", "trombone bass", "bass tbn"], family: .lowBrass, instrument: "Bass Trombone"),
    PartFolderEntry(phrases: ["euphonium", "euphoniums", "euph", "eupho"], family: .lowBrass, instrument: "Euphonium"),
    PartFolderEntry(phrases: ["baritone horn", "baritone"], family: .lowBrass, instrument: "Baritone"),
    PartFolderEntry(phrases: ["tuba", "tubas", "sousaphone", "eb tuba", "bb tuba"], family: .lowBrass, instrument: "Tuba"),

    // Percussion
    PartFolderEntry(phrases: ["timpani", "timp", "timps"], family: .percussion, instrument: "Timpani"),
    PartFolderEntry(phrases: ["mallet percussion", "mallets", "mallet", "bells", "orchestra bells", "glockenspiel",
                              "glock", "xylophone", "xylo", "vibraphone", "vibes", "marimba", "chimes",
                              "tubular bells", "crotales"], family: .percussion, instrument: "Mallet Percussion"),
    PartFolderEntry(phrases: ["percussion", "perc", "auxiliary", "aux", "aux percussion", "auxiliary percussion",
                              "snare", "snare drum", "bass drum", "cymbal", "cymbals", "crash cymbals",
                              "suspended cymbal", "tambourine", "triangle", "congas", "bongos", "timbales",
                              "shaker", "claves", "woodblock", "wood block", "gong", "tam tam", "toms",
                              "concert toms", "tenor drum"], family: .percussion, instrument: "Percussion"),
    PartFolderEntry(phrases: ["drums", "drum set", "drumset", "drum kit", "drumkit", "kit"], family: .drumKit, instrument: "Drums"),

    // Rhythm (in a band these go in Brass)
    PartFolderEntry(phrases: ["piano", "pno"], family: .keyboard, instrument: "Piano"),
    PartFolderEntry(phrases: ["keyboard", "keyboards", "keys", "kbd", "synth", "synthesizer"], family: .keyboard, instrument: "Keyboard"),
    PartFolderEntry(phrases: ["organ"], family: .keyboard, instrument: "Organ"),
    PartFolderEntry(phrases: ["celesta", "celeste"], family: .keyboard, instrument: "Celesta"),
    PartFolderEntry(phrases: ["guitar", "guitars", "gtr", "electric guitar", "acoustic guitar"], family: .guitar, instrument: "Guitar"),
    PartFolderEntry(phrases: ["bass guitar", "electric bass", "bass gtr"], family: .bassGuitar, instrument: "Bass Guitar"),

    // Strings
    PartFolderEntry(phrases: ["violin", "violins", "vln", "vn"], family: .strings, instrument: "Violin"),
    PartFolderEntry(phrases: ["viola", "violas", "vla"], family: .strings, instrument: "Viola"),
    PartFolderEntry(phrases: ["cello", "cellos", "celli", "violoncello", "vc"], family: .strings, instrument: "Cello"),
    PartFolderEntry(phrases: ["harp"], family: .strings, instrument: "Harp"),
    PartFolderEntry(phrases: ["string bass", "double bass", "contrabass", "basses", "bass"], family: .stringBass, instrument: "Bass"),

    // Voices
    PartFolderEntry(phrases: ["voice", "voices", "vocal", "vocals", "vox", "vocalist", "choir"], family: .voice, instrument: "Vocals"),
]

/// The section folders for an ensemble, in score order — offered by "Move to Folder".
/// `numbered`: "1 Woodwind", "2 Brass"… (each section keeps its number whichever are used,
/// so pieces split into one folder share the same folders).
func partFolderSections(for ensemble: EnsembleType, numbered: Bool = false) -> [String] {
    let sections: [String]
    switch ensemble {
    case .jazz:      sections = ["Saxophones", "Trumpets", "Trombones", "Rhythm", "Strings", "Vocals"]
    case .band:      sections = ["Woodwind", "Brass", "Percussion", "Strings", "Vocals"]
    case .orchestra: sections = ["Woodwind", "Brass", "Percussion", "Rhythm", "Strings", "Vocals"]
    }
    return numbered ? sections.enumerated().map { "\($0.offset + 1) \($0.element)" } : sections
}

/// A section folder's numbered name ("2 Brass"), or `section` if it isn't one of the ensemble's.
func numberedPartSection(_ section: String, ensemble: EnsembleType) -> String {
    guard let index = partFolderSections(for: ensemble).firstIndex(of: section) else { return section }
    return "\(index + 1) \(section)"
}

/// A folder name without a leading section number: "2 Brass" → "Brass".
func partFolderBaseName(_ name: String) -> String {
    guard let match = name.firstMatch(of: /^\d+\s+(.+)$/) else { return name }
    return String(match.output.1)
}

/// Why a folder name typed by the person can't be used, or nil when it's fine.
func partFolderNameError(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return "Give the folder a name." }
    if trimmed.contains("/") || trimmed.contains(":") { return "A folder name can't contain “/” or “:”." }
    if trimmed.hasPrefix(".") { return "A folder name can't start with a full stop (it would be hidden)." }
    return nil
}

/// The section a family belongs to in this ensemble; nil for the score.
private func partSection(_ family: PartFamily, ensemble: EnsembleType) -> String? {
    if ensemble == .jazz {
        switch family {
        case .score:                                    return nil
        case .woodwind, .saxophone:                     return "Saxophones"
        case .trumpet:                                  return "Trumpets"
        case .horn, .lowBrass:                          return "Trombones"
        case .percussion, .drumKit, .keyboard, .guitar,
             .bassGuitar, .stringBass:                  return "Rhythm"
        case .strings:                                  return "Strings"
        case .voice:                                    return "Vocals"
        }
    }
    // A concert band's piano, string bass and other rhythm parts sit with the brass (Ben,
    // 2026-11-16); an orchestra keeps a Rhythm folder and its basses in Strings.
    let band = ensemble == .band
    switch family {
    case .score:                                        return nil
    case .woodwind, .saxophone:                         return "Woodwind"
    case .trumpet, .horn, .lowBrass:                    return "Brass"
    case .percussion, .drumKit:                         return "Percussion"
    case .keyboard, .guitar, .bassGuitar:               return band ? "Brass" : "Rhythm"
    case .stringBass:                                   return band ? "Brass" : "Strings"
    case .strings:                                      return "Strings"
    case .voice:                                        return "Vocals"
    }
}

/// The file name as whole words: lowercase, extension dropped, punctuation as spaces, with a
/// space at each end so a phrase can be found as " phrase ".
private func partFolderWords(_ fileName: String) -> String {
    var name = fileName.lowercased()
    if name.hasSuffix(".pdf") { name = String(name.dropLast(4)) }
    let spaced = String(name.map { $0.isLetter || $0.isNumber ? $0 : " " })
    return " " + spaced.split(separator: " ").joined(separator: " ") + " "
}

/// The folder a part named `fileName` belongs in, or nil for the score, an unrecognised name,
/// or `.off`.
func partFolderName(forFileName fileName: String, mode: PartFolderMode, ensemble: EnsembleType,
                    numbered: Bool = false) -> String? {
    guard mode != .off else { return nil }
    var words = partFolderWords(fileName)
    // A clef ("Baritone B.C.", "Bass Clef Euphonium") marks the brass baritone, and its
    // "bass" mustn't be read as a string bass.
    let hasClef = [" bass clef ", " treble clef ", " b c ", " t c ", " bc ", " tc "].contains { words.contains($0) }
    for clef in [" bass clef ", " treble clef "] { words = words.replacingOccurrences(of: clef, with: " ") }

    // Leftmost phrase wins; at the same spot, the longest.
    var best: (position: Int, length: Int, entry: PartFolderEntry)? = nil
    for entry in partFolderEntries {
        for phrase in entry.phrases {
            guard let range = words.range(of: " \(phrase) ") else { continue }
            let position = words.distance(from: words.startIndex, to: range.lowerBound)
            if best == nil || position < best!.position || (position == best!.position && phrase.count > best!.length) {
                best = (position, phrase.count, entry)
            }
        }
    }
    guard var entry = best?.entry else { return nil }

    // A bare "Baritone" is the low brass in a band or orchestra, but the bari sax in a big
    // band (unless a clef says otherwise).
    if entry.instrument == "Baritone", ensemble == .jazz, !hasClef, !words.contains(" baritone horn ") {
        entry = PartFolderEntry(phrases: [], family: .saxophone, instrument: "Baritone Saxophone")
    }

    switch mode {
    case .off:        return nil
    case .section:    return partSection(entry.family, ensemble: ensemble)
                            .map { numbered ? numberedPartSection($0, ensemble: ensemble) : $0 }
    case .instrument: return entry.family == .score ? nil : entry.instrument
    }
}

/// The folder for one split or bulk-renamed part, read from its part name (the suffix) rather
/// than the whole file name, whose piece name can name an instrument ("Trumpet Voluntary -
/// Flute 1"). A part with no name of its own (a single file kept under its own name) goes by
/// the whole file name.
func partFolderName(partName: String, fileName: String, mode: PartFolderMode, ensemble: EnsembleType,
                    numbered: Bool = false) -> String? {
    let part = partName.trimmingCharacters(in: .whitespaces)
    return partFolderName(forFileName: part.isEmpty ? fileName : part, mode: mode, ensemble: ensemble,
                          numbered: numbered)
}

/// `fileName` inside `folder` ("Woodwind/01 - Flute 1.pdf"), or unchanged with no folder.
func partFolderPath(_ fileName: String, folder: String?) -> String {
    guard let folder else { return fileName }
    return "\(folder)/\(fileName)"
}

/// Where a file at `url` goes when sorted: into its folder beside it — unless it's already in
/// a folder of that name, so sorting a sorted folder again doesn't nest them. `partName`, when
/// known, decides the folder (see `partFolderName(partName:…)`).
func partFolderDestination(for url: URL, partName: String? = nil, mode: PartFolderMode, ensemble: EnsembleType,
                           numbered: Bool = false) -> URL {
    partFolderDestination(for: url, folder: partFolderName(partName: partName ?? "", fileName: url.lastPathComponent,
                                                           mode: mode, ensemble: ensemble, numbered: numbered))
}

/// Every folder name "Sort into folders" makes, lowercased: each ensemble's sections and
/// every instrument folder.
let allPartFolderNames: Set<String> = Set(
    ([EnsembleType.band, .jazz, .orchestra].flatMap { partFolderSections(for: $0) } + partFolderEntries.map(\.instrument))
        .map { $0.lowercased() })

/// A folder named like one "Sort into folders" makes (Woodwind, "2 Brass", Trumpet…).
func isPartFolderName(_ name: String) -> Bool {
    allPartFolderNames.contains(partFolderBaseName(name).lowercased())
}

/// The part folders directly inside `folder` that hold parts: a piece's Woodwind, Brass…
func partSubfolders(of folder: URL) -> [URL] {
    let items = (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    return items.filter { urlIsDirectory($0) && isPartFolderName($0.lastPathComponent) }
        .filter { !renamableFiles(in: $0, recursive: false).isEmpty }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

/// The piece folder a part belongs to: the folder it's in — or, for a part in a part folder
/// (Woodwind, Trumpet…) directly inside `root`, `root` itself. Sorting into folders and
/// gathering parts back out both work from here. With no `root`, always the file's folder.
func partPieceFolder(of url: URL, root: URL?) -> URL {
    let parent = url.deletingLastPathComponent()
    guard let root, isPartFolderName(parent.lastPathComponent),
          parent.deletingLastPathComponent().resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path
    else { return parent }
    return root
}

/// `url` moved into `folder` beside it (nil: left where it is), without nesting a file
/// already in a folder of that name — numbered or not ("Brass" and "2 Brass" count as one).
func partFolderDestination(for url: URL, folder: String?) -> URL {
    let parent = url.deletingLastPathComponent()
    guard let folder, !folder.isEmpty,
          partFolderBaseName(parent.lastPathComponent).caseInsensitiveCompare(partFolderBaseName(folder)) != .orderedSame
    else { return url }
    return parent.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(url.lastPathComponent)
}
