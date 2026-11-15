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

    @Test("Move to Folder: a file chosen by hand goes where it was put, not where ScoreSort guessed")
    func handChosenFolders() throws {
        InstrumentOrders.setup()
        let dir = folder(with: ["Bass.pdf", "Flute 1.pdf", "01 - Piano.pdf", "Score.pdf"])
        let operations = planScoreOrderRename(files: renamableFiles(in: dir, recursive: false),
                                              order: InstrumentOrders.getOrder(for: .band), separator: " - ",
                                              folderMode: .section, ensemble: .band,
                                              folderOverrides: ["Bass.pdf": "Rhythm", "Flute 1.pdf": "",
                                                                "01 - Piano.pdf": "Keys & Synths"])
        let bass = try #require(operations.first { $0.originalName == "Bass.pdf" })
        #expect(bass.folder == "Rhythm")                      // not Strings
        let flute = try #require(operations.first { $0.originalName == "Flute 1.pdf" })
        #expect(flute.folder == nil)                          // kept at the top
        _ = performRenames(operations)
        let names = contents(dir)
        #expect(names.contains { $0.hasPrefix("Rhythm/") && $0.hasSuffix("Bass.pdf") })
        #expect(names.contains("Keys & Synths/01 - Piano.pdf"))
        #expect(names.contains { !$0.contains("/") && $0.hasSuffix("Flute 1.pdf") })
        #expect(names.contains { !$0.contains("/") && $0.hasSuffix("Score.pdf") })
    }

    @Test("Hand-chosen folders are ignored with folders off")
    func handChosenFoldersNeedFoldersOn() {
        InstrumentOrders.setup()
        let dir = folder(with: ["Flute 1.pdf"])
        let operations = planScoreOrderRename(files: renamableFiles(in: dir, recursive: false),
                                              order: InstrumentOrders.getOrder(for: .band), separator: " - ",
                                              folderOverrides: ["Flute 1.pdf": "Brass"])
        #expect(operations.first?.folder == nil)
    }

    @Test("Folder names that can't be used are refused")
    func folderNameErrors() {
        #expect(partFolderNameError("Low Brass") == nil)
        #expect(partFolderNameError("  ") != nil)
        #expect(partFolderNameError("Brass/Low") != nil)
        #expect(partFolderNameError(".hidden") != nil)
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

    @Test("The command line's rename takes --folder to correct a guess")
    func renameCommandFolderChoice() throws {
        let dir = folder(with: ["Bass.pdf", "Flute 1.pdf"])
        let result = try ScoreSortCLI.runRename(paths: [dir.path], ensemble: .band, separator: " - ",
                                                folders: .section, folderOverrides: ["Bass.pdf": "Rhythm"],
                                                apply: false)
        let files = try #require(result.json["files"] as? [[String: Any]])
        #expect(files.first { $0["file"] as? String == "Bass.pdf" }?["folder"] as? String == "Rhythm")
        #expect(throws: CommandError.self) {
            try ScoreSortCLI.runRename(paths: [dir.path], ensemble: .band, folders: .section,
                                       folderOverrides: ["Tuba.pdf": "Brass"], apply: false)
        }
    }
}

@Suite("A piece sorted into folders, renamed again or gathered back")
@MainActor
struct SortedPieceTests {

    /// A piece folder as "Sort into folders" leaves it: the score at the top, parts in sections.
    private func sortedPiece(_ names: [String] = ["00 - Score.pdf", "Woodwind/01 - Flute 1.pdf",
                                                  "Woodwind/02 - Clarinet 1.pdf", "Brass/03 - Trumpet 1.pdf",
                                                  "Percussion/04 - Snare Drum.pdf"]) -> URL {
        let dir = temporaryFolder("piece").appendingPathComponent("Spring Overture")
        for name in names {
            let url = dir.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            writePDF(pages: 1, to: url)
        }
        return dir
    }

    private func contents(_ dir: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: dir.path)
        return ((enumerator?.allObjects as? [String]) ?? []).filter { $0.hasSuffix(".pdf") }.sorted()
    }

    private func plan(_ dir: URL, mode: PartFolderMode, rescan: Bool = false,
                      overrides: [String: String] = [:]) -> [RenameOperation] {
        InstrumentOrders.setup()
        return planScoreOrderRename(files: renamerJobFiles(in: dir, recursive: false),
                                    order: InstrumentOrders.getOrder(for: .band), separator: " - ", rescan: rescan,
                                    folderMode: mode, ensemble: .band, folderOverrides: overrides, root: dir)
    }

    @Test("Dropping the piece folder is one job, its section folders included; a section on its own is still a job")
    func oneJob() {
        let piece = sortedPiece()
        #expect(expandToRenameJobFolders([piece]).map(\.lastPathComponent) == ["Spring Overture"])
        #expect(renamerJobFiles(in: piece, recursive: false).count == 5)
        #expect(expandToRenameJobFolders([piece.appendingPathComponent("Brass")]).map(\.lastPathComponent) == ["Brass"])

        // A concert folder of two sorted pieces: two jobs, not one per section.
        let concert = piece.deletingLastPathComponent()
        let second = concert.appendingPathComponent("March")
        try? FileManager.default.createDirectory(at: second.appendingPathComponent("Brass"), withIntermediateDirectories: true)
        writePDF(pages: 1, to: second.appendingPathComponent("Brass/Tuba.pdf"))
        #expect(expandToRenameJobFolders([concert]).map(\.lastPathComponent) == ["March", "Spring Overture"])
    }

    @Test("By Section again: nothing moves, and the parts are listed in their folders")
    func bySectionLeavesThem() {
        let operations = plan(sortedPiece(), mode: .section)
        #expect(operations.allSatisfy { $0.type == .alreadyPrefixed })
        #expect(operations.first { $0.originalName.hasSuffix("Trumpet 1.pdf") }?.folder == "Brass")
        #expect(operations.first { $0.originalName.hasSuffix("Score.pdf") }?.folder == nil)
    }

    @Test("Renumbering numbers the sections as one piece")
    func renumberedTogether() {
        let operations = plan(sortedPiece(["Score.pdf", "Woodwind/Flute 1.pdf", "Brass/Trumpet 1.pdf", "Brass/Tuba.pdf"]),
                              mode: .section)
        let names = operations.map(\.newPathForDisplay).sorted()
        #expect(names == ["00 - Score.pdf", "Brass/02 - Trumpet 1.pdf", "Brass/03 - Tuba.pdf", "Woodwind/01 - Flute 1.pdf"])
    }

    @Test("Sort into folders Off gathers the parts back into the piece folder, and the empty folders go")
    func offGathersBack() {
        let piece = sortedPiece()
        // A file that isn't a part stays in its folder, and so does the folder.
        writePDF(pages: 1, to: piece.appendingPathComponent("Percussion/Setup notes.pdf"))
        let operations = plan(piece, mode: .off)
        let flute = operations.first { $0.originalName == "01 - Flute 1.pdf" }
        #expect(flute?.newPathForDisplay == "01 - Flute 1.pdf (out of Woodwind)")
        let report = performRenames(operations)
        #expect(report.errors.isEmpty)
        #expect(contents(piece) == ["00 - Score.pdf", "01 - Flute 1.pdf", "02 - Clarinet 1.pdf", "03 - Trumpet 1.pdf",
                                    "04 - Snare Drum.pdf", "Percussion/Setup notes.pdf"])
        #expect(!FileManager.default.fileExists(atPath: piece.appendingPathComponent("Woodwind").path))
        #expect(FileManager.default.fileExists(atPath: piece.appendingPathComponent("Percussion").path))
    }

    @Test("Move to Folder ▸ Top Level takes a part out of its section folder; another section moves it across")
    func handChosenFromSorted() {
        let piece = sortedPiece()
        let operations = plan(piece, mode: .section,
                              overrides: ["03 - Trumpet 1.pdf": "", "04 - Snare Drum.pdf": "Rhythm"])
        #expect(operations.first { $0.originalName == "03 - Trumpet 1.pdf" }?.newPathForDisplay
                == "03 - Trumpet 1.pdf (out of Brass)")
        #expect(operations.first { $0.originalName == "04 - Snare Drum.pdf" }?.newPathForDisplay
                == "Rhythm/04 - Snare Drum.pdf")
        _ = performRenames(operations)
        #expect(contents(piece) == ["00 - Score.pdf", "03 - Trumpet 1.pdf", "Rhythm/04 - Snare Drum.pdf",
                                    "Woodwind/01 - Flute 1.pdf", "Woodwind/02 - Clarinet 1.pdf"])
    }

    @Test("The Renamer loads a sorted piece as one, and Off gathers it")
    func renamerManager() {
        let piece = sortedPiece()
        let manager = RenamerManager()
        manager.partFolderMode = .off   // not the user's setting
        manager.loadFolder(url: piece)
        #expect(manager.operations.count == 5)
        #expect(manager.renameCount == 4)   // every part but the score moves up
    }

    @Test("The command line leaves parts in their folders unless --folders is given")
    func commandLine() throws {
        let piece = sortedPiece()
        _ = try ScoreSortCLI.runRename(paths: [piece.path], ensemble: .band, separator: " - ", apply: true)
        #expect(contents(piece).contains("Woodwind/01 - Flute 1.pdf"))
        _ = try ScoreSortCLI.runRename(paths: [piece.path], ensemble: .band, separator: " - ", folders: .off, apply: true)
        #expect(contents(piece) == ["00 - Score.pdf", "01 - Flute 1.pdf", "02 - Clarinet 1.pdf", "03 - Trumpet 1.pdf",
                                    "04 - Snare Drum.pdf"])
    }
}

@Suite("Renumber prefixed files stays as you set it")
@MainActor
struct StickyRenumberTests {
    private func folder(_ names: [String]) -> URL {
        let dir = temporaryFolder("sticky")
        for name in names { writePDF(pages: 1, to: dir.appendingPathComponent(name)) }
        return dir
    }

    @Test("Ticked, it stays ticked for the next folder, and after Clear")
    func staysTicked() {
        let manager = RenamerManager()
        manager.partFolderMode = .off   // not the user's setting
        manager.customInstrumentOrder = ["flute", "clarinet", "trumpet"]
        manager.loadFolder(url: folder(["01 - Flute.pdf", "02 - Clarinet 1.pdf"]))
        manager.setRescanMode(true)
        manager.loadFolder(url: folder(["01 - Flute.pdf", "02 - Trumpet 1.pdf"]))
        #expect(manager.isRescanMode && !manager.renumberedAutomatically)
        manager.clearFolder()
        manager.loadFolder(url: folder(["01 - Clarinet 1.pdf"]))
        #expect(manager.isRescanMode)
    }

    @Test("Unticked, a mixed folder still turns it on — for that folder only")
    func automaticOnlyForThatFolder() {
        let manager = RenamerManager()
        manager.partFolderMode = .off   // not the user's setting
        manager.customInstrumentOrder = ["flute", "clarinet", "trumpet"]
        manager.loadFolder(url: folder(["01 - Flute.pdf", "Clarinet 1.pdf"]))
        #expect(manager.isRescanMode && manager.renumberedAutomatically)
        manager.loadFolder(url: folder(["01 - Flute.pdf", "02 - Clarinet 1.pdf"]))
        #expect(!manager.isRescanMode)
    }
}
