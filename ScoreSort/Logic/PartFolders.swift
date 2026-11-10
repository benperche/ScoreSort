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

    /// The Settings default (Settings ▸ Renamer), which each tab's menu starts from.
    static let defaultsKey = "partFolderDefault"

    static var savedDefault: PartFolderMode {
        PartFolderMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .off
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

    // Rhythm
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
func partFolderSections(for ensemble: EnsembleType) -> [String] {
    ensemble == .jazz
        ? ["Saxophones", "Trumpets", "Trombones", "Rhythm", "Strings", "Vocals"]
        : ["Woodwind", "Brass", "Percussion", "Rhythm", "Strings", "Vocals"]
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
    switch family {
    case .score:                                        return nil
    case .woodwind, .saxophone:                         return "Woodwind"
    case .trumpet, .horn, .lowBrass:                    return "Brass"
    case .percussion, .drumKit:                         return "Percussion"
    case .keyboard, .guitar, .bassGuitar:               return "Rhythm"
    case .strings, .stringBass:                         return "Strings"
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
func partFolderName(forFileName fileName: String, mode: PartFolderMode, ensemble: EnsembleType) -> String? {
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
    case .instrument: return entry.family == .score ? nil : entry.instrument
    }
}

/// The folder for one split or bulk-renamed part, read from its part name (the suffix) rather
/// than the whole file name, whose piece name can name an instrument ("Trumpet Voluntary -
/// Flute 1"). A part with no name of its own (a single file kept under its own name) goes by
/// the whole file name.
func partFolderName(partName: String, fileName: String, mode: PartFolderMode, ensemble: EnsembleType) -> String? {
    let part = partName.trimmingCharacters(in: .whitespaces)
    return partFolderName(forFileName: part.isEmpty ? fileName : part, mode: mode, ensemble: ensemble)
}

/// `fileName` inside `folder` ("Woodwind/01 - Flute 1.pdf"), or unchanged with no folder.
func partFolderPath(_ fileName: String, folder: String?) -> String {
    guard let folder else { return fileName }
    return "\(folder)/\(fileName)"
}

/// Where a file at `url` goes when sorted: into its folder beside it — unless it's already in
/// a folder of that name, so sorting a sorted folder again doesn't nest them. `partName`, when
/// known, decides the folder (see `partFolderName(partName:…)`).
func partFolderDestination(for url: URL, partName: String? = nil, mode: PartFolderMode, ensemble: EnsembleType) -> URL {
    partFolderDestination(for: url, folder: partFolderName(partName: partName ?? "", fileName: url.lastPathComponent,
                                                           mode: mode, ensemble: ensemble))
}

/// `url` moved into `folder` beside it (nil: left where it is), without nesting a file
/// already in a folder of that name.
func partFolderDestination(for url: URL, folder: String?) -> URL {
    let parent = url.deletingLastPathComponent()
    guard let folder, !folder.isEmpty,
          parent.lastPathComponent.caseInsensitiveCompare(folder) != .orderedSame else { return url }
    return parent.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(url.lastPathComponent)
}
