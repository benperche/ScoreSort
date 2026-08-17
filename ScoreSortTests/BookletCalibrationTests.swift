//
//  BookletCalibrationTests.swift
//  ScoreSortTests
//
//  Tests for the two-sided setup: the generated test sheet, and the per-printer memory of the
//  answer. The wizard itself is UI and isn't covered — but the sheet it prints must go through
//  the real imposition, or folding it would prove nothing about real booklets.
//

import Testing
import Foundation
import AppKit
import PDFKit
@testable import ScoreSort

@Suite("Booklet calibration sheet")
struct BookletCalibrationSheetTests {

    @Test func fourReadingPagesAtA4() throws {
        let pages = try #require(bookletCalibrationPages())
        #expect(pages.pageCount == 4)          // exactly one folded sheet
        let bounds = try #require(pages.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - 595) < 1)
        #expect(abs(bounds.height - 842) < 1)
    }

    @Test func pagesCarryTheirNumbers() throws {
        // The whole test is "can you read 1, 2, 3, 4" — so the numerals have to be on the pages.
        let pages = try #require(bookletCalibrationPages())
        for i in 0..<4 {
            let text = try #require(pages.page(at: i)).string ?? ""
            #expect(text.contains("\(i + 1)"), "page \(i + 1) should show its number")
        }
    }

    @Test func imposesToASingleSheet() throws {
        let sheet = try #require(bookletCalibrationSheet(sheetSize: .fitA4Landscape,
                                                         rotateBackFaces: false))
        #expect(sheet.pageCount == 2)          // front and back of one piece of paper
        let bounds = try #require(sheet.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - 842) < 1)
        #expect(abs(bounds.height - 595) < 1)
    }

    @Test func doubleSizeGivesA3() throws {
        let sheet = try #require(bookletCalibrationSheet(sheetSize: .doubleSize,
                                                         rotateBackFaces: false))
        let bounds = try #require(sheet.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - 1190) < 1)
    }

    /// The sheet has to reflect whatever the flip is currently set to, otherwise printing it
    /// again after switching would show no difference and the wizard's second pass is useless.
    @Test func rotationReachesTheSheet() throws {
        let plain = try #require(bookletCalibrationSheet(sheetSize: .fitA4Landscape,
                                                         rotateBackFaces: false))
        let rotated = try #require(bookletCalibrationSheet(sheetSize: .fitA4Landscape,
                                                           rotateBackFaces: true))
        #expect(plain.pageCount == rotated.pageCount)
        #expect(plain.dataRepresentation() != rotated.dataRepresentation())
    }
}

@Suite("Duplex flip per printer", .serialized)
struct BookletDuplexDefaultsTests {

    private func clean(_ printer: String) {
        var stored = UserDefaults.standard.dictionary(forKey: "combineDuplexFlipByPrinter") as? [String: String] ?? [:]
        stored[printer] = nil
        UserDefaults.standard.set(stored, forKey: "combineDuplexFlipByPrinter")
    }

    @Test func unknownPrinterDefaultsToLongEdge() {
        let printer = "unknown-\(UUID().uuidString)"
        defer { clean(printer) }
        #expect(BookletDuplexDefaults.flip(forPrinter: printer) == .longEdge)
    }

    @Test func remembersTheAnswer() {
        let printer = "test-\(UUID().uuidString)"
        defer { clean(printer) }
        BookletDuplexDefaults.setFlip(.shortEdge, forPrinter: printer)
        #expect(BookletDuplexDefaults.flip(forPrinter: printer) == .shortEdge)
    }

    /// The point of storing per printer: two sites, two answers, neither clobbering the other.
    @Test func printersAreIndependent() {
        let home = "home-\(UUID().uuidString)"
        let school = "school-\(UUID().uuidString)"
        defer { clean(home); clean(school) }

        BookletDuplexDefaults.setFlip(.shortEdge, forPrinter: home)
        BookletDuplexDefaults.setFlip(.longEdge, forPrinter: school)
        #expect(BookletDuplexDefaults.flip(forPrinter: home) == .shortEdge)
        #expect(BookletDuplexDefaults.flip(forPrinter: school) == .longEdge)
    }
}
