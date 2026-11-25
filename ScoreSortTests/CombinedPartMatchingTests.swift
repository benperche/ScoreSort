//
//  CombinedPartMatchingTests.swift
//  ScoreSortTests
//
//  A combined part ("Flute Oboe", as in Ed Wilson's charts) covers every preset entry it
//  names that has no file of its own, so its copies are their total.
//

import Testing
import Foundation
@testable import ScoreSort

@Suite("Combine presets: combined parts")
struct CombinedPartMatchingTests {

    private func match(_ parts: [(String, Int)], _ names: [String]) -> (copies: [String: Int], result: PresetMatchResult, ids: [String: UUID]) {
        let files = names.map { (id: UUID(), name: $0) }
        let ids = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.id) })
        let result = matchPreset(parts: parts.map { PresetPart(name: $0.0, copies: $0.1) }, files: files)
        let byId = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.name) })
        var copies: [String: Int] = [:]
        for (id, n) in result.copies { copies[byId[id]!] = n }
        return (copies, result, ids)
    }

    @Test("Flute Oboe alone covers the flutes and the oboes, marked as the app's call")
    func combinedAlone() {
        let m = match([("Flute", 6), ("Oboe", 2), ("Clarinet", 8)], ["01 Flute Oboe.pdf", "02 Clarinet.pdf"])
        #expect(m.copies == ["01 Flute Oboe.pdf": 8, "02 Clarinet.pdf": 8])
        #expect(m.result.unmatchedPartNames.isEmpty)
        #expect(m.result.splitFileIds == [m.ids["01 Flute Oboe.pdf"]!])
        #expect(m.result.copies.count == 2)   // one entry per file, so applying sets each once
    }

    @Test("with a Flute part of its own, Flute Oboe covers just the oboes")
    func combinedBesideASinglePart() {
        let m = match([("Flute", 6), ("Oboe", 2)], ["Flute.pdf", "Flute Oboe.pdf"])
        #expect(m.copies == ["Flute.pdf": 6, "Flute Oboe.pdf": 2])
        #expect(m.result.unmatchedPartNames.isEmpty)
    }

    @Test("with both parts of their own, a combined part shares as before")
    func combinedWhenBothExist() {
        let m = match([("Flute", 6), ("Oboe", 2)], ["Flute.pdf", "Oboe.pdf", "Flute Oboe.pdf"])
        #expect(m.copies["Oboe.pdf"] == 2)
        #expect((m.copies["Flute.pdf"] ?? 0) + (m.copies["Flute Oboe.pdf"] ?? 0) == 6)
    }

    @Test("numbered combined parts share both entries between them")
    func numberedCombined() {
        let m = match([("Flute", 6), ("Oboe", 2)], ["Flute Oboe 1.pdf", "Flute Oboe 2.pdf"])
        #expect(m.copies == ["Flute Oboe 1.pdf": 4, "Flute Oboe 2.pdf": 4])
    }

    @Test("Tuned Percussion goes to the mallet entry when there is one, else to Percussion")
    func tunedPercussion() {
        let both = match([("Percussion", 4), ("Mallet Percussion", 2)], ["Percussion.pdf", "Tuned Percussion.pdf"])
        #expect(both.copies == ["Percussion.pdf": 4, "Tuned Percussion.pdf": 2])
        let one = match([("Percussion", 4)], ["Tuned Percussion.pdf"])
        #expect(one.copies == ["Tuned Percussion.pdf": 4])
    }

    @Test("Eb Horn and F Horn are horn parts")
    func horns() {
        let m = match([("Horn", 4)], ["F Horn.pdf", "Eb Horn.pdf"])
        #expect(m.copies.values.reduce(0, +) == 4)
        #expect(m.result.unmatchedFileIds.isEmpty)
    }
}
