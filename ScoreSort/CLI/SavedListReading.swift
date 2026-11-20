//
//  SavedListReading.swift
//  ScoreSort
//
//  The command line's view of the saved presets and stamps: what could be read, and — when
//  something couldn't — a sentence saying why, so `presets`, `stamps`, `combine --preset`
//  and `--stamp` never answer "no presets" or "not found" when the truth is "the file is
//  damaged".
//
//  Read-only, always: the CLI never sets a file aside or rewrites it. That's the app's job
//  (`SavedListFile`), done once, with a notice the person sees.
//

import Foundation

/// A saved list as the command line reads it.
struct CLISavedList<Entry> {
    /// The entries that could be read.
    var entries: [Entry] = []
    /// Why the file couldn't be read at all, as a full sentence; nil if it was read (or
    /// there's no file yet — a first run).
    var unreadable: String?
    /// Entries in an otherwise readable file that couldn't be read, and are left out.
    var skipped = 0

    /// One sentence about anything that wasn't read, or nil when everything was.
    var problem: String? {
        unreadable ?? skippedNote
    }

    private var skippedNote: String?

    init(reading url: URL?, kind: SavedListKind) where Entry: Decodable {
        guard let url else { return }
        let place = "“\(url.path)”"
        switch readSavedList(Entry.self, at: url) {
        case .missing:
            break
        case .loaded(let entries, let bad):
            self.entries = entries
            skipped = bad
            if bad > 0 {
                skippedNote = "\(bad) saved \(bad == 1 ? kind.singular : kind.plural) in \(place) couldn't be read, so \(bad == 1 ? "it is" : "they are") left out. The next time ScoreSort opens, it keeps a copy of the whole file."
            }
        case .unreadable(let reason):
            unreadable = "ScoreSort couldn't read the file your saved \(kind.plural) are kept in (\(place)): \(reason). The command line leaves it untouched; the next time ScoreSort opens, it keeps the file under a new name and starts a new list."
        }
    }

    /// For "no such preset / stamp" messages: a sentence to add when the one asked for might
    /// be among what couldn't be read. Empty when everything was read.
    var mightBeUnreadable: String {
        guard let problem else { return "" }
        return " " + problem
    }
}

extension ScoreSortCLI {
    /// The ensemble presets saved in the app (`ensemble-presets.json`). `url` is injectable so
    /// tests read a file in a temporary folder, never the real one.
    static func savedPresets(at url: URL? = EnsemblePresetStore.defaultFileURL) -> CLISavedList<EnsemblePreset> {
        CLISavedList(reading: url, kind: .presets)
    }

    /// The stamp designs saved in the app (`stamps.json`) — not the placeholder the app shows
    /// when there are none (`StampStore()` seeds one). `url` is injectable, as above.
    static func savedStamps(at url: URL? = StampStore.defaultFileURL) -> CLISavedList<Stamp> {
        CLISavedList(reading: url, kind: .stamps)
    }
}
