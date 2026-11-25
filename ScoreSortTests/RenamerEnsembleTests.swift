//
//  RenamerEnsembleTests.swift
//  ScoreSortTests
//
//  Switching ensemble has to actually change what the renamer recognises. It once didn't:
//  loading a preset order set the "user has customised this" flag itself, so the first switch
//  locked the list and every switch after it moved the picker while detection stayed put.
//

import Testing
import Foundation
@testable import ScoreSort

@Suite("Renamer ensemble switching", .serialized)
@MainActor
struct RenamerEnsembleTests {

    @Test func switchingEnsembleChangesWhatIsRecognised() {
        let manager = RenamerManager()
        manager.partFolderMode = .off   // not the user's Settings default

        // Orchestra knows the strings; jazz doesn't.
        manager.ensembleType = .orchestra
        #expect(manager.detectInstrument(in: "9 Ligeti Chamber Concerto Violin 1.pdf") != nil)

        manager.ensembleType = .jazz
        #expect(manager.detectInstrument(in: "9 Ligeti Chamber Concerto Violin 1.pdf") == nil,
                "jazz has no violin")

        // The bug: this second switch back used to be ignored entirely.
        manager.ensembleType = .orchestra
        #expect(manager.detectInstrument(in: "9 Ligeti Chamber Concerto Violin 1.pdf") != nil,
                "switching back to orchestra must restore the orchestral instruments")
        #expect(manager.detectInstrument(in: "2 Ligeti Chamber Concerto Oboe.pdf") != nil,
                "oboe is in every orchestra order")
    }

    @Test func everySwitchTakesEffectNotJustTheFirst() {
        let manager = RenamerManager()
        manager.partFolderMode = .off   // not the user's Settings default
        for type in [EnsembleType.jazz, .orchestra, .band, .orchestra, .jazz] {
            manager.ensembleType = type
            #expect(manager.customInstrumentOrder == InstrumentOrders.getOrder(for: type),
                    "order should follow the ensemble every time, not only the first")
        }
    }

    /// Orders are saved per ensemble now (`InstrumentOrders.saveOrder`), so switching ensemble
    /// always brings in that ensemble's own order; an unsaved edit doesn't follow you to another
    /// ensemble any more (it used to, and was lost on quit anyway).
    @Test func switchingEnsembleBringsItsOwnOrder() {
        let manager = RenamerManager()
        manager.partFolderMode = .off   // not the user's Settings default
        manager.ensembleType = .orchestra
        manager.customInstrumentOrder = ["tuba", "piccolo"]      // an edit that wasn't saved
        manager.ensembleType = .band
        #expect(manager.customInstrumentOrder == InstrumentOrders.getOrder(for: .band))
    }
}

@Suite("Renumbering around numbers chosen by hand")
@MainActor
struct RenumberAroundManualTests {

    private let names = ["Alto Saxophone", "Tenor Saxophone", "Trumpet 1", "Trumpet 2", "Trumpet 3", "Trumpet 4",
                         "Trombone 1", "Trombone 3", "Trombone 2", "Trombone 4", "Guitar", "Piano",
                         "Bass Clarinet", "Bass", "Drums", "Clarinet 1", "Clarinet 2 Piccolo"]

    /// The folder as it was: numbered 01–17 in the order above (Trombone 3 before 2, the
    /// clarinets last).
    private func numberedFolder() -> URL {
        let dir = temporaryFolder("renumber")
        for (i, name) in names.enumerated() {
            writePDF(pages: 1, to: dir.appendingPathComponent(String(format: "%02d - Arabesque Cookie - %@.pdf", i + 1, name)))
        }
        return dir
    }

    private func file(_ name: String, in dir: URL) -> String {
        renamableFiles(in: dir, recursive: false).map(\.lastPathComponent).first { $0.hasSuffix(" - \(name).pdf") }!
    }

    @Test("Clarinets set to 1 and 2 and the bass clarinet to 5: everything else fills in around them")
    func arabesqueCookie() {
        InstrumentOrders.setup()
        let dir = numberedFolder()
        let overrides = [file("Clarinet 1", in: dir): 1, file("Clarinet 2 Piccolo", in: dir): 2,
                         file("Bass Clarinet", in: dir): 5]
        let operations = planScoreOrderRename(files: renamableFiles(in: dir, recursive: false),
                                              order: InstrumentOrders.getOrder(for: .jazz), separator: " - ",
                                              rescan: true, manualOverrides: overrides)
        let result = operations.map { $0.newName.isEmpty ? $0.originalName : $0.newName }
            .map { $0.replacingOccurrences(of: " - Arabesque Cookie - ", with: " ").replacingOccurrences(of: ".pdf", with: "") }
            .sorted()
        #expect(result == ["01 Clarinet 1", "02 Clarinet 2 Piccolo", "03 Alto Saxophone", "04 Tenor Saxophone",
                           "05 Bass Clarinet", "06 Trumpet 1", "07 Trumpet 2", "08 Trumpet 3", "09 Trumpet 4",
                           "10 Trombone 1", "11 Trombone 2", "12 Trombone 3", "13 Trombone 4",
                           "14 Guitar", "15 Piano", "16 Bass", "17 Drums"])
    }

    @Test("Renumbering puts parts of one instrument in order, whatever they were numbered before")
    func sameInstrumentInNaturalOrder() {
        InstrumentOrders.setup()
        let dir = numberedFolder()
        let operations = planScoreOrderRename(files: renamableFiles(in: dir, recursive: false),
                                              order: InstrumentOrders.getOrder(for: .jazz), separator: " - ",
                                              rescan: true)
        let trombone2 = operations.first { $0.originalName.hasSuffix("Trombone 2.pdf") }
        let trombone3 = operations.first { $0.originalName.hasSuffix("Trombone 3.pdf") }
        #expect(trombone2?.newName.hasPrefix("08") == true)
        #expect(trombone3?.newName.hasPrefix("09") == true)
    }
}

@Suite("Renumbering a folder that mixes numbered and unnumbered parts")
@MainActor
struct MixedNumberingTests {

    private func folder(_ names: [String]) -> URL {
        let dir = temporaryFolder("mixed")
        for name in names { writePDF(pages: 1, to: dir.appendingPathComponent(name)) }
        return dir
    }

    @Test("Only a real mix counts")
    func detection() {
        let order = ["flute", "clarinet", "trumpet"]
        let urls = { (names: [String]) in names.map { URL(fileURLWithPath: "/x/\($0)") } }
        #expect(scoreOrderNeedsRenumbering(files: urls(["01 - Flute.pdf", "Clarinet 1.pdf"]), order: order))
        #expect(!scoreOrderNeedsRenumbering(files: urls(["01 - Flute.pdf", "02 - Clarinet 1.pdf"]), order: order))
        #expect(!scoreOrderNeedsRenumbering(files: urls(["Flute.pdf", "Clarinet 1.pdf"]), order: order))
        // An unnumbered file with no instrument (programme notes) isn't a part to number.
        #expect(!scoreOrderNeedsRenumbering(files: urls(["01 - Flute.pdf", "Notes.pdf"]), order: order))
    }

    @Test("Loading a mixed folder turns renumbering on, and says why; a tidy one doesn't")
    func loading() {
        let manager = RenamerManager()
        manager.partFolderMode = .off   // not the user's setting
        manager.customInstrumentOrder = ["flute", "clarinet", "trumpet"]
        manager.loadFolder(url: folder(["01 - Flute.pdf", "02 - Trumpet 1.pdf", "Clarinet 1.pdf"]))
        #expect(manager.isRescanMode)
        #expect(manager.renumberedAutomatically)
        #expect(manager.statusText.contains("Renumbering them all"))
        let newNames = manager.operations.map(\.newName).filter { !$0.isEmpty }.sorted()
        #expect(newNames == ["02 - Clarinet 1.pdf", "03 - Trumpet 1.pdf"])   // Flute stays 01

        // Unticking it is the person's choice, and sticks.
        manager.setRescanMode(false)
        #expect(!manager.renumberedAutomatically)

        manager.loadFolder(url: folder(["01 - Flute.pdf", "02 - Clarinet 1.pdf"]))
        #expect(!manager.isRescanMode)
    }

    @Test("Typing a number for an already-numbered file renumbers the rest around it")
    func numberForANumberedFile() {
        let manager = RenamerManager()
        manager.partFolderMode = .off   // not the user's setting
        manager.customInstrumentOrder = ["flute", "clarinet", "trumpet"]
        manager.loadFolder(url: folder(["01 - Flute.pdf", "02 - Trumpet 1.pdf", "03 - Clarinet 1.pdf"]))
        #expect(!manager.isRescanMode)   // tidy, so left alone at first

        manager.setManualOverride(for: "03 - Clarinet 1.pdf", number: 1)
        #expect(manager.isRescanMode && manager.renumberedAutomatically)
        let names = manager.operations.map { $0.newName.isEmpty ? $0.originalName : $0.newName }.sorted()
        #expect(names == ["01 - Clarinet 1.pdf", "02 - Flute.pdf", "03 - Trumpet 1.pdf"])
    }
}
