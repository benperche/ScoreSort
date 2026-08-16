//
//  PrintLogicTests.swift
//  ScoreSortTests
//
//  Tests for the print settings a document goes out with. The dialog itself can't be driven
//  headlessly, which is why the settings are built by a separate function — the one thing
//  worth guarding is that the paper is turned to match the sheets, since booklet output is
//  landscape and portrait paper squashes it into a corner.
//

import Testing
import Foundation
import AppKit
import PDFKit
@testable import ScoreSort

private func document(width: CGFloat, height: CGFloat, pages: Int = 2) -> PDFDocument {
    let doc = PDFDocument()
    for i in 0..<pages {
        let page = PDFPage()
        let box = CGRect(x: 0, y: 0, width: width, height: height)
        page.setBounds(box, for: .mediaBox)
        page.setBounds(box, for: .cropBox)
        doc.insert(page, at: i)
    }
    return doc
}

@Suite("Print settings")
struct PrintSettingsTests {

    @Test func landscapeSheetsTurnThePaper() throws {
        // An A5 booklet's sheets are A4 landscape; on portrait paper they'd be squashed.
        let doc = document(width: 842, height: 595)
        let info = try #require(printSettings(for: doc, basedOn: NSPrintInfo(),
                                              twoSidedShortEdge: true))
        #expect(info.orientation == .landscape)
        #expect(info.paperSize.width > info.paperSize.height)
    }

    @Test func doubleSizeSheetsAlsoTurnThePaper() throws {
        let doc = document(width: 1190, height: 842)
        let info = try #require(printSettings(for: doc, basedOn: NSPrintInfo(),
                                              twoSidedShortEdge: true))
        #expect(info.orientation == .landscape)
    }

    @Test func portraitDocumentsAreLeftAlone() throws {
        // Single-page output is ordinary A4 portrait and must stay that way.
        let doc = document(width: 595, height: 842)
        let info = try #require(printSettings(for: doc, basedOn: NSPrintInfo(),
                                              twoSidedShortEdge: false))
        #expect(info.orientation == .portrait)
        #expect(info.paperSize.height > info.paperSize.width)
    }

    @Test func sheetsAreCentredWithNoMargins() throws {
        // The fold has to land in the middle of the paper, so centring matters here more
        // than anywhere else in the app.
        let doc = document(width: 842, height: 595)
        let info = try #require(printSettings(for: doc, basedOn: NSPrintInfo(),
                                              twoSidedShortEdge: true))
        #expect(info.isHorizontallyCentered)
        #expect(info.isVerticallyCentered)
        #expect(info.topMargin == 0)
        #expect(info.bottomMargin == 0)
        #expect(info.leftMargin == 0)
        #expect(info.rightMargin == 0)
    }

    @Test func duplexIsRequestedAsShortEdgeFlip() throws {
        let doc = document(width: 842, height: 595)
        let key = "com_apple_print_PrintSettings_PMDuplexing"

        let tumbling = try #require(printSettings(for: doc, basedOn: NSPrintInfo(),
                                                  twoSidedShortEdge: true))
        #expect((tumbling.printSettings[key] as? NSNumber)?.intValue == kPMDuplexTumble)

        let simplex = try #require(printSettings(for: doc, basedOn: NSPrintInfo(),
                                                 twoSidedShortEdge: false))
        #expect((simplex.printSettings[key] as? NSNumber)?.intValue == kPMDuplexNone)
    }
}
