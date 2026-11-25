//
//  SplitModelTests.swift
//  ScoreSortTests
//
//  The Split tab's Step 1 state (`SplitModel`): what each operation changes and what it
//  keeps — splits, skips, the in-place rebuilds (Swap with Next, Fix Booklet Order),
//  Split Double Pages, undo and redo, clearing, and opening a new PDF after a rebuild (#29).
//  Documents are real files drawn by Core Graphics (`writeDrawnPDF`, CLITests.swift).
//  Suggest Splits (#17) is `SplitModelSuggestionTests`.
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

private let a4 = CGSize(width: 595, height: 842)
private let a3Landscape = CGSize(width: 1191, height: 842)

/// A model with a freshly opened PDF of `pages` pages called "`name`.pdf".
@MainActor
private func openedModel(pages: Int, size: CGSize = a4, name: String = "Holst Suite",
                         model: SplitModel = SplitModel()) throws -> (model: SplitModel, suggestion: SplitLoadSuggestion) {
    let url = temporaryFolder("splitmodel").appendingPathComponent("\(name).pdf")
    writeDrawnPDF(pages: pages, size: size, to: url)
    let suggestion = try #require(model.load(from: url))
    return (model, suggestion)
}

/// The document's pages, by identity, so a test can see where each one went.
@MainActor
private func pageObjects(_ model: SplitModel) -> [PDFPage] {
    guard let doc = model.document else { return [] }
    return (0..<doc.pageCount).compactMap { doc.page(at: $0) }
}

@MainActor
@Suite("Split model: opening and clearing")
struct SplitModelLoadTests {

    @Test("A new PDF is one file named after it, on page 1, with nothing skipped")
    func freshLoad() throws {
        let (model, suggestion) = try openedModel(pages: 8)
        #expect(suggestion == .ordinaryPages)
        #expect(model.fileSizes == [8])
        #expect(model.baseFileName == "Holst Suite")
        #expect(model.sourceFileName == "Holst Suite")
        #expect(model.sourceURL?.lastPathComponent == "Holst Suite.pdf")
        #expect(model.currentPage == 0)
        #expect(model.skippedPages.isEmpty)
        #expect(model.customFileNames.isEmpty)
        #expect(model.skipMode == .file)
        #expect(!model.documentRebuilt)
        #expect(!model.canUndo)
        // One file, nothing skipped, nothing rebuilt: nothing new to save yet.
        #expect(!model.canContinueToNaming)
    }

    @Test("A file that won't open changes nothing")
    func unreadableFile() throws {
        let (model, _) = try openedModel(pages: 4)
        model.toggleSplitAt(page: 2)
        let before = model.document
        let missing = temporaryFolder("splitmodel").appendingPathComponent("Missing.pdf")
        #expect(model.load(from: missing) == nil)
        #expect(model.document === before)
        #expect(model.fileSizes == [2, 2])
        #expect(model.canUndo)
    }

    @Test("Double pages are offered Split Double Pages; near-A3 proportions only a hint")
    func doublePageSuggestions() throws {
        #expect(try openedModel(pages: 3, size: a3Landscape).suggestion == .splitDoublePages)
        // Landscape at A3's proportions but too big to be A3, all one size: only the hint.
        #expect(try openedModel(pages: 2, size: CGSize(width: 1700, height: 1190)).suggestion == .doublePageHint)
    }

    @Test("Opening another PDF starts afresh but keeps the stride and the last booklet order")
    func reloadResets() throws {
        let (model, _) = try openedModel(pages: 8)
        model.stride = 4
        model.applyStride()
        model.customFileNames = [0: "Flute", 1: "Oboe"]
        model.toggleSkipPage(5)
        model.currentPage = 5
        model.skipMode = .page
        model.applyBookletOrder(pages: model.pagesForFile(0), order: coverFirstFrontBackOrder(n: 4))
        #expect(model.documentRebuilt)

        _ = try openedModel(pages: 3, name: "Elgar", model: model)
        #expect(model.fileSizes == [3])
        #expect(model.baseFileName == "Elgar")
        #expect(model.customFileNames.isEmpty)
        #expect(model.skippedPages.isEmpty)
        #expect(model.selectedFileIndices.isEmpty)
        #expect(model.currentPage == 0)
        #expect(model.skipMode == .file)
        #expect(!model.documentRebuilt)
        #expect(!model.canUndo)
        #expect(model.stride == 4)
        #expect(model.lastBookletOrder?.n == 4)
    }

    @Test("Clearing forgets the document and everything about it")
    func clear() throws {
        let (model, _) = try openedModel(pages: 8)
        model.applyStride()
        model.customFileNames = [0: "Flute"]
        model.baseFileName = "Holst"
        model.toggleSkipPage(3)
        model.currentPage = 6
        model.skipMode = .page
        model.applyBookletOrder(pages: [0, 1, 2, 3], order: coverFirstFrontBackOrder(n: 4))

        model.clear()
        #expect(model.document == nil)
        #expect(model.sourceURL == nil)
        #expect(model.totalPages == 0)
        #expect(model.fileSizes.isEmpty)
        #expect(model.customFileNames.isEmpty)
        #expect(model.baseFileName.isEmpty)
        #expect(model.skippedPages.isEmpty)
        #expect(model.currentPage == 0)
        #expect(model.skipMode == .file)
        #expect(!model.documentRebuilt)
        #expect(model.lastBookletOrder == nil)
        #expect(model.documentBookmarks.isEmpty)
        #expect(!model.canUndo && !model.canRedo)
    }

    @Test("After Swap with Next or Fix Booklet Order, the next PDF is still offered Split Double Pages (#29)")
    func rebuildsDontSuppressTheOffer() throws {
        let (model, _) = try openedModel(pages: 8)
        model.swapCurrentPageWithNext()
        #expect(try openedModel(pages: 3, size: a3Landscape, name: "Scan 1", model: model).suggestion == .splitDoublePages)

        _ = try openedModel(pages: 8, model: model)
        model.applyBookletOrder(pages: model.pagesForFile(0), order: coverFirstFrontBackOrder(n: 8))
        model.applyBookletOrderToAllMatchingFiles(order: coverFirstFrontBackOrder(n: 8), n: 8)
        #expect(try openedModel(pages: 3, size: a3Landscape, name: "Scan 2", model: model).suggestion == .splitDoublePages)
    }

    @Test("A PDF reopened after Split Double Pages is offered it again")
    func reopenAfterScanSplit() throws {
        let (model, _) = try openedModel(pages: 2, size: a3Landscape)
        let url = try #require(model.sourceURL)
        let source = try #require(model.document)
        model.applyScanSplit(ScanSplitChoice(layouts: [.split(at: 0.5), .split(at: 0.5)], leftFirst: true,
                                             skippedPages: []), to: source)
        #expect(model.totalPages == 4)
        #expect(model.load(from: url) == .splitDoublePages)
        #expect(model.totalPages == 2)
    }
}

@MainActor
@Suite("Split model: split points and skips")
struct SplitModelEditTests {

    @Test("Space splits a file, and at a file's first page merges it back")
    func toggleSplit() throws {
        let (model, _) = try openedModel(pages: 8)
        model.toggleSplitAt(page: 3)
        #expect(model.fileSizes == [3, 5])
        #expect(model.splitMarkers == [3])
        #expect(model.numberOfFiles == 2)
        #expect(model.canContinueToNaming)
        model.toggleSplitAt(page: 3)
        #expect(model.fileSizes == [8])
        #expect(model.splitMarkers.isEmpty)
    }

    @Test("Names stay with the page their file starts on")
    func namesFollowTheirFile() throws {
        let (model, _) = try openedModel(pages: 8)
        model.toggleSplitAt(page: 4)                 // [4, 4]
        model.customFileNames = [0: "Flute", 1: "Oboe"]
        model.toggleSplitAt(page: 2)                 // [2, 2, 4]: Oboe's file is now the third
        #expect(model.fileSizes == [2, 2, 4])
        #expect(model.customFileNames[0] == "Flute")
        #expect(model.customFileNames[1] == nil)
        #expect(model.customFileNames[2] == "Oboe")
    }

    @Test("Apply strides from scratch; Re-stride keeps the files before the current page")
    func strides() throws {
        let (model, _) = try openedModel(pages: 12)
        model.toggleSkipPage(1)
        model.stride = 4
        model.applyStride()
        #expect(model.fileSizes == [4, 4, 4])
        #expect(model.skippedPages.isEmpty)

        model.customFileNames = [0: "Piccolo", 1: "Flute", 2: "Oboe"]
        model.currentPage = 3                        // the piccolo part is only 3 pages
        model.restrideFromCurrentPage()
        #expect(model.fileSizes == [3, 4, 4, 1])
        #expect(model.customFileNames == [0: "Piccolo"])
    }

    @Test("Clear All: one file again, names and skips gone, and it can be undone")
    func clearAllSplits() throws {
        let (model, _) = try openedModel(pages: 6)
        model.toggleSplitAt(page: 2)
        model.customFileNames = [1: "Horn"]
        model.toggleSkipPage(0)
        model.clearAllSplits()
        #expect(model.fileSizes == [6])
        #expect(model.customFileNames.isEmpty)
        #expect(model.skippedPages.isEmpty)
        model.undo()
        #expect(model.fileSizes == [2, 4])
        #expect(model.skippedPages == [0])
        #expect(model.customFileNames == [1: "Horn"])
    }

    @Test("Skipping a page, and un-skipping it")
    func skipPage() throws {
        let (model, _) = try openedModel(pages: 4)
        model.toggleSplitAt(page: 2)                 // [2, 2]
        model.toggleSkipPage(3)
        #expect(model.skippedPages == [3])
        #expect(model.isFilePartiallySkipped(1))
        #expect(!model.isFileFullySkipped(1))
        model.toggleSkipPage(3)
        #expect(model.skippedPages.isEmpty)
    }

    @Test("Skipping files: all skipped unless every one already is, then all un-skipped")
    func skipFiles() throws {
        let (model, _) = try openedModel(pages: 6)
        model.toggleSplitAt(page: 2)
        model.toggleSplitAt(page: 4)                 // [2, 2, 2]
        model.selectFile(1, command: false, shift: false)
        model.toggleSkipFiles([1])
        #expect(model.skippedPages == [2, 3])
        #expect(model.skippedFileIndices == [1])
        #expect(model.activeFileCount == 2)
        #expect(model.selectedFileIndices.isEmpty)

        model.toggleSkipFiles([1, 2])                // file 2 isn't skipped yet: skip both
        #expect(model.skippedPages == [2, 3, 4, 5])
        model.toggleSkipFiles([1, 2])                // both are: un-skip both
        #expect(model.skippedPages.isEmpty)

        model.toggleSkipFiles([0, 1, 2])
        #expect(model.activeFileCount == 0)
        #expect(!model.canContinueToNaming)
    }

    @Test("Delete skips the current page in page mode, the selected files or current file in file mode")
    func deleteKey() throws {
        let (model, _) = try openedModel(pages: 6)
        model.toggleSplitAt(page: 2)
        model.toggleSplitAt(page: 4)                 // [2, 2, 2]

        model.currentPage = 3
        model.toggleSkipForDeleteKey()               // file mode, nothing selected: page 3's file
        #expect(model.skippedPages == [2, 3])

        model.selectFile(0, command: false, shift: false)
        model.selectFile(2, command: true, shift: false)
        #expect(model.selectedFileIndices == [0, 2])
        model.toggleSkipForDeleteKey()               // the selected files
        #expect(model.skippedPages == [0, 1, 2, 3, 4, 5])

        model.skipMode = .page
        model.currentPage = 4
        model.toggleSkipForDeleteKey()
        #expect(model.skippedPages == [0, 1, 2, 3, 5])
    }

    @Test("Bookmarks replace the split like a fresh load, naming the files from their titles")
    func bookmarks() throws {
        let (model, _) = try openedModel(pages: 6, name: "Sousa")
        model.toggleSkipPage(1)
        let sections = [BookmarkSection(startPage: 0, pageCount: 2, title: "Sousa - Liberty Bell - Flute"),
                        BookmarkSection(startPage: 2, pageCount: 4, title: "Sousa - Liberty Bell - Tuba")]
        model.applyBookmarks(sections, nameStyle: .pieceAndTitle)
        #expect(model.fileSizes == [2, 4])
        #expect(model.baseFileName == "Sousa - Liberty Bell")
        #expect(model.customFileNames == [0: "Flute", 1: "Tuba"])
        #expect(model.skippedPages.isEmpty)
        #expect(!model.canUndo)

        model.applyBookmarks(sections, nameStyle: nil)  // Split Only
        #expect(model.baseFileName == "Sousa")
        #expect(model.customFileNames.isEmpty)

        // Sections that don't cover the document are refused.
        model.applyBookmarks([BookmarkSection(startPage: 0, pageCount: 2, title: "A")], nameStyle: nil)
        #expect(model.fileSizes == [2, 4])
    }

    @Test("Arrows move between pages and files, and ⇧ grows the selection")
    func navigation() throws {
        let (model, _) = try openedModel(pages: 6)
        model.toggleSplitAt(page: 2)
        model.toggleSplitAt(page: 4)                 // [2, 2, 2]
        model.goToNextPage()
        #expect(model.currentPage == 1)
        #expect(model.selectedFileIndices == [0])
        model.goToNextFile()
        #expect(model.currentPage == 2)
        #expect(model.selectedFileIndices == [1])
        model.goToNextFile(extendingSelection: true)
        #expect(model.currentPage == 4)
        #expect(model.selectedFileIndices == [1, 2])
        model.goToNextFile()                         // no file after the last: stays
        #expect(model.currentPage == 4)
        model.goToPreviousFile()
        #expect(model.currentPage == 2)
        model.goToNextPage(toLast: true)
        #expect(model.currentPage == 5)
        model.goToPreviousPage(toFirst: true)
        #expect(model.currentPage == 0)
        #expect(model.selectedFileIndices == [0])
        model.selectFile(2, command: false, shift: false)
        #expect(model.currentPage == 4)
        model.selectFile(0, command: false, shift: true)
        #expect(model.selectedFileIndices == [0, 1, 2])
    }
}

@MainActor
@Suite("Split model: undo and redo")
struct SplitModelUndoTests {

    @Test("Undo and redo step through splits, skips and names")
    func undoRedo() throws {
        let (model, _) = try openedModel(pages: 8)
        model.toggleSplitAt(page: 2)
        model.customFileNames = [1: "Clarinet"]
        model.toggleSkipPage(5)
        model.selectFile(1, command: false, shift: false)

        model.undo()
        #expect(model.skippedPages.isEmpty)
        #expect(model.fileSizes == [2, 6])
        #expect(model.customFileNames == [1: "Clarinet"])
        #expect(model.selectedFileIndices.isEmpty)
        model.undo()
        #expect(model.fileSizes == [8])
        #expect(model.customFileNames.isEmpty)
        #expect(!model.canUndo)
        model.undo()                                 // nothing left: no change
        #expect(model.fileSizes == [8])

        model.redo()
        #expect(model.fileSizes == [2, 6])
        #expect(model.customFileNames == [1: "Clarinet"])
        model.redo()
        #expect(model.skippedPages == [5])
        #expect(!model.canRedo)

        model.undo()
        model.toggleSplitAt(page: 4)                 // a new edit drops what could be redone
        #expect(!model.canRedo)
    }

    @Test("Undo keeps the last 50 edits")
    func undoLimit() throws {
        let (model, _) = try openedModel(pages: 4)
        for _ in 0..<55 { model.toggleSkipPage(1) }
        var undos = 0
        while model.canUndo { model.undo(); undos += 1 }
        #expect(undos == 50)
    }

    @Test("Rebuilds and bookmarks start a new undo history")
    func rebuildsClearUndo() throws {
        let (model, _) = try openedModel(pages: 8)
        model.toggleSplitAt(page: 4)
        model.swapCurrentPageWithNext()
        #expect(!model.canUndo)
        model.toggleSplitAt(page: 2)
        model.applyBookletOrder(pages: model.pagesForFile(2), order: coverFirstFrontBackOrder(n: 4))
        #expect(!model.canUndo)
        model.toggleSplitAt(page: 6)
        model.undo()
        model.applyBookletOrderToAllMatchingFiles(order: coverFirstFrontBackOrder(n: 4), n: 4)
        #expect(!model.canUndo && !model.canRedo)
    }
}

@MainActor
@Suite("Split model: rebuilding the document")
struct SplitModelRebuildTests {

    @Test("Swap with Next swaps two pages and keeps the split, names, skips and current page")
    func swapWithNext() throws {
        let (model, _) = try openedModel(pages: 4)
        let original = pageObjects(model)
        model.toggleSplitAt(page: 2)                 // [2, 2]
        model.customFileNames = [0: "Trumpet", 1: "Horn"]
        model.toggleSkipPage(3)
        model.currentPage = 1

        model.swapCurrentPageWithNext()
        let now = pageObjects(model)
        #expect(now.count == 4)
        #expect(now[0] === original[0])
        #expect(now[1] === original[2])
        #expect(now[2] === original[1])
        #expect(now[3] === original[3])
        #expect(model.fileSizes == [2, 2])
        #expect(model.customFileNames == [0: "Trumpet", 1: "Horn"])
        #expect(model.skippedPages == [3])
        #expect(model.currentPage == 1)
        #expect(model.documentRebuilt)
        #expect(model.baseFileName == "Holst Suite")
        #expect(model.sourceURL?.lastPathComponent == "Holst Suite.pdf")
    }

    @Test("Swap with Next does nothing on the last page")
    func swapOnLastPage() throws {
        let (model, _) = try openedModel(pages: 3)
        let before = model.document
        model.currentPage = 2
        model.swapCurrentPageWithNext()
        #expect(model.document === before)
        #expect(!model.documentRebuilt)
    }

    @Test("Fix Booklet Order reorders one file; names stay with their parts and skips move with their pages")
    func bookletOrder() throws {
        let (model, _) = try openedModel(pages: 12)
        let original = pageObjects(model)
        model.toggleSplitAt(page: 4)                 // [4, 8]: a score, then an 8-page booklet
        model.customFileNames = [0: "Score", 1: "Flute"]
        model.toggleSkipPage(4)                      // the booklet's first scan
        model.toggleSkipPage(1)                      // a page outside it

        let order = coverFirstFrontBackOrder(n: 8)   // [1, 2, 5, 6, 7, 4, 3, 0]
        let pages = model.pagesForFile(1)
        model.applyBookletOrder(pages: pages, order: order)

        let now = pageObjects(model)
        for i in 0..<4 { #expect(now[i] === original[i]) }
        for (readingPos, scanPos) in order.enumerated() {
            #expect(now[4 + readingPos] === original[4 + scanPos])
        }
        #expect(model.fileSizes == [4, 8])
        #expect(model.customFileNames == [0: "Score", 1: "Flute"])
        // Scan 0 is read last, so its skip moves to the booklet's last page.
        #expect(model.skippedPages == [1, 11])
        #expect(model.lastBookletOrder == SplitBookletOrder(n: 8, order: order))
        #expect(model.documentRebuilt)
        #expect(model.canContinueToNaming)
    }

    @Test("Apply to All reorders every file of that length and leaves the others alone")
    func bookletOrderToAll() throws {
        let (model, _) = try openedModel(pages: 10)
        let original = pageObjects(model)
        model.toggleSplitAt(page: 4)
        model.toggleSplitAt(page: 6)                 // [4, 2, 4]
        model.customFileNames = [0: "Flute", 1: "Notes", 2: "Oboe"]
        model.toggleSkipPage(6)                      // the second booklet's first scan

        let order = coverFirstFrontBackOrder(n: 4)   // [1, 2, 3, 0]
        model.applyBookletOrderToAllMatchingFiles(order: order, n: 4)

        let now = pageObjects(model)
        for (readingPos, scanPos) in order.enumerated() {
            #expect(now[readingPos] === original[scanPos])
            #expect(now[6 + readingPos] === original[6 + scanPos])
        }
        #expect(now[4] === original[4])
        #expect(now[5] === original[5])
        #expect(model.fileSizes == [4, 2, 4])
        #expect(model.customFileNames == [0: "Flute", 1: "Notes", 2: "Oboe"])
        #expect(model.skippedPages == [9])
        #expect(model.lastBookletOrder == SplitBookletOrder(n: 4, order: order))
    }

    @Test("Split Double Pages starts the split afresh, then skips the marked pieces page by page")
    func scanSplit() throws {
        let (model, suggestion) = try openedModel(pages: 3, size: a3Landscape, name: "Band Scan")
        #expect(suggestion == .splitDoublePages)
        // Work done before splitting refers to the old pages, so it goes.
        model.toggleSplitAt(page: 1)
        model.customFileNames = [1: "Flute"]
        model.baseFileName = "Edited"
        model.currentPage = 2
        model.stride = 3
        let source = try #require(model.document)

        let choice = ScanSplitChoice(layouts: [.split(at: 0.5), .single, .split(at: 0.5)],
                                     leftFirst: true, skippedPages: [2, 9])
        let split = try #require(model.applyScanSplit(choice, to: source))
        #expect(split.pageCount == 5)
        #expect(model.document === split)
        #expect(model.fileSizes == [5])
        #expect(model.customFileNames.isEmpty)
        #expect(model.baseFileName == "Band Scan")
        #expect(model.currentPage == 0)
        #expect(model.skippedPages == [2])           // out-of-range skips are dropped
        #expect(model.skipMode == .page)
        #expect(model.documentRebuilt)
        #expect(model.canContinueToNaming)
        #expect(!model.canUndo)
        #expect(model.stride == 3)
        #expect(model.sourceURL?.lastPathComponent == "Band Scan.pdf")
    }

    @Test("Split Double Pages that cuts nothing and skips nothing leaves everything alone")
    func scanSplitNothingToDo() throws {
        let (model, _) = try openedModel(pages: 2, size: a3Landscape)
        model.toggleSplitAt(page: 1)
        let source = try #require(model.document)
        let choice = ScanSplitChoice(layouts: [.single, .single], leftFirst: true, skippedPages: [])
        #expect(model.applyScanSplit(choice, to: source) == nil)
        #expect(model.document === source)
        #expect(model.fileSizes == [1, 1])
        #expect(!model.documentRebuilt)
        #expect(model.canUndo)
    }
}

@MainActor
@Suite("Split model: Suggest Splits")
struct SplitModelSuggestionTests {

    @Test("Start pages become file sizes; anything that doesn't fit the document is refused")
    func sizesFromStarts() {
        #expect(splitSizes(startPages: [0, 4, 9], totalPages: 12) == [4, 5, 3])
        #expect(splitSizes(startPages: [0], totalPages: 5) == [5])
        #expect(splitSizes(startPages: [1, 4], totalPages: 8) == nil)      // must start on page 1
        #expect(splitSizes(startPages: [0, 4, 4], totalPages: 8) == nil)   // in order, no repeats
        #expect(splitSizes(startPages: [0, 8], totalPages: 8) == nil)      // inside the document
        #expect(splitSizes(startPages: [], totalPages: 8) == nil)
    }

    @Test("Applying a suggestion splits and names the files, keeps skips, and undoes in one step")
    func apply() throws {
        let (model, _) = try openedModel(pages: 10)
        model.toggleSkipPage(9)
        model.toggleSplitAt(page: 5)
        model.customFileNames = [0: "Old"]
        let parts = [SuggestedPart(startPage: 0, name: "Horn"), SuggestedPart(startPage: 4, name: "Trumpet 1"),
                     SuggestedPart(startPage: 7, name: "")]
        #expect(model.applySuggestedParts(parts))
        #expect(model.fileSizes == [4, 3, 3])
        #expect(model.customFileNames == [0: "Horn", 1: "Trumpet 1"])   // the unread name stays numbered
        #expect(model.skippedPages == [9])
        #expect(model.canContinueToNaming)

        model.undo()
        #expect(model.fileSizes == [5, 5])
        #expect(model.customFileNames == [0: "Old"])
        model.redo()
        #expect(model.fileSizes == [4, 3, 3])
    }

    @Test("A suggestion that doesn't fit changes nothing; names are made file-name safe")
    func refuseAndSanitise() throws {
        let (model, _) = try openedModel(pages: 6)
        #expect(!model.applySuggestedParts([SuggestedPart(startPage: 0, name: "Flute"), SuggestedPart(startPage: 9, name: "Oboe")]))
        #expect(model.fileSizes == [6])
        #expect(!model.canUndo)
        #expect(model.applySuggestedParts([SuggestedPart(startPage: 0, name: "Flute 1/2"), SuggestedPart(startPage: 3, name: "Oboe")]))
        #expect(model.customFileNames[0] == "Flute 1-2")
    }

    @Test("Reading a PDF with no text suggests nothing and says why, whether or not Vision runs here")
    func readsNothing() async throws {
        let url = temporaryFolder("suggest").appendingPathComponent("Blank.pdf")
        writeDrawnPDF(pages: 3, size: a4, to: url)
        let doc = try #require(PDFDocument(url: url))
        let suggestion = SplitSuggestion(document: doc, ensemble: .band)
        await suggestion.start()
        let reading = try #require(suggestion.reading)
        #expect(suggestion.parts == nil)
        #expect(reading.problem != nil)
        #expect(suggestion.read == 3)
    }
}
