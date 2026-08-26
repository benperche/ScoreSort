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

// MARK: - Duplex flip

/// Which way the printer turns the paper between sides.
///
/// This can't be chosen from code: the print panel resets duplex from the printer's own
/// preset the moment it appears, so a requested value is overwritten (measured — asking for
/// tumble yields no-tumble). What the app *can* do is lay the sheets out to suit, which is
/// what this setting drives.
enum BookletDuplexFlip: String, CaseIterable, Identifiable, Codable {
    /// The usual default, and what "Double-sided: On" normally means. The sheet turns about
    /// its long edge, which on a landscape booklet sheet lands the back upside down — so the
    /// back faces are rotated 180° when imposing, to cancel it out.
    case longEdge
    /// The sheet turns about its short edge, which needs no compensation.
    case shortEdge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .longEdge:  return "Long edge (usual)"
        case .shortEdge: return "Short edge"
        }
    }

    /// True when imposition has to rotate the back of each sheet to compensate.
    var rotatesBackFaces: Bool { self == .longEdge }
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

/// How one part's pages are arranged on its sheets.
///
/// Publishers design page turns, so the right answer differs part to part — sometimes within the
/// same print run. Both go through the same imposition; they differ only in the slot order, and
/// `.flat` is simply reading order, so this is a choice of *where the page turns fall* rather than
/// two separate algorithms.
enum BookletPartLayout: String, CaseIterable, Identifiable, Codable {
    /// Saddle stitch — sheets nest and the part is folded and stapled. 4|1, 2|3.
    case folded
    /// Reading order, two pages up, printed on both sides. 1|2, 3|4. The sheet is read open,
    /// turning the whole sheet rather than a page.
    case flat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .folded: return "Folded"
        case .flat:   return "Flat"
        }
    }

    /// Which pages end up facing each other, e.g. "1 · 2–3 · 4" — the thing a player actually
    /// judges, since it says where they'll have to turn.
    func spreadDescription(pageCount: Int) -> String {
        bookletSpreads(pageCount: pageCount, layout: self)
            .map { $0.count == 1 ? "\($0[0])" : "\($0[0])–\($0[$0.count - 1])" }
            .joined(separator: " · ")
    }
}

/// The pages visible at once, in order, as 1-based page numbers — so `[[1], [2, 3], [4]]` for a
/// folded four-page part. The gaps between these groups are exactly where the player turns.
///
/// Grouped over the *padded* length, since that's the booklet that physically exists — but any
/// trailing group that is entirely padding is dropped, because announcing a turn onto two blank
/// sides would be worse than saying nothing. A two-page part laid flat is "1–2", not "1–2 · 3–4".
func bookletSpreads(pageCount: Int, layout: BookletPartLayout) -> [[Int]] {
    let n = bookletPaddedCount(pageCount)
    guard n > 0 else { return [] }
    func trimmed(_ groups: [[Int]]) -> [[Int]] {
        var groups = groups
        while let last = groups.last, last.allSatisfy({ $0 > pageCount }) { groups.removeLast() }
        return groups
    }
    switch layout {
    case .folded:
        // A cover on its own, facing pairs through the middle, then the back on its own.
        var groups: [[Int]] = [[1]]
        var page = 2
        while page + 1 <= n - 1 { groups.append([page, page + 1]); page += 2 }
        if n > 1 { groups.append([n]) }
        return trimmed(groups)
    case .flat:
        return trimmed(stride(from: 1, through: n, by: 2).map { [$0, $0 + 1] })
    }
}

/// The layout to use when the user hasn't chosen one.
///
/// Two pages read best flat — side by side, no page turn at all — which is the one case where the
/// folded form is simply worse. Anything longer defaults to the folded booklet.
func bookletDefaultLayout(pageCount: Int) -> BookletPartLayout {
    pageCount == 2 ? .flat : .folded
}

/// `order[sheetSlot] = readingPos`, slots running [front-left, front-right, back-left,
/// back-right] per sheet. Reading positions past the end of the part are padding and are left
/// blank by the drawing step.
func bookletSlotOrder(pageCount: Int, layout: BookletPartLayout) -> [Int] {
    let n = bookletPaddedCount(pageCount)
    guard n > 0 else { return [] }
    switch layout {
    case .folded: return bookletImpositionOrder(n: n)
    case .flat:   return Array(0..<n)
    }
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
    // A flat spread is one sheet too, and bookletPaddedCount already rounds 2 up to 4, so this
    // needs no special case.
    segments.reduce(0) { $0 + bookletPaddedCount($1.count) / 4 }
}

// MARK: - Imposition

/// The range the page scale is clamped to. Published music rarely sits comfortably on A4,
/// so the useful range runs either side of a straight fit — under 100% for more air around
/// each page, over it to push the notes up a little.
let bookletPageScaleRange: ClosedRange<Double> = 0.5...1.5

/// Imposes `doc` as saddle-stitch booklets, one per segment, each padded with blanks to a
/// whole number of folded sheets. Returns the sheet document along with the sheet index
/// each booklet starts at, so the caller can rebuild an outline against the new pages.
///
/// `pageScale` sizes each page *within its half of the sheet*, about the half's centre, so
/// the fold stays put and the two halves stay symmetrical: 1.0 fits the half exactly, 1.03
/// draws the music 3% larger, 0.95 leaves more white space around it. Anything that spills
/// past the half is clipped, so it can never cross the fold into the facing page.
///
/// Like `stampedDocument(_:stamp:pageIndices:)`, this rebuilds page content through a
/// `CGPDFContext`, so annotations, links and outlines on the source pages are dropped —
/// callers that want an outline must build it on the returned document.
/// `layouts` is index-aligned with `segments`; anything missing falls back to
/// `bookletDefaultLayout(pageCount:)` for that segment's length.
func imposedBookletDocument(_ doc: PDFDocument,
                            segments: [Range<Int>],
                            sheetSize: BookletSheetSize,
                            pageScale: Double = 1.0,
                            rotateBackFaces: Bool = false,
                            layouts: [BookletPartLayout] = []) -> (doc: PDFDocument, sheetStarts: [Int])? {
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
    let scale = min(max(pageScale, bookletPageScaleRange.lowerBound),
                    bookletPageScaleRange.upperBound)

    for (segmentIndex, segment) in segments.enumerated() {
        // Appended for every segment, empty or not, so the returned array stays index-aligned
        // with `segments` and the caller's outline labels line up.
        sheetStarts.append(facesWritten)
        let padded = bookletPaddedCount(segment.count)
        let layout = segmentIndex < layouts.count
            ? layouts[segmentIndex]
            : bookletDefaultLayout(pageCount: segment.count)
        let order = bookletSlotOrder(pageCount: segment.count, layout: layout)
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
            // Faces alternate front, back, front, back — so every second one is the back of
            // a sheet, and that's the one a long-edge duplexer lands upside down.
            if rotateBackFaces && (slot / 2) % 2 == 1 {
                ctx.translateBy(x: sheetBox.midX, y: sheetBox.midY)
                ctx.rotate(by: .pi)
                ctx.translateBy(x: -sheetBox.midX, y: -sheetBox.midY)
            }
            draw(readingPos: order[slot],     of: segment, from: source, into: leftHalf,
                 scale: scale, in: ctx)
            draw(readingPos: order[slot + 1], of: segment, from: source, into: rightHalf,
                 scale: scale, in: ctx)
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
                  scale: Double,
                  in ctx: CGContext) {
    guard readingPos >= 0, readingPos < segment.count else { return }
    // CGPDFDocument pages are 1-based.
    guard let page = source.page(at: segment.lowerBound + readingPos + 1) else { return }

    ctx.saveGState()
    // Clipping happens in sheet coordinates, before the transforms below, so an oversized
    // page is trimmed at the half's edge and can never bleed across the fold.
    ctx.clip(to: half)
    // Applied before the fit transform, so it scales the *fitted* page about the centre of
    // its half rather than about the page's own origin — the fold line therefore doesn't move.
    if scale != 1.0 {
        ctx.translateBy(x: half.midX, y: half.midY)
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        ctx.translateBy(x: -half.midX, y: -half.midY)
    }
    // getDrawingTransform fits the page into `half` and accounts for its own /Rotate, so
    // it handles placement, scaling and rotation in one step — which is why both sheet
    // sizes share this code and only differ in how big `half` is.
    ctx.concatenate(page.getDrawingTransform(.cropBox, rect: half, rotate: 0,
                                             preserveAspectRatio: true))
    ctx.drawPDFPage(page)
    ctx.restoreGState()
}
