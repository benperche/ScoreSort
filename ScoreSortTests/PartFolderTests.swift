//
//  PartFolderTests.swift
//  ScoreSortTests
//
//  "Sort into folders" (Logic/PartFolders.swift): which section or instrument folder a
//  part goes in, and the Rename tab's and command line's moves into those folders.
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

@Suite("Sort into folders: which folder")
struct PartFolderNameTests {

    private func section(_ name: String, _ ensemble: EnsembleType = .band) -> String? {
        partFolderName(forFileName: name, mode: .section, ensemble: ensemble)
    }

    private func instrument(_ name: String, _ ensemble: EnsembleType = .band) -> String? {
        partFolderName(forFileName: name, mode: .instrument, ensemble: ensemble)
    }

    @Test("Concert band sections, with piano, guitar and bass guitar in Rhythm")
    func bandSections() {
        #expect(section("01 - Flute 1.pdf") == "Woodwind")
        #expect(section("Holst - First Suite - Alto Sax 2.pdf") == "Woodwind")
        #expect(section("Bass Clarinet.pdf") == "Woodwind")
        #expect(section("English Horn.pdf") == "Woodwind")
        #expect(section("Trumpet 1.pdf") == "Brass")
        #expect(section("Horn in F 2.pdf") == "Brass")
        #expect(section("Flugelhorn.pdf") == "Brass")
        #expect(section("Euphonium B.C..pdf") == "Brass")
        #expect(section("Baritone TC.pdf") == "Brass")
        #expect(section("Bass Trombone.pdf") == "Brass")
        #expect(section("Trombone Baritone Bassoon.pdf") == "Brass")   // leftmost wins, as in score order
        #expect(section("Timpani.pdf") == "Percussion")
        #expect(section("Bass Drum.pdf") == "Percussion")
        #expect(section("Drum Kit.pdf") == "Percussion")
        #expect(section("Mallet Percussion.pdf") == "Percussion")
        #expect(section("Piano.pdf") == "Rhythm")
        #expect(section("Electric Guitar.pdf") == "Rhythm")
        #expect(section("Bass Guitar.pdf") == "Rhythm")
        #expect(section("String Bass.pdf") == "Strings")
        #expect(section("Violin II.pdf") == "Strings")
    }

    @Test("The score and unrecognised parts stay at the top")
    func topLevel() {
        #expect(section("00 - Score.pdf") == nil)
        #expect(section("Full Score.pdf") == nil)
        #expect(section("Conductor's Score.pdf") == nil)
        #expect(section("Instrumentation.pdf") == nil)
        #expect(section("Kazoo.pdf") == nil)
        #expect(instrument("Full Score.pdf") == nil)
        #expect(partFolderName(forFileName: "Flute 1.pdf", mode: .off, ensemble: .band) == nil)
    }

    @Test("Instrument words inside other words don't count")
    func wholeWords() {
        #expect(section("Bassoon 1.pdf") == "Woodwind")       // not "bass"
        #expect(section("Flugelhorn 1.pdf") == "Brass")
        #expect(section("Shorn.pdf") == nil)                   // not "horn"
    }

    @Test("A jazz band: Saxophones, Trumpets, Trombones, Rhythm")
    func jazzSections() {
        #expect(section("Alto Sax 1.pdf", .jazz) == "Saxophones")
        #expect(section("Tenor 2.pdf", .jazz) == "Saxophones")
        #expect(section("Baritone.pdf", .jazz) == "Saxophones")    // the bari sax in a big band
        #expect(section("Flute.pdf", .jazz) == "Saxophones")       // a sax double
        #expect(section("Trumpet 4.pdf", .jazz) == "Trumpets")
        #expect(section("Flugelhorn.pdf", .jazz) == "Trumpets")
        #expect(section("Bass Trombone.pdf", .jazz) == "Trombones")
        #expect(section("Piano.pdf", .jazz) == "Rhythm")
        #expect(section("Guitar Chords.pdf", .jazz) == "Rhythm")
        #expect(section("Bass.pdf", .jazz) == "Rhythm")
        #expect(section("Drums.pdf", .jazz) == "Rhythm")
        #expect(section("Vibes.pdf", .jazz) == "Rhythm")
        #expect(section("Baritone.pdf", .band) == "Brass")         // the low brass elsewhere
    }

    @Test("By instrument: numbered parts and spellings share a folder")
    func instruments() {
        #expect(instrument("Clarinet 1.pdf") == "Clarinet")
        #expect(instrument("Clarinet 3.pdf") == "Clarinet")
        #expect(instrument("Alto Sax 1.pdf") == "Alto Saxophone")
        #expect(instrument("Sax Alto 2.pdf") == "Alto Saxophone")
        #expect(instrument("Bari Sax.pdf") == "Baritone Saxophone")
        #expect(instrument("Horn in F 1.pdf") == "Horn")
        #expect(instrument("Glockenspiel.pdf") == "Mallet Percussion")
        #expect(instrument("Percussion 2 (Snare, Bass Drum).pdf") == "Percussion")
        #expect(instrument("Baritone.pdf", .jazz) == "Baritone Saxophone")
    }

    @Test("A split part goes by its part name, not the piece's")
    func splitPartName() {
        // "Trumpet Voluntary" names an instrument; the part is the flute.
        #expect(partFolderName(partName: "Flute 1", fileName: "Trumpet Voluntary - Flute 1.pdf",
                               mode: .section, ensemble: .band) == "Woodwind")
        // A single file kept under its own name has no part name: the whole name decides.
        #expect(partFolderName(partName: "", fileName: "02 Ebony Alto 1.pdf",
                               mode: .section, ensemble: .band) == "Woodwind")
        #expect(partFolderPath("01 - Flute.pdf", folder: "Woodwind") == "Woodwind/01 - Flute.pdf")
        #expect(partFolderPath("00 - Score.pdf", folder: nil) == "00 - Score.pdf")
    }

    @Test("A file already in its folder isn't nested again")
    func noNesting() {
        let loose = URL(fileURLWithPath: "/Parts/01 - Flute.pdf")
        #expect(partFolderDestination(for: loose, mode: .section, ensemble: .band).path == "/Parts/Woodwind/01 - Flute.pdf")
        let sorted = URL(fileURLWithPath: "/Parts/Woodwind/01 - Flute.pdf")
        #expect(partFolderDestination(for: sorted, mode: .section, ensemble: .band) == sorted)
    }
}

@Suite("Sort into folders: saving and renaming")
struct PartFolderWritingTests {

    private func contents(_ dir: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: dir.path)
        return ((enumerator?.allObjects as? [String]) ?? []).filter { $0.hasSuffix(".pdf") }.sorted()
    }

    private func folder(with names: [String]) -> URL {
        let dir = temporaryFolder("folders")
        for name in names { writePDF(pages: 1, to: dir.appendingPathComponent(name)) }
        return dir
    }

    @Test("The Score Order Sorter numbers parts and moves them into section folders")
    func renameIntoSections() throws {
        InstrumentOrders.setup()
        let dir = folder(with: ["Score.pdf", "Flute 1.pdf", "Trumpet 2.pdf", "Kazoo.pdf"])
        let operations = planScoreOrderRename(files: renamableFiles(in: dir, recursive: false),
                                              order: InstrumentOrders.getOrder(for: .band), separator: " - ",
                                              folderMode: .section, ensemble: .band)
        let flute = try #require(operations.first { $0.originalName == "Flute 1.pdf" })
        #expect(flute.newPathForDisplay == "Woodwind/01 - Flute 1.pdf")
        let report = performRenames(operations)
        #expect(report.errors.isEmpty)
        #expect(contents(dir) == ["00 - Score.pdf", "Brass/02 - Trumpet 2.pdf", "Kazoo.pdf", "Woodwind/01 - Flute 1.pdf"])
    }

    @Test("Parts already numbered just move into their folders")
    func movesNumberedParts() throws {
        InstrumentOrders.setup()
        let dir = folder(with: ["01 - Flute 1.pdf", "02 - Trumpet 2.pdf"])
        let operations = planScoreOrderRename(files: renamableFiles(in: dir, recursive: false),
                                              order: InstrumentOrders.getOrder(for: .band), separator: " - ",
                                              folderMode: .instrument, ensemble: .band)
        #expect(operations.allSatisfy { $0.type == .rename && $0.newName == $0.originalName })
        _ = performRenames(operations)
        #expect(contents(dir) == ["Flute/01 - Flute 1.pdf", "Trumpet/02 - Trumpet 2.pdf"])
    }

    @Test("With folders off, nothing moves into folders")
    func offLeavesFolderAlone() {
        InstrumentOrders.setup()
        let dir = folder(with: ["01 - Flute 1.pdf"])
        let operations = planScoreOrderRename(files: renamableFiles(in: dir, recursive: false),
                                              order: InstrumentOrders.getOrder(for: .band), separator: " - ")
        #expect(operations.map(\.type) == [.alreadyPrefixed])
    }

    @Test("The command line's split saves into section folders inside --out")
    func splitIntoSections() throws {
        let source = temporaryFolder().appendingPathComponent("Band.pdf")
        writeDrawnPDF(pages: 6, to: source)
        let out = source.deletingLastPathComponent().appendingPathComponent("out")
        var options = ScoreSortCLI.SplitOptions(out: out.path)
        options.parts = [(pages: "1-2", name: "Score"), (pages: "3-4", name: "Flute 1"), (pages: "5-6", name: "Trumpet 1")]
        options.base = "Trumpet Voluntary"
        options.separator = " - "
        options.folders = .section
        let result = try ScoreSortCLI.runSplit(file: source, options: options)
        #expect(result.exitCode == 0)
        #expect(contents(out) == ["Brass/Trumpet Voluntary - Trumpet 1.pdf", "Trumpet Voluntary - Score.pdf",
                                  "Woodwind/Trumpet Voluntary - Flute 1.pdf"])
    }

    @Test("The command line's rename takes --folders")
    func renameCommand() throws {
        let dir = folder(with: ["Alto Sax 1.pdf", "Drums.pdf"])
        let result = try ScoreSortCLI.runRename(paths: [dir.path], ensemble: .jazz, separator: " - ",
                                                folders: .section, apply: true)
        #expect(result.exitCode == 0)
        let names = contents(dir)
        #expect(names.count == 2)
        #expect(names.contains { $0.hasPrefix("Saxophones/") && $0.hasSuffix("Alto Sax 1.pdf") })
        #expect(names.contains { $0.hasPrefix("Rhythm/") && $0.hasSuffix("Drums.pdf") })
        #expect(throws: CommandError.self) { try ScoreSortCLI.parsePartFolderMode("sections please") }
    }
}
