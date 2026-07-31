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

/// The nine quick positions offered as buttons. These are *presets* that set a stamp's
/// free `positionX`/`positionY` — the stamp itself stores the fractions, so it can also be
/// dragged anywhere in between on the preview.
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

    /// The fractional position this preset corresponds to (x: 0 = left, y: 0 = bottom).
    var position: (x: Double, y: Double) {
        switch self {
        case .topLeft:      return (0,   1)
        case .topCentre:    return (0.5, 1)
        case .topRight:     return (1,   1)
        case .middleLeft:   return (0,   0.5)
        case .centre:       return (0.5, 0.5)
        case .middleRight:  return (1,   0.5)
        case .bottomLeft:   return (0,   0)
        case .bottomCentre: return (0.5, 0)
        case .bottomRight:  return (1,   0)
        }
    }

    var label: String {
        switch self {
        case .topLeft:      return "Top left"
        case .topCentre:    return "Top centre"
        case .topRight:     return "Top right"
        case .middleLeft:   return "Middle left"
        case .centre:       return "Centre"
        case .middleRight:  return "Middle right"
        case .bottomLeft:   return "Bottom left"
        case .bottomCentre: return "Bottom centre"
        case .bottomRight:  return "Bottom right"
        }
    }
}

/// How the stamp's lines line up with each other inside its box. Only visible on a
/// multi-line stamp, and deliberately a stored choice rather than something derived from the
/// stamp's position — dragging a stamp around shouldn't re-flow its text.
enum StampTextAlignment: String, Codable, CaseIterable, Identifiable {
    case left, centre, right

    var id: String { rawValue }

    var nsAlignment: NSTextAlignment {
        switch self {
        case .left:   return .left
        case .centre: return .center
        case .right:  return .right
        }
    }

    var symbolName: String {
        switch self {
        case .left:   return "text.alignleft"
        case .centre: return "text.aligncenter"
        case .right:  return "text.alignright"
        }
    }

    var label: String {
        switch self {
        case .left:   return "Align left"
        case .centre: return "Align centre"
        case .right:  return "Align right"
        }
    }

    /// What the alignment used to be inferred from, kept for migrating stamps saved before
    /// this became an explicit control.
    static func derived(fromPositionX x: Double) -> StampTextAlignment {
        if x < 1.0 / 3 { return .left }
        if x > 2.0 / 3 { return .right }
        return .centre
    }
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
    /// The stamped text as plain characters. Newlines are honoured. Kept in sync with
    /// `richTextData` — used for labels, `isDrawable`, and as the fallback when there's no
    /// rich text yet.
    var text: String
    /// The stamped text as RTF, and the source of truth when present: bold, italic, font,
    /// size and colour can vary **run by run** inside one stamp. `nil` until the text has
    /// been edited in the rich editor, in which case the fields below supply the attributes
    /// for the whole string.
    var richTextData: Data?
    /// Free position inside the margin-inset area: 0 = hard left / bottom, 1 = hard right /
    /// top. Set by the nine preset buttons or by dragging the stamp on the preview. Stored
    /// as fractions of the *inset* area so a stamp keeps its margins on any page size and
    /// doesn't drift as the text length changes.
    var positionX: Double = 1
    var positionY: Double = 1
    /// Minimum gap between the stamp and the page edge, in points. Also bounds how far the
    /// stamp can be dragged.
    var margin: Double = 24
    // Base attributes: what the whole string looks like before any per-run formatting, and
    // what newly typed text inherits.
    var fontFamily: String = "Helvetica"
    var isBold: Bool = true
    var isItalic: Bool = false
    var fontSize: Double = 11
    var colourHex: String = "#000000"
    var hasBorder: Bool = true
    /// How multi-line text lines up inside the stamp's box.
    var alignment: StampTextAlignment = .centre

    /// Nothing to draw for an all-whitespace stamp.
    var isDrawable: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when the stamp sits on one of the nine presets, so the grid can show which
    /// button is active (and nothing after a free drag in between).
    func matches(_ anchor: StampAnchor) -> Bool {
        let p = anchor.position
        return abs(positionX - p.x) < 0.005 && abs(positionY - p.y) < 0.005
    }

    mutating func move(to anchor: StampAnchor) {
        let p = anchor.position
        positionX = p.x
        positionY = p.y
    }

    // Hand-written decoding so fields can be added over time without invalidating an
    // existing stamps.json: every key is optional, and the pre-drag `anchor` field is
    // migrated to the free position.
    private enum LegacyKeys: String, CodingKey { case anchor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decodeIfPresent(UUID.self,   forKey: .id) ?? UUID()
        name        = try c.decodeIfPresent(String.self, forKey: .name) ?? "Stamp"
        text          = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        richTextData  = try c.decodeIfPresent(Data.self,   forKey: .richTextData)
        margin        = try c.decodeIfPresent(Double.self, forKey: .margin) ?? 24
        fontFamily  = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? "Helvetica"
        isBold      = try c.decodeIfPresent(Bool.self,   forKey: .isBold) ?? true
        isItalic    = try c.decodeIfPresent(Bool.self,   forKey: .isItalic) ?? false
        fontSize    = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 11
        colourHex   = try c.decodeIfPresent(String.self, forKey: .colourHex) ?? "#000000"
        hasBorder   = try c.decodeIfPresent(Bool.self,   forKey: .hasBorder) ?? true

        if let x = try c.decodeIfPresent(Double.self, forKey: .positionX),
           let y = try c.decodeIfPresent(Double.self, forKey: .positionY) {
            positionX = x
            positionY = y
        } else if let legacy = try? decoder.container(keyedBy: LegacyKeys.self),
                  let raw = (try? legacy.decodeIfPresent(String.self, forKey: .anchor)) ?? nil,
                  let anchor = StampAnchor(rawValue: raw) {
            (positionX, positionY) = anchor.position
        } else {
            positionX = 1
            positionY = 1
        }

        // Stamps saved before alignment was a control inferred it from the position; keep
        // them looking the way they did.
        alignment = try c.decodeIfPresent(StampTextAlignment.self, forKey: .alignment)
            ?? .derived(fromPositionX: positionX)
    }

    init(id: UUID = UUID(), name: String, text: String, richTextData: Data? = nil,
         positionX: Double = 1, positionY: Double = 1, margin: Double = 24,
         fontFamily: String = "Helvetica", isBold: Bool = true, isItalic: Bool = false,
         fontSize: Double = 11, colourHex: String = "#000000", hasBorder: Bool = true,
         alignment: StampTextAlignment = .centre) {
        self.id = id
        self.name = name
        self.text = text
        self.richTextData = richTextData
        self.positionX = positionX
        self.positionY = positionY
        self.margin = margin
        self.fontFamily = fontFamily
        self.isBold = isBold
        self.isItalic = isItalic
        self.fontSize = fontSize
        self.colourHex = colourHex
        self.hasBorder = hasBorder
        self.alignment = alignment
    }

    /// Convenience for the presets and for tests.
    init(name: String, text: String, anchor: StampAnchor, margin: Double = 24,
         hasBorder: Bool = true) {
        self.init(name: name, text: text,
                  positionX: anchor.position.x, positionY: anchor.position.y,
                  margin: margin, hasBorder: hasBorder)
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
func stampFont(_ stamp: Stamp) -> NSFont {
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


/// The attributes newly typed (or unformatted) stamp text takes: the stamp's base font,
/// traits and colour.
func stampBaseAttributes(_ stamp: Stamp) -> [NSAttributedString.Key: Any] {
    [.font: stampFont(stamp), .foregroundColor: nsColor(fromHex: stamp.colourHex)]
}

/// Decodes the stamp's rich text, or nil when it has none yet.
func stampRichText(_ stamp: Stamp) -> NSAttributedString? {
    guard let data = stamp.richTextData,
          let rich = NSAttributedString(rtf: data, documentAttributes: nil),
          rich.length > 0 else { return nil }
    return rich
}

/// The string that actually gets drawn — the rich text when there is any, otherwise the
/// plain text in the stamp's base attributes.
///
/// The stamp's alignment is applied over the whole range here — *without* touching the
/// per-run font and colour attributes — rather than being carried in the RTF, so the control
/// stays authoritative whatever the editor happens to have stored.
func stampAttributedString(_ stamp: Stamp) -> NSAttributedString {
    let base = stampRichText(stamp)
        ?? NSAttributedString(string: stamp.text, attributes: stampBaseAttributes(stamp))

    let para = NSMutableParagraphStyle()
    para.alignment = stamp.alignment.nsAlignment
    para.lineBreakMode = .byWordWrapping

    let result = NSMutableAttributedString(attributedString: base)
    result.addAttribute(.paragraphStyle, value: para,
                        range: NSRange(location: 0, length: result.length))
    return result
}

/// Serialises an edited attributed string for storage in `stamps.json`.
func stampRTFData(from attributed: NSAttributedString) -> Data? {
    attributed.rtf(from: NSRange(location: 0, length: attributed.length),
                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
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

/// The size of the full stamp box: the laid-out text plus border padding.
func stampBoxSize(for stamp: Stamp, textSize: CGSize) -> CGSize {
    let padH = stamp.hasBorder ? stampPaddingH : 0
    let padV = stamp.hasBorder ? stampPaddingV : 0
    return CGSize(width: textSize.width + padH * 2, height: textSize.height + padV * 2)
}

/// The travel available to the stamp box inside `pageBox` once the margins and the box's
/// own size are taken out. Zero on an axis means the box fills that axis — it then simply
/// sits at the margin. Also the denominator when converting a drag into a position.
func stampTravel(for stamp: Stamp, boxSize: CGSize, in pageBox: CGRect) -> CGSize {
    let margin = CGFloat(stamp.margin)
    return CGSize(width:  max(0, pageBox.width  - margin * 2 - boxSize.width),
                  height: max(0, pageBox.height - margin * 2 - boxSize.height))
}

/// The stamp box placed inside `pageBox` at the stamp's fractional position. `pageBox` is
/// in PDF user space — y increases upwards, so `positionY == 1` is the top of the page.
func stampRect(for stamp: Stamp, textSize: CGSize, in pageBox: CGRect) -> CGRect {
    let size = stampBoxSize(for: stamp, textSize: textSize)
    let travel = stampTravel(for: stamp, boxSize: size, in: pageBox)
    let margin = CGFloat(stamp.margin)
    let fx = min(max(stamp.positionX, 0), 1)
    let fy = min(max(stamp.positionY, 0), 1)
    return CGRect(x: pageBox.minX + margin + travel.width  * fx,
                  y: pageBox.minY + margin + travel.height * fy,
                  width: size.width, height: size.height)
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

/// The page box the preview (and the drag maths on top of it) works in: the crop box
/// normalised to the origin and swapped for 90°/270° rotation, or A4 when there's no page.
func visualPageBox(for page: PDFPage?) -> CGRect {
    guard let page else { return CGRect(x: 0, y: 0, width: 595, height: 842) }   // A4
    var box = page.bounds(for: .cropBox)
    if box.isEmpty { box = page.bounds(for: .mediaBox) }
    var w = box.width, h = box.height
    if page.rotation % 180 != 0 { swap(&w, &h) }
    return CGRect(x: 0, y: 0, width: w, height: h)
}

/// Renders `page` (or a blank A4 sheet when nil) as a bitmap, **without** any stamp.
///
/// The designer draws the stamp as a separate live layer on top of this (see
/// `StampPreviewCanvas`): rendering a dense score page costs tens of milliseconds, so it's
/// cached per page while dragging redraws only the stamp.
func stampPagePreviewImage(page: PDFPage?, maxDimension: CGFloat = 1400) -> NSImage? {
    let pageBox = visualPageBox(for: page)
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

    guard let image = ctx.makeImage() else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))
}
