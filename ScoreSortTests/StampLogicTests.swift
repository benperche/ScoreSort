//
//  StampLogicTests.swift
//  ScoreSortTests
//
//  Tests for the stamping logic: anchor placement maths and the flattener that burns
//  the stamp into page content. The drawing itself isn't asserted pixel-by-pixel — what
//  matters is that pages survive, keep their visual size (including rotated and
//  A3-cropped pages), and that only the requested pages are touched.
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

/// A4 portrait page with real bounds, so crop/media boxes are meaningful.
private func a4Page(rotation: Int = 0) -> PDFPage {
    let page = PDFPage()
    let box = CGRect(x: 0, y: 0, width: 595, height: 842)
    page.setBounds(box, for: .mediaBox)
    page.setBounds(box, for: .cropBox)
    page.rotation = rotation
    return page
}

private func document(pages: [PDFPage]) -> PDFDocument {
    let doc = PDFDocument()
    for (i, page) in pages.enumerated() { doc.insert(page, at: i) }
    return doc
}

private func testStamp(anchor: StampAnchor = .topRight,
                       margin: Double = 24,
                       border: Bool = true,
                       scope: StampScope = .everyPage) -> Stamp {
    Stamp(name: "Test", text: "Example School Band",
          anchor: anchor, margin: margin, hasBorder: border, scope: scope)
}

// MARK: - Placement

@Suite("Stamp placement")
struct StampPlacementTests {

    private let pageBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    private let textSize = CGSize(width: 120, height: 14)

    @Test("every anchor places the stamp inside the page")
    func allAnchorsStayInsidePage() {
        for anchor in StampAnchor.allCases {
            let rect = stampRect(for: testStamp(anchor: anchor), textSize: textSize, in: pageBox)
            #expect(pageBox.contains(rect), "\(anchor) fell outside the page: \(rect)")
        }
    }

    @Test("top anchors sit at the top edge, bottom anchors at the bottom")
    func verticalPlacement() {
        let margin: Double = 24
        let top = stampRect(for: testStamp(anchor: .topLeft, margin: margin), textSize: textSize, in: pageBox)
        let bottom = stampRect(for: testStamp(anchor: .bottomLeft, margin: margin), textSize: textSize, in: pageBox)
        // PDF user space is y-up, so "top" means near maxY.
        #expect(abs(top.maxY - (pageBox.maxY - margin)) < 0.01)
        #expect(abs(bottom.minY - (pageBox.minY + margin)) < 0.01)
        #expect(top.minY > bottom.maxY)
    }

    @Test("left / right / centre anchors respect the margin")
    func horizontalPlacement() {
        let margin: Double = 30
        let left = stampRect(for: testStamp(anchor: .middleLeft, margin: margin), textSize: textSize, in: pageBox)
        let right = stampRect(for: testStamp(anchor: .middleRight, margin: margin), textSize: textSize, in: pageBox)
        let centre = stampRect(for: testStamp(anchor: .centre, margin: margin), textSize: textSize, in: pageBox)
        #expect(abs(left.minX - (pageBox.minX + margin)) < 0.01)
        #expect(abs(right.maxX - (pageBox.maxX - margin)) < 0.01)
        #expect(abs(centre.midX - pageBox.midX) < 0.01)
    }

    @Test("centre anchor is vertically centred")
    func centreIsCentred() {
        let rect = stampRect(for: testStamp(anchor: .centre), textSize: textSize, in: pageBox)
        #expect(abs(rect.midY - pageBox.midY) < 0.01)
    }

    @Test("the border adds padding around the text")
    func borderAddsPadding() {
        let withBorder = stampRect(for: testStamp(border: true), textSize: textSize, in: pageBox)
        let without = stampRect(for: testStamp(border: false), textSize: textSize, in: pageBox)
        #expect(withBorder.width == textSize.width + stampPaddingH * 2)
        #expect(withBorder.height == textSize.height + stampPaddingV * 2)
        #expect(without.size == textSize)
    }

    @Test("placement is relative to a non-zero page origin")
    func honoursPageOrigin() {
        let offsetBox = CGRect(x: 100, y: 50, width: 400, height: 600)
        let rect = stampRect(for: testStamp(anchor: .bottomLeft, margin: 10),
                             textSize: textSize, in: offsetBox)
        #expect(abs(rect.minX - 110) < 0.01)
        #expect(abs(rect.minY - 60) < 0.01)
    }
}

// MARK: - Scope

@Suite("Stamp scope")
struct StampScopeTests {

    @Test("every-page scope covers the whole document")
    func everyPage() {
        let indices = stampPageIndices(for: testStamp(scope: .everyPage),
                                      pageCount: 5, partFirstPages: [0, 2])
        #expect(indices == Set(0..<5))
    }

    @Test("first-page scope uses the part start pages")
    func firstPageOfEachPart() {
        let indices = stampPageIndices(for: testStamp(scope: .firstPageOfEachPart),
                                      pageCount: 6, partFirstPages: [0, 2, 4])
        #expect(indices == Set([0, 2, 4]))
    }

    @Test("out-of-range part pages are ignored")
    func dropsOutOfRangePages() {
        let indices = stampPageIndices(for: testStamp(scope: .firstPageOfEachPart),
                                      pageCount: 3, partFirstPages: [0, 5, -1])
        #expect(indices == Set([0]))
    }
}

// MARK: - Flattening

@Suite("Stamp flattening")
struct StampFlatteningTests {

    @Test("stamping preserves the page count")
    func preservesPageCount() {
        let doc = document(pages: [a4Page(), a4Page(), a4Page()])
        let stamped = stampedDocument(doc, stamp: testStamp(), pageIndices: [0, 1, 2])
        #expect(stamped?.pageCount == 3)
    }

    @Test("stamping only some pages still returns every page")
    func partialStampKeepsAllPages() {
        let doc = document(pages: [a4Page(), a4Page(), a4Page(), a4Page()])
        let stamped = stampedDocument(doc, stamp: testStamp(), pageIndices: [0, 2])
        #expect(stamped?.pageCount == 4)
    }

    @Test("an empty stamp produces nothing to write")
    func blankTextIsRejected() {
        let doc = document(pages: [a4Page()])
        var stamp = testStamp()
        stamp.text = "   \n "
        #expect(stampedDocument(doc, stamp: stamp, pageIndices: [0]) == nil)
        #expect(stamp.isDrawable == false)
    }

    @Test("an empty document produces nothing")
    func emptyDocumentIsRejected() {
        #expect(stampedDocument(PDFDocument(), stamp: testStamp(), pageIndices: [0]) == nil)
    }

    @Test("the stamped document survives a write / reload round trip")
    func survivesRoundTrip() throws {
        let doc = document(pages: [a4Page(), a4Page()])
        let stamped = try #require(stampedDocument(doc, stamp: testStamp(), pageIndices: [0]))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stamp-roundtrip-\(UUID().uuidString).pdf")
        #expect(stamped.write(to: url))
        defer { try? FileManager.default.removeItem(at: url) }

        let reloaded = try #require(PDFDocument(url: url))
        #expect(reloaded.pageCount == 2)
        let bounds = try #require(reloaded.page(at: 0)?.bounds(for: .mediaBox))
        #expect(abs(bounds.width - 595) < 1)
        #expect(abs(bounds.height - 842) < 1)
    }

    @Test("a 90°-rotated page comes out at its visual size")
    func rotatedPageKeepsVisualSize() throws {
        // Portrait page with a 90° rotation flag reads as landscape on screen; the stamped
        // output bakes that in, so the page itself must be landscape.
        let doc = document(pages: [a4Page(rotation: 90)])
        let stamped = try #require(stampedDocument(doc, stamp: testStamp(), pageIndices: [0]))
        let bounds = try #require(stamped.page(at: 0)?.bounds(for: .mediaBox))
        #expect(bounds.width > bounds.height)
        #expect(abs(bounds.width - 842) < 1)
        #expect(abs(bounds.height - 595) < 1)
    }

    @Test("an A3-split page keeps its cropped half, not the whole sheet")
    func cropBoxWins() throws {
        // Mirrors what splitA3Pages leaves behind: a media box covering the full A3 sheet
        // with the crop box limited to one half. The stamped page must be the half.
        let page = PDFPage()
        let full = CGRect(x: 0, y: 0, width: 1190, height: 842)
        let half = CGRect(x: 0, y: 0, width: 595, height: 842)
        page.setBounds(full, for: .mediaBox)
        page.setBounds(half, for: .cropBox)

        let stamped = try #require(stampedDocument(document(pages: [page]),
                                                  stamp: testStamp(), pageIndices: [0]))
        let bounds = try #require(stamped.page(at: 0)?.bounds(for: .mediaBox))
        #expect(abs(bounds.width - 595) < 1)
        #expect(abs(bounds.height - 842) < 1)
    }
}

// MARK: - Colour round trip

@Suite("Stamp colour parsing")
struct StampColourTests {

    @Test("hex parses and re-serialises unchanged")
    func roundTrip() {
        for hex in ["#000000", "#FFFFFF", "#3366CC"] {
            #expect(hexString(from: nsColor(fromHex: hex)) == hex)
        }
    }

    @Test("a leading hash is optional")
    func hashOptional() {
        #expect(hexString(from: nsColor(fromHex: "3366CC")) == "#3366CC")
    }

    @Test("unparseable input falls back to black")
    func fallsBackToBlack() {
        #expect(hexString(from: nsColor(fromHex: "not a colour")) == "#000000")
        #expect(hexString(from: nsColor(fromHex: "#12345")) == "#000000")
    }
}
