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
                       border: Bool = true) -> Stamp {
    Stamp(name: "Test", text: "Example School Band",
          anchor: anchor, margin: margin, hasBorder: border)
}

private func testJob(_ scope: StampScope) -> StampJob {
    StampJob(stamp: testStamp(), scope: scope)
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

// MARK: - Free positioning (drag)

@Suite("Stamp free positioning")
struct StampFreePositionTests {

    private let pageBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    private let textSize = CGSize(width: 120, height: 14)

    @Test("a mid-page fraction lands proportionally along the available travel")
    func fractionMapsToTravel() {
        var stamp = testStamp(margin: 20)
        stamp.positionX = 0.25
        stamp.positionY = 0.75
        let box = stampBoxSize(for: stamp, textSize: textSize)
        let travel = stampTravel(for: stamp, boxSize: box, in: pageBox)
        let rect = stampRect(for: stamp, textSize: textSize, in: pageBox)
        #expect(abs(rect.minX - (20 + travel.width * 0.25)) < 0.01)
        #expect(abs(rect.minY - (20 + travel.height * 0.75)) < 0.01)
    }

    @Test("fractions outside 0…1 are clamped onto the page")
    func clampsOutOfRangeFractions() {
        var stamp = testStamp(margin: 20)
        stamp.positionX = 4
        stamp.positionY = -2
        let rect = stampRect(for: stamp, textSize: textSize, in: pageBox)
        #expect(pageBox.contains(rect))
        #expect(abs(rect.maxX - (pageBox.maxX - 20)) < 0.01)
        #expect(abs(rect.minY - (pageBox.minY + 20)) < 0.01)
    }

    @Test("margin bounds the travel, so it also bounds a drag")
    func marginBoundsTravel() {
        let box = stampBoxSize(for: testStamp(), textSize: textSize)
        let tight = stampTravel(for: testStamp(margin: 100), boxSize: box, in: pageBox)
        let loose = stampTravel(for: testStamp(margin: 10), boxSize: box, in: pageBox)
        #expect(tight.width < loose.width)
        #expect(tight.height < loose.height)
    }

    @Test("a stamp wider than the page still starts at the margin rather than off-page")
    func oversizedStampHasNoTravel() {
        let huge = CGSize(width: 2000, height: 14)
        let stamp = testStamp(margin: 20)
        let travel = stampTravel(for: stamp, boxSize: stampBoxSize(for: stamp, textSize: huge), in: pageBox)
        #expect(travel.width == 0)
        let rect = stampRect(for: stamp, textSize: huge, in: pageBox)
        #expect(abs(rect.minX - 20) < 0.01)
    }

    @Test("presets round-trip through move(to:) and matches(_:)")
    func presetsRoundTrip() {
        for anchor in StampAnchor.allCases {
            var stamp = testStamp()
            stamp.move(to: anchor)
            #expect(stamp.matches(anchor))
            // Only that one preset should report a match (each has a distinct position).
            let others = StampAnchor.allCases.filter { $0 != anchor && stamp.matches($0) }
            #expect(others.isEmpty)
        }
    }

    @Test("a dragged stamp matches no preset")
    func draggedStampMatchesNoPreset() {
        var stamp = testStamp()
        stamp.positionX = 0.42
        stamp.positionY = 0.17
        #expect(StampAnchor.allCases.allSatisfy { !stamp.matches($0) })
    }
}

// MARK: - Persistence

@Suite("Stamp coding")
struct StampCodingTests {

    @Test("a stamp survives an encode / decode round trip")
    func roundTrip() throws {
        var stamp = testStamp(margin: 18)
        stamp.positionX = 0.3
        stamp.positionY = 0.6
        stamp.text = "Two\nLines"
        stamp.colourHex = "#123456"
        stamp.fontSize = 16

        let data = try JSONEncoder().encode(stamp)
        let decoded = try JSONDecoder().decode(Stamp.self, from: data)
        #expect(decoded == stamp)
    }

    @Test("a pre-drag stamp with an anchor migrates to the matching position")
    func migratesLegacyAnchor() throws {
        // Shape written by the first stamping build: an `anchor` string, no positions,
        // and a `scope` field that has since moved to StampJob.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","text":"Example School Band",
         "anchor":"bottomLeft","margin":30,"fontFamily":"Helvetica","isBold":true,
         "isItalic":false,"fontSize":12,"colourHex":"#000000","hasBorder":true,
         "scope":"everyPage"}
        """
        let decoded = try JSONDecoder().decode(Stamp.self, from: Data(json.utf8))
        #expect(decoded.matches(.bottomLeft))
        #expect(decoded.margin == 30)
        #expect(decoded.name == "Old")
    }

    @Test("missing fields fall back to defaults rather than failing to decode")
    func toleratesMissingFields() throws {
        let decoded = try JSONDecoder().decode(Stamp.self, from: Data(#"{"text":"Hi"}"#.utf8))
        #expect(decoded.text == "Hi")
        #expect(decoded.margin == 24)
        #expect(decoded.fontFamily == "Helvetica")
        #expect(decoded.matches(.topRight))   // default position
    }
}

// MARK: - Scope

@Suite("Stamp scope")
struct StampScopeTests {

    @Test("every-page scope covers the whole document")
    func everyPage() {
        let indices = testJob(.everyPage).pageIndices(pageCount: 5, partFirstPages: [0, 2])
        #expect(indices == Set(0..<5))
    }

    @Test("first-page scope uses the part start pages")
    func firstPageOfEachPart() {
        let indices = testJob(.firstPageOfEachPart).pageIndices(pageCount: 6, partFirstPages: [0, 2, 4])
        #expect(indices == Set([0, 2, 4]))
    }

    @Test("out-of-range part pages are ignored")
    func dropsOutOfRangePages() {
        let indices = testJob(.firstPageOfEachPart).pageIndices(pageCount: 3, partFirstPages: [0, 5, -1])
        #expect(indices == Set([0]))
    }

    @Test("a blank stamp is not a drawable job")
    func blankJobIsNotDrawable() {
        var stamp = testStamp()
        stamp.text = " "
        #expect(StampJob(stamp: stamp, scope: .everyPage).isDrawable == false)
        #expect(testJob(.everyPage).isDrawable)
    }
}

// MARK: - applyingStamp (the call-site helper)

@Suite("applyingStamp")
struct ApplyingStampTests {

    @Test("a nil job returns the same document untouched")
    func nilJobIsPassThrough() {
        let doc = document(pages: [a4Page(), a4Page()])
        let result = applyingStamp(nil, to: doc, partFirstPages: [0])
        #expect(result === doc)
    }

    @Test("a blank stamp returns the same document untouched")
    func blankJobIsPassThrough() {
        let doc = document(pages: [a4Page()])
        var stamp = testStamp()
        stamp.text = ""
        let result = applyingStamp(StampJob(stamp: stamp, scope: .everyPage),
                                   to: doc, partFirstPages: [0])
        #expect(result === doc)
    }

    @Test("a drawable job returns a new document with the same page count")
    func drawableJobStamps() {
        let doc = document(pages: [a4Page(), a4Page(), a4Page()])
        let result = applyingStamp(testJob(.firstPageOfEachPart), to: doc, partFirstPages: [0, 2])
        #expect(result !== doc)
        #expect(result.pageCount == 3)
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

// MARK: - Folder expansion (shared with the Combine tab's drop handling)

@Suite("File expansion")
struct ExpandToFilesTests {

    /// Builds a temp tree:  root/a.pdf, root/b.PDF, root/notes.txt, root/sub/c.pdf
    private func makeTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("stamp-expand-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        for name in ["a.pdf", "b.PDF", "notes.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        try Data("x".utf8).write(to: sub.appendingPathComponent("c.pdf"))
        return root
    }

    @Test("a folder expands recursively to its PDFs, name-sorted")
    func expandsFolderRecursively() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let found = expandToFiles([root], extensions: ["pdf"])
        #expect(found.map { $0.lastPathComponent } == ["a.pdf", "b.PDF", "c.pdf"])
    }

    @Test("the extension match is case-insensitive and filters everything else out")
    func filtersByExtension() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let pdfs = expandToFiles([root], extensions: ["pdf"])
        #expect(pdfs.allSatisfy { $0.pathExtension.lowercased() == "pdf" })
        #expect(expandToFiles([root], extensions: ["txt"]).count == 1)
    }

    @Test("plain files pass through and missing paths are ignored")
    func handlesFilesAndMissingPaths() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("a.pdf")
        let missing = root.appendingPathComponent("nope.pdf")
        #expect(expandToFiles([file], extensions: ["pdf"]) == [file])
        #expect(expandToFiles([missing], extensions: ["pdf"]).isEmpty)
        #expect(expandToFiles([], extensions: ["pdf"]).isEmpty)
    }

    @Test("a mixed drop of a file and a folder is combined and sorted")
    func mixesFilesAndFolders() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let found = expandToFiles([root.appendingPathComponent("sub"),
                                   root.appendingPathComponent("a.pdf")],
                                  extensions: ["pdf"])
        #expect(found.map { $0.lastPathComponent } == ["a.pdf", "c.pdf"])
    }
}

// MARK: - Rich text

@Suite("Stamp rich text")
struct StampRichTextTests {

    /// "Plain " + bold "Bold" + red italic "Italic", the shape the editor produces.
    private func mixedAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "Plain ", attributes: [
            .font: NSFont(name: "Helvetica", size: 12)!,
            .foregroundColor: NSColor.black]))
        result.append(NSAttributedString(string: "Bold", attributes: [
            .font: NSFont(name: "Helvetica-Bold", size: 12)!,
            .foregroundColor: NSColor.black]))
        result.append(NSAttributedString(string: "Italic", attributes: [
            .font: NSFont(name: "Helvetica-Oblique", size: 14)!,
            .foregroundColor: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)]))
        return result
    }

    private func fontRuns(_ attributed: NSAttributedString) -> [(name: String, size: Double, text: String)] {
        var runs: [(String, Double, String)] = []
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let font = value as! NSFont
            runs.append((font.fontName, Double(font.pointSize),
                         (attributed.string as NSString).substring(with: range)))
        }
        return runs
    }

    @Test("RTF round trips the per-run fonts and colours")
    func rtfRoundTrip() throws {
        let data = try #require(stampRTFData(from: mixedAttributedString()))
        let stamp = Stamp(name: "Mixed", text: "Plain BoldItalic", richTextData: data)
        let decoded = try #require(stampRichText(stamp))

        let runs = fontRuns(decoded)
        #expect(runs.count == 3)
        #expect(runs[0].name == "Helvetica")
        #expect(runs[1].name == "Helvetica-Bold")
        #expect(runs[2].name == "Helvetica-Oblique")
        #expect(runs[2].size == 14)   // the per-run size survives, not just the traits
    }

    @Test("rich text wins over the plain text and base attributes")
    func richTextTakesPrecedence() throws {
        let data = try #require(stampRTFData(from: mixedAttributedString()))
        var stamp = Stamp(name: "Mixed", text: "Plain BoldItalic", richTextData: data)
        stamp.isBold = false          // base attributes say "not bold"…
        stamp.fontSize = 30           // …and 30 pt

        let drawn = stampAttributedString(stamp)
        let runs = fontRuns(drawn)
        // …but the rich runs are what get drawn.
        #expect(runs.contains { $0.name == "Helvetica-Bold" })
        #expect(runs.allSatisfy { $0.size != 30 })
    }

    @Test("applying alignment doesn't flatten the per-run styling")
    func alignmentPreservesRuns() throws {
        let data = try #require(stampRTFData(from: mixedAttributedString()))
        var stamp = Stamp(name: "Mixed", text: "Plain BoldItalic", richTextData: data)
        stamp.alignment = .right

        let drawn = stampAttributedString(stamp)
        #expect(fontRuns(drawn).count == 3)
        let para = drawn.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(para?.alignment == .right)
        // The colour of the last run must also survive.
        let colour = drawn.attribute(.foregroundColor, at: drawn.length - 1,
                                     effectiveRange: nil) as? NSColor
        #expect(colour?.usingColorSpace(.sRGB)?.redComponent ?? 0 > 0.9)
    }

    @Test("without rich text the base attributes are used")
    func fallsBackToBaseAttributes() {
        var stamp = testStamp()
        stamp.richTextData = nil
        stamp.isBold = true
        stamp.fontSize = 20

        let drawn = stampAttributedString(stamp)
        let runs = fontRuns(drawn)
        #expect(runs.count == 1)
        #expect(runs[0].size == 20)
        #expect(NSFontManager.shared.traits(of: NSFont(name: runs[0].name, size: 20)!)
            .contains(.boldFontMask))
    }

    @Test("empty rich text falls back rather than drawing nothing")
    func emptyRichTextIsIgnored() throws {
        let empty = try #require(stampRTFData(from: NSAttributedString(string: "")))
        var stamp = testStamp()
        stamp.richTextData = empty
        #expect(stampRichText(stamp) == nil)
        #expect(stampAttributedString(stamp).string == stamp.text)
    }

    @Test("rich text survives the stamp's own encode / decode")
    func survivesStampCoding() throws {
        let data = try #require(stampRTFData(from: mixedAttributedString()))
        let stamp = Stamp(name: "Mixed", text: "Plain BoldItalic", richTextData: data)
        let coded = try JSONDecoder().decode(Stamp.self, from: try JSONEncoder().encode(stamp))
        #expect(coded.richTextData == data)
        #expect(fontRuns(try #require(stampRichText(coded))).count == 3)
    }
}

// MARK: - Text alignment

@Suite("Stamp text alignment")
struct StampAlignmentTests {

    @Test("the stored alignment is what gets drawn, whatever the position")
    func alignmentIsStoredNotDerived() {
        for alignment in StampTextAlignment.allCases {
            var stamp = testStamp()
            stamp.alignment = alignment
            // Move the stamp across the page: alignment must not follow it.
            for x in [0.0, 0.5, 1.0] {
                stamp.positionX = x
                let para = stampAttributedString(stamp)
                    .attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
                #expect(para?.alignment == alignment.nsAlignment)
            }
        }
    }

    @Test("a stamp saved before the control existed keeps the look it had")
    func migratesFromPosition() throws {
        // Old shape: no `alignment` key. Alignment used to be inferred from positionX.
        func decode(positionX: Double) throws -> Stamp {
            let json = #"{"name":"Old","text":"Two\nLines","positionX":\#(positionX),"positionY":0.5}"#
            return try JSONDecoder().decode(Stamp.self, from: Data(json.utf8))
        }
        #expect(try decode(positionX: 0).alignment == .left)
        #expect(try decode(positionX: 0.5).alignment == .centre)
        #expect(try decode(positionX: 1).alignment == .right)
    }

    @Test("an explicit alignment survives coding")
    func survivesCoding() throws {
        var stamp = testStamp()
        stamp.alignment = .left
        stamp.positionX = 1      // a position that would once have forced .right
        let coded = try JSONDecoder().decode(Stamp.self, from: try JSONEncoder().encode(stamp))
        #expect(coded.alignment == .left)
    }
}

// MARK: - Toolbar label

@Suite("Stamp button label")
struct ShortenedStampNameTests {

    @Test("a short name is left alone")
    func shortNameUnchanged() {
        #expect(shortenedStampName("School Band") == "School Band")
        #expect(shortenedStampName("") == "")
    }

    @Test("a long name is trimmed to the limit with an ellipsis")
    func longNameTruncated() {
        let result = shortenedStampName("Hornsby North Public School Concert Band", limit: 18)
        #expect(result.hasSuffix("…"))
        #expect(result.count <= 18)
    }

    @Test("no stranded space before the ellipsis")
    func trimsTrailingSpace() {
        // The cut lands mid-gap: "Hornsby North Publ" → cut at 17 = "Hornsby North Pub".
        #expect(shortenedStampName("Hornsby North Pub School", limit: 15) == "Hornsby North…")
    }

    @Test("a name exactly at the limit isn't touched")
    func boundaryIsInclusive() {
        let name = String(repeating: "a", count: 18)
        #expect(shortenedStampName(name, limit: 18) == name)
        #expect(shortenedStampName(name + "b", limit: 18).hasSuffix("…"))
    }
}
