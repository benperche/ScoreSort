//
//  CombineBookmarkSavingTests.swift
//  ScoreSortTests
//
//  The table of contents has to survive being *saved*, not just exist in memory. PDFKit on
//  macOS 27.0 keeps an outline assigned to a document it opened from data in memory, then
//  writes the file without it — and both stamping and booklet imposition hand back exactly
//  that kind of document. So every test here writes the combined PDF, checks the raw bytes,
//  and reopens it from disk.
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

/// A PDF drawn by Core Graphics, like the files people actually drop in — rather than one
/// assembled from `PDFPage()`s by PDFKit, which happens to dodge the bug being tested.
private func writeCoreGraphicsPDF(pages: Int, to url: URL) {
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    for _ in 0..<pages {
        ctx.beginPDFPage(nil)
        ctx.fill(CGRect(x: 72, y: 72, width: 100, height: 100))
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

private func containsOutlines(_ url: URL) throws -> Bool {
    try Data(contentsOf: url).range(of: Data("/Outlines".utf8)) != nil
}

@Suite("Combine bookmarks survive saving")
struct CombineBookmarkSavingTests {

    /// Each output route that rebuilds the document differently before the outline goes on.
    enum Output: String, CaseIterable {
        case singlePages, stampedPages, booklet, stampedBooklet

        var options: CombineOutputOptions {
            var options = CombineOutputOptions()
            if self == .booklet || self == .stampedBooklet { options.layout = .booklet }
            return options
        }

        var stampJob: StampJob? {
            guard self == .stampedPages || self == .stampedBooklet else { return nil }
            return StampJob(stamp: Stamp(name: "Test", text: "Example School Band"),
                            scope: .firstPageOfEachPart)
        }
    }

    let tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    private func combine(_ parts: [(name: String, pages: Int)], as output: Output) -> URL {
        let urls = parts.map { tempDir.appendingPathComponent("\($0.name).pdf") }
        for (url, part) in zip(urls, parts) { writeCoreGraphicsPDF(pages: part.pages, to: url) }

        let manager = CombineManager()
        manager.addFiles(urls: urls, undoManager: nil)
        let out = tempDir.appendingPathComponent("combined-\(output.rawValue).pdf")
        manager.createCombinedPDF(to: out, options: output.options,
                                  stampJob: output.stampJob) { _, _, _ in }
        return out
    }

    @Test(arguments: Output.allCases)
    func savedFileKeepsItsTableOfContents(_ output: Output) throws {
        let out = combine([("Flute", 4), ("Oboe", 8), ("Horn", 4)], as: output)

        #expect(try containsOutlines(out), "no /Outlines written to the file")

        let saved = try #require(PDFDocument(url: out))
        let root = try #require(saved.outlineRoot, "the reopened file has no table of contents")
        #expect(root.numberOfChildren == 3)
        let labels = (0..<root.numberOfChildren).map { root.child(at: $0)?.label }
        #expect(labels == ["Flute", "Oboe", "Horn"])

        // Each entry must still point at the right page of the *saved* file: reading pages
        // for single-page output, sheet faces (two per four pages) for booklets.
        let starts = (0..<root.numberOfChildren).compactMap { i -> Int? in
            guard let page = root.child(at: i)?.destination?.page else { return nil }
            return saved.index(for: page)
        }
        #expect(starts == (output.options.layout == .booklet ? [0, 2, 6] : [0, 4, 12]))
    }

    /// The round trip the bookmarks exist for: a stamped, combined set of parts dropped on the
    /// Split tab should come back pre-split and pre-named.
    @Test func stampedCombinedPDFSplitsBackIntoItsParts() throws {
        let out = combine([("01 - Suite - Flute", 3), ("02 - Suite - Oboe", 2)], as: .stampedPages)

        let saved = try #require(PDFDocument(url: out))
        let split = try #require(splitSizesFromBookmarks(saved))
        #expect(split.sizes == [3, 2])
        let names = try #require(extractSplitNames(from: split.labels))
        #expect(names.baseName == "Suite")
        #expect(names.suffixes == ["Flute", "Oboe"])
    }
}
