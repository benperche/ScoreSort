//
//  Music_PDF_ManagerTests.swift
//  Music PDF ManagerTests
//

import Testing
import Foundation
@testable import Music_PDF_Manager

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
