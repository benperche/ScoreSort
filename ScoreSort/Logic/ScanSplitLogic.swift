//
//  ScanSplitLogic.swift
//  ScoreSort
//
//  Splitting scanned double pages: deciding, scan by scan, whether a page holds one
//  page or two, where to cut it, and which pieces hold nothing worth keeping.
//
//  Built for overhead/book scanners, whose output is a mix of two-page spreads and
//  single pages, each cropped to its own size, with the cut rarely in the exact middle
//  and the black scanner bed often filling one side. (A flatbed A3 scan is the easy
//  case of the same thing: every page a spread, every cut in the middle.)
//
//  Detection works on a small greyscale render of each scan:
//    1. A wide band of black scanner bed down one side → cut at its edge.
//    2. Otherwise a scan wider than it is tall holds two pages → cut in the gutter:
//       the ink-free band between them, as near the middle as that band allows.
//  Each resulting piece that is almost all black, or has next to no ink, is a blank
//  (the bed, or an empty facing page) and is suggested for skipping.
//
//  The splitting itself only sets crop boxes, so the scan images are never re-encoded.
//  No view state; unit-tested directly. The analysis functions are `nonisolated` so the
//  sheet can run them for many pages at once off the main actor.
//

import Foundation
import CoreGraphics
import PDFKit

// MARK: - Model

/// How one scan becomes pages.
nonisolated enum ScanLayout: Equatable, Sendable {
    /// One page: leave it whole.
    case single
    /// Two pieces, cut at this fraction (0…1) of the width as the reader sees it,
    /// measured from the left.
    case split(at: Double)

    var pieceCount: Int {
        switch self {
        case .single: return 1
        case .split:  return 2
        }
    }

    /// The pieces' horizontal extents as fractions of the visual width, left to right.
    var pieceRanges: [ClosedRange<Double>] {
        switch self {
        case .single:          return [0...1]
        case .split(let f):    return [0...f, f...1]
        }
    }
}

/// Why a cut was placed where it was — shown to nobody, but kept for tests and tuning.
nonisolated enum CutReason: Equatable, Sendable { case none, gutter, scannerBed, leastInk, middle }

nonisolated struct ScanAnalysis: Equatable, Sendable {
    var layout: ScanLayout
    var reason: CutReason
}

/// A piece of a scan with nothing on it worth keeping.
nonisolated enum BlankKind: Equatable, Sendable {
    /// The scanner bed (or anything else almost entirely dark).
    case black
    /// Paper with next to no ink — an empty facing page.
    case white
}

// MARK: - Greyscale rendering

/// An 8-bit greyscale bitmap, row 0 at the top. 0 = black, 255 = white.
nonisolated struct GrayImage: Sendable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Greyscale copy of `image` at its own size.
    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 255, count: w * h)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, pixels: px)
    }
}

/// What's needed to render one page off the main actor: the Core Graphics page plus the
/// box and rotation PDFKit reports for it (a page PDFKit has re-cropped — an earlier split —
/// keeps its full-size Core Graphics page, so the crop has to be applied here).
nonisolated struct ScanRenderSource: @unchecked Sendable {
    let page: CGPDFPage
    let cropBox: CGRect
    /// Clockwise degrees, normalised to 0, 90, 180 or 270.
    let rotation: Int

    /// The page's size as the reader sees it (rotation applied).
    var visualSize: CGSize {
        rotation % 180 == 0 ? cropBox.size : CGSize(width: cropBox.height, height: cropBox.width)
    }
}

extension PDFPage {
    /// The page as a `ScanRenderSource`, or nil if PDFKit has no Core Graphics page for it
    /// (a page built in memory rather than read from a file).
    var scanRenderSource: ScanRenderSource? {
        guard let ref = pageRef else { return nil }
        return ScanRenderSource(page: ref,
                                cropBox: bounds(for: .cropBox),
                                rotation: ((rotation % 360) + 360) % 360)
    }
}

/// Renders the page upright, `width` pixels wide, in colour on white.
/// Safe to call for different pages on different threads at once — it touches only
/// Core Graphics, never PDFKit.
nonisolated func renderScan(_ source: ScanRenderSource, width: Int) -> CGImage? {
    let size = source.visualSize
    guard size.width > 0, size.height > 0, width > 0 else { return nil }
    let pxW = width
    let pxH = max(1, Int((CGFloat(width) * size.height / size.width).rounded()))
    guard let ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
    ctx.interpolationQuality = .medium

    let s = CGFloat(pxW) / size.width
    ctx.scaleBy(x: s, y: s)
    // PDF rotation is clockwise; turn the native page so it reads upright in `size`.
    switch source.rotation {
    case 90:  ctx.translateBy(x: 0, y: size.height);          ctx.rotate(by: -.pi / 2)
    case 180: ctx.translateBy(x: size.width, y: size.height); ctx.rotate(by: .pi)
    case 270: ctx.translateBy(x: size.width, y: 0);           ctx.rotate(by: .pi / 2)
    default:  break
    }
    let crop = source.cropBox
    ctx.translateBy(x: -crop.minX, y: -crop.minY)
    ctx.clip(to: crop)
    ctx.drawPDFPage(source.page)
    return ctx.makeImage()
}

/// `renderScan` for many pages at once, in parallel; `nil` where a page couldn't be rendered.
/// `width` gives each page's pixel width.
nonisolated func renderScans(_ sources: [ScanRenderSource], width: (ScanRenderSource) -> Int) -> [CGImage?] {
    final class Box: @unchecked Sendable {
        var images: [CGImage?]
        let lock = NSLock()
        init(count: Int) { images = Array(repeating: nil, count: count) }
    }
    let box = Box(count: sources.count)
    let widths = sources.map(width)
    DispatchQueue.concurrentPerform(iterations: sources.count) { i in
        let image = renderScan(sources[i], width: widths[i])
        box.lock.lock()
        box.images[i] = image
        box.lock.unlock()
    }
    return box.images
}

// MARK: - Column profile

nonisolated struct ColumnStat: Equatable, Sendable {
    /// Mean brightness, 0 (black) … 1 (white).
    var mean: Double
    /// Fraction of the column dark enough to be ink (or scanner bed).
    var ink: Double
}

/// Pixels darker than this count as ink.
private nonisolated let inkLevel: UInt8 = 140
/// A column is scanner bed when at least this much of it is dark. The bed is solid
/// (every pixel); dark cover artwork, the nearest thing on a real page, stays below ~0.95.
private nonisolated let bedColumnInk = 0.97
/// A piece is scanner bed when it's this dark on average and at least `bedPieceInk` of it is dark.
private nonisolated let bedBrightness = 0.35
private nonisolated let bedPieceInk = 0.9
/// A column is part of a gap between pages when no more than this much of it is ink —
/// a few specks of dust. A column through a line of music is well over 3%.
private nonisolated let gapInk = 0.012

/// Per-column statistics, ignoring the top and bottom 8% (where scanner edges, page
/// curl and shadows live).
nonisolated func columnProfile(_ img: GrayImage) -> [ColumnStat] {
    let y0 = img.height * 8 / 100
    let y1 = max(y0 + 1, img.height * 92 / 100)
    guard img.width > 0, y1 <= img.height else { return [] }
    let n = Double(y1 - y0)
    var result = [ColumnStat]()
    result.reserveCapacity(img.width)
    for x in 0..<img.width {
        var sum = 0, dark = 0
        for y in y0..<y1 {
            let v = img.pixels[y * img.width + x]
            sum += Int(v)
            if v < inkLevel { dark += 1 }
        }
        result.append(ColumnStat(mean: Double(sum) / n / 255, ink: Double(dark) / n))
    }
    return result
}

// MARK: - Finding the cut

/// Width of the band of scanner bed running in from one edge. A few stray light columns
/// (dust, a page corner poking over) don't end it.
nonisolated func scannerBedWidth(_ profile: [ColumnStat], fromLeft: Bool) -> Int {
    let n = profile.count
    let allowedMisses = max(2, n / 100)
    var width = 0, misses = 0
    for i in 0..<n {
        if profile[fromLeft ? i : n - 1 - i].ink >= bedColumnInk {
            width = i + 1
            misses = 0
        } else {
            misses += 1
            if misses > allowedMisses { break }
        }
    }
    return width
}

/// Decides whether a scan holds one page or two, and where to cut it.
/// - Parameters:
///   - profile: `columnProfile` of the scan.
///   - aspect: the scan's width ÷ height as the reader sees it.
nonisolated func analyseScan(profile: [ColumnStat], aspect: Double) -> ScanAnalysis {
    let n = profile.count
    guard n >= 20 else { return ScanAnalysis(layout: .single, reason: .none) }

    // 1. A wide band of scanner bed down one side: the page ends where it starts.
    let left = scannerBedWidth(profile, fromLeft: true)
    let right = scannerBedWidth(profile, fromLeft: false)
    let wideBand = Int(Double(n) * 0.12)
    if max(left, right) >= wideBand && left + right < n - wideBand {
        let cut = left >= right ? Double(left) : Double(n - right)
        return ScanAnalysis(layout: .split(at: cut / Double(n)), reason: .scannerBed)
    }

    // 2. Otherwise only a scan wider than it is tall holds two pages. (A single page is
    //    about 0.7 as wide as it is tall; a spread about 1.4.)
    guard aspect >= 1.0 else { return ScanAnalysis(layout: .single, reason: .none) }

    // The gutter should sit mid-way across the paper (thin bed edges left out), so only
    // look for it in the middle of the paper.
    let paperLo = left, paperHi = n - right
    let paperWidth = Double(paperHi - paperLo)
    let middle = Double(paperLo + paperHi) / 2
    let lo = paperLo + Int(paperWidth * 0.28)
    let hi = paperLo + Int(paperWidth * 0.72)
    guard hi > lo else { return ScanAnalysis(layout: .split(at: middle / Double(n)), reason: .middle) }

    // Ink per column, smoothed over five columns so a one- or two-column dark line — the
    // fold's shadow, a sheet's edge — doesn't break up the gap around it.
    let ink = profile.map(\.ink)
    func smoothedInk(_ i: Int) -> Double {
        let window = ink[max(0, i - 2)...min(n - 1, i + 2)].sorted()
        return window[window.count / 2]
    }

    // Runs of ink-free columns: the margins of the two pages, meeting at the gutter.
    let smoothed = (lo..<hi).map(smoothedInk)
    var gaps: [Range<Int>] = []
    var start: Int? = nil
    for i in lo..<hi {
        if smoothed[i - lo] <= gapInk {
            if start == nil { start = i }
        } else if let s = start {
            gaps.append(s..<i)
            start = nil
        }
    }
    if let s = start { gaps.append(s..<hi) }
    gaps = gaps.filter { $0.count >= max(2, n / 100) }

    guard !gaps.isEmpty else {
        // Music running right into the fold: cut through the least ink near the middle.
        let reach = max(1, n / 100)
        func cost(_ i: Int) -> Double {
            let window = smoothed[max(0, i - reach)...min(smoothed.count - 1, i + reach)]
            let ink = window.reduce(0, +) / Double(window.count)
            return ink + abs(Double(lo + i) - middle) / Double(n) * 0.1
        }
        guard let best = smoothed.indices.min(by: { cost($0) < cost($1) }) else {
            return ScanAnalysis(layout: .split(at: middle / Double(n)), reason: .middle)
        }
        return ScanAnalysis(layout: .split(at: Double(lo + best) / Double(n)), reason: .leastInk)
    }
    // The widest gap wins, with a penalty for being off-centre.
    func score(_ gap: Range<Int>) -> Double {
        let centre = Double(gap.lowerBound + gap.upperBound) / 2
        return Double(gap.count) - abs(centre - middle) * 0.5
    }
    let best = gaps.max { score($0) < score($1) }!
    // Cut as near the middle as that gap allows, but keep clear of the music either side.
    let margin = min(Double(best.count) / 2, Double(n) * 0.02)
    let cut = min(max(middle, Double(best.lowerBound) + margin), Double(best.upperBound) - margin)
    return ScanAnalysis(layout: .split(at: cut / Double(n)), reason: .gutter)
}

// MARK: - Blank pieces

/// Whether columns `x0..<x1` of `img` hold nothing worth keeping. The outer 6% of the
/// piece is ignored, where page edges and shadows are.
nonisolated func blankKind(_ img: GrayImage, x0: Int, x1: Int) -> BlankKind? {
    let x0 = max(0, x0), x1 = min(img.width, x1)
    let w = x1 - x0
    // A sliver isn't a page — nothing to keep.
    guard w > max(4, img.width / 25) else { return .white }
    let ix0 = x0 + w * 6 / 100, ix1 = x1 - w * 6 / 100
    let iy0 = img.height * 6 / 100, iy1 = img.height * 94 / 100
    guard ix1 > ix0, iy1 > iy0 else { return .white }
    var sum = 0, dark = 0
    for y in iy0..<iy1 {
        let row = y * img.width
        for x in ix0..<ix1 {
            let v = img.pixels[row + x]
            sum += Int(v)
            if v < inkLevel { dark += 1 }
        }
    }
    let count = Double((ix1 - ix0) * (iy1 - iy0))
    if Double(sum) / count / 255 < bedBrightness && Double(dark) / count >= bedPieceInk { return .black }
    // A few specks of dust or a stray pencil mark are still an empty page; a line of
    // music is several times this.
    if Double(dark) / count < 0.0015 { return .white }
    return nil
}

/// `blankKind` for each piece of `layout`, left to right.
nonisolated func blankPieces(_ img: GrayImage, layout: ScanLayout) -> [BlankKind?] {
    layout.pieceRanges.map { range in
        blankKind(img,
                  x0: Int((range.lowerBound * Double(img.width)).rounded()),
                  x1: Int((range.upperBound * Double(img.width)).rounded()))
    }
}

// MARK: - Which documents to offer this for

/// True when a document looks like it came off a scanner as double pages: a good share of
/// its pages are wider than tall, and the pages aren't all one size (an overhead scanner
/// crops every scan to the book in front of it; a flatbed A3 scan is caught by
/// `isA3Landscape` instead). Bounds only, so it's cheap enough to run on every load.
func looksLikeDoublePageScan(_ doc: PDFDocument) -> Bool {
    guard doc.pageCount >= 2 else { return false }
    var wide = 0
    var sizes = Set<String>()
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i) else { continue }
        let b = page.bounds(for: .cropBox)
        var w = b.width, h = b.height
        if page.rotation % 180 != 0 { swap(&w, &h) }
        guard h > 0 else { continue }
        if w / h >= 1.2 { wide += 1 }
        sizes.insert("\(Int(w.rounded()))x\(Int(h.rounded()))")
    }
    return sizes.count > 1 && wide * 4 >= doc.pageCount
}

/// True when every page is the same landscape sheet — a flatbed scan of A3 (or any
/// uniform two-up) sheets, where one cut in the same place on every page is what's
/// wanted, rather than hunting for each scan's gutter. Sizes may differ by a point or two.
func isUniformSheetScan(_ doc: PDFDocument) -> Bool {
    guard doc.pageCount > 0 else { return false }
    var first: CGSize? = nil
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i) else { return false }
        let b = page.bounds(for: .cropBox)
        let size = page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
        guard size.height > 0, size.width / size.height >= 1.2 else { return false }
        if let first {
            if abs(size.width - first.width) > 2 || abs(size.height - first.height) > 2 { return false }
        } else {
            first = size
        }
    }
    return true
}

// MARK: - Splitting

/// The page index each piece will have in the split document, scan by scan, with each
/// scan's pieces listed left to right. With `leftFirst` false a split scan's right piece
/// comes first.
nonisolated func scanPieceOutputIndices(layouts: [ScanLayout], leftFirst: Bool) -> [[Int]] {
    var next = 0
    return layouts.map { layout in
        switch layout {
        case .single:
            defer { next += 1 }
            return [next]
        case .split:
            defer { next += 2 }
            return leftFirst ? [next, next + 1] : [next + 1, next]
        }
    }
}

/// The two pieces of `page` when cut at `fraction` of its visual width (from the visual
/// left), in reading order. Only crop and media boxes change — the content is untouched.
///
/// The box is in native (unrotated) coordinates, so the cut has to go along whichever
/// native axis is horizontal on screen. PDF rotation is clockwise:
///   0°   → cut on native X; visual left = native left.
///   90°  → cut on native Y; visual left = native bottom.
///   180° → cut on native X; visual left = native right.
///   270° → cut on native Y; visual left = native top.
func splitPage(_ page: PDFPage, at fraction: Double, leftFirst: Bool) -> [PDFPage] {
    let box = page.bounds(for: .cropBox)
    let rot = ((page.rotation % 360) + 360) % 360
    let f = CGFloat(min(max(fraction, 0), 1))

    let visualLeft: CGRect
    let visualRight: CGRect
    switch rot {
    case 90:
        let cut = box.minY + f * box.height
        visualLeft  = CGRect(x: box.minX, y: box.minY, width: box.width, height: cut - box.minY)
        visualRight = CGRect(x: box.minX, y: cut,      width: box.width, height: box.maxY - cut)
    case 270:
        let cut = box.maxY - f * box.height
        visualLeft  = CGRect(x: box.minX, y: cut,      width: box.width, height: box.maxY - cut)
        visualRight = CGRect(x: box.minX, y: box.minY, width: box.width, height: cut - box.minY)
    case 180:
        let cut = box.maxX - f * box.width
        visualLeft  = CGRect(x: cut,      y: box.minY, width: box.maxX - cut, height: box.height)
        visualRight = CGRect(x: box.minX, y: box.minY, width: cut - box.minX, height: box.height)
    default:
        let cut = box.minX + f * box.width
        visualLeft  = CGRect(x: box.minX, y: box.minY, width: cut - box.minX, height: box.height)
        visualRight = CGRect(x: cut,      y: box.minY, width: box.maxX - cut, height: box.height)
    }

    let ordered = leftFirst ? [visualLeft, visualRight] : [visualRight, visualLeft]
    return ordered.compactMap { rect in
        guard let piece = page.copy() as? PDFPage else { return nil }
        piece.setBounds(rect, for: .mediaBox)
        piece.setBounds(rect, for: .cropBox)
        return piece
    }
}

/// A new document with each page of `doc` kept whole or cut in two per `layouts`
/// (index-aligned; pages beyond `layouts` are kept whole).
func splitScans(_ doc: PDFDocument, layouts: [ScanLayout], leftFirst: Bool) -> PDFDocument {
    let result = PDFDocument()
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i) else { continue }
        let layout = i < layouts.count ? layouts[i] : .single
        switch layout {
        case .single:
            if let copy = page.copy() as? PDFPage { result.insert(copy, at: result.pageCount) }
        case .split(let f):
            for piece in splitPage(page, at: f, leftFirst: leftFirst) {
                result.insert(piece, at: result.pageCount)
            }
        }
    }
    return result
}
