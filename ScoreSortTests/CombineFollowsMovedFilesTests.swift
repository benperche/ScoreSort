//
//  CombineFollowsMovedFilesTests.swift
//  ScoreSortTests
//
//  Combine reads its input files again when the PDF is made. These check that a file moved,
//  renamed or re-exported in Finder after being added is still found — via the bookmark stored
//  when it was added — and that a file moved to the Trash isn't.
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

@Suite("Combine follows moved files")
struct CombineFollowsMovedFilesTests {
    let dir: URL
    let fm = FileManager.default

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func added(_ parts: [(name: String, pages: Int)]) -> (CombineManager, [URL]) {
        let urls = parts.map { dir.appendingPathComponent("\($0.name).pdf") }
        for (url, part) in zip(urls, parts) { writePDF(pages: part.pages, to: url) }
        let manager = CombineManager()
        manager.addFiles(urls: urls, undoManager: nil)
        return (manager, urls)
    }

    private func create(_ manager: CombineManager) -> (isError: Bool, message: String, doc: PDFDocument?) {
        let out = dir.appendingPathComponent("out-\(UUID().uuidString).pdf")
        var result = (isError: false, message: "")
        manager.createCombinedPDF(to: out, options: CombineOutputOptions()) { _, m, e in result = (e, m) }
        return (result.isError, result.message, PDFDocument(url: out))
    }

    @Test func addedFilesCarryABookmark() {
        let (manager, _) = added([("Flute", 2)])
        #expect(manager.files.first?.bookmark != nil)
    }

    /// The reported case: files dragged in, then moved to another folder before saving.
    @Test func fileMovedToAnotherFolderIsFollowed() throws {
        let (manager, urls) = added([("Flute", 3), ("Oboe", 2)])
        let elsewhere = dir.appendingPathComponent("Moved")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let newOboe = elsewhere.appendingPathComponent("Oboe.pdf")
        try fm.moveItem(at: urls[1], to: newOboe)

        let result = create(manager)
        #expect(!result.isError, "\(result.message)")
        #expect(result.doc?.pageCount == 5)
        #expect(manager.files[1].url.standardizedFileURL == newOboe.standardizedFileURL)
    }

    @Test func renamedFileIsFollowedAndRelabelled() throws {
        let (manager, urls) = added([("Flute", 2)])
        try fm.moveItem(at: urls[0], to: dir.appendingPathComponent("Flute 1.pdf"))

        let result = create(manager)
        #expect(!result.isError, "\(result.message)")
        #expect(manager.files[0].name == "Flute 1.pdf")
        // The table of contents takes the file's current name.
        #expect(result.doc?.outlineRoot?.child(at: 0)?.label == "Flute 1")
    }

    @Test func fileReExportedOverTheSameNameUsesTheNewVersion() throws {
        let (manager, urls) = added([("Flute", 2)])
        let replacement = PDFDocument()
        for i in 0..<4 { replacement.insert(PDFPage(), at: i) }
        try #require(replacement.dataRepresentation()).write(to: urls[0], options: .atomic)

        let result = create(manager)
        #expect(!result.isError, "\(result.message)")
        #expect(result.doc?.pageCount == 4)
    }

    /// A bookmark follows a file into the Trash; that must count as gone. A folder named
    /// ".Trash" stands in for the real one, so the test never touches the user's Trash.
    @Test func fileMovedToTheTrashCountsAsGone() throws {
        let (manager, urls) = added([("Flute", 2)])
        let trash = dir.appendingPathComponent(".Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try fm.moveItem(at: urls[0], to: trash.appendingPathComponent("Flute.pdf"))

        #expect(currentLocation(ofBookmark: try #require(manager.files[0].bookmark)) == nil)
        let result = create(manager)
        #expect(result.isError)
        #expect(result.message.contains("Flute.pdf"))
    }
}
