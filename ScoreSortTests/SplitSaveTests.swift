//
//  SplitSaveTests.swift
//  ScoreSortTests
//
//  Saving a split in the background (#34): `writeSplitFiles` reports progress and stops
//  when cancelled, and `SplitSaveProgress.run` writes the same files off the main thread
//  from its own copy of the document.
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

private func plans(_ names: [String], pagesEach: Int = 2) -> [SplitFilePlan] {
    names.enumerated().map { i, name in
        SplitFilePlan(name: name, pages: Array((i * pagesEach)..<((i + 1) * pagesEach)))
    }
}

/// Records progress callbacks, which `writeSplitFiles` may make from any thread.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(Int, Int, String?)] = []
    func add(_ done: Int, _ total: Int, _ next: String?) { lock.lock(); calls.append((done, total, next)); lock.unlock() }
    var all: [(Int, Int, String?)] { lock.lock(); defer { lock.unlock() }; return calls }
}

@Suite("Split save: progress and cancelling")
struct SplitWriteProgressTests {

    @Test("progress is reported before each file, then once at the end")
    func progressInOrder() throws {
        let folder = temporaryFolder("split-save")
        let source = folder.appendingPathComponent("Source.pdf")
        writeDrawnPDF(pages: 6, to: source)
        let document = try #require(PDFDocument(url: source))
        let out = folder.appendingPathComponent("out")
        let log = ProgressLog()

        let report = writeSplitFiles(plans(["A.pdf", "B.pdf", "C.pdf"]), from: document, to: out,
                                     stampJob: nil, progress: log.add)

        #expect(report.written == ["A.pdf", "B.pdf", "C.pdf"])
        #expect(!report.wasCancelled)
        #expect(log.all.map(\.0) == [0, 1, 2, 3])
        #expect(log.all.map(\.1) == [3, 3, 3, 3])
        #expect(log.all.map(\.2) == ["A.pdf", "B.pdf", "C.pdf", nil])
    }

    @Test("cancelling stops between files and lists the rest as not written")
    func cancelStopsBetweenFiles() throws {
        let folder = temporaryFolder("split-save")
        let source = folder.appendingPathComponent("Source.pdf")
        writeDrawnPDF(pages: 6, to: source)
        let document = try #require(PDFDocument(url: source))
        let out = folder.appendingPathComponent("out")
        let flag = CancelFlag()

        // Cancel as soon as the first file starts: it finishes, the others aren't begun.
        let report = writeSplitFiles(plans(["A.pdf", "B.pdf", "C.pdf"]), from: document, to: out,
                                     stampJob: nil,
                                     progress: { done, _, _ in if done == 0 { flag.set() } },
                                     isCancelled: { flag.isSet })

        #expect(report.written == ["A.pdf"])
        #expect(report.notWritten == ["B.pdf", "C.pdf"])
        #expect(report.wasCancelled)
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path)
        #expect(files == ["A.pdf"])
    }

    @Test("without progress or cancelling, the command line's behaviour is unchanged")
    func defaultsUnchanged() throws {
        let folder = temporaryFolder("split-save")
        let source = folder.appendingPathComponent("Source.pdf")
        writeDrawnPDF(pages: 4, to: source)
        let document = try #require(PDFDocument(url: source))
        let report = writeSplitFiles(plans(["A.pdf", "B.pdf"]), from: document,
                                     to: folder.appendingPathComponent("out"), stampJob: nil)
        #expect(report.written == ["A.pdf", "B.pdf"])
        #expect(report.notWritten.isEmpty)
    }
}

@MainActor
@Suite("Split save: in the background")
struct SplitBackgroundSaveTests {

    @Test("an untouched document is reopened from its file; a rebuilt one is snapshotted")
    func sourceChoice() throws {
        let folder = temporaryFolder("split-save")
        let url = folder.appendingPathComponent("Source.pdf")
        writeDrawnPDF(pages: 3, to: url)
        let loaded = try #require(PDFDocument(url: url))
        guard case .file(let reopened) = try #require(SplitSaveSource.of(loaded, loadedFrom: url)) else {
            Issue.record("expected the file to be reopened"); return
        }
        #expect(reopened == url)

        // Swap with Next and Fix Booklet Order build a new document in memory.
        let rebuilt = PDFDocument()
        for i in [1, 0, 2] { rebuilt.insert(try #require(loaded.page(at: i)?.copy() as? PDFPage), at: rebuilt.pageCount) }
        guard case .data = try #require(SplitSaveSource.of(rebuilt, loadedFrom: url)) else {
            Issue.record("expected a snapshot of the rebuilt document"); return
        }
    }

    @Test("writes the same files as the main-thread writer, from either source")
    func backgroundMatchesForeground() async throws {
        let folder = temporaryFolder("split-save")
        let url = folder.appendingPathComponent("Source.pdf")
        writeDrawnPDF(pages: 6, to: url)
        let document = try #require(PDFDocument(url: url))
        let work = plans(["Flute.pdf", "Brass/Trumpet.pdf", "Percussion.pdf"])

        let expected = folder.appendingPathComponent("expected")
        _ = writeSplitFiles(work, from: document, to: expected, stampJob: nil)

        for (label, source) in [("file", SplitSaveSource.file(url)),
                                ("data", SplitSaveSource.data(try #require(document.dataRepresentation())))] {
            let out = folder.appendingPathComponent(label)
            let progress = SplitSaveProgress(total: work.count)
            let report = await progress.run(work, from: source, expectingPageCount: 6, to: out, stampJob: nil)
            #expect(report.written == work.map(\.name), "\(label)")
            #expect(progress.done == work.count, "\(label)")
            for plan in work {
                let made = try #require(PDFDocument(url: out.appendingPathComponent(plan.name)), "\(label): \(plan.name)")
                let reference = try #require(PDFDocument(url: expected.appendingPathComponent(plan.name)))
                #expect(made.pageCount == reference.pageCount, "\(label): \(plan.name)")
            }
        }
    }

    @Test("stamping works off the main thread")
    func stampsInBackground() async throws {
        let folder = temporaryFolder("split-save")
        let url = folder.appendingPathComponent("Source.pdf")
        writeDrawnPDF(pages: 4, to: url)
        let job = StampJob(stamp: Stamp(name: "Test", text: "Example School Band"), scope: .firstPageOfEachPart)
        let work = plans(["A.pdf", "B.pdf"])

        let plain = folder.appendingPathComponent("plain")
        let stamped = folder.appendingPathComponent("stamped")
        _ = await SplitSaveProgress(total: 2).run(work, from: .file(url), expectingPageCount: 4, to: plain, stampJob: nil)
        let report = await SplitSaveProgress(total: 2).run(work, from: .file(url), expectingPageCount: 4,
                                                           to: stamped, stampJob: job)
        #expect(report.written == ["A.pdf", "B.pdf"])
        for name in ["A.pdf", "B.pdf"] {
            let a = try Data(contentsOf: plain.appendingPathComponent(name))
            let b = try Data(contentsOf: stamped.appendingPathComponent(name))
            #expect(a != b, "\(name) should carry the stamp")
            #expect(PDFDocument(data: b)?.pageCount == 2)
        }
    }

    @Test("a source that no longer matches what's on screen is refused, writing nothing")
    func changedSourceRefused() async throws {
        let folder = temporaryFolder("split-save")
        let url = folder.appendingPathComponent("Source.pdf")
        writeDrawnPDF(pages: 4, to: url)
        let out = folder.appendingPathComponent("out")
        // The file now has 4 pages, but the document being split had 6.
        let report = await SplitSaveProgress(total: 2).run(plans(["A.pdf", "B.pdf"]), from: .file(url),
                                                           expectingPageCount: 6, to: out, stampJob: nil)
        #expect(report.written.isEmpty)
        #expect(report.failures.count == 1)
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test("cancelling from the main actor stops the background save")
    func cancelFromMainActor() async throws {
        let folder = temporaryFolder("split-save")
        let url = folder.appendingPathComponent("Source.pdf")
        writeDrawnPDF(pages: 8, to: url)
        let progress = SplitSaveProgress(total: 4)
        progress.cancel()   // before it starts: nothing is written
        let report = await progress.run(plans(["A.pdf", "B.pdf", "C.pdf", "D.pdf"]), from: .file(url),
                                        expectingPageCount: 8, to: folder.appendingPathComponent("out"), stampJob: nil)
        #expect(report.written.isEmpty)
        #expect(report.notWritten == ["A.pdf", "B.pdf", "C.pdf", "D.pdf"])
        #expect(progress.isCancelling)
    }
}
