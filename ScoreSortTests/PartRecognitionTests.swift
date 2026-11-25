//
//  PartRecognitionTests.swift
//  ScoreSortTests
//
//  #17: reading part names off the page. The interpretation is tested with plain lines; the
//  recognition itself with a page drawn through Core Graphics.
//

import Testing
import Foundation
import AppKit
import PDFKit
@testable import ScoreSort

private func line(_ text: String, x: CGFloat = 0.05, y: CGFloat, h: CGFloat = 0.02, conf: Float = 0.9) -> RecognizedLine {
    RecognizedLine(text: text, box: CGRect(x: x, y: y, width: 0.2, height: h), confidence: conf)
}

@MainActor
@Suite("Part recognition: reading the lines")
struct PartRecognitionTests {
    private let band = InstrumentOrders.defaultOrders["band"]!

    @Test("instruments are matched as whole words only")
    func wholeWords() {
        #expect(instrumentInPageText("Clarinet in B♭ 2", order: band)?.1 == "clarinet")
        #expect(instrumentInPageText("Hornpipe", order: band) == nil)
        #expect(instrumentInPageText("The Embassy March", order: band) == nil)
        #expect(instrumentInPageText("Bass Clarinet", order: band)?.1 == "bass clarinet")
    }

    @Test("the part name is the instrument line nearest the top, not the title")
    func partName() {
        let lines = [line("Allegro moderato", y: 0.2), line("Flute 1", y: 0.08), line("Trumpet Voluntary", x: 0.3, y: 0.05, h: 0.04)]
        #expect(partNameLine(in: lines, order: band, ignoring: ["trumpet voluntary"])?.text == "Flute 1")
    }

    @Test("the preview looks at the part name, or the first text from the top if there's none")
    func focus() {
        let named = [line("Dedicated to someone", x: 0.4, y: 0.05), line("Oboe", x: 0.6, y: 0.1)]
        #expect(partNameFocus(in: named, order: band)?.minX == 0.6)
        let unnamed = [line("EBONY CONCERTO", x: 0.2, y: 0.15), line("Dedicated", x: 0.4, y: 0.09)]
        #expect(partNameFocus(in: unnamed, order: band)?.minY == 0.09)
        #expect(partNameFocus(in: [], order: band) == nil)
    }

    @Test("titles repeated on each part's first page are set aside; a part's own header isn't")
    func repeated() {
        let title = line("Shea Butter Suite", y: 0.03)
        let pages: [[RecognizedLine]] = [[title, line("Flute", y: 0.08)], [line("Flute", y: 0.05)], [line("Flute", y: 0.05)],
                                         [title, line("Oboe", y: 0.08)], [line("Oboe", y: 0.05)], [title, line("Clarinet", y: 0.08)]]
        let r = repeatedLines(pages)
        #expect(r.contains("shea butter suite"))
        #expect(!r.contains("flute"))
    }

    @Test("parts start where the name changes; unnamed pages belong to the part before")
    func suggested() {
        let parts = suggestedParts(pageNames: ["Flute", nil, "Flute", "Oboe", nil, "Clarinet 1", "Clarinet 2"])
        #expect(parts == [SuggestedPart(startPage: 0, name: "Flute"), SuggestedPart(startPage: 3, name: "Oboe"),
                          SuggestedPart(startPage: 5, name: "Clarinet 1"), SuggestedPart(startPage: 6, name: "Clarinet 2")])
        #expect(suggestedParts(pageNames: [nil, nil, nil, "Flute"]).isEmpty)   // nothing reliable near the start
        #expect(suggestedParts(pageNames: ["Flute"]).isEmpty)
    }

    @Test("a name is tidied the way it would be typed")
    func tidy() {
        #expect(tidiedPartName("clarinet in B♭  2") == "Clarinet In Bb 2")
        #expect(tidiedPartName("FLUTE") == "FLUTE")
    }
}

@Suite("Part recognition: on a drawn page")
struct PartRecognitionPageTests {

    // GitHub's macOS runners can't run Vision's text recognition (it fails to compile its
    // model: "E5RT … compile failed"), so CI skips this one; it runs on a real Mac.
    @Test("Vision reads a part name drawn at the top of a page, and where it is",
          .disabled(if: ProcessInfo.processInfo.environment["SCORESORT_CI_NO_VISION"] != nil,
                    "Vision text recognition isn't available on GitHub's runner"))
    func readsDrawnName() throws {
        let url = temporaryFolder("ocr").appendingPathComponent("Part.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(box)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "Trumpet 2", attributes: [.font: NSFont.boldSystemFont(ofSize: 22)])
            .draw(at: CGPoint(x: 360, y: 770))   // near the top right
        NSGraphicsContext.current = previous
        ctx.endPDFPage(); ctx.closePDF()

        let source = try #require(PDFDocument(url: url)?.page(at: 0)?.scanRenderSource)
        let lines = recognizePageText(source)
        let name = try #require(lines.first { $0.text.lowercased().contains("trumpet") })
        #expect(name.box.minX > 0.5)                 // right half
        #expect(name.box.minY < 0.15)                // near the top
    }
}
