//
//  SavedListFileTests.swift
//  ScoreSortTests
//
//  The saved lists — ensemble presets and stamps — must never be lost because the file
//  couldn't be read (issue #8). Everything here works in a temporary folder: the stores take
//  an injected file URL, so the real Application Support folder is never touched.
//

import Testing
import Foundation
import SwiftUI
import AppKit
@testable import ScoreSort

/// A temporary folder, and the helpers the suites below share. Each test removes it with
/// `defer { scratch.cleanUp() }`.
private struct Scratch {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScoreSortSavedListTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func cleanUp() {
        // In case a test left the folder read-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }

    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    @discardableResult
    func write(_ text: String, to name: String) throws -> Data {
        let data = Data(text.utf8)
        try data.write(to: file(name))
        return data
    }

    /// The set-aside copies in the folder ("… (unreadable 2026-11-16).json").
    func setAside() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("(unreadable ") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

private let twoGoodPresetsAndOneBad = """
[
  {"id":"11111111-1111-1111-1111-111111111111","name":"Concert Band",
   "parts":[{"id":"AAAAAAAA-0000-0000-0000-000000000001","name":"Flute","copies":4}]},
  {"id":"not-a-uuid","name":"From the future","parts":"something this version can't decode"},
  {"id":"22222222-2222-2222-2222-222222222222","name":"Stage Band",
   "parts":[{"id":"AAAAAAAA-0000-0000-0000-000000000002","name":"Trumpet 1","copies":2}]}
]
"""

// MARK: - The shared loader

@Suite("Saved list files: reading")
struct SavedListReadingTests {

    @Test("no file is 'missing', not an error")
    func missing() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        guard case .missing = readSavedList(EnsemblePreset.self, at: scratch.file("ensemble-presets.json")) else {
            Issue.record("expected .missing")
            return
        }
    }

    @Test("a damaged file is 'unreadable'", arguments: [
        "{ \"half\": \"writt",          // cut off mid-write
        "",                              // empty
        "{\"presets\": []}",             // not a list
        "[\"a\", 3, {\"name\": 5}]",     // a list, but nothing in it is a preset
    ])
    func unreadable(contents: String) throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.write(contents, to: "ensemble-presets.json")
        guard case .unreadable(let reason) = readSavedList(EnsemblePreset.self, at: scratch.file("ensemble-presets.json")) else {
            Issue.record("expected .unreadable for \(contents)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("an empty list is a loaded, empty list")
    func emptyList() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.write("[]", to: "ensemble-presets.json")
        guard case .loaded(let entries, let bad) = readSavedList(EnsemblePreset.self, at: scratch.file("ensemble-presets.json")) else {
            Issue.record("expected .loaded")
            return
        }
        #expect(entries.isEmpty)
        #expect(bad == 0)
    }

    @Test("one bad entry doesn't take the others with it, and reading changes nothing on disk")
    func entryByEntry() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let original = try scratch.write(twoGoodPresetsAndOneBad, to: "ensemble-presets.json")
        guard case .loaded(let entries, let bad) = readSavedList(EnsemblePreset.self, at: scratch.file("ensemble-presets.json")) else {
            Issue.record("expected .loaded")
            return
        }
        #expect(entries.map(\.name) == ["Concert Band", "Stage Band"])
        #expect(entries.first?.parts.first?.copies == 4)
        #expect(bad == 1)
        // This is the path the command line uses: read-only.
        #expect(try Data(contentsOf: scratch.file("ensemble-presets.json")) == original)
        #expect(try scratch.setAside().isEmpty)
    }

    @Test("the set-aside name carries the date, and never replaces an earlier copy")
    func setAsideNaming() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("ensemble-presets.json")
        let date = day(2026, 11, 16)
        #expect(setAsideURL(for: url, today: date).lastPathComponent == "ensemble-presets (unreadable 2026-11-16).json")
        try scratch.write("first", to: "ensemble-presets (unreadable 2026-11-16).json")
        #expect(setAsideURL(for: url, today: date).lastPathComponent == "ensemble-presets (unreadable 2026-11-16 2).json")
        try scratch.write("second", to: "ensemble-presets (unreadable 2026-11-16 2).json")
        #expect(setAsideURL(for: url, today: date).lastPathComponent == "ensemble-presets (unreadable 2026-11-16 3).json")
    }

    @Test("an unreadable file is moved to the dated name and reported once")
    func loadSetsAside() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("ensemble-presets.json")
        let original = try scratch.write("not json at all", to: "ensemble-presets.json")

        var file = SavedListFile<EnsemblePreset>(url: url, kind: .presets)
        let first = file.load(today: day(2026, 11, 16))
        let copy = scratch.file("ensemble-presets (unreadable 2026-11-16).json")
        #expect(first.entries.isEmpty)
        #expect(first.notices.count == 1)
        #expect(first.notices.first?.fileURL == copy)
        #expect(first.notices.first?.message.contains("ensemble-presets (unreadable 2026-11-16).json") == true)
        #expect(try Data(contentsOf: copy) == original)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!file.savingBlocked)

        // The next launch finds no file: a clean first run, with nothing more to say.
        var again = SavedListFile<EnsemblePreset>(url: url, kind: .presets)
        let second = again.load(today: day(2026, 11, 17))
        #expect(second.entries.isEmpty)
        #expect(second.notices.isEmpty)
        #expect(try scratch.setAside().count == 1)
    }
}

// MARK: - Ensemble presets

@Suite("Preset store: the saved file is never lost")
struct PresetStoreFileTests {

    @Test("damaged file: the store is empty, the bytes survive, and a later save doesn't destroy them")
    func damagedFile() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("ensemble-presets.json")
        let original = try scratch.write("[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"name\":\"Concert Ba", to: "ensemble-presets.json")

        let store = EnsemblePresetStore(fileURL: url)
        #expect(store.presets.isEmpty)
        #expect(store.selectedPresetId == nil)
        #expect(store.notices.count == 1)

        let copies = try scratch.setAside()
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: copies[0]) == original)
        // (Names, not URLs: the folder listing spells the temporary path /private/var, not /var.)
        #expect(store.notices.first?.fileURL?.lastPathComponent == copies.first?.lastPathComponent)
        #expect(store.notices.first?.message.contains(copies[0].lastPathComponent) == true)

        store.addPreset(name: "New Band", parts: [PresetPart(name: "Score", copies: 1)])
        store.save()

        #expect(try Data(contentsOf: copies[0]) == original)        // still there, untouched
        #expect(try scratch.setAside().count == 1)
        #expect(store.notices.count == 1)                            // told once
        let reopened = EnsemblePresetStore(fileURL: url)
        #expect(reopened.presets.map(\.name) == ["New Band"])
        #expect(reopened.notices.isEmpty)
    }

    @Test("one malformed entry among good ones: the good ones load, the original is kept whole")
    func oneBadEntry() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("ensemble-presets.json")
        let original = try scratch.write(twoGoodPresetsAndOneBad, to: "ensemble-presets.json")

        let store = EnsemblePresetStore(fileURL: url)
        #expect(store.presets.map(\.name) == ["Concert Band", "Stage Band"])
        #expect(store.selectedPresetId == store.presets.first?.id)
        #expect(store.notices.count == 1)
        #expect(store.notices.first?.title == "1 saved preset couldn't be read")
        #expect(store.notices.first?.message.contains("2 presets") == true)

        // The entry that failed is preserved, byte for byte, in the set-aside copy.
        let copies = try scratch.setAside()
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: copies[0]) == original)

        // The list was rewritten with what loaded, so the next launch is quiet and complete.
        let reopened = EnsemblePresetStore(fileURL: url)
        #expect(reopened.presets == store.presets)
        #expect(reopened.notices.isEmpty)
        #expect(try scratch.setAside().count == 1)
    }

    @Test("missing file: an empty store, nothing said, nothing written")
    func missingFile() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("ensemble-presets.json")
        let store = EnsemblePresetStore(fileURL: url)
        #expect(store.presets.isEmpty)
        #expect(store.selectedPresetId == nil)
        #expect(store.notices.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.folder.path).isEmpty)
    }

    @Test("a file from this version round-trips unchanged")
    func roundTrip() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("ensemble-presets.json")
        let stampId = UUID()

        let writer = EnsemblePresetStore(fileURL: url)
        writer.addPreset(name: "Concert Band", parts: [PresetPart(name: "Flute 1", copies: 3),
                                                       PresetPart(name: "Tuba", copies: 2)])
        writer.addPreset(name: "Stage Band", parts: [PresetPart(name: "Alto Sax 1", copies: 1)])
        var linked = writer.presets[1]
        linked.stampId = stampId
        writer.updatePreset(linked)
        let written = try Data(contentsOf: url)

        // Still a bare array, as older versions and the command line expect.
        let plain = try JSONDecoder().decode([EnsemblePreset].self, from: written)
        #expect(plain == writer.presets)

        let reader = EnsemblePresetStore(fileURL: url)
        #expect(reader.presets == writer.presets)
        #expect(reader.presets[1].stampId == stampId)
        #expect(reader.notices.isEmpty)
        #expect(try Data(contentsOf: url) == written)                // loading rewrote nothing
        #expect(try scratch.setAside().isEmpty)

        reader.save()
        let resaved = try JSONDecoder().decode([EnsemblePreset].self, from: Data(contentsOf: url))
        #expect(resaved == writer.presets)
    }

    @Test("a save that fails is reported, once, and reported again only after one has worked")
    func saveFailureIsSurfaced() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        // The folder the file should live in is a plain file, so nothing can be written there.
        try scratch.write("in the way", to: "blocker")
        let store = EnsemblePresetStore(fileURL: scratch.file("blocker").appendingPathComponent("ensemble-presets.json"))
        #expect(store.notices.isEmpty)

        store.addPreset(name: "Band", parts: [])
        #expect(store.notices.count == 1)
        #expect(store.notices.first?.title == "Your presets couldn't be saved")
        #expect(store.notices.first?.message.isEmpty == false)

        store.addPreset(name: "Another", parts: [])                  // still failing: not repeated
        #expect(store.notices.count == 1)
        #expect(store.presets.count == 2)                            // the list itself is intact
    }

    @Test("a file that can't be moved aside is left alone, and saving is refused rather than risked")
    func cannotSetAside() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("ensemble-presets.json")
        let original = try scratch.write("damaged", to: "ensemble-presets.json")
        // A read-only folder: the file can be read, but not moved, copied beside, or replaced.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: scratch.folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.folder.path) }

        let store = EnsemblePresetStore(fileURL: url)
        #expect(store.presets.isEmpty)
        #expect(store.notices.count == 1)
        #expect(store.notices.first?.fileURL == url)
        #expect(store.notices.first?.message.contains("won't be saved") == true)

        store.addPreset(name: "Band", parts: [])
        #expect(try Data(contentsOf: url) == original)

        // Even once the folder is writable again, this session must not write over the file.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scratch.folder.path)
        store.addPreset(name: "Another", parts: [])
        #expect(try Data(contentsOf: url) == original)
        #expect(store.notices.count == 1)
    }

    @Test("with no file at all the store works in memory")
    func inMemory() {
        let store = EnsemblePresetStore(fileURL: nil)
        store.addPreset(name: "Band", parts: [])
        #expect(store.presets.count == 1)
        #expect(store.notices.isEmpty)
    }
}

// MARK: - Stamps

@Suite("Stamp store: the saved file is never lost")
struct StampStoreFileTests {

    private func isPlaceholderOnly(_ store: StampStore) -> Bool {
        store.stamps.count == 1 && store.stamps[0].name == "Ensemble Name"
            && store.stamps[0].text == "Example School Band"
    }

    @Test("damaged file: only the placeholder, the bytes survive, and a later save doesn't destroy them")
    func damagedFile() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("stamps.json")
        let original = try scratch.write("[{\"name\":\"Northside High\",\"text\":\"Property of Nor", to: "stamps.json")

        let store = StampStore(fileURL: url)
        #expect(isPlaceholderOnly(store))
        #expect(store.selectedStampId == store.stamps.first?.id)
        #expect(store.notices.count == 1)
        #expect(store.notices.first?.title == "Your saved stamps couldn't be read")

        let copies = try scratch.setAside()
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: copies[0]) == original)
        // Seeding the placeholder writes nothing by itself.
        #expect(!FileManager.default.fileExists(atPath: url.path))

        store.addStamp(name: "New", text: "Hello")
        #expect(try Data(contentsOf: copies[0]) == original)
        #expect(try scratch.setAside().count == 1)
        let reopened = StampStore(fileURL: url)
        #expect(reopened.stamps.map(\.name) == ["Ensemble Name", "New"])
        #expect(reopened.notices.isEmpty)
    }

    @Test("one malformed entry among good ones: the good ones load, the original is kept whole")
    func oneBadEntry() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("stamps.json")
        let original = try scratch.write("""
        [
          {"id":"33333333-3333-3333-3333-333333333333","name":"School","text":"Northside High","fontSize":14},
          {"name":"Broken","text":"x","fontSize":"enormous"},
          "not a stamp at all",
          {"name":"Library","text":"Music Library"}
        ]
        """, to: "stamps.json")

        let store = StampStore(fileURL: url)
        #expect(store.stamps.map(\.name) == ["School", "Library"])
        #expect(store.stamps.first?.fontSize == 14)
        #expect(store.notices.count == 1)
        #expect(store.notices.first?.title == "2 saved stamps couldn't be read")

        let copies = try scratch.setAside()
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: copies[0]) == original)

        let reopened = StampStore(fileURL: url)
        #expect(reopened.stamps == store.stamps)
        #expect(reopened.notices.isEmpty)
        #expect(try scratch.setAside().count == 1)
    }

    @Test("missing file: the placeholder is still seeded, nothing said, nothing written")
    func missingFile() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let store = StampStore(fileURL: scratch.file("stamps.json"))
        #expect(isPlaceholderOnly(store))
        #expect(store.selectedStampId == store.stamps.first?.id)
        #expect(store.notices.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.folder.path).isEmpty)
    }

    @Test("a file from this version round-trips unchanged")
    func roundTrip() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("stamps.json")

        let writer = StampStore(fileURL: url)
        var school = writer.addStamp(name: "School", text: "Northside High\nMusic Department")
        school.positionX = 0.25
        school.positionY = 0
        school.fontSize = 13.5
        school.colourHex = "#AA0000"
        school.alignment = .left
        school.richTextData = Data([0x7B, 0x5C, 0x72, 0x74, 0x66, 0x31, 0x7D])
        writer.updateStamp(school)
        writer.flushPendingSave()
        let written = try Data(contentsOf: url)

        let plain = try JSONDecoder().decode([Stamp].self, from: written)
        #expect(plain == writer.stamps)

        let reader = StampStore(fileURL: url)
        #expect(reader.stamps == writer.stamps)
        #expect(reader.notices.isEmpty)
        #expect(try Data(contentsOf: url) == written)
        #expect(try scratch.setAside().isEmpty)

        reader.save()
        let resaved = try JSONDecoder().decode([Stamp].self, from: Data(contentsOf: url))
        #expect(resaved == writer.stamps)
    }

    @Test("a save that fails is reported")
    func saveFailureIsSurfaced() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.write("in the way", to: "blocker")
        let store = StampStore(fileURL: scratch.file("blocker").appendingPathComponent("stamps.json"))
        #expect(store.notices.isEmpty)
        store.addStamp(name: "A", text: "a")
        store.addStamp(name: "B", text: "b")
        #expect(store.notices.count == 1)
        #expect(store.notices.first?.title == "Your stamps couldn't be saved")
    }
}

// MARK: - Instrument orders

@Suite("Instrument orders file: a broken edit is kept, not overwritten")
struct InstrumentOrdersFileTests {

    @Test("missing file: the defaults are written, nothing said")
    func missing() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("instrument-orders.json")
        #expect(InstrumentOrders.prepareFile(at: url) == nil)
        let dict = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        #expect(dict["band"]?.isEmpty == false)
        #expect(dict["_version"]?.count == 1)
        #expect(try scratch.setAside().isEmpty)
    }

    @Test("a file that can't be read is set aside before the defaults replace it")
    func unreadable() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("instrument-orders.json")
        // A hand edit with a missing comma — the file invites editing, so this happens.
        let original = try scratch.write("{ \"band\": [\"score\" \"my own order\"] }", to: "instrument-orders.json")

        let notice = InstrumentOrders.prepareFile(at: url, today: day(2026, 11, 16))
        let copy = scratch.file("instrument-orders (unreadable 2026-11-16).json")
        #expect(notice?.fileURL == copy)
        #expect(notice?.message.contains("instrument-orders (unreadable 2026-11-16).json") == true)
        #expect(try Data(contentsOf: copy) == original)
        // And a usable file is back in place.
        let dict = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        #expect(dict["band"]?.isEmpty == false)

        // Next launch: nothing more to do or say.
        #expect(InstrumentOrders.prepareFile(at: url, today: day(2026, 11, 17)) == nil)
        #expect(try scratch.setAside().count == 1)
    }

    @Test("a readable file from an older version is still regenerated, on purpose")
    func olderVersionRegenerates() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("instrument-orders.json")
        let original = try scratch.write("{\"_version\":[\"1\"],\"band\":[\"kazoo\"]}", to: "instrument-orders.json")

        #expect(InstrumentOrders.prepareFile(at: url) == nil)
        #expect(try Data(contentsOf: url) != original)
        let dict = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        #expect(dict["band"]?.contains("kazoo") == false)
        #expect(try scratch.setAside().isEmpty)                      // not an "unreadable" case
    }

    @Test("a current file with the user's own order is left exactly as it is")
    func currentFileUntouched() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("instrument-orders.json")
        #expect(InstrumentOrders.prepareFile(at: url) == nil)        // writes the current defaults
        var dict = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        dict["band"] = ["score", "kazoo", "flute"]
        let edited = try JSONEncoder().encode(dict)
        try edited.write(to: url)

        #expect(InstrumentOrders.prepareFile(at: url) == nil)
        #expect(try Data(contentsOf: url) == edited)
        #expect(try scratch.setAside().isEmpty)
    }
}

// MARK: - The strip that shows a notice

@MainActor
@Suite("Saved file notices: the strip above the tabs")
struct SavedFileNoticeBarTests {

    /// Hosts the strip with real notices in it (a damaged presets file and a failed stamp
    /// save), so its rows are built and laid out. A construction crash fails the test.
    @Test("renders with notices from both stores, and gives the space back when they're dismissed")
    func renders() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        try scratch.write("damaged", to: "ensemble-presets.json")
        try scratch.write("in the way", to: "blocker")
        let presets = EnsemblePresetStore(fileURL: scratch.file("ensemble-presets.json"))
        let stamps = StampStore(fileURL: scratch.file("blocker").appendingPathComponent("stamps.json"))
        stamps.addStamp(name: "A", text: "a")
        #expect(presets.notices.count == 1)
        #expect(stamps.notices.count == 1)

        let host = NSHostingView(
            rootView: Text("Content")
                .savedFileNotices()
                .environmentObject(presets)
                .environmentObject(stamps)
        )
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        host.layoutSubtreeIfNeeded()
        let withNotices = host.fittingSize.height

        // Dismissing is just removing the notice.
        presets.notices.removeAll()
        stamps.notices.removeAll()
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height < withNotices)
    }
}

// MARK: - The command line says why

/// `presets`, `stamps`, `combine --preset` and `--stamp` read the saved files read-only
/// (issue #26). A file that can't be read is an error with the reason, not "no presets"; an
/// entry that couldn't be read is mentioned. The CLI never moves or rewrites either file.
@Suite("Command line: saved presets and stamps it can't read")
struct CLISavedListTests {

    private let damaged = "{ \"half\": \"writt"

    /// A stamps file with one good stamp and one entry this version can't decode.
    private func stampsWithOneBad(in scratch: Scratch) throws -> Data {
        let good = Stamp(name: "Sydney Youth Band", text: "Sydney Youth Band")
        let goodJSON = String(decoding: try JSONEncoder().encode(good), as: UTF8.self)
        return try scratch.write("[\(goodJSON), {\"name\": 5}]", to: "stamps.json")
    }

    @Test("presets: a damaged file is an error that says why, and is left untouched")
    func presetsUnreadable() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let original = try scratch.write(damaged, to: "ensemble-presets.json")
        let result = ScoreSortCLI.runPresets(presetsFile: scratch.file("ensemble-presets.json"),
                                             stampsFile: scratch.file("stamps.json"))
        #expect(result.isError)
        #expect(result.json["ok"] as? Bool == false)
        #expect(result.text.contains("couldn't read"))
        #expect(result.text.contains("damaged"))
        #expect(result.text.contains(scratch.file("ensemble-presets.json").path))
        #expect(!result.text.contains("No saved presets"))
        #expect(try Data(contentsOf: scratch.file("ensemble-presets.json")) == original)
        #expect(try scratch.setAside().isEmpty)
    }

    @Test("presets: entries that couldn't be read are mentioned; the rest are listed")
    func presetsSkipped() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let original = try scratch.write(twoGoodPresetsAndOneBad, to: "ensemble-presets.json")
        let result = ScoreSortCLI.runPresets(presetsFile: scratch.file("ensemble-presets.json"),
                                             stampsFile: scratch.file("stamps.json"))
        #expect(!result.isError)
        #expect((result.json["presets"] as? [[String: Any]])?.count == 2)
        #expect(result.text.contains("Concert Band"))
        #expect(result.text.contains("1 saved preset"))
        #expect((result.json["warnings"] as? [String])?.count == 1)
        #expect(try Data(contentsOf: scratch.file("ensemble-presets.json")) == original)
        #expect(try scratch.setAside().isEmpty)
    }

    @Test("presets: no file yet, or a clean one, has nothing to note")
    func presetsMissingOrClean() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let none = ScoreSortCLI.runPresets(presetsFile: scratch.file("ensemble-presets.json"),
                                           stampsFile: scratch.file("stamps.json"))
        #expect(!none.isError)
        #expect(none.text.contains("No saved presets"))
        #expect(none.json["warnings"] == nil)

        try scratch.write("[]", to: "ensemble-presets.json")
        let empty = ScoreSortCLI.runPresets(presetsFile: scratch.file("ensemble-presets.json"),
                                            stampsFile: scratch.file("stamps.json"))
        #expect(!empty.isError)
        #expect(empty.json["warnings"] == nil)
    }

    @Test("combine --preset: an unreadable file is the reason, not 'no saved presets'")
    func presetLookup() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("ensemble-presets.json")
        try scratch.write(damaged, to: "ensemble-presets.json")
        do {
            _ = try ScoreSortCLI.preset(named: "Concert Band", presetsFile: url)
            Issue.record("expected an error")
        } catch let error as CommandError {
            #expect(error.message.contains("damaged"))
            #expect(!error.message.contains("no saved presets"))
        }

        // A preset that isn't found may be one of the entries that couldn't be read.
        try scratch.write(twoGoodPresetsAndOneBad, to: "ensemble-presets.json")
        #expect(try ScoreSortCLI.preset(named: "stage", presetsFile: url).name == "Stage Band")
        do {
            _ = try ScoreSortCLI.preset(named: "From the future", presetsFile: url)
            Issue.record("expected an error")
        } catch let error as CommandError {
            #expect(error.message.contains("No single preset"))
            #expect(error.message.contains("1 saved preset"))
        }
    }

    @Test("stamps: a damaged file is an error that says why, and is left untouched")
    func stampsUnreadable() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("stamps.json")
        let original = try scratch.write("", to: "stamps.json")
        let result = ScoreSortCLI.runStamps(stampsFile: url)
        #expect(result.isError)
        #expect(result.text.contains("the file is empty"))
        #expect(!result.text.contains("No saved stamps"))
        do {
            _ = try ScoreSortCLI.stampJob(named: "Sydney Youth Band", scope: .everyPage, stampsFile: url)
            Issue.record("expected an error")
        } catch let error as CommandError {
            #expect(error.message.contains("the file is empty"))
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try scratch.setAside().isEmpty)
    }

    @Test("stamps: entries that couldn't be read are mentioned; the rest still work")
    func stampsSkipped() throws {
        let scratch = try Scratch()
        defer { scratch.cleanUp() }
        let url = scratch.file("stamps.json")
        let original = try stampsWithOneBad(in: scratch)
        let result = ScoreSortCLI.runStamps(stampsFile: url)
        #expect(!result.isError)
        #expect((result.json["stamps"] as? [[String: Any]])?.count == 1)
        #expect(result.text.contains("1 saved stamp"))
        #expect(try ScoreSortCLI.stampJob(named: "sydney", scope: .everyPage, stampsFile: url).stamp.name == "Sydney Youth Band")
        do {
            _ = try ScoreSortCLI.stampJob(named: "Another School", scope: .everyPage, stampsFile: url)
            Issue.record("expected an error")
        } catch let error as CommandError {
            #expect(error.message.contains("No single stamp"))
            #expect(error.message.contains("1 saved stamp"))
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try scratch.setAside().isEmpty)
    }
}
