//
//  ScanSplitLogicTests.swift
//  ScoreSortTests
//
//  Splitting scanned double pages: where detection cuts a scan (the gutter, the edge of
//  the black scanner bed), when it leaves one whole, which pieces it marks to skip, and
//  the crop boxes the split produces for every page rotation.
//
//  Detection is tested on drawn greyscale scans: staff lines for music, solid dark for
//  the scanner bed. The real scans it was tuned on (overhead-scanner part books) aren't
//  in the repository.
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

// MARK: - Drawn scans

/// A white scan with "music" (staff-line rows across the middle 70% of the height) in each
/// `music` range and solid scanner bed in each `bed` range — ranges as fractions of the width.
private func drawnScan(width: Int = 400, height: Int = 280,
                       music: [ClosedRange<Double>] = [],
                       bed: [ClosedRange<Double>] = [],
                       musicRowEvery: Int = 12) -> GrayImage {
    var px = [UInt8](repeating: 250, count: width * height)
    func columns(_ r: ClosedRange<Double>) -> Range<Int> {
        Int(r.lowerBound * Double(width))..<min(width, Int(r.upperBound * Double(width)))
    }
    for r in music {
        for y in (height * 15 / 100)..<(height * 85 / 100) where y % musicRowEvery < 2 {
            for x in columns(r) { px[y * width + x] = 20 }
        }
    }
    for r in bed {
        for y in 0..<height { for x in columns(r) { px[y * width + x] = 25 } }
    }
    return GrayImage(width: width, height: height, pixels: px)
}

private func analyse(_ img: GrayImage) -> ScanAnalysis {
    analyseScan(profile: columnProfile(img), aspect: Double(img.width) / Double(img.height))
}

private func cut(_ a: ScanAnalysis) -> Double? {
    if case .split(let f) = a.layout { return f }
    return nil
}

// MARK: - Detection

@Suite("Scan split detection")
struct ScanSplitDetectionTests {

    @Test("A spread is cut in the gutter")
    func spreadCutInGutter() throws {
        let a = analyse(drawnScan(music: [0.04...0.46, 0.54...0.96]))
        #expect(a.reason == .gutter)
        let f = try #require(cut(a))
        #expect(abs(f - 0.5) < 0.01)
    }

    @Test("An off-centre gutter is followed, keeping clear of the music")
    func offCentreGutter() throws {
        let a = analyse(drawnScan(music: [0.04...0.55, 0.62...0.96]))
        #expect(a.reason == .gutter)
        let f = try #require(cut(a))
        #expect(f > 0.555 && f < 0.615)
    }

    @Test("Specks of dust in the gutter don't hide it")
    func dustInGutter() throws {
        var img = drawnScan(music: [0.04...0.46, 0.54...0.96])
        // One dark pixel in every gutter column.
        for x in 186...214 { img.pixels[(100 + x % 50) * img.width + x] = 0 }
        let a = analyse(img)
        #expect(a.reason == .gutter)
        #expect(abs(try #require(cut(a)) - 0.5) < 0.01)
    }

    @Test("Music running into the fold is cut through the least ink")
    func musicIntoFold() throws {
        // Dense music everywhere except a sparser strip at 47–50%.
        let img = drawnScan(music: [0.04...0.47, 0.50...0.96])
        var sparse = drawnScan(music: [0.47...0.50], musicRowEvery: 60)
        for i in sparse.pixels.indices where sparse.pixels[i] == 250 { sparse.pixels[i] = img.pixels[i] }
        let a = analyse(sparse)
        #expect(a.reason == .leastInk)
        let f = try #require(cut(a))
        #expect(f >= 0.46 && f <= 0.51)
    }

    @Test("A page beside the scanner bed is cut where the bed starts")
    func scannerBedOnRight() throws {
        let img = drawnScan(music: [0.05...0.58], bed: [0.62...1.0])
        let a = analyse(img)
        #expect(a.reason == .scannerBed)
        let f = try #require(cut(a))
        #expect(abs(f - 0.62) < 0.01)
        #expect(blankPieces(img, layout: a.layout) == [nil, .black])
    }

    @Test("A black strip down one side of a single page is cut off, however narrow the scan")
    func scannerBedStripOnLeft() throws {
        // Near-square: one page plus a strip of bed — still cut.
        let img = drawnScan(width: 300, height: 300, music: [0.32...0.95], bed: [0.0...0.25])
        let a = analyse(img)
        #expect(a.reason == .scannerBed)
        #expect(abs(try #require(cut(a)) - 0.25) < 0.01)
        #expect(blankPieces(img, layout: a.layout) == [.black, nil])
    }

    @Test("A thin dark edge isn't scanner bed")
    func thinEdgeIgnored() {
        let a = analyse(drawnScan(width: 200, height: 280, music: [0.1...0.9], bed: [0.0...0.05]))
        #expect(a.layout == .single)
    }

    @Test("Dark artwork isn't mistaken for scanner bed")
    func darkArtworkNotBed() {
        // 90% dark on the left — a cover picture, not the solid bed.
        var img = drawnScan(music: [0.55...0.95])
        for y in 0..<img.height where y % 10 != 0 {
            for x in 0..<(img.width * 45 / 100) { img.pixels[y * img.width + x] = 30 }
        }
        #expect(analyse(img).reason != .scannerBed)
    }

    @Test("A single page, taller than wide, is left whole")
    func singlePageWhole() {
        let a = analyse(drawnScan(width: 200, height: 280, music: [0.1...0.9]))
        #expect(a.layout == .single)
        #expect(a.reason == .none)
    }

    @Test("An empty facing page is cut off and marked to skip")
    func emptyFacingPage() throws {
        let img = drawnScan(music: [0.04...0.46])
        let a = analyse(img)
        #expect(abs(try #require(cut(a)) - 0.5) < 0.01)
        #expect(blankPieces(img, layout: a.layout) == [nil, .white])
    }

    @Test("Pages with music are never marked blank")
    func musicNotBlank() {
        let img = drawnScan(music: [0.04...0.46, 0.54...0.96])
        #expect(blankPieces(img, layout: .split(at: 0.5)) == [nil, nil])
        #expect(blankPieces(img, layout: .single) == [nil])
    }

    @Test("A sliver of a piece counts as blank")
    func sliverIsBlank() {
        let img = drawnScan(music: [0.0...1.0])
        #expect(blankKind(img, x0: 0, x1: 6) == .white)
    }
}

// MARK: - Layout maths

@Suite("Scan split layout")
struct ScanSplitLayoutTests {

    @Test("Pieces run left to right across the scan")
    func pieceRanges() {
        #expect(ScanLayout.single.pieceRanges == [0...1])
        #expect(ScanLayout.split(at: 0.4).pieceRanges == [0...0.4, 0.4...1])
        #expect(ScanLayout.single.pieceCount == 1)
        #expect(ScanLayout.split(at: 0.4).pieceCount == 2)
    }

    @Test("Output page numbers follow the reading order")
    func outputIndices() {
        let layouts: [ScanLayout] = [.single, .split(at: 0.5), .split(at: 0.4), .single]
        #expect(scanPieceOutputIndices(layouts: layouts, leftFirst: true) == [[0], [1, 2], [3, 4], [5]])
        #expect(scanPieceOutputIndices(layouts: layouts, leftFirst: false) == [[0], [2, 1], [4, 3], [5]])
    }

    @Test("Skips come back as pages of the split document")
    @MainActor
    func choiceMapsSkips() {
        let doc = PDFDocument()
        for i in 0..<3 { doc.insert(PDFPage(), at: i) }
        let model = ScanSplitModel(document: doc)
        model.scans[1].layout = .split(at: 0.5)
        model.scans[1].skip = [false, true]   // the right-hand piece
        model.scans[2].skip = [true]
        model.leftFirst = false               // right-hand piece comes first
        let choice = model.choice
        #expect(choice.layouts == [.single, .split(at: 0.5), .single])
        #expect(choice.skippedPages == [1, 3])
        #expect(model.pageCount == 4)
        #expect(model.skippedCount == 2)
    }

    /// A one-scan model whose scan holds music on the left and nothing on the right.
    @MainActor
    private func halfEmptyScanModel() -> ScanSplitModel {
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0)
        let model = ScanSplitModel(document: doc)
        model.scans[0].gray = drawnScan(music: [0.04...0.46])
        model.scans[0].layout = .split(at: 0.5)
        model.scans[0].suggested = .split(at: 0.5)
        model.scans[0].skip = [false, true]
        return model
    }

    @Test("Moving a cut re-checks its pieces for blanks")
    @MainActor
    func moveCutRechecksBlanks() {
        let model = halfEmptyScanModel()
        // Dragged into the music: the right piece now has some, so it's kept.
        model.moveCut(to: 0.3, scan: 0, final: false)
        #expect(model.scans[0].skip == [false, true])   // not re-checked mid-drag
        model.moveCut(to: 0.3, scan: 0, final: true)
        #expect(model.scans[0].layout == .split(at: 0.3))
        #expect(model.scans[0].skip == [false, false])
    }

    @Test("A skip the user chose survives moving the cut")
    @MainActor
    func userSkipsKept() {
        let model = halfEmptyScanModel()
        model.toggleSkip(piece: 0, scan: 0)
        #expect(model.scans[0].skip == [true, true])
        model.moveCut(to: 0.3, scan: 0, final: true)
        #expect(model.scans[0].skip == [true, true])
    }

    @Test("Switching between one page and two")
    @MainActor
    func switchOneAndTwoPages() {
        let model = halfEmptyScanModel()
        model.setTwoPages(false, scan: 0)
        #expect(model.scans[0].layout == .single)
        #expect(model.scans[0].skip == [false])
        // Back to two: the detected cut, and its blank piece, return.
        model.setTwoPages(true, scan: 0)
        #expect(model.scans[0].layout == .split(at: 0.5))
        #expect(model.scans[0].skip == [false, true])
    }

    @Test("A scan detected as one page splits down the middle when switched")
    @MainActor
    func switchSingleToTwo() {
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0)
        let model = ScanSplitModel(document: doc)
        model.setTwoPages(true, scan: 0)
        #expect(model.scans[0].layout == .split(at: 0.5))
        #expect(model.scans[0].skip == [false, false])
    }
}

// MARK: - Splitting

@Suite("Scan splitting")
struct ScanSplittingTests {

    private func page(width: CGFloat, height: CGFloat, rotation: Int = 0) -> PDFPage {
        let p = PDFPage()
        p.setBounds(CGRect(x: 0, y: 0, width: width, height: height), for: .mediaBox)
        p.rotation = rotation
        return p
    }

    private func crops(_ pages: [PDFPage]) -> [CGRect] { pages.map { $0.bounds(for: .cropBox) } }

    @Test("Unrotated: cut on the native x axis")
    func rotation0() {
        let p = page(width: 1000, height: 600)
        #expect(crops(splitPage(p, at: 0.3, leftFirst: true)) ==
                [CGRect(x: 0, y: 0, width: 300, height: 600), CGRect(x: 300, y: 0, width: 700, height: 600)])
        #expect(crops(splitPage(p, at: 0.3, leftFirst: false)) ==
                [CGRect(x: 300, y: 0, width: 700, height: 600), CGRect(x: 0, y: 0, width: 300, height: 600)])
    }

    @Test("180°: the visual left is the native right")
    func rotation180() {
        let p = page(width: 1000, height: 600, rotation: 180)
        #expect(crops(splitPage(p, at: 0.3, leftFirst: true)) ==
                [CGRect(x: 700, y: 0, width: 300, height: 600), CGRect(x: 0, y: 0, width: 700, height: 600)])
    }

    @Test("90° clockwise: the visual left is the native bottom")
    func rotation90() {
        let p = page(width: 600, height: 1000, rotation: 90)
        #expect(crops(splitPage(p, at: 0.3, leftFirst: true)) ==
                [CGRect(x: 0, y: 0, width: 600, height: 300), CGRect(x: 0, y: 300, width: 600, height: 700)])
    }

    @Test("270° clockwise: the visual left is the native top")
    func rotation270() {
        let p = page(width: 600, height: 1000, rotation: 270)
        #expect(crops(splitPage(p, at: 0.3, leftFirst: true)) ==
                [CGRect(x: 0, y: 700, width: 600, height: 300), CGRect(x: 0, y: 0, width: 600, height: 700)])
    }

    @Test("Media box follows the crop box, so the cut-off part is gone for good")
    func mediaMatchesCrop() {
        for piece in splitPage(page(width: 1000, height: 600), at: 0.4, leftFirst: true) {
            #expect(piece.bounds(for: .mediaBox) == piece.bounds(for: .cropBox))
        }
    }

    @Test("Whole and split scans together")
    func mixedDocument() {
        let doc = PDFDocument()
        doc.insert(page(width: 600, height: 850), at: 0)
        doc.insert(page(width: 1300, height: 850), at: 1)
        doc.insert(page(width: 600, height: 850), at: 2)
        let out = splitScans(doc, layouts: [.single, .split(at: 0.4), .single], leftFirst: true)
        #expect(out.pageCount == 4)
        #expect(out.page(at: 0)?.bounds(for: .cropBox).width == 600)
        #expect(out.page(at: 1)?.bounds(for: .cropBox).width == 520)
        #expect(out.page(at: 2)?.bounds(for: .cropBox).width == 780)
        #expect(out.page(at: 3)?.bounds(for: .cropBox).width == 600)
    }

    @Test("Pages beyond the layouts are kept whole")
    func missingLayoutsKeepWhole() {
        let doc = PDFDocument()
        doc.insert(page(width: 1300, height: 850), at: 0)
        doc.insert(page(width: 1300, height: 850), at: 1)
        #expect(splitScans(doc, layouts: [.split(at: 0.5)], leftFirst: true).pageCount == 3)
    }
}

// MARK: - Rendering & offering

@Suite("Scan split rendering")
struct ScanSplitRenderingTests {

    /// A 400 × 200 landscape page whose left half is solid black, drawn by Core Graphics
    /// (only file-backed pages have the Core Graphics page the renderer uses).
    private func leftHalfBlackDocument() throws -> PDFDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-render-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 400, height: 200)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        ctx.endPDFPage()
        ctx.closePDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        return try #require(PDFDocument(data: data))
    }

    private func gray(_ doc: PDFDocument, width: Int) throws -> GrayImage {
        let source = try #require(doc.page(at: 0)?.scanRenderSource)
        let image = try #require(renderScan(source, width: width))
        return try #require(GrayImage(image))
    }

    private func meanBrightness(_ img: GrayImage, rows: Range<Int>, columns: Range<Int>) -> Double {
        var sum = 0
        for y in rows { for x in columns { sum += Int(img.pixels[y * img.width + x]) } }
        return Double(sum) / Double(rows.count * columns.count) / 255
    }

    @Test("Renders upright")
    func uprightRender() throws {
        let img = try gray(leftHalfBlackDocument(), width: 200)
        #expect(img.width == 200 && img.height == 100)
        #expect(meanBrightness(img, rows: 0..<100, columns: 10..<90) < 0.1)
        #expect(meanBrightness(img, rows: 0..<100, columns: 110..<190) > 0.9)
    }

    @Test("Honours a 90° rotation: the native left edge comes out on top")
    func rotatedRender() throws {
        let doc = try leftHalfBlackDocument()
        doc.page(at: 0)?.rotation = 90
        let img = try gray(doc, width: 100)
        #expect(img.width == 100 && img.height == 200)
        #expect(meanBrightness(img, rows: 10..<90, columns: 0..<100) < 0.1)
        #expect(meanBrightness(img, rows: 110..<190, columns: 0..<100) > 0.9)
    }

    @Test("Honours a crop box set by PDFKit")
    func croppedRender() throws {
        let doc = try leftHalfBlackDocument()
        doc.page(at: 0)?.setBounds(CGRect(x: 200, y: 0, width: 200, height: 200), for: .cropBox)
        let img = try gray(doc, width: 100)
        #expect(img.width == 100 && img.height == 100)
        #expect(meanBrightness(img, rows: 0..<100, columns: 0..<100) > 0.9)
    }

    private func document(sizes: [(CGFloat, CGFloat)]) -> PDFDocument {
        let doc = PDFDocument()
        for (i, size) in sizes.enumerated() {
            let p = PDFPage()
            p.setBounds(CGRect(x: 0, y: 0, width: size.0, height: size.1), for: .mediaBox)
            doc.insert(p, at: i)
        }
        return doc
    }

    @Test("Offered for a book scanner's mix of spreads and single pages")
    func offeredForMixedScan() {
        #expect(looksLikeDoublePageScan(document(sizes: [(662, 937), (1326, 933), (659, 936), (1329, 950)])))
    }

    @Test("Not offered for ordinary portrait pages")
    func notOfferedForPortrait() {
        #expect(!looksLikeDoublePageScan(document(sizes: [(595, 842), (595, 842), (595, 842)])))
        #expect(!looksLikeDoublePageScan(document(sizes: [(876, 1216), (842, 1240), (865, 1223)])))
    }

    @Test("Not offered for a document of identical landscape pages")
    func notOfferedForUniformLandscape() {
        // A designed landscape document; a flatbed A3 scan is `isA3Landscape`'s job.
        #expect(!looksLikeDoublePageScan(document(sizes: [(842, 595), (842, 595), (842, 595)])))
    }
}
