//
//  StampLogic.swift
//  ScoreSort
//
//  The stamp model plus the drawing and flattening logic behind it — a small text
//  overlay ("Example School Band", "Property of XYZ") burned onto pages the way a
//  physical rubber stamp would be.
//
//  One drawing routine (`drawStamp`) is shared by the PDF flattener and the live
//  preview, so what the designer shows and what gets written can never diverge.
//  No view state; unit-tested directly.
//

import Foundation
import AppKit
import PDFKit
import CoreText

// MARK: - Model

/// Where on the page the stamp sits — a 3×3 grid of anchors.
enum StampAnchor: String, Codable, CaseIterable, Identifiable {
    case topLeft, topCentre, topRight
    case middleLeft, centre, middleRight
    case bottomLeft, bottomCentre, bottomRight

    var id: String { rawValue }

    /// Rows top→bottom, each left→centre→right. Used to lay out the picker grid.
    static let grid: [[StampAnchor]] = [
        [.topLeft, .topCentre, .topRight],
        [.middleLeft, .centre, .middleRight],
        [.bottomLeft, .bottomCentre, .bottomRight]
    ]
}

/// Which pages of a document get stamped. Chosen **per job**, not saved on the stamp — the
/// same design is often wanted on every page of one document and only the first page of
/// the next.
enum StampScope: String, Codable, CaseIterable, Identifiable {
    /// Every page of the output.
    case everyPage
    /// Only the first page of each sub-document — each source file in a combined PDF,
    /// or each output file of a split.
    case firstPageOfEachPart

    var id: String { rawValue }

    var label: String {
        switch self {
        case .everyPage:           return "Every page"
        case .firstPageOfEachPart: return "First page of each part"
        }
    }
}

/// A saved stamp design. Extra appearance options (opacity, rotation) can be added
/// later as new defaulted fields without breaking existing `stamps.json` files.
struct Stamp: Identifiable, Codable, Equatable {
    var id = UUID()
    /// Preset name shown in the picker (not drawn on the page).
    var name: String
    /// The stamped text. Newlines are honoured.
    var text: String
    var anchor: StampAnchor = .topRight
    /// Distance from the page edge, in points.
    var margin: Double = 24
    var fontFamily: String = "Helvetica"
    var isBold: Bool = true
    var isItalic: Bool = false
    var fontSize: Double = 11
    var colourHex: String = "#000000"
    var hasBorder: Bool = true

    /// Nothing to draw for an all-whitespace stamp.
    var isDrawable: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One stamping request: a design plus the pages it should land on. Bundling the two keeps
/// the export APIs to a single optional parameter — nil means "don't stamp".
struct StampJob {
    let stamp: Stamp
    let scope: StampScope

    /// A job is worth running only if there's actually something to draw.
    var isDrawable: Bool { stamp.isDrawable }

    /// The pages to stamp in a document of `pageCount` pages. `partFirstPages` is the page
    /// index each part starts at — ignored for `.everyPage`.
    func pageIndices(pageCount: Int, partFirstPages: [Int]) -> Set<Int> {
        switch scope {
        case .everyPage:
            return Set(0..<pageCount)
        case .firstPageOfEachPart:
            return Set(partFirstPages.filter { $0 >= 0 && $0 < pageCount })
        }
    }
}

/// Inset between the text and the border box, when a border is drawn.
let stampPaddingH: CGFloat = 7
let stampPaddingV: CGFloat = 4

// MARK: - Colour helpers

/// Parses "#RRGGBB" (or "RRGGBB"). Falls back to black on anything unparseable.
func nsColor(fromHex hex: String) -> NSColor {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let value = UInt32(s, radix: 16) else { return .black }
    return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                   green:   CGFloat((value >> 8) & 0xFF) / 255,
                   blue:    CGFloat(value & 0xFF) / 255,
                   alpha: 1)
}

/// Serialises a colour as "#RRGGBB" for storage in `stamps.json`.
func hexString(from color: NSColor) -> String {
    let rgb = color.usingColorSpace(.sRGB) ?? .black
    let r = Int((rgb.redComponent   * 255).rounded())
    let g = Int((rgb.greenComponent * 255).rounded())
    let b = Int((rgb.blueComponent  * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
}

// MARK: - Text layout

/// Resolves the stamp's font family + traits, falling back to the system font when the
/// family isn't available (e.g. a stamp designed on another Mac).
private func stampFont(_ stamp: Stamp) -> NSFont {
    let size = CGFloat(stamp.fontSize)
    var traits: NSFontTraitMask = []
    if stamp.isBold { traits.insert(.boldFontMask) }
    if stamp.isItalic { traits.insert(.italicFontMask) }
    if let font = NSFontManager.shared.font(withFamily: stamp.fontFamily,
                                           traits: traits,
                                           weight: stamp.isBold ? 9 : 5,
                                           size: size) {
        return font
    }
    return NSFont.systemFont(ofSize: size, weight: stamp.isBold ? .bold : .regular)
}

/// Multi-line stamps align towards their anchor, so a right-anchored two-line stamp
/// reads as a right-aligned block rather than a ragged one.
private func stampAlignment(_ anchor: StampAnchor) -> NSTextAlignment {
    switch anchor {
    case .topLeft, .middleLeft, .bottomLeft:       return .left
    case .topCentre, .centre, .bottomCentre:       return .center
    case .topRight, .middleRight, .bottomRight:    return .right
    }
}

func stampAttributedString(_ stamp: Stamp) -> NSAttributedString {
    let para = NSMutableParagraphStyle()
    para.alignment = stampAlignment(stamp.anchor)
    para.lineBreakMode = .byWordWrapping
    return NSAttributedString(string: stamp.text, attributes: [
        .font: stampFont(stamp),
        .foregroundColor: nsColor(fromHex: stamp.colourHex),
        .paragraphStyle: para
    ])
}

/// The laid-out size of the stamp's text, wrapped to fit inside the page's margins.
func stampTextSize(_ stamp: Stamp, in pageBox: CGRect) -> CGSize {
    let attr = stampAttributedString(stamp)
    guard attr.length > 0 else { return .zero }
    let padH = stamp.hasBorder ? stampPaddingH : 0
    let maxWidth = max(1, pageBox.width - CGFloat(stamp.margin) * 2 - padH * 2)
    let framesetter = CTFramesetterCreateWithAttributedString(attr)
    let size = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter, CFRangeMake(0, 0), nil,
        CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
    return CGSize(width: ceil(size.width), height: ceil(size.height))
}

// MARK: - Placement

/// The full stamp box (text plus border padding) placed against `pageBox` according to
/// the anchor and margin. `pageBox` is in PDF user space — y increases upwards, so the
/// "top" anchors sit at `maxY`.
func stampRect(for stamp: Stamp, textSize: CGSize, in pageBox: CGRect) -> CGRect {
    let padH = stamp.hasBorder ? stampPaddingH : 0
    let padV = stamp.hasBorder ? stampPaddingV : 0
    let width  = textSize.width  + padH * 2
    let height = textSize.height + padV * 2
    let margin = CGFloat(stamp.margin)

    let x: CGFloat
    switch stamp.anchor {
    case .topLeft, .middleLeft, .bottomLeft:
        x = pageBox.minX + margin
    case .topCentre, .centre, .bottomCentre:
        x = pageBox.midX - width / 2
    case .topRight, .middleRight, .bottomRight:
        x = pageBox.maxX - margin - width
    }

    let y: CGFloat
    switch stamp.anchor {
    case .topLeft, .topCentre, .topRight:
        y = pageBox.maxY - margin - height
    case .middleLeft, .centre, .middleRight:
        y = pageBox.midY - height / 2
    case .bottomLeft, .bottomCentre, .bottomRight:
        y = pageBox.minY + margin
    }

    return CGRect(x: x, y: y, width: width, height: height)
}

// MARK: - Drawing

/// Draws the stamp into `ctx`, positioned within `pageBox` (PDF user space, y up).
/// Shared by the PDF flattener and the designer's live preview.
func drawStamp(_ stamp: Stamp, in ctx: CGContext, pageBox: CGRect) {
    guard stamp.isDrawable else { return }
    let attr = stampAttributedString(stamp)
    let textSize = stampTextSize(stamp, in: pageBox)
    guard textSize.width > 0, textSize.height > 0 else { return }

    let box = stampRect(for: stamp, textSize: textSize, in: pageBox)
    ctx.saveGState()

    if stamp.hasBorder {
        let lineWidth = max(0.75, CGFloat(stamp.fontSize) / 12)
        let borderRect = box.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        ctx.setStrokeColor(nsColor(fromHex: stamp.colourHex).cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.addPath(CGPath(roundedRect: borderRect, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.strokePath()
    }

    let textRect = stamp.hasBorder ? box.insetBy(dx: stampPaddingH, dy: stampPaddingV) : box
    let framesetter = CTFramesetterCreateWithAttributedString(attr)
    let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0),
                                         CGPath(rect: textRect, transform: nil), nil)
    ctx.textMatrix = .identity
    CTFrameDraw(frame, ctx)

    ctx.restoreGState()
}

// MARK: - Flattening

/// The page's visual box, normalised to the origin: the crop box, with width and height
/// swapped when the page carries a 90°/270° rotation flag.
///
/// The *crop* box (not the media box) is deliberate — `splitA3Pages` sets both boxes to
/// one half of an A3 sheet, and using the media box alone would resurrect the half the
/// user discarded.
func visualPageBox(_ page: CGPDFPage) -> CGRect {
    var box = page.getBoxRect(.cropBox)
    if box.isEmpty { box = page.getBoxRect(.mediaBox) }
    var w = box.width, h = box.height
    if page.rotationAngle % 180 != 0 { swap(&w, &h) }
    return CGRect(x: 0, y: 0, width: w, height: h)
}

/// Returns a copy of `doc` with the stamp burned into the content of the pages in
/// `pageIndices` (0-based). Pages not listed are copied through unchanged.
///
/// The stamp becomes part of the page, so it prints identically everywhere and can't be
/// selected or deleted in a viewer. Two consequences worth knowing:
///   • page content is rebuilt, so annotations and links on the source pages are dropped;
///   • outlines/bookmarks do not survive — callers that want them must build the
///     `PDFOutline` on the *returned* document (page indices are unchanged).
func stampedDocument(_ doc: PDFDocument, stamp: Stamp, pageIndices: Set<Int>) -> PDFDocument? {
    guard doc.pageCount > 0, stamp.isDrawable else { return nil }
    guard let data = doc.dataRepresentation(),
          let provider = CGDataProvider(data: data as CFData),
          let source = CGPDFDocument(provider) else { return nil }

    let output = NSMutableData()
    guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return nil }
    // A4 placeholder; every page then declares its own media box in beginPage.
    var defaultBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let ctx = CGContext(consumer: consumer, mediaBox: &defaultBox, nil) else { return nil }

    for index in 0..<source.numberOfPages {
        guard let page = source.page(at: index + 1) else { continue }
        var box = visualPageBox(page)
        guard !box.isEmpty else { continue }

        ctx.beginPage(mediaBox: &box)
        ctx.saveGState()
        ctx.clip(to: box)
        // getDrawingTransform accounts for the page's own /Rotate, so everything below
        // is positioned in *visual* coordinates — where the user actually sees it.
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0,
                                                 preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        ctx.restoreGState()

        if pageIndices.contains(index) {
            drawStamp(stamp, in: ctx, pageBox: box)
        }
        ctx.endPage()
    }

    ctx.closePDF()
    return PDFDocument(data: output as Data)
}

/// Applies `job` to `doc`, or returns `doc` unchanged when there's nothing to stamp or the
/// flatten fails — so callers can use it inline without losing the document.
func applyingStamp(_ job: StampJob?, to doc: PDFDocument, partFirstPages: [Int]) -> PDFDocument {
    guard let job, job.isDrawable else { return doc }
    let indices = job.pageIndices(pageCount: doc.pageCount, partFirstPages: partFirstPages)
    return stampedDocument(doc, stamp: job.stamp, pageIndices: indices) ?? doc
}

// MARK: - Preview

/// Renders `page` (or a blank A4 sheet when nil) with the stamp applied, for the designer's
/// live preview. Uses the same `drawStamp` as the flattener, so the preview is faithful.
func stampPreviewImage(_ stamp: Stamp, page: PDFPage?, maxDimension: CGFloat = 460) -> NSImage? {
    let pageBox: CGRect
    if let page {
        var box = page.bounds(for: .cropBox)
        if box.isEmpty { box = page.bounds(for: .mediaBox) }
        var w = box.width, h = box.height
        if page.rotation % 180 != 0 { swap(&w, &h) }
        pageBox = CGRect(x: 0, y: 0, width: w, height: h)
    } else {
        pageBox = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4
    }
    guard pageBox.width > 0, pageBox.height > 0 else { return nil }

    let scale = maxDimension / max(pageBox.width, pageBox.height)
    let pixelWidth  = Int(ceil(pageBox.width * scale))
    let pixelHeight = Int(ceil(pageBox.height * scale))
    guard pixelWidth > 0, pixelHeight > 0,
          let ctx = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }

    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
    ctx.scaleBy(x: scale, y: scale)

    // A PDFKit-synthesised page (blank page, image page) has no pageRef — the preview then
    // just shows the stamp on a blank sheet, which is all it can honestly show.
    if let ref = page?.pageRef {
        ctx.saveGState()
        ctx.clip(to: pageBox)
        ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: pageBox, rotate: 0,
                                                preserveAspectRatio: true))
        ctx.drawPDFPage(ref)
        ctx.restoreGState()
    }

    drawStamp(stamp, in: ctx, pageBox: pageBox)

    guard let image = ctx.makeImage() else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
}
