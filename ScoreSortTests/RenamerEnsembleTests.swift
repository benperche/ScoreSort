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
        for type in [EnsembleType.jazz, .orchestra, .band, .orchestra, .jazz] {
            manager.ensembleType = type
            #expect(manager.customInstrumentOrder == InstrumentOrders.getOrder(for: type),
                    "order should follow the ensemble every time, not only the first")
        }
    }

    /// The flag still has its original job: an order the user edited themselves survives an
    /// ensemble change rather than being silently replaced.
    @Test func aUserEditedOrderIsNotOverwritten() {
        let manager = RenamerManager()
        manager.ensembleType = .orchestra
        manager.customInstrumentOrder = ["tuba", "piccolo"]      // as if edited in Preferences
        manager.ensembleType = .band
        #expect(manager.customInstrumentOrder == ["tuba", "piccolo"])
    }
}
