//
//  SplitBookmarkNamingTests.swift
//  ScoreSortTests
//
//  Splitting at a PDF's existing bookmarks: which files the bookmarks produce, how
//  their titles become file names, and names staying with their file when the split
//  points are edited afterwards.
//

import Testing
import PDFKit
@testable import ScoreSort

/// An in-memory document with a top-level bookmark at each given page.
private func bookmarkedDocument(pages: Int, bookmarks: [(label: String, page: Int)]) -> PDFDocument {
    let doc = PDFDocument()
    for i in 0..<pages { doc.insert(PDFPage(), at: i) }
    let root = PDFOutline()
    for entry in bookmarks {
        guard let page = doc.page(at: entry.page) else { continue }
        let item = PDFOutline()
        item.label = entry.label
        item.destination = PDFDestination(page: page, at: .zero)
        root.insertChild(item, at: root.numberOfChildren)
    }
    doc.outlineRoot = root
    return doc
}

@Suite("bookmarkSections")
struct BookmarkSectionsTests {

    @Test func oneSectionPerBookmark() throws {
        let doc = bookmarkedDocument(pages: 6, bookmarks: [("Score", 0), ("Flute", 4)])
        let sections = try #require(bookmarkSections(in: doc))
        #expect(sections == [BookmarkSection(startPage: 0, pageCount: 4, title: "Score"),
                             BookmarkSection(startPage: 4, pageCount: 2, title: "Flute")])
    }

    @Test func pagesBeforeTheFirstBookmarkGetAnUntitledSection() throws {
        // The title must stay with the pages it points at, not slide onto the cover.
        let doc = bookmarkedDocument(pages: 6, bookmarks: [("Flute", 2), ("Oboe", 4)])
        let sections = try #require(bookmarkSections(in: doc))
        #expect(sections.map { $0.title } == ["", "Flute", "Oboe"])
        #expect(sections.map { $0.pageCount } == [2, 2, 2])

        let split = try #require(splitSizesFromBookmarks(doc))
        #expect(split.sizes.count == split.labels.count)
    }

    @Test func twoBookmarksOnOnePageMakeOneFile() throws {
        let doc = bookmarkedDocument(pages: 6, bookmarks: [("Score", 0), ("Flute", 3), ("Flute again", 3)])
        let sections = try #require(bookmarkSections(in: doc))
        #expect(sections.map { $0.pageCount } == [3, 3])
        #expect(sections.map { $0.title } == ["Score", "Flute"])
    }

    @Test func nilWhenTheBookmarksDontDivideTheDocument() {
        #expect(bookmarkSections(in: bookmarkedDocument(pages: 4, bookmarks: [("Only", 0)])) == nil)
        #expect(bookmarkSections(in: bookmarkedDocument(pages: 4, bookmarks: [])) == nil)
    }
}

@Suite("bookmarkSplitNames")
struct BookmarkSplitNamesTests {

    @Test func plainTitlesBecomeSuffixesUnderTheFileName() {
        let names = bookmarkSplitNames(titles: ["Conductor Score", "Flute 1", "Flute 2"],
                                       fallbackBaseName: "First Suite", style: .pieceAndTitle)
        #expect(names.baseName == "First Suite")
        #expect(names.suffixes == ["Conductor Score", "Flute 1", "Flute 2"])
    }

    @Test func sharedPieceNameBecomesTheBase() {
        let names = bookmarkSplitNames(titles: ["First Suite - Flute", "First Suite - Horn - in F"],
                                       fallbackBaseName: "scan0042", style: .pieceAndTitle)
        #expect(names.baseName == "First Suite")
        #expect(names.suffixes == ["Flute", "Horn - in F"])
    }

    @Test func agreesWithExtractSplitNamesOnScoreSortLabels() throws {
        let labels = ["00 - Symphony 5 - Score", "01 - Symphony 5 - Flute", "02 - Symphony 5 - Oboe"]
        let expected = try #require(extractSplitNames(from: labels))
        let names = bookmarkSplitNames(titles: labels, fallbackBaseName: "combined", style: .pieceAndTitle)
        #expect(names.baseName == expected.baseName)
        #expect(names.suffixes == expected.suffixes)
    }

    @Test func scoreOrderNumbersAreDroppedWithoutAPieceName() {
        // Step 3 numbers the files again, so "01 - 01 - Flute" must not happen.
        let names = bookmarkSplitNames(titles: ["01 - Flute", "02 - Oboe"],
                                       fallbackBaseName: "March", style: .pieceAndTitle)
        #expect(names.baseName == "March")
        #expect(names.suffixes == ["Flute", "Oboe"])
    }

    @Test func differentPiecesKeepTheirOwnNames() {
        let names = bookmarkSplitNames(titles: ["01 - March - Flute", "01 - Waltz - Flute"],
                                       fallbackBaseName: "Concert", style: .pieceAndTitle)
        #expect(names.baseName == "Concert")
        #expect(names.suffixes == ["March - Flute", "Waltz - Flute"])
    }

    @Test func aSharedFirstWordIsNotAPieceName() {
        let names = bookmarkSplitNames(titles: ["Clarinet 1", "Clarinet 2", "Clarinet 3"],
                                       fallbackBaseName: "Parts", style: .pieceAndTitle)
        #expect(names.baseName == "Parts")
        #expect(names.suffixes == ["Clarinet 1", "Clarinet 2", "Clarinet 3"])
    }

    @Test func titleOnlyUsesTheWholeTitleAndNoBase() {
        let names = bookmarkSplitNames(titles: ["01 - March", "02 - Waltz"],
                                       fallbackBaseName: "Dance Book", style: .titleOnly)
        #expect(names.baseName == "")
        #expect(names.suffixes == ["01 - March", "02 - Waltz"])
    }

    @Test func untitledSectionsAreLeftForAutoNumbering() {
        let names = bookmarkSplitNames(titles: ["", "Suite - Flute", "Suite - Oboe"],
                                       fallbackBaseName: "scan", style: .pieceAndTitle)
        #expect(names.baseName == "Suite")
        #expect(names.suffixes == ["", "Flute", "Oboe"])
    }

    @Test func titlesAreMadeSafeForFileNames() {
        // Combine labels multi-copy parts "Flute 2/3"; a "/" would block saving in Step 2.
        let names = bookmarkSplitNames(titles: ["Flute 2/3", "Suite: Finale", "  Oboe.pdf ", "Horn\nin F"],
                                       fallbackBaseName: "Piece", style: .pieceAndTitle)
        #expect(names.suffixes == ["Flute 2-3", "Suite - Finale", "Oboe", "Horn in F"])
        for suffix in names.suffixes { #expect(pdfFilenameError(for: suffix) == nil) }
    }
}

@Suite("Split file names")
struct SplitFileNameTests {

    @Test func composesBaseSeparatorAndSuffix() {
        #expect(splitOutputFileName(base: "Suite", separator: " - ", suffix: "Flute", fileIndex: 3) == "Suite - Flute.pdf")
        #expect(splitOutputFileName(base: "Suite", separator: "_", suffix: "", fileIndex: 3) == "Suite_4.pdf")
    }

    @Test func anEmptyBaseLeavesTheSuffixOnItsOwn() {
        #expect(splitOutputFileName(base: "", separator: " - ", suffix: "March", fileIndex: 0) == "March.pdf")
        #expect(splitOutputFileName(base: "", separator: " - ", suffix: "", fileIndex: 1) == "2.pdf")
        // Step 3's save passes the complete name as the suffix.
        #expect(splitOutputFileName(base: "", separator: "", suffix: "01 - Suite - Flute", fileIndex: 0) == "01 - Suite - Flute.pdf")
    }

    @Test func namesStayWithTheirFileWhenASplitIsRemoved() {
        // Score | Flute | Oboe → merge Flute into Score: Oboe is now file 1, still "Oboe".
        let names = remapFileNames([0: "Score", 1: "Flute", 2: "Oboe"], from: [4, 2, 2], to: [6, 2])
        #expect(names == [0: "Score", 1: "Oboe"])
    }

    @Test func namesStayWithTheirFileWhenASplitIsAdded() {
        // Splitting the score in two leaves the new second half unnamed, the rest untouched.
        let names = remapFileNames([0: "Score", 1: "Flute", 2: "Oboe"], from: [4, 2, 2], to: [2, 2, 2, 2])
        #expect(names == [0: "Score", 2: "Flute", 3: "Oboe"])
    }
}
