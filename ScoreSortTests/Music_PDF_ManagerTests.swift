//
//  ScoreSortTests.swift
//  ScoreSortTests
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

// MARK: - Shared test helpers

/// Writes a real PDF with `pages` blank pages to `url` using PDFKit.
/// Used wherever a test needs PDFDocument(url:) to succeed and return a non-zero page count.
func writePDF(pages: Int, to url: URL) {
    let doc = PDFDocument()
    for i in 0..<pages { doc.insert(PDFPage(), at: i) }
    doc.write(to: url)
}

// MARK: - Filename Validation
// Tests for pdfFilenameError(for:) — the shared validation used in the Split tab
// to catch characters that are illegal in macOS filenames.

@Suite("Filename Validation")
struct FilenameValidationTests {

    @Test func validFilenameReturnsNil() {
        #expect(pdfFilenameError(for: "Symphony No 5") == nil)
    }

    @Test func emptyStringReturnsNil() {
        // Empty suffix is allowed — the app auto-numbers in that case
        #expect(pdfFilenameError(for: "") == nil)
    }

    @Test func slashIsIllegal() {
        #expect(pdfFilenameError(for: "path/name") != nil)
    }

    @Test func colonIsIllegal() {
        #expect(pdfFilenameError(for: "name:thing") != nil)
    }

    @Test func backslashIsIllegal() {
        #expect(pdfFilenameError(for: "name\\thing") != nil)
    }

    @Test func nullCharacterIsIllegal() {
        #expect(pdfFilenameError(for: "name\0thing") != nil)
    }

    @Test func spacesAndNumbersAreAllowed() {
        #expect(pdfFilenameError(for: "Flute 1") == nil)
    }

    @Test func hyphenAndDotAreAllowed() {
        #expect(pdfFilenameError(for: "Mvt. 1 - Allegro") == nil)
    }
}

// MARK: - Instrument Detection
// Tests for RenamerManager.detectInstrument(in:)
// This is the core logic of the Renamer tab — it matches instrument names in
// filenames and returns the instrument's position in the ordering list.

@Suite("Instrument Detection")
struct InstrumentDetectionTests {

    // Each test creates a fresh manager and sets a small custom order so
    // we're testing the detection logic in isolation, not the full instrument list.

    @Test func detectsSimpleInstrument() {
        let manager = RenamerManager()
        manager.customInstrumentOrder = ["flute", "clarinet", "trumpet"]
        let result = manager.detectInstrument(in: "Flute Part.pdf")
        #expect(result != nil)
        #expect(result?.1 == "flute")
    }

    @Test func detectionIsCaseInsensitive() {
        let manager = RenamerManager()
        manager.customInstrumentOrder = ["flute"]
        // Filename is mixed case; instrument list is lowercase
        #expect(manager.detectInstrument(in: "FLUTE 1.pdf") != nil)
        #expect(manager.detectInstrument(in: "Flute.pdf") != nil)
    }

    @Test func returnsNilWhenNoMatch() {
        let manager = RenamerManager()
        manager.customInstrumentOrder = ["flute", "clarinet"]
        #expect(manager.detectInstrument(in: "Untitled Score.pdf") == nil)
    }

    @Test func returnsLeftmostMatchNotLongest() {
        // "Baritone BC Bassoon.pdf" — baritone appears before bassoon,
        // so baritone should win even though both match.
        let manager = RenamerManager()
        manager.customInstrumentOrder = ["baritone", "bassoon"]
        let result = manager.detectInstrument(in: "Baritone BC Bassoon.pdf")
        #expect(result?.1 == "baritone")
    }

    @Test func longerInstrumentBeatsSubstring() {
        // "Bass Clarinet Part.pdf" — both "clarinet" and "bass clarinet" match,
        // but the length-sort means "bass clarinet" is tried first and wins
        // because it appears at the same (or earlier) position.
        let manager = RenamerManager()
        manager.customInstrumentOrder = ["clarinet", "bass clarinet"]
        let result = manager.detectInstrument(in: "Bass Clarinet Part.pdf")
        #expect(result?.1 == "bass clarinet")
    }

    @Test func orderIndexReflectsCustomList() {
        // The returned index should be the position in customInstrumentOrder,
        // which is used to sort files into the right score order.
        let manager = RenamerManager()
        manager.customInstrumentOrder = ["flute", "oboe", "clarinet"]
        let fluteResult = manager.detectInstrument(in: "Flute.pdf")
        let clarResult  = manager.detectInstrument(in: "Clarinet.pdf")
        let fluteIndex  = try! #require(fluteResult).0
        let clarIndex   = try! #require(clarResult).0
        #expect(fluteIndex < clarIndex)
    }
}

// MARK: - Manual Override
// Tests for RenamerManager.setManualOverride(for:number:)
// Manual overrides let the user pin a specific file to a specific number.
// When a conflict arises the existing overrides shift up to make room.

@Suite("Manual Override")
struct ManualOverrideTests {

    @Test func assignsNumberToFile() {
        let manager = RenamerManager()
        manager.setManualOverride(for: "Flute.pdf", number: 3)
        #expect(manager.manualOverrides["Flute.pdf"] == 3)
    }

    @Test func replacesExistingOverrideForSameFile() {
        let manager = RenamerManager()
        manager.setManualOverride(for: "Flute.pdf", number: 3)
        manager.setManualOverride(for: "Flute.pdf", number: 5)
        #expect(manager.manualOverrides["Flute.pdf"] == 5)
        // Should only have one entry for this file
        #expect(manager.manualOverrides.filter { $0.value == 3 }.isEmpty)
    }

    @Test func conflictingNumberShiftsExistingOverride() {
        let manager = RenamerManager()
        manager.setManualOverride(for: "Clarinet.pdf", number: 3)
        // Assigning 3 again for a different file should push Clarinet to 4
        manager.setManualOverride(for: "Flute.pdf", number: 3)
        #expect(manager.manualOverrides["Flute.pdf"] == 3)
        #expect(manager.manualOverrides["Clarinet.pdf"] == 4)
    }

    @Test func conflictShiftsChainOfOverrides() {
        let manager = RenamerManager()
        manager.setManualOverride(for: "File A.pdf", number: 3)
        manager.setManualOverride(for: "File B.pdf", number: 4)
        // Inserting at 3 should push both A and B up
        manager.setManualOverride(for: "File C.pdf", number: 3)
        #expect(manager.manualOverrides["File C.pdf"] == 3)
        #expect(manager.manualOverrides["File A.pdf"] == 4)
        #expect(manager.manualOverrides["File B.pdf"] == 5)
    }
}

// MARK: - Scan Folder
// Tests for the full scanFolder() pipeline, exercised via loadFolder(url:).
// We create real (but empty-content) PDF files in a temp directory so the
// scanner has something to find.

@Suite("Scan Folder")
struct ScanFolderTests {

    // Creates a temporary directory and removes it after each test.
    var tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    // Creates a minimal valid-ish PDF file at the given filename.
    // PDFKit won't choke — the renamer only cares about filenames, not content.
    @discardableResult
    func makePDFFile(named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let minimalPDF = "%PDF-1.4\n%%EOF\n"
        try minimalPDF.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test mutating func scoreFileGetsPrefix00() throws {
        try makePDFFile(named: "Score.pdf")
        let manager = RenamerManager()
        manager.customInstrumentOrder = ["score", "flute"]
        manager.loadFolder(url: tempDir)

        let op = try #require(manager.operations.first { $0.originalName == "Score.pdf" })
        #expect(op.newName.hasPrefix("00"))
    }

    @Test mutating func detectedFilesGetSequentialPrefixes() throws {
        try makePDFFile(named: "Flute.pdf")
        try makePDFFile(named: "Clarinet.pdf")
        let manager = RenamerManager()
        manager.customInstrumentOrder = ["flute", "clarinet"]
        manager.loadFolder(url: tempDir)

        let fluteOp  = try #require(manager.operations.first { $0.originalName == "Flute.pdf" })
        let clarOp   = try #require(manager.operations.first { $0.originalName == "Clarinet.pdf" })
        #expect(fluteOp.newName.hasPrefix("01"))
        #expect(clarOp.newName.hasPrefix("02"))
    }

    @Test mutating func unrecognisedFileIsMarkedUndetected() throws {
        try makePDFFile(named: "Mystery Part.pdf")
        let manager = RenamerManager()
        manager.customInstrumentOrder = ["flute", "clarinet"]
        manager.loadFolder(url: tempDir)

        let op = try #require(manager.operations.first { $0.originalName == "Mystery Part.pdf" })
        #expect(op.type == .undetected)
    }

    @Test mutating func manualOverrideIsRespected() throws {
        try makePDFFile(named: "Flute.pdf")
        let manager = RenamerManager()
        manager.customInstrumentOrder = ["flute"]
        manager.loadFolder(url: tempDir)           // load first — as in real usage
        manager.setManualOverride(for: "Flute.pdf", number: 5)

        let op = try #require(manager.operations.first { $0.originalName == "Flute.pdf" })
        #expect(op.newName.hasPrefix("05"))
        #expect(op.type == .manual)
    }

    @Test mutating func alreadyPrefixedFileSkippedInNormalMode() throws {
        try makePDFFile(named: "01 - Flute.pdf")
        let manager = RenamerManager()
        manager.customInstrumentOrder = ["flute"]
        manager.loadFolder(url: tempDir)

        let op = try #require(manager.operations.first { $0.originalName == "01 - Flute.pdf" })
        #expect(op.type == .alreadyPrefixed)
    }
}

// MARK: - Split Logic
// Tests for the two pure functions that power the Split tab's file-division model.
// fileSizes is a [Int] where each element is the page count of one output file.
// e.g. [4] = one 4-page file; [2, 2] = two 2-page files.

@Suite("Split Logic – toggleSplit")
struct ToggleSplitTests {

    @Test func splitMidFileDividesItInTwo() {
        // [4] split at page 2 → [2, 2]
        let result = toggleSplit(in: [4], at: 2)
        #expect(result == [2, 2])
    }

    @Test func splitAtBoundaryMergesFiles() {
        // [2, 2] with toggle at page 2 (the start of the second file) → [4]
        let result = toggleSplit(in: [2, 2], at: 2)
        #expect(result == [4])
    }

    @Test func splitAtPageZeroIsNoOp() {
        // Page 0 is the very start of the document — no merge is possible before it
        let result = toggleSplit(in: [4], at: 0)
        #expect(result == [4])
    }

    @Test func splitAtFirstPageOfFirstFileIsNoOp() {
        // Can't merge file 0 with the file before it — there isn't one
        let result = toggleSplit(in: [2, 2], at: 0)
        #expect(result == [2, 2])
    }

    @Test func splitInMiddleOfMultiFileDocument() {
        // [2, 4, 2] split at page 4 (inside the second file, local offset 2) → [2, 2, 2, 2]
        let result = toggleSplit(in: [2, 4, 2], at: 4)
        #expect(result == [2, 2, 2, 2])
    }

    @Test func mergeMiddleBoundaryInMultiFileDocument() {
        // [2, 2, 2, 2] toggle at page 4 (start of third file) → [2, 4, 2]
        let result = toggleSplit(in: [2, 2, 2, 2], at: 4)
        #expect(result == [2, 4, 2])
    }

    @Test func emptyArrayIsUnchanged() {
        let result = toggleSplit(in: [], at: 1)
        #expect(result == [])
    }

    @Test func splitAtLastPageProducesTrailingOnePage() {
        // [4] split at page 3 → [3, 1]
        let result = toggleSplit(in: [4], at: 3)
        #expect(result == [3, 1])
    }

    @Test func splitAtPageOneProducesLeadingOnePage() {
        // [4] split at page 1 → [1, 3]
        let result = toggleSplit(in: [4], at: 1)
        #expect(result == [1, 3])
    }
}

@Suite("Split Logic – splitSizes")
struct SplitSizesTests {

    @Test func evenDivision() {
        // 8 pages at stride 2 → four 2-page files
        #expect(splitSizes(totalPages: 8, stride: 2) == [2, 2, 2, 2])
    }

    @Test func unevenDivisionLastChunkTakesRemainder() {
        // 7 pages at stride 2 → [2, 2, 2, 1]
        #expect(splitSizes(totalPages: 7, stride: 2) == [2, 2, 2, 1])
    }

    @Test func strideLargerThanTotalPages() {
        // stride > total → single file with all pages
        #expect(splitSizes(totalPages: 3, stride: 10) == [3])
    }

    @Test func strideEqualsTotal() {
        #expect(splitSizes(totalPages: 4, stride: 4) == [4])
    }

    @Test func zeroPagesReturnsEmpty() {
        #expect(splitSizes(totalPages: 0, stride: 2) == [])
    }

    @Test func strideLargerChunk() {
        // 10 pages at stride 4 → [4, 4, 2]
        #expect(splitSizes(totalPages: 10, stride: 4) == [4, 4, 2])
    }
}

// MARK: - Combine Manager
// Tests for CombineManager — the model behind the Combine tab.
// Most tests construct CombineFile values directly and assign them to manager.files,
// so they don't need real PDF files on disk.
//
// Note: createCombinedPDF is tested below. The method uses a completion callback
// for result reporting so tests can capture results without any UI interaction.

@Suite("Combine Manager")
struct CombineManagerTests {

    // MARK: Helpers

    // Create a CombineFile without going through addFiles — lets us control
    // pageCount and copies directly without needing a real PDF on disk.
    func makeFile(name: String, pageCount: Int, copies: Int = 1) -> CombineFile {
        CombineFile(url: URL(fileURLWithPath: "/dev/null"), name: name, pageCount: pageCount, copies: copies)
    }

    // MARK: - Computed properties

    @Test func totalFilesCountsCopies() {
        let manager = CombineManager()
        manager.files = [
            makeFile(name: "A.pdf", pageCount: 4, copies: 2),
            makeFile(name: "B.pdf", pageCount: 2, copies: 3),
        ]
        #expect(manager.totalFiles == 5)
    }

    @Test func totalPagesMultipliesPageCountByCopies() {
        let manager = CombineManager()
        manager.files = [
            makeFile(name: "A.pdf", pageCount: 4, copies: 2),  // 8
            makeFile(name: "B.pdf", pageCount: 3, copies: 1),  // 3
        ]
        #expect(manager.totalPages == 11)
    }

    @Test func emptyManagerHasZeroTotals() {
        let manager = CombineManager()
        #expect(manager.totalFiles == 0)
        #expect(manager.totalPages == 0)
    }

    // MARK: - addFiles

    @Test func addFilesPopulatesListAndTotals() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("Test.pdf")
        writePDF(pages: 4, to: url)

        let manager = CombineManager()
        manager.addFiles(urls: [url], undoManager: nil)

        #expect(manager.files.count == 1)
        #expect(manager.files.first?.pageCount == 4)
        #expect(manager.totalPages == 4)
        #expect(manager.totalFiles == 1)
    }

    @Test func addFilesIgnoresNonPDFURLs() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // A plain text file — PDFDocument(url:) will return nil and it should be skipped
        let url = tempDir.appendingPathComponent("notes.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)

        let manager = CombineManager()
        manager.addFiles(urls: [url], undoManager: nil)

        #expect(manager.files.isEmpty)
    }

    // MARK: - removeFiles

    @Test func removeFilesByID() {
        let manager = CombineManager()
        let a = makeFile(name: "A.pdf", pageCount: 2)
        let b = makeFile(name: "B.pdf", pageCount: 3)
        let c = makeFile(name: "C.pdf", pageCount: 1)
        manager.files = [a, b, c]

        manager.removeFiles(ids: [b.id], undoManager: nil)

        #expect(manager.files.count == 2)
        #expect(manager.files.map(\.name) == ["A.pdf", "C.pdf"])
    }

    @Test func removeAllFiles() {
        let manager = CombineManager()
        manager.files = [makeFile(name: "A.pdf", pageCount: 2), makeFile(name: "B.pdf", pageCount: 3)]
        manager.clearAll(undoManager: nil)
        #expect(manager.files.isEmpty)
    }

    // MARK: - updateCopies

    @Test func updateCopiesChangesTotalPages() {
        let manager = CombineManager()
        let file = makeFile(name: "A.pdf", pageCount: 4, copies: 1)
        manager.files = [file]

        manager.updateCopies(for: file.id, copies: 3, undoManager: nil)

        #expect(manager.files.first?.copies == 3)
        #expect(manager.totalPages == 12)
    }

    @Test func updateCopiesBelowOneClampedToOne() {
        let manager = CombineManager()
        let file = makeFile(name: "A.pdf", pageCount: 4, copies: 2)
        manager.files = [file]

        manager.updateCopies(for: file.id, copies: 0, undoManager: nil)

        #expect(manager.files.first?.copies == 1)
    }

    // MARK: - moveUp / moveDown

    @Test func moveUpShiftsFileEarlier() {
        let manager = CombineManager()
        let a = makeFile(name: "A.pdf", pageCount: 1)
        let b = makeFile(name: "B.pdf", pageCount: 1)
        let c = makeFile(name: "C.pdf", pageCount: 1)
        manager.files = [a, b, c]

        manager.moveUp(ids: [c.id], undoManager: nil)

        #expect(manager.files.map(\.name) == ["A.pdf", "C.pdf", "B.pdf"])
    }

    @Test func moveUpFirstFileIsNoOp() {
        let manager = CombineManager()
        let a = makeFile(name: "A.pdf", pageCount: 1)
        let b = makeFile(name: "B.pdf", pageCount: 1)
        manager.files = [a, b]

        manager.moveUp(ids: [a.id], undoManager: nil)

        #expect(manager.files.map(\.name) == ["A.pdf", "B.pdf"])
    }

    @Test func moveDownShiftsFileLater() {
        let manager = CombineManager()
        let a = makeFile(name: "A.pdf", pageCount: 1)
        let b = makeFile(name: "B.pdf", pageCount: 1)
        let c = makeFile(name: "C.pdf", pageCount: 1)
        manager.files = [a, b, c]

        manager.moveDown(ids: [a.id], undoManager: nil)

        #expect(manager.files.map(\.name) == ["B.pdf", "A.pdf", "C.pdf"])
    }

    @Test func moveDownLastFileIsNoOp() {
        let manager = CombineManager()
        let a = makeFile(name: "A.pdf", pageCount: 1)
        let b = makeFile(name: "B.pdf", pageCount: 1)
        manager.files = [a, b]

        manager.moveDown(ids: [b.id], undoManager: nil)

        #expect(manager.files.map(\.name) == ["A.pdf", "B.pdf"])
    }

    @Test func moveUpAdjacentSelectionMovesAsBlock() {
        // B and C are both selected — they should move together, not pass through each other
        let manager = CombineManager()
        let a = makeFile(name: "A.pdf", pageCount: 1)
        let b = makeFile(name: "B.pdf", pageCount: 1)
        let c = makeFile(name: "C.pdf", pageCount: 1)
        let d = makeFile(name: "D.pdf", pageCount: 1)
        manager.files = [a, b, c, d]

        manager.moveUp(ids: [b.id, c.id], undoManager: nil)

        #expect(manager.files.map(\.name) == ["B.pdf", "C.pdf", "A.pdf", "D.pdf"])
    }

    @Test func moveDownAdjacentSelectionMovesAsBlock() {
        let manager = CombineManager()
        let a = makeFile(name: "A.pdf", pageCount: 1)
        let b = makeFile(name: "B.pdf", pageCount: 1)
        let c = makeFile(name: "C.pdf", pageCount: 1)
        let d = makeFile(name: "D.pdf", pageCount: 1)
        manager.files = [a, b, c, d]

        manager.moveDown(ids: [b.id, c.id], undoManager: nil)

        #expect(manager.files.map(\.name) == ["A.pdf", "D.pdf", "B.pdf", "C.pdf"])
    }

    // MARK: - createCombinedPDF

    @Test func createCombinedPDFOutputPageCountMatchesTotals() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let urlA = tempDir.appendingPathComponent("A.pdf")
        let urlB = tempDir.appendingPathComponent("B.pdf")
        writePDF(pages: 3, to: urlA)
        writePDF(pages: 2, to: urlB)

        let manager = CombineManager()
        manager.addFiles(urls: [urlA, urlB], undoManager: nil)

        let outURL = tempDir.appendingPathComponent("combined.pdf")
        var resultTitle = ""
        manager.createCombinedPDF(to: outURL, addBlankPages: false) { title, _, _ in
            resultTitle = title
        }

        let result = try #require(PDFDocument(url: outURL))
        #expect(result.pageCount == 5)
        #expect(resultTitle == "PDF Created Successfully")
    }

    @Test func createCombinedPDFInsertsBlanksAfterOddPageFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 3-page file (odd) → should get a blank appended; 2-page file (even) → no blank
        let urlA = tempDir.appendingPathComponent("A.pdf")
        let urlB = tempDir.appendingPathComponent("B.pdf")
        writePDF(pages: 3, to: urlA)
        writePDF(pages: 2, to: urlB)

        let manager = CombineManager()
        manager.addFiles(urls: [urlA, urlB], undoManager: nil)

        let outURL = tempDir.appendingPathComponent("combined_blank.pdf")
        manager.createCombinedPDF(to: outURL, addBlankPages: true) { _, _, _ in }

        // 3 pages + 1 blank + 2 pages = 6
        let result = try #require(PDFDocument(url: outURL))
        #expect(result.pageCount == 6)
    }

    @Test func createCombinedPDFRespectsMultipleCopies() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("A.pdf")
        writePDF(pages: 4, to: url)

        let manager = CombineManager()
        manager.addFiles(urls: [url], undoManager: nil)
        manager.updateCopies(for: manager.files[0].id, copies: 3, undoManager: nil)

        let outURL = tempDir.appendingPathComponent("combined_copies.pdf")
        manager.createCombinedPDF(to: outURL, addBlankPages: false) { _, _, _ in }

        // 4 pages × 3 copies = 12
        let result = try #require(PDFDocument(url: outURL))
        #expect(result.pageCount == 12)
    }
}

// MARK: - PDF Manager
// Tests for PDFManager.saveRotatedPDF and saveSplitPDF.
// Both methods post their completion alerts via DispatchQueue.main.async,
// so they return before the alert fires — no blocking in tests.

@Suite("PDF Manager")
struct PDFManagerTests {

    var tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    /// Writes a PDF to a temp file, loads it into a fresh PDFManager, and returns it.
    func makeManager(pages: Int) -> PDFManager {
        let url = tempDir.appendingPathComponent("\(UUID().uuidString).pdf")
        writePDF(pages: pages, to: url)
        let manager = PDFManager()
        manager.loadPDF(from: url)
        return manager
    }

    // MARK: - saveRotatedPDF

    @Test func baseRotationAppliedToAllPages() throws {
        let manager = makeManager(pages: 4)
        let outURL = tempDir.appendingPathComponent("rotated.pdf")

        manager.saveRotatedPDF(to: outURL, baseRotation: .rotate90,
                               additionalRotationMode: .none, additionalRotationAngle: .none) { _, _, _ in }

        let result = try #require(PDFDocument(url: outURL))
        for i in 0..<result.pageCount {
            #expect(result.page(at: i)?.rotation == 90)
        }
    }

    @Test func saveRotatedPDFDoesNotMutateSourceDocument() throws {
        // Regression guard: pages must be copied, not modified in place.
        // If this fails it means the copy() call was removed from saveRotatedPDF.
        let manager = makeManager(pages: 2)
        let originalDoc = try #require(manager.pdfDocument)
        let originalRotations = (0..<originalDoc.pageCount).compactMap { originalDoc.page(at: $0)?.rotation }

        let outURL = tempDir.appendingPathComponent("rotated.pdf")
        manager.saveRotatedPDF(to: outURL, baseRotation: .rotate90,
                               additionalRotationMode: .none, additionalRotationAngle: .none) { _, _, _ in }

        for i in 0..<originalDoc.pageCount {
            let page = try #require(originalDoc.page(at: i))
            #expect(page.rotation == originalRotations[i])
        }
    }

    @Test func additionalRotationAppliedToOddPagesOnly() throws {
        // Base 90° + additional 90° on odd pages → odd pages 180°, even pages 90°
        let manager = makeManager(pages: 4)
        let outURL = tempDir.appendingPathComponent("odd_rotated.pdf")

        manager.saveRotatedPDF(to: outURL, baseRotation: .rotate90,
                               additionalRotationMode: .odd, additionalRotationAngle: .rotate90) { _, _, _ in }

        let result = try #require(PDFDocument(url: outURL))
        #expect(result.page(at: 0)?.rotation == 180)  // page 1 (odd)
        #expect(result.page(at: 1)?.rotation == 90)   // page 2 (even)
        #expect(result.page(at: 2)?.rotation == 180)  // page 3 (odd)
        #expect(result.page(at: 3)?.rotation == 90)   // page 4 (even)
    }

    @Test func additionalRotationAppliedToEvenPagesOnly() throws {
        // Base 90° + additional 90° on even pages → odd pages 90°, even pages 180°
        let manager = makeManager(pages: 4)
        let outURL = tempDir.appendingPathComponent("even_rotated.pdf")

        manager.saveRotatedPDF(to: outURL, baseRotation: .rotate90,
                               additionalRotationMode: .even, additionalRotationAngle: .rotate90) { _, _, _ in }

        let result = try #require(PDFDocument(url: outURL))
        #expect(result.page(at: 0)?.rotation == 90)   // page 1 (odd)
        #expect(result.page(at: 1)?.rotation == 180)  // page 2 (even)
        #expect(result.page(at: 2)?.rotation == 90)   // page 3 (odd)
        #expect(result.page(at: 3)?.rotation == 180)  // page 4 (even)
    }

    // MARK: - saveSplitPDF

    @Test func splitCreatesCorrectNumberOfFiles() throws {
        let manager = makeManager(pages: 4)
        let outDir = tempDir.appendingPathComponent("split_count")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // [2, 2]: pages 0-1 → file 0, pages 2-3 → file 1
        let mapping: [Int: Int] = [0: 0, 1: 0, 2: 1, 3: 1]
        manager.saveSplitPDF(to: outDir, splitMarkers: [2], baseFileName: "Test",
                             customFileNames: [:], pageToFileMapping: mapping,
                             separator: "_") { _, _, _ in }

        let pdfs = try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pdf" }
        #expect(pdfs.count == 2)
    }

    @Test func splitFilesHaveCorrectPageCounts() throws {
        let manager = makeManager(pages: 6)
        let outDir = tempDir.appendingPathComponent("split_pages")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // [2, 4]: pages 0-1 → file 0, pages 2-5 → file 1
        let mapping: [Int: Int] = [0: 0, 1: 0, 2: 1, 3: 1, 4: 1, 5: 1]
        manager.saveSplitPDF(to: outDir, splitMarkers: [2], baseFileName: "Test",
                             customFileNames: [:], pageToFileMapping: mapping,
                             separator: "_") { _, _, _ in }

        let file1 = try #require(PDFDocument(url: outDir.appendingPathComponent("Test_1.pdf")))
        let file2 = try #require(PDFDocument(url: outDir.appendingPathComponent("Test_2.pdf")))
        #expect(file1.pageCount == 2)
        #expect(file2.pageCount == 4)
    }

    @Test func splitUsesCustomFilenames() throws {
        let manager = makeManager(pages: 4)
        let outDir = tempDir.appendingPathComponent("split_names")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Suffix is just the name part; separator is passed separately.
        let mapping: [Int: Int] = [0: 0, 1: 0, 2: 1, 3: 1]
        manager.saveSplitPDF(to: outDir, splitMarkers: [2], baseFileName: "Sonata",
                             customFileNames: [0: "Mvt1", 1: "Mvt2"], pageToFileMapping: mapping,
                             separator: " ") { _, _, _ in }

        let names = try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pdf" }
            .map(\.lastPathComponent)
            .sorted()
        #expect(names == ["Sonata Mvt1.pdf", "Sonata Mvt2.pdf"])
    }

    @Test func splitAutoNumbersFilesWithoutCustomNames() throws {
        let manager = makeManager(pages: 4)
        let outDir = tempDir.appendingPathComponent("split_autonumber")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let mapping: [Int: Int] = [0: 0, 1: 0, 2: 1, 3: 1]
        manager.saveSplitPDF(to: outDir, splitMarkers: [2], baseFileName: "Part",
                             customFileNames: [:], pageToFileMapping: mapping,
                             separator: "_") { _, _, _ in }

        let names = try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pdf" }
            .map(\.lastPathComponent)
            .sorted()
        #expect(names == ["Part_1.pdf", "Part_2.pdf"])
    }
}

// MARK: - Roman Numeral Normalisation Tests
@Suite("Roman numeral normalisation")
struct RomanNumeralTests {
    @Test("leaves plain strings unchanged")
    func noChange() {
        #expect(normalizeRomanNumerals("flute") == "flute")
        #expect(normalizeRomanNumerals("celli") == "celli")   // no space before i
        #expect(normalizeRomanNumerals("violin") == "violin")
    }

    @Test("converts trailing I II III IV")
    func converts() {
        #expect(normalizeRomanNumerals("violin i")   == "violin 1")
        #expect(normalizeRomanNumerals("violin ii")  == "violin 2")
        #expect(normalizeRomanNumerals("violin iii") == "violin 3")
        #expect(normalizeRomanNumerals("violin iv")  == "violin 4")
    }

    @Test("IV is matched before I")
    func ivBeforeI() {
        // If I were checked first "violin iv" would become "violin 1v"
        #expect(normalizeRomanNumerals("violin iv") == "violin 4")
    }
}

// MARK: - Numbered Base Tests
@Suite("numberedBase helper")
struct NumberedBaseTests {
    @Test("arabic numerals")
    func arabic() {
        #expect(numberedBase(of: "Flute 1") == "flute")
        #expect(numberedBase(of: "Clarinet 3") == "clarinet")
    }

    @Test("roman numerals")
    func roman() {
        #expect(numberedBase(of: "Violin I")  == "violin")
        #expect(numberedBase(of: "Violin II") == "violin")
    }

    @Test("returns nil for unnumbered names")
    func unnumbered() {
        #expect(numberedBase(of: "Tuba") == nil)
        #expect(numberedBase(of: "Bass Clarinet") == nil)
    }
}

// MARK: - Renumber After Deletion Tests
@Suite("renumberAfterDeletion")
struct RenumberAfterDeletionTests {
    @Test("strips number from sole arabic survivor")
    func arabic() {
        let parts = [PresetPart(name: "Flute 1", copies: 1)]
        let result = renumberAfterDeletion(parts)
        #expect(result[0].name == "Flute")
    }

    @Test("strips numeral from sole roman-numeral survivor")
    func roman() {
        let parts = [PresetPart(name: "Violin I", copies: 1)]
        let result = renumberAfterDeletion(parts)
        #expect(result[0].name == "Violin")
    }

    @Test("leaves pair untouched")
    func pair() {
        let parts = [PresetPart(name: "Horn 1", copies: 1),
                     PresetPart(name: "Horn 2", copies: 1)]
        let result = renumberAfterDeletion(parts)
        #expect(result.map(\.name) == ["Horn 1", "Horn 2"])
    }

    @Test("preserves capitalisation of survivor")
    func capitalisation() {
        let parts = [PresetPart(name: "Alto Saxophone 1", copies: 1)]
        let result = renumberAfterDeletion(parts)
        #expect(result[0].name == "Alto Saxophone")
    }
}

// MARK: - extractSplitNames
// Tests for the pure function that parses ScoreSort-formatted bookmark labels
// ("NN - Piecename - Partname") into a shared base name and per-file suffixes.

@Suite("extractSplitNames")
struct ExtractSplitNamesTests {

    @Test func parsesWellFormedLabels() throws {
        let labels = ["01 - Symphony 5 - Flute", "02 - Symphony 5 - Oboe"]
        let result = try #require(extractSplitNames(from: labels))
        #expect(result.baseName == "Symphony 5")
        #expect(result.suffixes == ["Flute", "Oboe"])
    }

    @Test func returnsNilForNonNumericPrefix() {
        let labels = ["Score - Symphony 5 - Flute"]
        #expect(extractSplitNames(from: labels) == nil)
    }

    @Test func returnsNilForFewerThanThreeParts() {
        let labels = ["01 - Symphony 5"]
        #expect(extractSplitNames(from: labels) == nil)
    }

    @Test func returnsNilForInconsistentPieceNames() {
        let labels = ["01 - Symphony 5 - Flute", "02 - Concerto - Oboe"]
        #expect(extractSplitNames(from: labels) == nil)
    }

    @Test func handlesPartNameContainingHyphen() throws {
        // Part name itself contains " - "; should be preserved in the suffix
        let labels = ["01 - Piece - Horn - in F"]
        let result = try #require(extractSplitNames(from: labels))
        #expect(result.baseName == "Piece")
        #expect(result.suffixes == ["Horn - in F"])
    }

    @Test func returnsNilForEmptyInput() {
        #expect(extractSplitNames(from: []) == nil)
    }
}

// MARK: - splitSizesFromBookmarks
// Tests for the function that reads a PDF outline and converts it to a fileSizes array.

@Suite("splitSizesFromBookmarks")
struct SplitSizesFromBookmarksTests {

    /// Writes a PDF with bookmarks at the specified page indices to `url`.
    func writePDFWithBookmarks(pages: Int, bookmarks: [(label: String, page: Int)], to url: URL) {
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
        doc.write(to: url)
    }

    var tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    @Test func returnsCorrectSizesFromBookmarks() throws {
        let url = tempDir.appendingPathComponent("bookmarked.pdf")
        writePDFWithBookmarks(pages: 6,
                              bookmarks: [(label: "A", page: 0),
                                          (label: "B", page: 2),
                                          (label: "C", page: 4)],
                              to: url)
        let doc = try #require(PDFDocument(url: url))
        let result = try #require(splitSizesFromBookmarks(doc))
        #expect(result.sizes == [2, 2, 2])
        #expect(result.labels == ["A", "B", "C"])
    }

    @Test func returnsNilForDocumentWithNoOutline() throws {
        let url = tempDir.appendingPathComponent("no_outline.pdf")
        writePDF(pages: 4, to: url)
        let doc = try #require(PDFDocument(url: url))
        #expect(splitSizesFromBookmarks(doc) == nil)
    }

    @Test func returnsNilForSingleBookmarkAtPageZero() throws {
        // Only one section — not useful for splitting
        let url = tempDir.appendingPathComponent("one_bookmark.pdf")
        writePDFWithBookmarks(pages: 4,
                              bookmarks: [(label: "Only", page: 0)],
                              to: url)
        let doc = try #require(PDFDocument(url: url))
        #expect(splitSizesFromBookmarks(doc) == nil)
    }

    @Test func handlesBookmarksOutOfOrder() throws {
        // Bookmarks in reverse order in the outline — should still produce correct sizes
        let url = tempDir.appendingPathComponent("reversed.pdf")
        writePDFWithBookmarks(pages: 6,
                              bookmarks: [(label: "B", page: 3),
                                          (label: "A", page: 0)],
                              to: url)
        let doc = try #require(PDFDocument(url: url))
        let result = try #require(splitSizesFromBookmarks(doc))
        #expect(result.sizes == [3, 3])
        #expect(result.labels == ["A", "B"])
    }
}

// MARK: - Combine Manager — bookmarks and blank pages
// Extends CombineManagerTests with coverage for the newer features.

@Suite("Combine Manager – bookmarks and blank pages")
struct CombineManagerBookmarkTests {

    var tempDir: URL

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    func makeFile(name: String, pageCount: Int, copies: Int = 1) -> CombineFile {
        CombineFile(url: URL(fileURLWithPath: "/dev/null"), name: name, pageCount: pageCount, copies: copies)
    }

    @Test func combinedPDFHasOutlineWithOneEntryPerFile() throws {
        let urlA = tempDir.appendingPathComponent("Flute.pdf")
        let urlB = tempDir.appendingPathComponent("Oboe.pdf")
        writePDF(pages: 2, to: urlA)
        writePDF(pages: 3, to: urlB)

        let manager = CombineManager()
        manager.addFiles(urls: [urlA, urlB], undoManager: nil)

        let outURL = tempDir.appendingPathComponent("combined.pdf")
        manager.createCombinedPDF(to: outURL, addBlankPages: false) { _, _, _ in }

        let result = try #require(PDFDocument(url: outURL))
        let root = try #require(result.outlineRoot)
        #expect(root.numberOfChildren == 2)
        #expect(root.child(at: 0)?.label == "Flute")
        #expect(root.child(at: 1)?.label == "Oboe")
    }

    @Test func multiCopyBookmarksAreLabelledWithFraction() throws {
        let url = tempDir.appendingPathComponent("Flute.pdf")
        writePDF(pages: 2, to: url)

        let manager = CombineManager()
        manager.addFiles(urls: [url], undoManager: nil)
        manager.updateCopies(for: manager.files[0].id, copies: 3, undoManager: nil)

        let outURL = tempDir.appendingPathComponent("copies.pdf")
        manager.createCombinedPDF(to: outURL, addBlankPages: false) { _, _, _ in }

        let result = try #require(PDFDocument(url: outURL))
        let root = try #require(result.outlineRoot)
        #expect(root.numberOfChildren == 3)
        #expect(root.child(at: 0)?.label == "Flute 1/3")
        #expect(root.child(at: 1)?.label == "Flute 2/3")
        #expect(root.child(at: 2)?.label == "Flute 3/3")
    }

    @Test func blankPageEntryIsNotBookmarked() throws {
        let url = tempDir.appendingPathComponent("Flute.pdf")
        writePDF(pages: 2, to: url)

        let manager = CombineManager()
        manager.addFiles(urls: [url], undoManager: nil)
        manager.addBlankPage(after: [], undoManager: nil)

        let outURL = tempDir.appendingPathComponent("with_blank.pdf")
        manager.createCombinedPDF(to: outURL, addBlankPages: false) { _, _, _ in }

        let result = try #require(PDFDocument(url: outURL))
        #expect(result.pageCount == 3)
        let root = try #require(result.outlineRoot)
        // Only the real file gets a bookmark, not the blank page
        #expect(root.numberOfChildren == 1)
        #expect(root.child(at: 0)?.label == "Flute")
    }

    @Test func addBlankPageAppendsToEndWhenNothingSelected() {
        let manager = CombineManager()
        manager.files = [makeFile(name: "A.pdf", pageCount: 2),
                         makeFile(name: "B.pdf", pageCount: 2)]
        manager.addBlankPage(after: [], undoManager: nil)
        #expect(manager.files.count == 3)
        #expect(manager.files.last?.isBlankPage == true)
    }

    @Test func addBlankPageInsertsAfterSelectedFile() {
        let manager = CombineManager()
        let a = makeFile(name: "A.pdf", pageCount: 2)
        let b = makeFile(name: "B.pdf", pageCount: 2)
        let c = makeFile(name: "C.pdf", pageCount: 2)
        manager.files = [a, b, c]
        manager.addBlankPage(after: [a.id], undoManager: nil)
        #expect(manager.files.count == 4)
        #expect(manager.files[1].isBlankPage == true)
        #expect(manager.files[2].name == "B.pdf")
    }
}

// MARK: - Booklet Deimposition Math

// Tests for coverFirstFrontBackOrder, innerFirstFrontBackOrder, and bookletCandidates.
// These are pure functions with no dependencies on PDFKit or app state — the fastest
// tests in the suite.

@Suite("Booklet deimposition — coverFirstFrontBackOrder")
struct CoverFirstFrontBackOrderTests {

    // ── Correctness for small known cases ─────────────────────────────────

    @Test("N=4 matches user-reported scan order 4-1-2-3")
    func n4MatchesReportedOrder() {
        // User reports: pages come out as scan[4,1,2,3].
        // order[readingPos] = scanPos should be [1,2,3,0] so that
        // reading[0]=scan1=page1, reading[3]=scan0=page4.
        #expect(coverFirstFrontBackOrder(n: 4) == [1, 2, 3, 0])
    }

    @Test("N=8 produces the expected reordering")
    func n8ExpectedOrder() {
        #expect(coverFirstFrontBackOrder(n: 8) == [1, 2, 5, 6, 7, 4, 3, 0])
    }

    @Test("N=12 is a valid permutation")
    func n12IsValidPermutation() {
        let order = coverFirstFrontBackOrder(n: 12)
        #expect(order.count == 12)
        #expect(Set(order) == Set(0..<12))   // all indices present exactly once
    }

    @Test("N=16 is a valid permutation")
    func n16IsValidPermutation() {
        let order = coverFirstFrontBackOrder(n: 16)
        #expect(order.count == 16)
        #expect(Set(order) == Set(0..<16))
    }

    // ── Edge cases / guard conditions ─────────────────────────────────────

    @Test("n=0 returns empty")
    func n0ReturnsEmpty() {
        #expect(coverFirstFrontBackOrder(n: 0).isEmpty)
    }

    @Test("n=3 (not a multiple of 4) returns empty")
    func nonMultipleOf4ReturnsEmpty() {
        #expect(coverFirstFrontBackOrder(n: 3).isEmpty)
    }

    @Test("n=2 (too small) returns empty")
    func tooSmallReturnsEmpty() {
        #expect(coverFirstFrontBackOrder(n: 2).isEmpty)
    }

    @Test("n=6 (multiple of 2 but not 4) returns empty")
    func multipleOf2NotOf4ReturnsEmpty() {
        #expect(coverFirstFrontBackOrder(n: 6).isEmpty)
    }

    // ── Structural property: page 0 in reading order always comes from scan 1 ──

    @Test("Reading page 0 always comes from scan position 1 (cover right side)")
    func firstReadingPageIsAlwaysScanPosition1() {
        for n in stride(from: 4, through: 32, by: 4) {
            let order = coverFirstFrontBackOrder(n: n)
            #expect(order[0] == 1, "Failed for n=\(n)")
        }
    }

    @Test("Last reading page always comes from scan position 0 (cover left side)")
    func lastReadingPageIsAlwaysScanPosition0() {
        for n in stride(from: 4, through: 32, by: 4) {
            let order = coverFirstFrontBackOrder(n: n)
            #expect(order[n - 1] == 0, "Failed for n=\(n)")
        }
    }
}

@Suite("Booklet deimposition — innerFirstFrontBackOrder")
struct InnerFirstFrontBackOrderTests {

    @Test("N=8 is a valid permutation")
    func n8IsValidPermutation() {
        let order = innerFirstFrontBackOrder(n: 8)
        #expect(order.count == 8)
        #expect(Set(order) == Set(0..<8))
    }

    @Test("N=8 differs from cover-first order")
    func n8DiffersFromCoverFirst() {
        let inner   = innerFirstFrontBackOrder(n: 8)
        let cover   = coverFirstFrontBackOrder(n: 8)
        #expect(inner != cover)
    }

    @Test("N=16 is a valid permutation")
    func n16IsValidPermutation() {
        let order = innerFirstFrontBackOrder(n: 16)
        #expect(order.count == 16)
        #expect(Set(order) == Set(0..<16))
    }

    @Test("N=4 (too small for inner-first) returns empty")
    func n4ReturnsEmpty() {
        #expect(innerFirstFrontBackOrder(n: 4).isEmpty)
    }

    @Test("N=7 (not a multiple of 4) returns empty")
    func nonMultipleOf4ReturnsEmpty() {
        #expect(innerFirstFrontBackOrder(n: 7).isEmpty)
    }
}

@Suite("Booklet deimposition — bookletCandidates")
struct BookletCandidatesTests {

    @Test("N=4 returns exactly one candidate (inner-first requires n≥8)")
    func n4ReturnsSingleCandidate() {
        let candidates = bookletCandidates(n: 4)
        #expect(candidates.count == 1)
    }

    @Test("N=8 returns two candidates")
    func n8ReturnsTwoCandidates() {
        let candidates = bookletCandidates(n: 8)
        #expect(candidates.count == 2)
    }

    @Test("N=3 (not a multiple of 4) returns empty")
    func nonMultipleReturnsEmpty() {
        #expect(bookletCandidates(n: 3).isEmpty)
    }

    @Test("Every candidate order is a valid permutation")
    func allOrdersAreValidPermutations() {
        for n in [4, 8, 12, 16] {
            for candidate in bookletCandidates(n: n) {
                #expect(candidate.order.count == n,
                        "Wrong length for n=\(n), candidate '\(candidate.label)'")
                #expect(Set(candidate.order) == Set(0..<n),
                        "Duplicate or out-of-range index for n=\(n), candidate '\(candidate.label)'")
            }
        }
    }

    @Test("First candidate for N=4 matches the known correct order")
    func n4FirstCandidateIsCorrect() {
        let candidates = bookletCandidates(n: 4)
        #expect(candidates.first?.order == [1, 2, 3, 0])
    }

    @Test("Candidates have non-empty labels and descriptions")
    func candidatesHaveLabelsAndDescriptions() {
        for candidate in bookletCandidates(n: 8) {
            #expect(!candidate.label.isEmpty)
            #expect(!candidate.description.isEmpty)
        }
    }
}

// MARK: - A3 Landscape Detection

// Tests for isA3Landscape(_:) — the predicate that decides whether to offer splitting.

@Suite("A3 landscape detection")
struct A3LandscapeDetectionTests {

    /// Creates a PDFDocument whose pages all have the given media box dimensions.
    private func makeDoc(width: CGFloat, height: CGFloat, pages: Int = 1) -> PDFDocument {
        let doc = PDFDocument()
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        for i in 0..<pages {
            let p = PDFPage()
            p.setBounds(bounds, for: .mediaBox)
            doc.insert(p, at: i)
        }
        return doc
    }

    @Test("Empty document returns false")
    func emptyDocReturnsFalse() {
        #expect(isA3Landscape(PDFDocument()) == false)
    }

    @Test("Portrait page returns false")
    func portraitReturnsFalse() {
        // A4 portrait: 595 × 842
        #expect(isA3Landscape(makeDoc(width: 595, height: 842)) == false)
    }

    @Test("Square page returns false (not landscape)")
    func squareReturnsFalse() {
        #expect(isA3Landscape(makeDoc(width: 800, height: 800)) == false)
    }

    @Test("Landscape but too narrow (≤ 1000 pt) returns false")
    func tooNarrowReturnsFalse() {
        // A4 landscape: 842 × 595 — width is only 842, below the 1000 pt threshold
        #expect(isA3Landscape(makeDoc(width: 842, height: 595)) == false)
    }

    @Test("Landscape and too wide (≥ 1400 pt) returns false")
    func tooWideReturnsFalse() {
        #expect(isA3Landscape(makeDoc(width: 1500, height: 800)) == false)
    }

    @Test("A3 landscape dimensions return true")
    func a3LandscapeReturnsTrue() {
        // A3 landscape: ≈ 1191 × 842 pt
        #expect(isA3Landscape(makeDoc(width: 1191, height: 842)) == true)
    }

    @Test("Multi-page A3 document returns true")
    func multiPageA3ReturnsTrue() {
        #expect(isA3Landscape(makeDoc(width: 1191, height: 842, pages: 4)) == true)
    }

    @Test("Mixed-size document (first page A3, rest portrait) returns false")
    func mixedSizeReturnsFalse() {
        // isA3Landscape checks the first 3 pages; if any fails the check it returns false.
        let doc = PDFDocument()
        let a3 = PDFPage(); a3.setBounds(CGRect(x: 0, y: 0, width: 1191, height: 842), for: .mediaBox)
        let portrait = PDFPage(); portrait.setBounds(CGRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox)
        doc.insert(a3,      at: 0)
        doc.insert(portrait, at: 1)
        doc.insert(portrait, at: 2)
        #expect(isA3Landscape(doc) == false)
    }
}

// MARK: - A3 Page Splitting

// Tests for splitA3Pages(_:leftFirst:) — crop-box based splitting that produces
// two A4-width pages from each A3 landscape page without re-rendering.

@Suite("A3 page splitting")
struct A3PageSplittingTests {

    private let pageWidth:  CGFloat = 1200
    private let pageHeight: CGFloat = 800

    /// Creates a document with `count` pages of uniform A3-like dimensions.
    private func makeA3Doc(pages count: Int) -> PDFDocument {
        let doc = PDFDocument()
        let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        for i in 0..<count {
            let p = PDFPage()
            p.setBounds(bounds, for: .mediaBox)
            doc.insert(p, at: i)
        }
        return doc
    }

    @Test("Output page count is twice the input")
    func outputPageCountDoubled() {
        let result = splitA3Pages(makeA3Doc(pages: 3), leftFirst: true)
        #expect(result.pageCount == 6)
    }

    @Test("Each output page is half the original width")
    func outputPageIsHalfWidth() {
        let result = splitA3Pages(makeA3Doc(pages: 1), leftFirst: true)
        let p = result.page(at: 0)
        #expect(p?.bounds(for: .mediaBox).width == pageWidth / 2)
    }

    @Test("Output page height is unchanged")
    func outputPageHeightUnchanged() {
        let result = splitA3Pages(makeA3Doc(pages: 1), leftFirst: true)
        let p = result.page(at: 0)
        #expect(p?.bounds(for: .mediaBox).height == pageHeight)
    }

    @Test("Left-first: first output page starts at x=0")
    func leftFirstFirstPageStartsAtOrigin() {
        let result = splitA3Pages(makeA3Doc(pages: 1), leftFirst: true)
        let p = result.page(at: 0)
        #expect(p?.bounds(for: .mediaBox).minX == 0)
    }

    @Test("Left-first: second output page starts at x = halfWidth")
    func leftFirstSecondPageStartsAtHalf() {
        let result = splitA3Pages(makeA3Doc(pages: 1), leftFirst: true)
        let p = result.page(at: 1)
        #expect(p?.bounds(for: .mediaBox).minX == pageWidth / 2)
    }

    @Test("Right-first: first output page starts at x = halfWidth")
    func rightFirstFirstPageStartsAtHalf() {
        let result = splitA3Pages(makeA3Doc(pages: 1), leftFirst: false)
        let p = result.page(at: 0)
        #expect(p?.bounds(for: .mediaBox).minX == pageWidth / 2)
    }

    @Test("Right-first: second output page starts at x=0")
    func rightFirstSecondPageStartsAtOrigin() {
        let result = splitA3Pages(makeA3Doc(pages: 1), leftFirst: false)
        let p = result.page(at: 1)
        #expect(p?.bounds(for: .mediaBox).minX == 0)
    }

    @Test("MediaBox and CropBox are set to the same half-page rect")
    func mediaBoxMatchesCropBox() {
        let result = splitA3Pages(makeA3Doc(pages: 1), leftFirst: true)
        guard let p = result.page(at: 0) else { return }
        #expect(p.bounds(for: .mediaBox) == p.bounds(for: .cropBox))
    }

    @Test("Empty input document produces empty output")
    func emptyInputProducesEmptyOutput() {
        let result = splitA3Pages(PDFDocument(), leftFirst: true)
        #expect(result.pageCount == 0)
    }
}

// MARK: - Read-only location detection (rename permission failures)

@Suite("Read-only location detection")
struct ReadOnlyLocationTests {

    /// Creates a temp directory, runs the body with it, then restores write perms and removes it.
    private func withTempDir(_ body: (URL) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scoresort-ro-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        body(dir)
    }

    @Test("Writable folder yields no non-writable parents")
    func writableFolderIsAllowed() {
        withTempDir { dir in
            let files = (0..<3).map { dir.appendingPathComponent("file\($0).pdf") }
            #expect(nonWritableParentDirectories(of: files).isEmpty)
        }
    }

    @Test("Read-only folder is flagged, deduplicated to one entry")
    func readOnlyFolderIsFlagged() {
        withTempDir { dir in
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
            let files = (0..<3).map { dir.appendingPathComponent("file\($0).pdf") }
            let flagged = nonWritableParentDirectories(of: files)
            #expect(flagged.count == 1)
            #expect(flagged.first?.path == dir.path)
        }
    }

    @Test("isFilePermissionError true for write-no-permission Cocoa error")
    func detectsCocoaPermissionError() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        #expect(isFilePermissionError(err))
    }

    @Test("isFilePermissionError true for POSIX EACCES / EROFS")
    func detectsPOSIXPermissionError() {
        #expect(isFilePermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        #expect(isFilePermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))))
    }

    @Test("isFilePermissionError true when POSIX error is nested under a Cocoa error")
    func detectsUnderlyingPOSIXError() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let wrapper = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                              userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(isFilePermissionError(wrapper))
    }

    @Test("isFilePermissionError false for a name-collision error")
    func ignoresNonPermissionError() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
        #expect(!isFilePermissionError(err))
    }

    @Test("Read-only message names the folder and mentions cloud providers")
    func messageIsActionable() {
        let msg = readOnlyLocationMessage(folderName: "The Moon at Midnight Charts")
        #expect(msg.contains("The Moon at Midnight Charts"))
        #expect(msg.contains("Dropbox"))
        #expect(msg.contains("Documents"))
    }

    @Test("Read-only message falls back gracefully when folder name is nil")
    func messageHandlesNilFolder() {
        let msg = readOnlyLocationMessage(folderName: nil)
        #expect(msg.contains("this location"))
    }
}

// MARK: - Split-stage ensemble inference (only high-confidence: strings → orchestra)

@Suite("Split ensemble inference")
struct SplitEnsembleInferenceTests {

    @Test("Flute alone is ambiguous (band vs orchestra) — no inference")
    func fluteAloneDoesNotInfer() {
        #expect(inferredSplitSuggestionEnsemble(["Flute"]) == nil)
    }

    @Test("A bowed-string part anywhere in the list infers orchestra")
    func stringsInferOrchestra() {
        #expect(inferredSplitSuggestionEnsemble(["Flute", "Oboe", "Violin 1"]) == .orchestra)
        #expect(inferredSplitSuggestionEnsemble(["Cello"]) == .orchestra)
        #expect(inferredSplitSuggestionEnsemble(["Viola"]) == .orchestra)
    }

    @Test("First part a saxophone infers jazz")
    func saxFirstInfersJazz() {
        #expect(inferredSplitSuggestionEnsemble(["Alto Sax 1", "Tenor Sax", "Trumpet"]) == .jazz)
        #expect(inferredSplitSuggestionEnsemble(["Baritone Saxophone"]) == .jazz)
    }

    @Test("A sax later in the list (after flute) is not a jazz signal")
    func saxNotFirstDoesNotInferJazz() {
        // Standard wind band: flute leads, saxes appear mid-list.
        #expect(inferredSplitSuggestionEnsemble(["Flute", "Clarinet", "Alto Saxophone"]) == nil)
    }

    @Test("Strings win even when a sax is present")
    func stringsTakePriorityOverSax() {
        #expect(inferredSplitSuggestionEnsemble(["Alto Sax", "Violin 1"]) == .orchestra)
    }

    @Test("Leading blank names are skipped when finding the first part")
    func skipsLeadingBlanks() {
        #expect(inferredSplitSuggestionEnsemble(["", "  ", "Soprano Sax"]) == .jazz)
    }

    @Test("Detection is case-insensitive")
    func caseInsensitive() {
        #expect(inferredSplitSuggestionEnsemble(["VIOLIN II"]) == .orchestra)
        #expect(inferredSplitSuggestionEnsemble(["ALTO SAX"]) == .jazz)
    }

    @Test("Ambiguous band instruments alone do not infer")
    func ambiguousInstrumentsDoNotInfer() {
        // Electric bass, drum set, brass all appear in modern wind bands too.
        #expect(inferredSplitSuggestionEnsemble(["Trumpet in Bb", "Trombone", "Electric Bass", "Drum Set"]) == nil)
    }

    @Test("Jazz upright 'string bass' / 'double bass' alone is not an orchestra signal")
    func uprightBassIsNotOrchestra() {
        #expect(inferredSplitSuggestionEnsemble(["Trumpet", "String Bass"]) == nil)
        #expect(inferredSplitSuggestionEnsemble(["Double Bass"]) == nil)
    }

    @Test("Empty input infers nothing")
    func emptyInfersNothing() {
        #expect(inferredSplitSuggestionEnsemble([]) == nil)
        #expect(inferredSplitSuggestionEnsemble([""]) == nil)
    }
}

// MARK: - Split naming: numbered-part progression

@Suite("Split numbered-part suggestions")
struct SplitNumberedSuggestionTests {

    @Test("Typical part counts (educational + jazz)")
    func typicalCounts() {
        // Band (concert/wind band): 3 trumpets, 1 tenor sax, 3 trombones.
        #expect(splitSuggestionTypicalPartCount("Trumpet", ensemble: .band) == 3)
        #expect(splitSuggestionTypicalPartCount("Tenor Saxophone", ensemble: .band) == 1)
        #expect(splitSuggestionTypicalPartCount("Trombone", ensemble: .band) == 3)
        #expect(splitSuggestionTypicalPartCount("Alto Saxophone", ensemble: .band) == 2)
        #expect(splitSuggestionTypicalPartCount("Baritone Saxophone", ensemble: .band) == 1)
        #expect(splitSuggestionTypicalPartCount("Bass Trombone", ensemble: .band) == 1)
        #expect(splitSuggestionTypicalPartCount("Flute", ensemble: .band) == 2)
        #expect(splitSuggestionTypicalPartCount("Tuba", ensemble: .band) == 1)
        // Jazz big band: 4 trumpets, 2 tenor saxes, 4 trombones.
        #expect(splitSuggestionTypicalPartCount("Trumpet", ensemble: .jazz) == 4)
        #expect(splitSuggestionTypicalPartCount("Tenor Saxophone", ensemble: .jazz) == 2)
        #expect(splitSuggestionTypicalPartCount("Trombone", ensemble: .jazz) == 4)
        // Default (no ensemble) is band.
        #expect(splitSuggestionTypicalPartCount("Trumpet") == 3)
    }

    @Test("Unknown instrument falls back to 2")
    func unknownFallsBackToTwo() {
        #expect(splitSuggestionTypicalPartCount("Theremin") == 2)
    }

    // A minimal score-order list covering the relevant boundaries.
    private let names = ["Trombone", "Bass Trombone", "Tuba", "Violin", "Viola"]

    @Test("Crossing from the last trombone to a single-part Bass Trombone is bare (no '1')")
    func crossToSinglePartIsBare() {
        // Trombone typical is now 4, so "Trombone 4" rolls over to Bass Trombone.
        let s = splitSuggestionStartingNumberedName(prevSuffix: "Trombone 4", instrumentNames: names)
        #expect(s == "Bass Trombone")
    }

    @Test("Crossing into a multi-part instrument keeps the '1'")
    func crossToMultiPartKeepsOne() {
        // Bass Trombone (1) rolls over to Tuba (1) — bare — and Tuba would roll to Violin (3) → "Violin 1".
        #expect(splitSuggestionStartingNumberedName(prevSuffix: "Tuba 1", instrumentNames: names) == "Violin 1")
    }

    @Test("Crossing from a single-part instrument to another single-part is bare")
    func crossSingleToSingleIsBare() {
        #expect(splitSuggestionStartingNumberedName(prevSuffix: "Bass Trombone 1", instrumentNames: names) == "Tuba")
    }

    @Test("Below the typical count does not cross the boundary")
    func belowTypicalDoesNotCross() {
        // "Trombone 2" is below the new typical of 4, so no cross-boundary suggestion.
        #expect(splitSuggestionStartingNumberedName(prevSuffix: "Trombone 2", instrumentNames: names) == nil)
    }

    @Test("Single-part clarinets are 1 (Alto Clarinet after Clarinet 3 is bare)")
    func singlePartClarinets() {
        #expect(splitSuggestionTypicalPartCount("Alto Clarinet") == 1)
        #expect(splitSuggestionTypicalPartCount("Eb Clarinet") == 1)
        let clarinets = ["Eb Clarinet", "Clarinet", "Alto Clarinet", "Bass Clarinet"]
        #expect(splitSuggestionStartingNumberedName(prevSuffix: "Clarinet 3", instrumentNames: clarinets) == "Alto Clarinet")
    }

    @Test("Crossing skips same-instrument aliases (Alto Saxophone 2 → Tenor Saxophone 1 in jazz)")
    func crossSkipsAliases() {
        // The list has several Alto-sax aliases in a row, as the real instrument list does.
        let saxes = ["Alto Saxophone", "Sax Alto", "Alto Sax", "Tenor Saxophone", "Tenor Sax"]
        #expect(splitSuggestionStartingNumberedName(prevSuffix: "Alto Saxophone 2", instrumentNames: saxes, ensemble: .jazz) == "Tenor Saxophone 1")
    }

    @Test("Band has a single tenor sax: Alto Saxophone 2 → bare Tenor Saxophone")
    func bandTenorSaxIsBare() {
        let saxes = ["Alto Saxophone", "Tenor Saxophone", "Baritone Saxophone"]
        #expect(splitSuggestionStartingNumberedName(prevSuffix: "Alto Saxophone 2", instrumentNames: saxes, ensemble: .band) == "Tenor Saxophone")
    }

    @Test("Trumpet count is ensemble-specific: band 'Trumpet 3' crosses, jazz does not")
    func trumpetCountByEnsemble() {
        let brass = ["Trumpet", "Horn", "Trombone"]
        // Band: 3rd trumpet is the last → crosses to Horn (4 parts → "Horn 1").
        #expect(splitSuggestionStartingNumberedName(prevSuffix: "Trumpet 3", instrumentNames: brass, ensemble: .band) == "Horn 1")
        // Jazz: a 4th trumpet is expected, so "Trumpet 3" does not cross yet.
        #expect(splitSuggestionStartingNumberedName(prevSuffix: "Trumpet 3", instrumentNames: brass, ensemble: .jazz) == nil)
    }
}

// MARK: - Output dialog default directory

@Suite("Output directory default")
struct OutputDirectoryTests {

    @Test("Returns the parent folder of the source file")
    func returnsParentFolder() {
        let src = URL(fileURLWithPath: "/Users/x/Scores/The Moon at Midnight/Full Score.pdf")
        // Compare paths, not URLs: deletingLastPathComponent() yields a directory URL with
        // a trailing slash, which isn't == a URL(fileURLWithPath:) of the same folder.
        #expect(outputDirectory(forSourceFile: src)?.path == "/Users/x/Scores/The Moon at Midnight")
    }

    @Test("Nil source yields nil (panel keeps its default)")
    func nilSourceYieldsNil() {
        #expect(outputDirectory(forSourceFile: nil) == nil)
    }
}

// MARK: - Renamable file types
// The Score Order Sorter renames PDFs and image scans; detection is filename-based.

@Suite("Renamable file types")
struct RenamableFileTests {

    @Test func acceptsPDF() {
        #expect(isRenamableFile(URL(fileURLWithPath: "/x/score.pdf")))
    }

    @Test func acceptsImages() {
        for ext in ["jpg", "jpeg", "png", "tif", "tiff", "heic", "bmp", "gif"] {
            #expect(isRenamableFile(URL(fileURLWithPath: "/x/scan.\(ext)")), "\(ext) should be renamable")
        }
    }

    @Test func isCaseInsensitive() {
        #expect(isRenamableFile(URL(fileURLWithPath: "/x/SCAN.PDF")))
        #expect(isRenamableFile(URL(fileURLWithPath: "/x/Photo.JPG")))
    }

    @Test func rejectsNonMedia() {
        for ext in ["txt", "doc", "mp3", "zip"] {
            #expect(!isRenamableFile(URL(fileURLWithPath: "/x/file.\(ext)")), "\(ext) should not be renamable")
        }
        #expect(!isRenamableFile(URL(fileURLWithPath: "/x/noextension")))
    }
}

// MARK: - Qualified folder names (batch queue / summary disambiguation)

@Suite("Qualified folder names")
struct QualifiedFolderNameTests {

    @Test("A single folder shows just its own name")
    func singleFolder() {
        let a = URL(fileURLWithPath: "/Music/Band A/Parts")
        #expect(qualifiedFolderName(for: a, among: [a]) == "Parts")
    }

    @Test("Distinct sibling names need no qualification")
    func distinctSiblings() {
        let a = URL(fileURLWithPath: "/Music/Symphony 1")
        let b = URL(fileURLWithPath: "/Music/Symphony 2")
        #expect(qualifiedFolderName(for: a, among: [a, b]) == "Symphony 1")
    }

    @Test("Same-named folders under different parents are disambiguated")
    func sameNameDifferentParents() {
        let a = URL(fileURLWithPath: "/Music/Band A/Parts")
        let b = URL(fileURLWithPath: "/Music/Band B/Parts")
        #expect(qualifiedFolderName(for: a, among: [a, b]) == "Band A › Parts")
        #expect(qualifiedFolderName(for: b, among: [a, b]) == "Band B › Parts")
    }

    @Test("Siblings under a shared parent collapse to their own names")
    func siblingsUnderSharedParent() {
        let a = URL(fileURLWithPath: "/Music/Band/Parts")
        let b = URL(fileURLWithPath: "/Music/Band/Score")
        #expect(qualifiedFolderName(for: a, among: [a, b]) == "Parts")
    }
}

// MARK: - Batch job-folder expansion (Score Order Sorter)
// `expandToRenameJobFolders` walks dropped folders and returns every directory (any
// depth) that directly contains a renamable file.

@Suite("Batch job folder expansion")
struct JobFolderExpansionTests {

    var root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Ensures a directory exists at `path` (relative to root) and returns its URL.
    @discardableResult
    func dir(_ path: String) throws -> URL {
        let u = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Creates an (empty) file at `path` (relative to root), making parent dirs as needed.
    func file(_ path: String) throws {
        let u = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: u, atomically: true, encoding: .utf8)
    }

    @Test mutating func folderWithPDFsIsOneJob() throws {
        try file("Band/flute.pdf")
        try file("Band/oboe.pdf")
        let jobs = expandToRenameJobFolders([try dir("Band")])
        #expect(jobs.map { $0.lastPathComponent } == ["Band"])
    }

    @Test mutating func parentOfFoldersBatchesChildren() throws {
        try file("Parent/Band A/flute.pdf")
        try file("Parent/Band B/flute.pdf")
        let jobs = expandToRenameJobFolders([try dir("Parent")])
        #expect(jobs.map { $0.lastPathComponent } == ["Band A", "Band B"])
    }

    @Test mutating func discoversNestedFoldersAtAnyDepth() throws {
        try file("Top/A/parts/flute.pdf")
        try file("Top/B/inner/parts/flute.pdf")
        let jobs = expandToRenameJobFolders([try dir("Top")])
        #expect(jobs.count == 2)
        #expect(jobs.allSatisfy { $0.lastPathComponent == "parts" })
    }

    @Test mutating func imageScansCountAsJobs() throws {
        try file("Scans/flute.jpg")
        try file("Scans/oboe.png")
        let jobs = expandToRenameJobFolders([try dir("Scans")])
        #expect(jobs.map { $0.lastPathComponent } == ["Scans"])
    }

    @Test mutating func foldersWithNoRenamableFilesYieldNoJobs() throws {
        try file("Docs/readme.txt")
        let jobs = expandToRenameJobFolders([try dir("Docs")])
        #expect(jobs.isEmpty)
    }

    @Test mutating func parentAndPDFSubfolderAreBothJobs() throws {
        try file("Mix/score.pdf")          // direct PDFs → Mix is a job
        try file("Mix/sub/flute.pdf")      // PDF subfolder → Mix/sub is also a job
        let jobs = expandToRenameJobFolders([try dir("Mix")])
        #expect(jobs.count == 2)
        #expect(Set(jobs.map { $0.lastPathComponent }) == ["Mix", "sub"])
    }
}

// MARK: - Score-order numbering (shared by splitter Step 3 / bulk Step 2 / renamer)
// scoreOrderNumbers: score → 0, manual numbers reserved (others reflow), auto from 1.

@Suite("Score-order numbering")
struct ScoreOrderNumberingTests {

    func item(_ id: Int, score: Bool = false, manual: Int? = nil, skipped: Bool = false) -> PrefixItem {
        PrefixItem(id: id, proposedName: "n\(id).pdf", page: nil,
                   isScore: score, manualNumber: manual, isSkipped: skipped)
    }

    @Test func scoreGetsZeroInstrumentsStartAtOne() {
        let n = scoreOrderNumbers(forOrderedItems: [item(0, score: true), item(1), item(2)])
        #expect(n[0] == 0)
        #expect(n[1] == 1)
        #expect(n[2] == 2)
    }

    @Test func noScoreStillStartsAtOne() {   // the reported bug: Flute must not become 00
        let n = scoreOrderNumbers(forOrderedItems: [item(0), item(1)])
        #expect(n[0] == 1)
        #expect(n[1] == 2)
    }

    @Test func manualNumberReservedWithReflow() {
        let n = scoreOrderNumbers(forOrderedItems: [item(0), item(1, manual: 1), item(2)])
        #expect(n[1] == 1)   // forced
        #expect(n[0] == 2)   // reflowed past the reserved 1
        #expect(n[2] == 3)
    }

    @Test func autoSkipsReservedManualNumber() {
        let n = scoreOrderNumbers(forOrderedItems: [item(0), item(1, manual: 1)])
        #expect(n[1] == 1)
        #expect(n[0] == 2)
    }

    @Test func skippedItemsOmittedAndDontConsumeNumbers() {
        let n = scoreOrderNumbers(forOrderedItems: [item(0), item(1, skipped: true), item(2)])
        #expect(n[1] == nil)
        #expect(n[0] == 1)
        #expect(n[2] == 2)   // gap closed — skip didn't consume a number
    }

    @Test func allManualKeepTheirNumbers() {
        let n = scoreOrderNumbers(forOrderedItems: [item(0, manual: 5), item(1, manual: 9)])
        #expect(n[0] == 5)
        #expect(n[1] == 9)
    }

    @Test func emptyYieldsEmpty() {
        #expect(scoreOrderNumbers(forOrderedItems: []).isEmpty)
    }
}

// MARK: - Preferred instrument display name (full sax names in suggestions)

@Suite("Preferred instrument display name")
struct PreferredInstrumentNameTests {

    @Test func canonicalisesSaxFamilyToFullNames() {
        #expect(preferredInstrumentDisplayName("Alto Sax") == "Alto Saxophone")
        #expect(preferredInstrumentDisplayName("alto saxophone") == "Alto Saxophone")
        #expect(preferredInstrumentDisplayName("Sax Alto") == "Alto Saxophone")
        #expect(preferredInstrumentDisplayName("Special Alto Sax") == "Alto Saxophone")
        #expect(preferredInstrumentDisplayName("Tenor Sax") == "Tenor Saxophone")
        #expect(preferredInstrumentDisplayName("Bari Sax") == "Baritone Saxophone")
        #expect(preferredInstrumentDisplayName("Baritone Saxophone") == "Baritone Saxophone")
        #expect(preferredInstrumentDisplayName("Sop Sax") == "Soprano Saxophone")
        #expect(preferredInstrumentDisplayName("Bass Sax") == "Bass Saxophone")
    }

    @Test func leavesNonSaxNamesUnchanged() {
        for name in ["Flute", "Clarinet", "Bass Clarinet", "Eb Clarinet", "Trumpet", "Horn in F"] {
            #expect(preferredInstrumentDisplayName(name) == name)
        }
    }

    @Test func canonicalisesBaritoneEuphoniumClefs() {
        for n in ["Baritone BC", "Baritone B.C.", "Baritone Bass Clef"] {
            #expect(preferredInstrumentDisplayName(n) == "Baritone BC")
        }
        for n in ["Baritone TC", "Baritone T.C.", "Baritone Treble Clef"] {
            #expect(preferredInstrumentDisplayName(n) == "Baritone TC")
        }
        #expect(preferredInstrumentDisplayName("Euphonium BC") == "Euphonium BC")
        #expect(preferredInstrumentDisplayName("Euphonium Treble Clef") == "Euphonium TC")
        #expect(preferredInstrumentDisplayName("Baritone") == "Baritone")
        #expect(preferredInstrumentDisplayName("Euphonium") == "Euphonium")
    }

    @Test func baritoneSaxIsSaxNotBrass() {
        // The bari *sax* must stay a saxophone, distinct from the baritone (euphonium) brass.
        #expect(preferredInstrumentDisplayName("Baritone Sax") == "Baritone Saxophone")
        #expect(preferredInstrumentDisplayName("Bari Sax") == "Baritone Saxophone")
        #expect(instrumentIdentityKey("Baritone Saxophone") != instrumentIdentityKey("Baritone BC"))
    }

    @Test func clefCompanionPairsBcAndTc() {
        #expect(clefCompanion(for: "Baritone BC") == "Baritone TC")
        #expect(clefCompanion(for: "Baritone Bass Clef") == "Baritone TC")   // canonicalised
        #expect(clefCompanion(for: "Euphonium TC") == "Euphonium BC")
        #expect(clefCompanion(for: "Tenor Saxophone") == nil)
        #expect(clefCompanion(for: "Flute") == nil)
    }
}

// MARK: - Next suggestion index (dropdown rotation start)

@Suite("Next suggestion index")
struct NextSuggestionIndexTests {

    func name(_ order: [String], after prev: String, used: Set<String> = []) -> String? {
        nextSuggestionIndex(after: prev, in: order, usedKeys: used).map { order[$0] }
    }

    @Test("Skips same-instrument aliases to the next distinct instrument")
    func skipsAliases() {
        let order = ["Alto Saxophone", "Sax Alto", "Tenor Saxophone", "Saxophone Tenor", "Sax Tenor", "Baritone Saxophone"]
        #expect(name(order, after: "Tenor Saxophone") == "Baritone Saxophone")
    }

    @Test("After bass clarinet, offers a not-yet-used bassoon")
    func bassoonAfterBassClarinet() {
        let order = ["Bassoon", "Eb Clarinet", "Clarinet", "Bass Clarinet", "Alto Saxophone"]
        #expect(name(order, after: "Bass Clarinet") == "Bassoon")
    }

    @Test("If bassoon was already used, bass clarinet rolls on normally")
    func bassoonAlreadyUsed() {
        let order = ["Bassoon", "Eb Clarinet", "Clarinet", "Bass Clarinet", "Alto Saxophone"]
        #expect(name(order, after: "Bass Clarinet", used: ["bassoon"]) == "Alto Saxophone")
    }

    @Test("Unrecognised previous instrument yields nil (caller falls through)")
    func unrecognisedYieldsNil() {
        let order = ["Flute", "Oboe", "Clarinet"]
        #expect(nextSuggestionIndex(after: "Theremin", in: order, usedKeys: []) == nil)
    }
}
