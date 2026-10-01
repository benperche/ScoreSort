//
//  CombineSaveErrorTests.swift
//  ScoreSortTests
//
//  When Combine can't produce its output, the message has to say which file and why. Input
//  files are reopened when the PDF is built, not when they're added, so a file can go missing
//  or become unreadable in between — and the app used to answer that with a bare
//  "Failed to create PDF", or quietly leave the part out.
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

@Suite("Combine save errors")
struct CombineSaveErrorTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func manager(adding names: [String]) -> (CombineManager, [URL]) {
        let urls = names.map { dir.appendingPathComponent("\($0).pdf") }
        for url in urls { writePDF(pages: 2, to: url) }
        let manager = CombineManager()
        manager.addFiles(urls: urls, undoManager: nil)
        return (manager, urls)
    }

    private func create(_ manager: CombineManager, to out: URL)
        -> (title: String, message: String, isError: Bool) {
        var result = (title: "", message: "", isError: false)
        manager.createCombinedPDF(to: out, options: CombineOutputOptions()) { result = ($0, $1, $2) }
        return result
    }

    @Test func fileDeletedAfterAddingIsNamedAndNothingIsSaved() throws {
        let (manager, urls) = manager(adding: ["Flute", "Oboe"])
        try FileManager.default.removeItem(at: urls[1])

        let out = dir.appendingPathComponent("out.pdf")
        let result = create(manager, to: out)
        #expect(result.isError)
        #expect(result.title == "Couldn’t Read Some Files")
        #expect(result.message.contains("Oboe.pdf"))
        #expect(result.message.contains("can't be found"))
        #expect(!result.message.contains("Flute.pdf"), "a readable file shouldn't be blamed")
        // A set with a part silently missing is worse than no file at all.
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    /// The reported case: every input unreadable used to build an empty document, which failed
    /// to save with nothing but "Failed to create PDF".
    @Test func everyFileUnreadableListsThemAll() throws {
        let (manager, urls) = manager(adding: ["Flute", "Oboe", "Horn"])
        for url in urls { try FileManager.default.removeItem(at: url) }

        let result = create(manager, to: dir.appendingPathComponent("out.pdf"))
        #expect(result.isError)
        #expect(result.message != "Failed to create PDF")
        for name in ["Flute.pdf", "Oboe.pdf", "Horn.pdf"] { #expect(result.message.contains(name)) }
    }

    @Test func fileDamagedAfterAddingSaysSo() throws {
        let (manager, urls) = manager(adding: ["Flute"])
        try Data("not a pdf any more".utf8).write(to: urls[0])

        let result = create(manager, to: dir.appendingPathComponent("out.pdf"))
        #expect(result.isError)
        #expect(result.message.contains("Flute.pdf"))
        #expect(result.message.contains("damaged"))
    }

    @Test func eachCopyOfAnUnreadableFileIsListedOnce() throws {
        let (manager, urls) = manager(adding: ["Flute"])
        manager.updateCopies(for: try #require(manager.files.first).id, copies: 4, undoManager: nil)
        try FileManager.default.removeItem(at: urls[0])

        let result = create(manager, to: dir.appendingPathComponent("out.pdf"))
        #expect(result.message.components(separatedBy: "Flute.pdf").count == 2)
    }

    @Test func readOnlyDestinationIsExplained() throws {
        let (manager, _) = manager(adding: ["Flute"])
        let locked = dir.appendingPathComponent("Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let result = create(manager, to: locked.appendingPathComponent("out.pdf"))
        #expect(result.isError)
        #expect(result.title == "Couldn’t Save the PDF")
        #expect(result.message.contains("Locked"))
    }

    @Test func emptyDocumentIsExplainedNotJustRefused() {
        #expect(savePDFDocument(PDFDocument(), to: dir.appendingPathComponent("empty.pdf"))
                == "There were no pages to save.")
    }

    @Test func openInPreviewReportsUnreadableFilesToo() throws {
        let (manager, urls) = manager(adding: ["Flute"])
        try FileManager.default.removeItem(at: urls[0])

        var message = ""
        manager.openInPreview(options: CombineOutputOptions()) { _, text, _ in message = text }
        #expect(message.contains("Flute.pdf"))
    }
}
