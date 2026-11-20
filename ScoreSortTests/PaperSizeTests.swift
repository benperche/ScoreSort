//
//  PaperSizeTests.swift
//  ScoreSortTests
//
//  US Letter and Tabloid beside A4 and A3 (issue #18). The A4 tests elsewhere are unchanged:
//  everything that takes a `PaperSize` defaults to A4, so these add the Letter variants.
//

import Testing
import Foundation
import AppKit
import PDFKit
@testable import ScoreSort

private let letter = CGSize(width: 612, height: 792)
private let tabloidLandscape = CGSize(width: 1224, height: 792)

private func near(_ a: CGSize, _ b: CGSize, _ tolerance: CGFloat = 1) -> Bool {
    abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
}

/// A document of blank pages of the given sizes (media box; rotation optional).
private func document(_ sizes: [(CGFloat, CGFloat)], rotation: Int = 0) -> PDFDocument {
    let doc = PDFDocument()
    for (i, size) in sizes.enumerated() {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: size.0, height: size.1), for: .mediaBox)
        page.rotation = rotation
        doc.insert(page, at: i)
    }
    return doc
}

/// A PNG of `width` × `height` pixels, in a temporary folder.
private func writePNG(width: Int, height: Int) throws -> URL {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0))
    let data = try #require(rep.representation(using: .png, properties: [:]))
    let url = temporaryFolder("paper").appendingPathComponent("scan.png")
    try data.write(to: url)
    return url
}

// MARK: - The helper

@Suite("Paper size: the default where there's no page to follow")
struct PaperSizeTests {

    @Test("A4 and Letter in points, either way up")
    func sizes() {
        #expect(PaperSize.a4.pageSize == CGSize(width: 595, height: 842))
        #expect(PaperSize.letter.pageSize == letter)
        #expect(PaperSize.letter.landscapeBox.size == CGSize(width: 792, height: 612))
        #expect(PaperSize.a4.landscapeBox.size == CGSize(width: 842, height: 595))
    }

    @Test("Recognises a printer's paper within a few points, and nothing else")
    func matching() {
        #expect(PaperSize.matching(CGSize(width: 595.28, height: 841.89)) == .a4)
        #expect(PaperSize.matching(CGSize(width: 842, height: 595)) == .a4)
        #expect(PaperSize.matching(letter) == .letter)
        #expect(PaperSize.matching(CGSize(width: 792, height: 612)) == .letter)
        #expect(PaperSize.matching(CGSize(width: 612, height: 1008)) == nil)    // Legal
        #expect(PaperSize.matching(CGSize(width: 842, height: 1191)) == nil)    // A3
    }

    @Test("Letter in North America, A4 everywhere else")
    func regions() {
        #expect(PaperSize.forRegion("US") == .letter)
        #expect(PaperSize.forRegion("ca") == .letter)
        #expect(PaperSize.forRegion("MX") == .letter)
        #expect(PaperSize.forRegion("AU") == .a4)
        #expect(PaperSize.forRegion("GB") == .a4)
        #expect(PaperSize.forRegion(nil) == .a4)
    }

    @Test("Automatic: the default printer's paper first, then the region")
    func automatic() {
        #expect(PaperSize.automatic(printerPaper: PaperSize.a4.pageSize, region: "US") == .a4)
        #expect(PaperSize.automatic(printerPaper: letter, region: "AU") == .letter)
        #expect(PaperSize.automatic(printerPaper: nil, region: "US") == .letter)
        #expect(PaperSize.automatic(printerPaper: CGSize(width: 842, height: 1191), region: "AU") == .a4)
        #expect(PaperSize.automatic(printerPaper: CGSize(width: 842, height: 1191), region: "CA") == .letter)
    }

    @Test("The Settings choice resolves, working out Automatic only when it's chosen")
    func choice() {
        var asked = false
        func system() -> PaperSize { asked = true; return .letter }
        #expect(PaperSizeChoice.a4.resolved(automatic: system()) == .a4)
        #expect(PaperSizeChoice.letter.resolved(automatic: system()) == .letter)
        #expect(!asked)
        #expect(PaperSizeChoice.automatic.resolved(automatic: system()) == .letter)
        #expect(asked)
        // The stored values: an existing preference must keep reading back.
        #expect(PaperSizeChoice(rawValue: "automatic") == .automatic)
        #expect(PaperSizeChoice(rawValue: "letter") == .letter)
    }
}

// MARK: - Booklets

@Suite("Booklets on Letter and Tabloid")
struct LetterBookletTests {

    @Test("Labels follow the paper; the A4 wording is unchanged")
    func labels() {
        #expect(BookletSheetSize.doubleSize.label(for: .a4) == BookletSheetSize.doubleSize.label)
        #expect(BookletSheetSize.fitA4Landscape.label(for: .a4) == BookletSheetSize.fitA4Landscape.label)
        #expect(BookletSheetSize.doubleSize.label == "Double size (A4 \u{2192} A3)")
        #expect(BookletSheetSize.fitA4Landscape.label == "Fit A4 landscape (A5 booklet)")
        #expect(BookletSheetSize.doubleSize.label(for: .letter) == "Double size (Letter \u{2192} Tabloid)")
        #expect(BookletSheetSize.fitA4Landscape.label(for: .letter) == "Fit Letter landscape (half-letter booklet)")
        #expect(BookletSheetSize.doubleSize.shortLabel(for: .a4) == "A3")
        #expect(BookletSheetSize.fitA4Landscape.shortLabel(for: .a4) == "A5")
        #expect(BookletSheetSize.doubleSize.shortLabel(for: .letter) == "Tabloid")
        #expect(BookletSheetSize.fitA4Landscape.shortLabel(for: .letter) == "Half-letter")
        // The saved choice keeps its raw value.
        #expect(BookletSheetSize(rawValue: "fitA4Landscape") == .fitA4Landscape)
    }

    @Test("Letter parts at double size give Tabloid sheets, whatever the default paper")
    func doubleSizeFollowsTheSource() throws {
        let doc = document(Array(repeating: (612, 792), count: 4))
        for paper in PaperSize.allCases {
            let page = try #require(imposedBookletDocument(doc, segments: [0..<4], sheetSize: .doubleSize,
                                                           paper: paper)?.doc.page(at: 0))
            #expect(near(page.bounds(for: .mediaBox).size, tabloidLandscape))
        }
    }

    @Test("Fit onto the paper: Letter landscape for a half-letter booklet")
    func fitOntoLetter() throws {
        let doc = document(Array(repeating: (612, 792), count: 4))
        let page = try #require(imposedBookletDocument(doc, segments: [0..<4], sheetSize: .fitA4Landscape,
                                                       paper: .letter)?.doc.page(at: 0))
        #expect(near(page.bounds(for: .mediaBox).size, CGSize(width: 792, height: 612)))
        // A4 parts fitted onto Letter come out on Letter too.
        let a4 = document(Array(repeating: (595, 842), count: 4))
        let fitted = try #require(imposedBookletDocument(a4, segments: [0..<4], sheetSize: .fitA4Landscape,
                                                         paper: .letter)?.doc.page(at: 0))
        #expect(near(fitted.bounds(for: .mediaBox).size, CGSize(width: 792, height: 612)))
    }

    @Test("The two-sided test sheet is made on the paper")
    func calibrationSheet() throws {
        let pages = try #require(bookletCalibrationPages(paper: .letter))
        #expect(pages.pageCount == 4)
        #expect(near(try #require(pages.page(at: 0)).bounds(for: .mediaBox).size, letter))

        let fitted = try #require(bookletCalibrationSheet(sheetSize: .fitA4Landscape, rotateBackFaces: false,
                                                          paper: .letter))
        #expect(near(try #require(fitted.page(at: 0)).bounds(for: .mediaBox).size, CGSize(width: 792, height: 612)))

        let double = try #require(bookletCalibrationSheet(sheetSize: .doubleSize, rotateBackFaces: true,
                                                          paper: .letter))
        #expect(near(try #require(double.page(at: 0)).bounds(for: .mediaBox).size, tabloidLandscape))
    }
}

// MARK: - Pictures, blank pages, the stamp designer

@Suite("Pages with no source to follow take the paper")
@MainActor
struct DefaultPaperPagesTests {

    @Test("A picture becomes a page of the paper; makeA4Page stays A4")
    func images() throws {
        let url = try writePNG(width: 300, height: 200)
        let onLetter = pdfPages(fromImageAt: url, paper: .letter)
        #expect(onLetter.count == 1)
        #expect(near(try #require(onLetter.first).bounds(for: .mediaBox).size, letter))
        let onA4 = pdfPages(fromImageAt: url)
        #expect(near(try #require(onA4.first).bounds(for: .mediaBox).size, PaperSize.a4.pageSize))
        let doc = try #require(pdfDocument(forFileAt: url, paper: .letter))
        #expect(near(try #require(doc.page(at: 0)).bounds(for: .mediaBox).size, letter))
    }

    @Test("The stamp designer's blank page is the paper")
    func blankStampPage() {
        #expect(visualPageBox(for: nil).size == PaperSize.a4.pageSize)
        #expect(visualPageBox(for: nil, blank: .letter).size == letter)
    }

    @Test("Combine: blank pages and pictures on Letter; Letter parts keep their size")
    func combine() throws {
        let dir = temporaryFolder("letter-combine")
        let part = dir.appendingPathComponent("Flute.pdf")
        writeDrawnPDF(pages: 3, size: CGSize(width: 595, height: 842), to: part)
        let picture = try writePNG(width: 400, height: 600)

        let manager = CombineManager()
        manager.addFiles(urls: [part, picture], undoManager: nil)
        manager.addBlankPage(after: [], undoManager: nil)
        let out = dir.appendingPathComponent("out.pdf")
        var options = CombineOutputOptions(addBlankPages: true)
        options.paper = .letter
        manager.createCombinedPDF(to: out, options: options) { _, _, _ in }

        let doc = try #require(PDFDocument(url: out))
        // 3 A4 pages, a blank (odd-length part), the picture, the Blank Page entry.
        #expect(doc.pageCount == 6)
        let sizes = (0..<doc.pageCount).compactMap { doc.page(at: $0)?.bounds(for: .mediaBox).size }
        #expect(sizes[0...2].allSatisfy { near($0, PaperSize.a4.pageSize) })   // the PDF keeps A4
        #expect(sizes[3...5].allSatisfy { near($0, letter) })
    }

    @Test("Combine: a booklet of Letter parts prints on Tabloid")
    func letterBooklet() throws {
        let dir = temporaryFolder("letter-booklet")
        let part = dir.appendingPathComponent("Trumpet.pdf")
        writeDrawnPDF(pages: 4, size: letter, to: part)
        let manager = CombineManager()
        manager.addFiles(urls: [part], undoManager: nil)
        let out = dir.appendingPathComponent("booklet.pdf")
        manager.createCombinedPDF(to: out, options: CombineOutputOptions(layout: .booklet)) { _, _, _ in }
        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 2)
        #expect(near(try #require(doc.page(at: 0)).bounds(for: .mediaBox).size, tabloidLandscape))
    }

    @Test("Command line: --sheet takes fit, fit-a4 and fit-letter")
    func cliSheet() throws {
        let dir = temporaryFolder("letter-cli")
        writeDrawnPDF(pages: 4, size: letter, to: dir.appendingPathComponent("Trumpet.pdf"))
        let out = temporaryFolder("letter-cli-out")
        func firstSheet(_ sheet: String) throws -> CGSize {
            let file = out.appendingPathComponent("\(sheet).pdf")
            #expect(ScoreSortCLI.main(["combine", dir.path, "--out", file.path, "--booklet", "--sheet", sheet]) == 0)
            return try #require(PDFDocument(url: file)?.page(at: 0)).bounds(for: .mediaBox).size
        }
        #expect(near(try firstSheet("double"), tabloidLandscape))
        #expect(near(try firstSheet("fit-letter"), CGSize(width: 792, height: 612)))
        #expect(near(try firstSheet("fit-a4"), CGSize(width: 842, height: 595)))
        let fit = try firstSheet("fit")    // the Settings paper, whichever this Mac has
        #expect(near(fit, CGSize(width: 792, height: 612)) || near(fit, CGSize(width: 842, height: 595)))
        #expect(ScoreSortCLI.main(["combine", dir.path, "--out", out.appendingPathComponent("x.pdf").path,
                                   "--booklet", "--sheet", "tabloid"]) != 0)
    }
}

// MARK: - Scan detection

@Suite("Double-page scan detection on Tabloid")
struct TabloidScanDetectionTests {

    @Test("Tabloid landscape is a two-page sheet, like A3")
    func tabloidIsDoublePage() {
        #expect(isA3Landscape(document([(1224, 792)])))
        #expect(isA3Landscape(document(Array(repeating: (1224, 792), count: 4))))
        // Stored portrait with a rotation flag, as many scanners do.
        #expect(isA3Landscape(document([(792, 1224)], rotation: 90)))
        #expect(isA3Landscape(document([(1226, 794)])))     // a scanner's slightly larger page
        #expect(looksLikeA3Landscape(document([(1224, 792)])))
    }

    @Test("Letter pages, either way up, are single pages")
    func letterIsNot() {
        #expect(!isA3Landscape(document([(612, 792)])))
        #expect(!isA3Landscape(document([(792, 612)])))
        #expect(!looksLikeA3Landscape(document([(792, 612)])))
        #expect(!looksLikeDoublePageScan(document([(612, 792), (612, 792), (612, 792)])))
        #expect(!isUniformSheetScan(document([(612, 792), (612, 792)])))
    }

    @Test("Identical Tabloid sheets are a uniform-sheet scan, not a book scanner's mix")
    func tabloidUniform() {
        #expect(isUniformSheetScan(document([(1224, 792), (1224, 792), (1223, 793)])))
        #expect(!looksLikeDoublePageScan(document([(1224, 792), (1224, 792), (1224, 792)])))
    }

    @Test("A book scanner's mix of Letter-sized spreads and single pages is offered")
    func letterSpreadsMixed() {
        #expect(looksLikeDoublePageScan(document([(620, 800), (1236, 798), (615, 796), (1240, 802)])))
    }
}
