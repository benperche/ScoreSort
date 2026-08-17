//
//  BookletLogicTests.swift
//  ScoreSortTests
//
//  Tests for saddle-stitch imposition: the sheet-slot permutation, how the combined
//  document is carved into one booklet per part, and the imposed document's shape.
//  The drawing isn't asserted pixel-by-pixel — what matters is that the permutation is a
//  faithful inverse of the deimposition the Split tab already uses, that padding takes each
//  part up to a whole folded sheet, and that sheets come out the right size.
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

/// A page with real bounds, so crop/media boxes and the sheet maths are meaningful.
private func page(width: CGFloat = 595, height: CGFloat = 842) -> PDFPage {
    let p = PDFPage()
    let box = CGRect(x: 0, y: 0, width: width, height: height)
    p.setBounds(box, for: .mediaBox)
    p.setBounds(box, for: .cropBox)
    return p
}

private func document(pageCount: Int, width: CGFloat = 595, height: CGFloat = 842) -> PDFDocument {
    let doc = PDFDocument()
    for i in 0..<pageCount { doc.insert(page(width: width, height: height), at: i) }
    return doc
}

// MARK: - Imposition order

@Suite("Booklet imposition — bookletImpositionOrder")
struct BookletImpositionOrderTests {

    @Test func isTheInverseOfDeimposition() {
        // The whole point: printing a booklet is the deimposition permutation run backwards.
        for n in [4, 8, 12, 16, 20] {
            let deimposed = coverFirstFrontBackOrder(n: n)
            let imposed = bookletImpositionOrder(n: n)
            #expect(imposed.count == n)
            for (readingPos, slot) in deimposed.enumerated() {
                #expect(imposed[slot] == readingPos)
            }
        }
    }

    @Test func fourPagesGivesCoverOrder() {
        // Slots are [front-left, front-right, back-left, back-right]:
        // front of the sheet carries page 4 then 1, the back carries 2 then 3.
        #expect(bookletImpositionOrder(n: 4) == [3, 0, 1, 2])
    }

    @Test func eightPagesMatchesTheStandardSheetOrder() {
        // 1-based: 8,1  2,7  6,3  4,5 — the textbook two-sheet saddle stitch.
        #expect(bookletImpositionOrder(n: 8) == [7, 0, 1, 6, 5, 2, 3, 4])
    }

    @Test func resultIsAlwaysAValidPermutation() {
        for n in stride(from: 4, through: 40, by: 4) {
            let order = bookletImpositionOrder(n: n)
            #expect(order.count == n)
            #expect(Set(order) == Set(0..<n))
        }
    }

    @Test func rejectsCountsThatAreNotWholeSheets() {
        #expect(bookletImpositionOrder(n: 0).isEmpty)
        #expect(bookletImpositionOrder(n: 3).isEmpty)
        #expect(bookletImpositionOrder(n: 6).isEmpty)
        #expect(bookletImpositionOrder(n: -4).isEmpty)
    }
}

// MARK: - Padding

@Suite("Booklet padding — bookletPaddedCount")
struct BookletPaddedCountTests {

    @Test func roundsUpToAWholeFoldedSheet() {
        #expect(bookletPaddedCount(1) == 4)
        #expect(bookletPaddedCount(4) == 4)
        #expect(bookletPaddedCount(5) == 8)
        #expect(bookletPaddedCount(8) == 8)
        #expect(bookletPaddedCount(9) == 12)
    }

    @Test func neverGoesBelowOneSheet() {
        // A single-page part still costs a whole folded sheet.
        #expect(bookletPaddedCount(2) == 4)
        #expect(bookletPaddedCount(3) == 4)
    }

    @Test func emptyIsZero() {
        #expect(bookletPaddedCount(0) == 0)
    }
}

// MARK: - Segments

@Suite("Booklet segments — bookletSegments")
struct BookletSegmentsTests {

    @Test func splitsAtEachPartStart() {
        let segments = bookletSegments(pageCount: 12, partFirstPages: [0, 4, 9])
        #expect(segments == [0..<4, 4..<9, 9..<12])
    }

    @Test func firstSegmentAlwaysStartsAtZero() {
        // A blank page inserted ahead of the first part carries no bookmark; it must still
        // be printed rather than silently dropped.
        let segments = bookletSegments(pageCount: 10, partFirstPages: [2, 6])
        #expect(segments == [0..<2, 2..<6, 6..<10])
    }

    @Test func noPartsGivesOneWholeDocumentSegment() {
        #expect(bookletSegments(pageCount: 8, partFirstPages: []) == [0..<8])
    }

    @Test func emptyDocumentGivesNoSegments() {
        #expect(bookletSegments(pageCount: 0, partFirstPages: [0]).isEmpty)
    }

    @Test func ignoresDuplicateAndOutOfRangeIndices() {
        // A file that fails to load contributes a label but no pages, so two parts can
        // report the same first page.
        let segments = bookletSegments(pageCount: 8, partFirstPages: [0, 4, 4, 99, -1])
        #expect(segments == [0..<4, 4..<8])
    }

    @Test func unsortedIndicesAreHandled() {
        #expect(bookletSegments(pageCount: 9, partFirstPages: [6, 0, 3]) == [0..<3, 3..<6, 6..<9])
    }
}

// MARK: - Sheet count

@Suite("Booklet sheet count — bookletSheetCount")
struct BookletSheetCountTests {

    @Test func onePartPadsUpToWholeSheets() {
        #expect(bookletSheetCount(segments: [0..<5]) == 2)   // 5 pages → 8 → 2 sheets
        #expect(bookletSheetCount(segments: [0..<4]) == 1)
    }

    @Test func partsAreCountedSeparately() {
        // Two 5-page parts cost 4 sheets, not the 3 a single 10-page booklet would.
        #expect(bookletSheetCount(segments: [0..<5, 5..<10]) == 4)
    }

    @Test func noSegmentsIsZero() {
        #expect(bookletSheetCount(segments: []) == 0)
    }
}

// MARK: - Imposed document

@Suite("Booklet imposition — imposedBookletDocument")
struct ImposedBookletDocumentTests {

    @Test func producesTwoReadingPagesPerSheetFace() {
        let doc = document(pageCount: 8)
        let result = imposedBookletDocument(doc, segments: [0..<8], sheetSize: .doubleSize)
        #expect(result?.doc.pageCount == 4)   // 8 pages → 4 faces → 2 sheets of paper
    }

    @Test func padsAShortPartUpToAWholeSheet() {
        let doc = document(pageCount: 5)
        let result = imposedBookletDocument(doc, segments: [0..<5], sheetSize: .doubleSize)
        #expect(result?.doc.pageCount == 4)   // padded to 8 reading pages → 4 faces
    }

    @Test func eachPartIsImposedSeparately() {
        // Two 5-page parts must not be folded into one 10-page booklet.
        let doc = document(pageCount: 10)
        let result = imposedBookletDocument(doc, segments: [0..<5, 5..<10], sheetSize: .doubleSize)
        #expect(result?.doc.pageCount == 8)             // 4 faces each
        #expect(result?.sheetStarts == [0, 4])
    }

    @Test func doubleSizeSheetsAreTwiceAsWide() {
        let doc = document(pageCount: 4, width: 595, height: 842)
        guard let sheet = imposedBookletDocument(doc, segments: [0..<4],
                                                 sheetSize: .doubleSize)?.doc.page(at: 0) else {
            Issue.record("no imposed page"); return
        }
        let bounds = sheet.bounds(for: .mediaBox)
        #expect(abs(bounds.width - 1190) < 1)
        #expect(abs(bounds.height - 842) < 1)
    }

    @Test func fitA4LandscapeSheetsAreA4Landscape() {
        let doc = document(pageCount: 4, width: 595, height: 842)
        guard let sheet = imposedBookletDocument(doc, segments: [0..<4],
                                                 sheetSize: .fitA4Landscape)?.doc.page(at: 0) else {
            Issue.record("no imposed page"); return
        }
        let bounds = sheet.bounds(for: .mediaBox)
        #expect(abs(bounds.width - 842) < 1)
        #expect(abs(bounds.height - 595) < 1)
    }

    @Test func sheetSizeFollowsTheSourcePageSize() {
        // A5 reading pages should give A4 sheets, not A3 ones.
        let doc = document(pageCount: 4, width: 420, height: 595)
        guard let sheet = imposedBookletDocument(doc, segments: [0..<4],
                                                 sheetSize: .doubleSize)?.doc.page(at: 0) else {
            Issue.record("no imposed page"); return
        }
        #expect(abs(sheet.bounds(for: .mediaBox).width - 840) < 1)
    }

    @Test func sheetStartsStayAlignedWithSegments() {
        // 4-page part (1 sheet → 2 faces) then a 12-page part (3 sheets → 6 faces).
        let doc = document(pageCount: 16)
        let result = imposedBookletDocument(doc, segments: [0..<4, 4..<16], sheetSize: .doubleSize)
        #expect(result?.sheetStarts == [0, 2])
        #expect(result?.doc.pageCount == 8)
    }

    @Test func pageScaleDoesNotChangeTheSheets() throws {
        // Scaling is content-only: same number of sheets, same paper size.
        let doc = document(pageCount: 8)
        let scaled = try #require(imposedBookletDocument(doc, segments: [0..<8],
                                                         sheetSize: .doubleSize, pageScale: 1.03))
        #expect(scaled.doc.pageCount == 4)
        let bounds = try #require(scaled.doc.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - 1190) < 1)
        #expect(abs(bounds.height - 842) < 1)
    }

    @Test func emptyInputsReturnNil() {
        #expect(imposedBookletDocument(PDFDocument(), segments: [0..<4], sheetSize: .doubleSize) == nil)
        #expect(imposedBookletDocument(document(pageCount: 4), segments: [], sheetSize: .doubleSize) == nil)
    }
}

// MARK: - Combine tab integration

@Suite("Booklet output through CombineManager")
struct CombineBookletOutputTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("booklet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func eachPartBecomesItsOwnBooklet() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 8 pages → 4 faces, 5 pages → padded to 8 → 4 faces, 4 pages → 2 faces.
        for (name, pages) in [("Flute", 8), ("Clarinet", 5), ("Trumpet", 4)] {
            writePDF(pages: pages, to: dir.appendingPathComponent("\(name).pdf"))
        }

        let manager = CombineManager()
        manager.addFiles(urls: ["Flute", "Clarinet", "Trumpet"].map {
            dir.appendingPathComponent("\($0).pdf")
        }, undoManager: nil)

        let out = dir.appendingPathComponent("out.pdf")
        var options = CombineOutputOptions()
        options.layout = .booklet
        manager.createCombinedPDF(to: out, options: options) { _, _, _ in }

        let result = try #require(PDFDocument(url: out))
        #expect(result.pageCount == 10)

        // The table of contents must point at the sheet each booklet starts on, not at the
        // reading-page index it had before imposition.
        let root = try #require(result.outlineRoot)
        #expect(root.numberOfChildren == 3)
        let starts = (0..<root.numberOfChildren).compactMap { i -> Int? in
            guard let page = root.child(at: i)?.destination?.page else { return nil }
            return result.index(for: page)
        }
        #expect(starts == [0, 4, 8])
    }

    @Test func copiesEachBecomeTheirOwnBooklet() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("Flute.pdf")
        writePDF(pages: 4, to: url)

        let manager = CombineManager()
        manager.addFiles(urls: [url], undoManager: nil)
        manager.updateCopies(for: try #require(manager.files.first).id, copies: 3, undoManager: nil)

        let out = dir.appendingPathComponent("out.pdf")
        var options = CombineOutputOptions()
        options.layout = .booklet
        manager.createCombinedPDF(to: out, options: options) { _, _, _ in }

        // Three foldable 4-page booklets (2 faces each), not one 12-page booklet (6 faces
        // — which would also be 6 pages, so check the outline too).
        let result = try #require(PDFDocument(url: out))
        #expect(result.pageCount == 6)
        #expect(result.outlineRoot?.numberOfChildren == 3)
    }

    /// The duplex compensation is for paper only. A saved or previewed booklet must read
    /// upright on screen, or it looks broken — so Create PDF never carries the rotation.
    @Test func savedOutputIsNotRotatedForDuplex() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reference = try #require(GreyReference(pageCount: 8))
        let src = dir.appendingPathComponent("Flute.pdf")
        #expect(reference.doc.write(to: src))

        let manager = CombineManager()
        manager.addFiles(urls: [src], undoManager: nil)
        var options = CombineOutputOptions()
        options.layout = .booklet
        options.duplexFlip = .longEdge          // the compensating setting, deliberately on

        let out = dir.appendingPathComponent("out.pdf")
        manager.createCombinedPDF(to: out, options: options) { _, _, _ in }
        let saved = try #require(PDFDocument(url: out))
        #expect(saved.pageCount == 4)

        // Face 1 is the back of the first sheet. Un-rotated, its halves sit in plain
        // imposition order; had the compensation leaked into Create PDF they'd be swapped.
        let order = bookletImpositionOrder(n: 8)
        let back = try #require(saved.page(at: 1))
        #expect(reference.identify(back, atFractionX: 0.25) == order[2])
        #expect(reference.identify(back, atFractionX: 0.75) == order[3])
    }

    @Test func singlePageLayoutIsUnchanged() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        for (name, pages) in [("Flute", 8), ("Clarinet", 5)] {
            writePDF(pages: pages, to: dir.appendingPathComponent("\(name).pdf"))
        }

        let manager = CombineManager()
        manager.addFiles(urls: ["Flute", "Clarinet"].map {
            dir.appendingPathComponent("\($0).pdf")
        }, undoManager: nil)

        let out = dir.appendingPathComponent("out.pdf")
        manager.createCombinedPDF(to: out, options: CombineOutputOptions()) { _, _, _ in }

        let result = try #require(PDFDocument(url: out))
        #expect(result.pageCount == 13)                      // no padding, no imposition
        #expect(result.outlineRoot?.numberOfChildren == 2)
    }
}

// MARK: - Content placement

/// A solid-grey page, so the page a half-sheet was drawn from can be identified afterwards
/// by sampling a pixel. `level` doubles as the page's identity.
private func greyPage(level: CGFloat, width: CGFloat = 200, height: CGFloat = 280) -> PDFPage? {
    guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue),
          let cg = { () -> CGImage? in
              ctx.setFillColor(gray: level, alpha: 1)
              ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
              return ctx.makeImage()
          }() else { return nil }

    let page = PDFPage(image: NSImage(cgImage: cg, size: NSSize(width: width, height: height)))
    let box = CGRect(x: 0, y: 0, width: width, height: height)
    page?.setBounds(box, for: .mediaBox)
    page?.setBounds(box, for: .cropBox)
    return page
}

/// The rendered grey level at `fractionX` across `page`, vertically centred.
private func measuredGrey(_ page: PDFPage, atFractionX fractionX: CGFloat) -> CGFloat? {
    let bounds = page.bounds(for: .mediaBox)
    let image = page.thumbnail(of: NSSize(width: bounds.width, height: bounds.height), for: .mediaBox)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let colour = rep.colorAt(x: min(Int(CGFloat(rep.pixelsWide) * fractionX), rep.pixelsWide - 1),
                                   y: rep.pixelsHigh / 2),
          let grey = colour.usingColorSpace(.deviceGray) else { return nil }
    return grey.whiteComponent
}

/// A document of solid-grey pages plus the grey each one actually renders as.
///
/// Rendering applies a gamma shift (a 0.3 fill comes back as ~0.375), so pages are
/// identified by matching against measured references rather than the levels they were
/// filled with — that stays correct whatever colour handling the OS applies.
private struct GreyReference {
    let doc: PDFDocument
    let levels: [CGFloat]

    init?(pageCount: Int) {
        let doc = PDFDocument()
        for i in 0..<pageCount {
            guard let page = greyPage(level: CGFloat(i) / 10) else { return nil }
            doc.insert(page, at: i)
        }
        var levels: [CGFloat] = []
        for i in 0..<pageCount {
            guard let page = doc.page(at: i),
                  let grey = measuredGrey(page, atFractionX: 0.5) else { return nil }
            levels.append(grey)
        }
        self.doc = doc
        self.levels = levels
    }

    /// Which source page a half-sheet was drawn from, or nil when the half is blank —
    /// padding renders white, far outside the tolerance around any real page.
    func identify(_ page: PDFPage, atFractionX fractionX: CGFloat) -> Int? {
        guard let value = measuredGrey(page, atFractionX: fractionX) else { return nil }
        let best = levels.enumerated().min { abs($0.element - value) < abs($1.element - value) }
        guard let best, abs(best.element - value) < 0.04 else { return nil }
        return best.offset
    }
}

@Suite("Booklet imposition — content placement")
struct BookletPlacementTests {

    /// The permutation is only useful if it reaches the paper. Eight identifiable pages are
    /// imposed and every half-sheet is read back, so a transposed pair or a mirrored sheet
    /// would fail here even though the page counts and sizes stayed right.
    @Test func eachHalfSheetCarriesTheExpectedPage() throws {
        let reference = try #require(GreyReference(pageCount: 8))

        let imposed = try #require(imposedBookletDocument(reference.doc, segments: [0..<8],
                                                          sheetSize: .doubleSize)).doc
        #expect(imposed.pageCount == 4)

        // Slots run [front-left, front-right, back-left, back-right] per sheet:
        // 1-based that reads 8,1 · 2,7 · 6,3 · 4,5 — the standard two-sheet saddle stitch.
        let expected = bookletImpositionOrder(n: 8)
        for face in 0..<imposed.pageCount {
            let sheet = try #require(imposed.page(at: face))
            #expect(reference.identify(sheet, atFractionX: 0.25) == expected[face * 2],
                    "left half of face \(face)")
            #expect(reference.identify(sheet, atFractionX: 0.75) == expected[face * 2 + 1],
                    "right half of face \(face)")
        }
    }

    /// Below 100% the page shrinks *about the centre of its half*, leaving an even margin.
    /// If it scaled about the page origin instead, the fold line would shift and the halves
    /// would stop being mirror images.
    @Test func scalingDownLeavesAnEvenMarginAroundEachHalf() throws {
        let reference = try #require(GreyReference(pageCount: 8))
        let imposed = try #require(imposedBookletDocument(reference.doc, segments: [0..<8],
                                                          sheetSize: .doubleSize,
                                                          pageScale: 0.8)).doc
        let sheet = try #require(imposed.page(at: 0))

        // At 80% the left half's page covers 0.05–0.45 of the sheet width, so the middle of
        // the half is still the page and both of its edges have become white.
        #expect(reference.identify(sheet, atFractionX: 0.25) == bookletImpositionOrder(n: 8)[0])
        #expect(reference.identify(sheet, atFractionX: 0.01) == nil, "outer edge should be blank")
        #expect(reference.identify(sheet, atFractionX: 0.47) == nil, "gutter edge should be blank")
    }

    /// Above 100% the page overflows its half and must be clipped at the fold — otherwise it
    /// would paint over the facing page.
    @Test func scalingUpIsClippedAtTheFold() throws {
        let reference = try #require(GreyReference(pageCount: 8))
        let imposed = try #require(imposedBookletDocument(reference.doc, segments: [0..<8],
                                                          sheetSize: .doubleSize,
                                                          pageScale: 1.2)).doc
        let sheet = try #require(imposed.page(at: 0))

        let order = bookletImpositionOrder(n: 8)
        // The right half is drawn second, so if it weren't clipped it would spill left of the
        // fold and cover the left half here. Seeing the left page just inside the fold proves
        // the clip is holding.
        #expect(reference.identify(sheet, atFractionX: 0.49) == order[0])
        #expect(reference.identify(sheet, atFractionX: 0.51) == order[1])
        // And it still fills its own half right out to the sheet edge.
        #expect(reference.identify(sheet, atFractionX: 0.01) == order[0])
    }

    /// A long-edge duplexer turns a landscape sheet upside down between sides, so the back
    /// faces are imposed rotated 180° to cancel it. Rotating a face swaps which half each page
    /// lands on, which is what this checks — fronts untouched, backs mirrored.
    @Test func backFacesAreRotatedForLongEdgeDuplex() throws {
        let reference = try #require(GreyReference(pageCount: 8))
        let order = bookletImpositionOrder(n: 8)

        let plain = try #require(imposedBookletDocument(reference.doc, segments: [0..<8],
                                                        sheetSize: .doubleSize)).doc
        let rotated = try #require(imposedBookletDocument(reference.doc, segments: [0..<8],
                                                          sheetSize: .doubleSize,
                                                          rotateBackFaces: true)).doc
        #expect(rotated.pageCount == plain.pageCount)

        for face in 0..<rotated.pageCount {
            let sheet = try #require(rotated.page(at: face))
            let left = reference.identify(sheet, atFractionX: 0.25)
            let right = reference.identify(sheet, atFractionX: 0.75)
            if face % 2 == 0 {
                // Front of a sheet — unchanged.
                #expect(left == order[face * 2], "front face \(face) left")
                #expect(right == order[face * 2 + 1], "front face \(face) right")
            } else {
                // Back of a sheet — rotated, so the halves trade places.
                #expect(left == order[face * 2 + 1], "back face \(face) left")
                #expect(right == order[face * 2], "back face \(face) right")
            }
        }
    }

    /// A 5-page part pads to 8, and the three padding slots must come out blank rather than
    /// wrapping around to real pages.
    @Test func paddingSlotsAreBlank() throws {
        let reference = try #require(GreyReference(pageCount: 5))

        let imposed = try #require(imposedBookletDocument(reference.doc, segments: [0..<5],
                                                          sheetSize: .doubleSize)).doc
        let order = bookletImpositionOrder(n: 8)
        var blanks = 0
        for face in 0..<imposed.pageCount {
            let sheet = try #require(imposed.page(at: face))
            for (half, fraction) in [(0, CGFloat(0.25)), (1, CGFloat(0.75))] {
                let readingPos = order[face * 2 + half]
                let found = reference.identify(sheet, atFractionX: fraction)
                if readingPos >= 5 {
                    #expect(found == nil, "reading position \(readingPos) should be blank")
                    blanks += 1
                } else {
                    #expect(found == readingPos)
                }
            }
        }
        #expect(blanks == 3)
    }
}
