//
//  BookletLogic.swift
//  ScoreSort
//
//  Saddle-stitch booklet *imposition* — reading order in, printer sheet order out.
//  The mirror image of the deimposition in SplitLogic.swift, and the forward direction
//  the Combine tab needs so a whole band folder can be printed as foldable booklets in
//  one job.
//
//  Booklet printing is not a macOS feature and only some printer drivers expose it, so
//  the app does the imposition itself and prints an ordinary two-up PDF.
//  No view state; unit-tested directly.
//

import Foundation
import PDFKit

// MARK: - Sheet size

/// The paper each pair of reading pages lands on.
enum BookletSheetSize: String, CaseIterable, Identifiable, Codable {
    /// Two pages side by side at full size — A4 reading pages give A3 sheets.
    /// Needs an A3-capable printer, and gives a stand-sized booklet.
    case doubleSize
    /// Two pages scaled down onto A4 landscape, giving an A5 booklet.
    /// Prints on any printer, but the music ends up half-size.
    case fitA4Landscape

    var id: String { rawValue }

    var label: String {
        switch self {
        case .doubleSize:     return "Double size (A4 \u{2192} A3)"
        case .fitA4Landscape: return "Fit A4 landscape (A5 booklet)"
        }
    }

    /// Short form for the menu button's own title.
    var shortLabel: String {
        switch self {
        case .doubleSize:     return "A3"
        case .fitA4Landscape: return "A5"
        }
    }
}

// MARK: - Imposition order

/// Saddle-stitch imposition order: `order[sheetSlot] = readingPos`, where slots run
/// `[front-left, front-right, back-left, back-right]` for each sheet in turn.
/// Returns `[]` when `n < 4` or `n % 4 != 0`.
///
/// This is the exact inverse of `coverFirstFrontBackOrder(n:)` — that function maps a
/// scanned booklet back to reading order, and printing one is the same permutation run
/// the other way. Deriving it by inversion rather than restating the sheet geometry keeps
/// a single source of truth for the maths.
///
/// Verified (1-based, for readability): N=4 → 4,1,2,3   N=8 → 8,1,2,7,6,3,4,5
func bookletImpositionOrder(n: Int) -> [Int] {
    let deimposed = coverFirstFrontBackOrder(n: n)
    guard !deimposed.isEmpty else { return [] }
    var result = [Int](repeating: 0, count: n)
    for (readingPos, slot) in deimposed.enumerated() { result[slot] = readingPos }
    return result
}

/// Pages padded up to the next multiple of 4 — a saddle-stitch booklet always uses whole
/// folded sheets, so a 5-page part prints as 8 with three blanks at the back.
func bookletPaddedCount(_ pages: Int) -> Int {
    guard pages > 0 else { return 0 }
    return max(4, (pages + 3) / 4 * 4)
}

// MARK: - Segments

/// Reading-page ranges, one per booklet, derived from the first-page index of each part.
///
/// The first segment always starts at page 0 even when the first index doesn't, so pages
/// ahead of the first bookmarked part (a blank the user inserted at the top of the list)
/// are still printed rather than silently dropped. Indices that are out of range,
/// duplicated, or out of order are ignored.
func bookletSegments(pageCount: Int, partFirstPages: [Int]) -> [Range<Int>] {
    guard pageCount > 0 else { return [] }

    var starts: [Int] = [0]
    for index in partFirstPages.sorted() where index > 0 && index < pageCount {
        if index != starts.last { starts.append(index) }
    }

    return starts.indices.map { i in
        starts[i]..<(i + 1 < starts.count ? starts[i + 1] : pageCount)
    }
}

/// Physical sheets of paper the job will consume — each segment padded to a whole number
/// of folded sheets. Two sheet faces (four reading pages) per sheet of paper.
func bookletSheetCount(segments: [Range<Int>]) -> Int {
    segments.reduce(0) { $0 + bookletPaddedCount($1.count) / 4 }
}

// MARK: - Imposition

/// Imposes `doc` as saddle-stitch booklets, one per segment, each padded with blanks to a
/// whole number of folded sheets. Returns the sheet document along with the sheet index
/// each booklet starts at, so the caller can rebuild an outline against the new pages.
///
/// Like `stampedDocument(_:stamp:pageIndices:)`, this rebuilds page content through a
/// `CGPDFContext`, so annotations, links and outlines on the source pages are dropped —
/// callers that want an outline must build it on the returned document.
func imposedBookletDocument(_ doc: PDFDocument,
                            segments: [Range<Int>],
                            sheetSize: BookletSheetSize) -> (doc: PDFDocument, sheetStarts: [Int])? {
    guard doc.pageCount > 0, !segments.isEmpty else { return nil }
    guard let data = doc.dataRepresentation(),
          let provider = CGDataProvider(data: data as CFData),
          let source = CGPDFDocument(provider) else { return nil }

    let output = NSMutableData()
    guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return nil }
    // A4 placeholder; every sheet then declares its own media box in beginPage.
    var defaultBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let ctx = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else { return nil }

    var sheetStarts: [Int] = []
    var facesWritten = 0

    for segment in segments {
        // Appended for every segment, empty or not, so the returned array stays index-aligned
        // with `segments` and the caller's outline labels line up.
        sheetStarts.append(facesWritten)
        let padded = bookletPaddedCount(segment.count)
        let order = bookletImpositionOrder(n: padded)
        guard !order.isEmpty else { continue }

        // Sheet size follows the segment's first page, so a booklet of A4 parts gives A3
        // sheets and a booklet of A5 parts gives A4 ones.
        let firstPage = source.page(at: segment.lowerBound + 1)
        let sourceBox = firstPage.map(visualPageBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        var sheetBox: CGRect
        switch sheetSize {
        case .doubleSize:
            sheetBox = CGRect(x: 0, y: 0, width: sourceBox.width * 2, height: sourceBox.height)
        case .fitA4Landscape:
            sheetBox = CGRect(x: 0, y: 0, width: 842, height: 595)
        }
        let halfWidth = sheetBox.width / 2
        let leftHalf  = CGRect(x: 0,         y: 0, width: halfWidth, height: sheetBox.height)
        let rightHalf = CGRect(x: halfWidth, y: 0, width: halfWidth, height: sheetBox.height)

        // Slots run [front-left, front-right, back-left, back-right] per sheet, so each
        // pair of slots is one face of paper.
        for slot in stride(from: 0, to: padded, by: 2) {
            ctx.beginPage(mediaBox: &sheetBox)
            draw(readingPos: order[slot],     of: segment, from: source, into: leftHalf,  in: ctx)
            draw(readingPos: order[slot + 1], of: segment, from: source, into: rightHalf, in: ctx)
            ctx.endPage()
            facesWritten += 1
        }
    }

    ctx.closePDF()
    guard let result = PDFDocument(data: output as Data) else { return nil }
    return (result, sheetStarts)
}

/// Draws one reading position of `segment` into `half`. Positions past the end of the
/// segment are the booklet's padding and leave the half blank.
private func draw(readingPos: Int,
                  of segment: Range<Int>,
                  from source: CGPDFDocument,
                  into half: CGRect,
                  in ctx: CGContext) {
    guard readingPos < segment.count else { return }
    // CGPDFDocument pages are 1-based.
    guard let page = source.page(at: segment.lowerBound + readingPos + 1) else { return }

    ctx.saveGState()
    ctx.clip(to: half)
    // getDrawingTransform fits the page into `half` and accounts for its own /Rotate, so
    // it handles placement, scaling and rotation in one step — which is why both sheet
    // sizes share this code and only differ in how big `half` is.
    ctx.concatenate(page.getDrawingTransform(.cropBox, rect: half, rotate: 0,
                                             preserveAspectRatio: true))
    ctx.drawPDFPage(page)
    ctx.restoreGState()
}
