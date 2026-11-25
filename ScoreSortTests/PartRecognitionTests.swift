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

/// Reading hand-copied parts: the cases come from the *Ebony Concerto* rental parts, as Vision
/// read them.
@MainActor
@Suite("Part recognition: misreadings, cues, scores and titles")
struct PartRecognitionRobustnessTests {
    private let band = InstrumentOrders.defaultOrders["band"]!
    private let jazz = InstrumentOrders.defaultOrders["jazz"]!

    private func name(_ text: String, order: [String], x: CGFloat = 0.1, y: CGFloat = 0.09, h: CGFloat = 0.025) -> String? {
        let matcher = InstrumentMatcher(order: order)
        return partNameMatch(in: [line(text, x: x, y: y, h: h, conf: 1)], matcher: matcher)
            .map { recognisedPartName(line: $0.line.text, match: $0.match, order: order) }
    }

    @Test("lookalike letters cost half an edit")
    func distance() {
        #expect(misreadDistance("horn", "horn") == 0)
        #expect(misreadDistance("horx", "horn") == 1)
        #expect(misreadDistance("jrumbet", "trumpet") == 1)        // j/t and b/p
        #expect(misreadDistance("", "oboe") == 4)
    }

    @Test("misread names match their instrument, about one letter in four")
    func forgiving() {
        let m = InstrumentMatcher(order: band)
        #expect(m.match("Irombrne", forgiving: true)?.instrument == "trombone")
        #expect(m.match("Horx", forgiving: true)?.instrument == "horn")
        #expect(m.match("Eb Alte Sexabhene I", forgiving: true)?.instrument == "alto saxophone")
        #expect(m.match("Irombrne") == nil)                          // only when asked to forgive
        #expect(m.match("Brass", forgiving: true) == nil)            // a section, not a bass
        #expect(m.match("Hornpipe", forgiving: true) == nil)
        #expect(m.match("Embassy", forgiving: true) == nil)
        #expect(m.match("Allegro", forgiving: true) == nil)
    }

    @Test("names come from the instrument matched, with the part number written")
    func names() {
        #expect(name("Eb Alte Sexabhene I", order: band) == "Alto Saxophone 1")
        #expect(name("Jrumbet IV in Bb", order: band) == "Trumpet 4")
        #expect(name("Jrombore II", order: band) == "Trombone 2")
        #expect(name("2nd Clarinet", order: band) == "Clarinet 2")
        #expect(name("Horn in F 3", order: band) == "Horn 3")
        #expect(name("Horx", order: band) == "Horn")
        #expect(name("SOLO Bb CLARINET", order: band) == "Solo Clarinet")
        #expect(name("SOLO Bb CLARINET", order: jazz) == "Solo Clarinet")   // not jazz's "solo bb"
        #expect(name("Alto", order: band) == "Alto Saxophone")
        #expect(name("Baritone", order: jazz) == "Baritone Saxophone")
        #expect(name("Baritone", order: band) == "Baritone")
        #expect(name("El Baritene Sraphene", order: band) == "Baritone Saxophone")
    }

    @Test("cues aren't part names: in brackets, low on the page, at the right, too small, too long")
    func cues() {
        #expect(name("(Bass Clar.)", order: band) == nil)
        #expect(name("Bass Clarinet", order: band, y: 0.3) == nil)
        #expect(name("Clarinet", order: band, x: 0.75) == nil)
        #expect(name("Alto S.", order: band, h: 0.009) == nil)
        #expect(name("Please note that the trumpet part must be returned", order: band) == nil)
        #expect(name("Clarinet", order: band) == "Clarinet")
    }

    @Test("a page naming three instruments is a score, with no part name")
    func score() {
        let labels = [line("Bb Clorinel", y: 0.11, h: 0.012), line("Eb Altos", y: 0.15, h: 0.012),
                      line("Rb Tenors", y: 0.18, h: 0.012), line("86 Boss Clorinel", y: 0.26, h: 0.012)]
        let matcher = InstrumentMatcher(order: band)
        #expect(looksLikeScorePage(labels, matcher: matcher))
        #expect(partNameMatch(in: labels, matcher: matcher) == nil)
        #expect(!looksLikeScorePage([line("Flute 1", y: 0.08), line("(Oboe)", y: 0.3)], matcher: matcher))
        #expect(readParts([labels, []], order: band).pageNames == ["Score", nil])
    }

    /// A part's first page: its name, the title and the composer as read.
    private func firstPage(_ part: String, title: String = "EBONY CONCERTO") -> [RecognizedLine] {
        [line(part, y: 0.09, h: 0.025), line(title, x: 0.4, y: 0.17, h: 0.04), line("I. STRAVINSKY", x: 0.7, y: 0.11, h: 0.03)]
    }

    @Test("pages carrying the first page's title start the parts, named or not")
    func titles() {
        let pages: [[RecognizedLine]?] = [
            firstPage("Horx"),
            [line("Bb Clarinet", y: 0.12)],                         // a doubling inside the part
            [line("HARMON", x: 0.4, y: 0.1)],                      // a direction, on several pages
            firstPage("Z Jrumbet I inBb", title: "EBONt COnCERTe"),
            [line("HARMON", x: 0.4, y: 0.1)],
            firstPage("Jrumtat", title: "EBINY CONCERTA"),          // name unreadable: still a part
            [],
        ]
        let reading = readParts(pages, order: band)
        #expect(reading.method == "titles")
        #expect(reading.parts == [SuggestedPart(startPage: 0, name: "Horn"), SuggestedPart(startPage: 3, name: "Trumpet 1"),
                                  SuggestedPart(startPage: 5, name: "")])
        #expect(reading.pageNames[1] == "Clarinet")                // read, but not a new part
    }

    @Test("a title only on the first page is one part, whatever it names later")
    func oneTitle() {
        let pages: [[RecognizedLine]?] = [firstPage("Alto Sax I"), [], [line("Bb Clarinet", y: 0.12)], []]
        let reading = readParts(pages, order: band)
        #expect(reading.parts == [SuggestedPart(startPage: 0, name: "Alto Saxophone 1")])
    }

    @Test("without titles, parts start where the name changes")
    func byName() {
        let pages: [[RecognizedLine]?] = [[line("Flute", y: 0.08)], [], [line("Oboe", y: 0.08)], [line("Oboe", y: 0.05)]]
        let reading = readParts(pages, order: band)
        #expect(reading.method == "names")
        #expect(reading.parts == [SuggestedPart(startPage: 0, name: "Flute"), SuggestedPart(startPage: 2, name: "Oboe")])
    }

    @Test("too few pages read, or nothing recognised, suggests nothing and says why")
    func fallback() {
        let unread = readParts([nil, nil, [line("Flute", y: 0.08)]], order: band)
        #expect(unread.parts.isEmpty)
        #expect(unread.problem?.contains("Only 1 of 3") == true)
        let failed = readParts([nil, nil], order: band)
        #expect(failed.parts.isEmpty && failed.problem != nil)
        let blank = readParts([[], []], order: band)
        #expect(blank.parts.isEmpty && blank.problem?.contains("No text") == true)
        let unnamed = readParts([[line("Allegro", y: 0.1)], [line("Andante", y: 0.1)]], order: band)
        #expect(unnamed.parts.isEmpty && unnamed.problem != nil)
    }
}

@MainActor
@Suite("Part recognition: the page cache")
struct PageTextCacheTests {
    @Test("a page's text is remembered until the page is cut differently or goes")
    func remembers() throws {
        let cache = PageTextCache()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox)
        #expect(cache.lines(for: page) == nil)
        cache.store([line("Flute", y: 0.1)], for: page)
        #expect(cache.lines(for: page)?.first?.text == "Flute")
        page.setBounds(CGRect(x: 0, y: 0, width: 297, height: 842), for: .cropBox)   // Split Double Pages
        #expect(cache.lines(for: page) == nil)
        #expect(cache.lines(for: PDFPage()) == nil)
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
        let name = try #require(lines?.first { $0.text.lowercased().contains("trumpet") })
        #expect(name.box.minX > 0.5)                 // right half
        #expect(name.box.minY < 0.15)                // near the top
    }
}
