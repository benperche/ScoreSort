//
//  InstrumentOrderMergeTests.swift
//  ScoreSortTests
//
//  New built-in instruments reach existing instrument-orders files without wiping an order
//  the user edited (they used to be overwritten), and the names added in version 9 number
//  where they belong in score order.
//

import Testing
import Foundation
@testable import ScoreSort

@MainActor
@Suite("Instrument orders: merging new defaults")
struct InstrumentOrderMergeTests {

    @Test("new instruments go after their neighbour, wherever the user moved things")
    func mergeKeepsEdits() {
        let saved = ["score", "tuba", "flute", "clarinet", "my special part"]   // tuba moved up, one added
        let defaults = ["score", "flute", "oboe", "clarinet", "bass clarinet", "tuba", "sousaphone"]
        let merged = InstrumentOrders.merged(saved, with: defaults)
        #expect(merged == ["score", "tuba", "sousaphone", "flute", "oboe", "clarinet", "bass clarinet", "my special part"])
    }

    @Test("an entry with nothing before it goes first; case is ignored; nothing is removed")
    func mergeEdges() {
        #expect(InstrumentOrders.merged(["flute"], with: ["conductor", "Flute"]) == ["conductor", "flute"])
        #expect(InstrumentOrders.merged(["a", "b"], with: ["b"]) == ["a", "b"])
    }

    @Test("an order never edited takes the new built-in order; an edited one is merged")
    func updatedFile() {
        let band = InstrumentOrders.defaultOrders["band"]!
        let oldBand = band.filter { $0 != "sousaphone" && $0 != "conductor" }
        // Written by a version that recorded its base, and never edited: replaced outright.
        let untouched = InstrumentOrders.updated(["_version": ["9"], "band": oldBand, "_base_band": oldBand])
        #expect(untouched["band"] == band)
        // Edited: tuba moved to the top. Kept, with the new names merged in.
        let edited = ["tuba"] + oldBand.filter { $0 != "tuba" }
        let merged = InstrumentOrders.updated(["_version": ["8"], "band": edited])
        #expect(merged["band"]?.first == "tuba")
        #expect(merged["band"]?.contains("sousaphone") == true)
        let order = merged["band"]!
        #expect(order.firstIndex(of: "sousaphone")! == order.firstIndex(of: "tuba")! + 1)
        #expect(merged["_version"] == [String(InstrumentOrders.defaultsVersion)])
        #expect(merged["_base_band"] == band)
        // A missing ensemble gets the built-in order.
        #expect(merged["jazz"] == InstrumentOrders.defaultOrders["jazz"])
    }

    @Test("a version 8 file on disk keeps its edits when updated")
    func updatesOnDisk() throws {
        let url = temporaryFolder("orders").appendingPathComponent("instrument-orders.json")
        let edited = ["score", "tuba", "flute", "clarinet"]
        let data = try JSONEncoder().encode(["_version": ["8"], "band": edited])
        try data.write(to: url)
        #expect(InstrumentOrders.prepareFile(at: url) == nil)
        let written = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        #expect(written["_version"] == ["9"])
        let band = try #require(written["band"])
        #expect(Array(band.prefix(2)) == ["score", "conductor"])
        #expect(band.contains("sousaphone") && band.contains("vocal"))
        #expect(band.firstIndex(of: "tuba")! < band.firstIndex(of: "flute")!)   // the user's move kept
    }
}

@MainActor
@Suite("Instrument orders: the names added in version 9")
struct NewInstrumentNamesTests {

    private func rank(_ name: String, _ ensemble: String = "band") -> (Int, String)? {
        detectScoreOrderInstrument(in: name, order: InstrumentOrders.defaultOrders[ensemble]!)
    }

    @Test("each new name is recognised, and lands after the instrument it follows")
    func placed() throws {
        let band = InstrumentOrders.defaultOrders["band"]!
        func index(_ s: String) -> Int { band.firstIndex(of: s)! }
        #expect(try #require(rank("Contra-alto Clarinet")).1.contains("contra"))
        #expect(try #require(rank("Contra-alto Clarinet")).0 > index("bass clarinet"))
        #expect(try #require(rank("Flugelhorn")).0 == index("flugelhorn"))
        #expect(try #require(rank("Sousaphone")).0 == index("tuba") + 1)
        #expect(try #require(rank("Bass Guitar")).1 == "bass guitar")
        #expect(try #require(rank("Synthesizer")).1 == "synthesizer")
        #expect(try #require(rank("Vocal")).1 == "vocal")
        #expect(try #require(rank("Vocal", "orchestra")).1 == "vocal")
        // A flex part is placed by its part number, before any instrument it lists.
        #expect(try #require(rank("Part 2 in Bb (Clarinet, Trumpet)")).1 == "part 2")
    }

    @Test("Conductor is numbered as the score")
    func conductorIsTheScore() {
        let items = ["Flute.pdf", "Conductor.pdf"].enumerated().map { PrefixItem(id: $0.offset, proposedName: $0.element, page: nil) }
        let sorted = scoreOrderSorted(items, by: InstrumentOrders.defaultOrders["band"]!)
        #expect(sorted.first?.proposedName == "Conductor.pdf")
        #expect(sorted.first?.isScore == true)
    }

    @Test("the new names are typed-only suggestions, never the next-part walk")
    func suggestions() {
        let typed = splitSuggestionTypedOptions(for: .band, alreadyOffered: [])
        for name in ["Flute/Piccolo", "Bb Clarinet", "Contra-alto Clarinet", "Sousaphone", "Part 1", "Conductor", "Choir"] {
            #expect(typed.contains(name), "\(name)")
        }
        let walk = Set(splitSuggestionOrder(for: .band).map { $0.lowercased() })
        for name in ["conductor", "vocal", "part 1", "sousaphone", "flugelhorn"] {
            #expect(!walk.contains(name), "\(name)")
        }
    }
}
