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

@Suite("Split Step 1: page previews and bookkeeping")
struct SplitStepOnePerformanceTests {

    @Test("a file's pages come straight from fileSizes, as the page map gave them")
    func filePagesMatchMapping() {
        let sizes = [3, 1, 4, 2]
        var mapping: [Int: Int] = [:]
        var pos = 0
        for (file, size) in sizes.enumerated() { for p in pos..<(pos + size) { mapping[p] = file }; pos += size }
        for file in sizes.indices {
            let fromMap = mapping.filter { $0.value == file }.keys.sorted()
            #expect(Array(splitFilePages(file, fileSizes: sizes)) == fromMap)
        }
        #expect(splitFilePages(4, fileSizes: sizes).isEmpty)
        #expect(splitFilePages(-1, fileSizes: sizes).isEmpty)
        #expect(splitFilePages(0, fileSizes: []).isEmpty)
    }

    @Test("the preview is twice the page's size, and an extra turn swaps its sides")
    func previewSizeAndRotation() throws {
        let folder = temporaryFolder("preview")
        let url = folder.appendingPathComponent("Page.pdf")
        writeDrawnPDF(pages: 1, to: url)
        let source = try #require(PDFDocument(url: url)?.page(at: 0)?.scanRenderSource)

        let upright = try #require(renderPagePreview(source, stamp: nil, extraRotation: 0))
        #expect(upright.pointSize == CGSize(width: 595, height: 842))
        #expect(upright.image.width == 1190)
        #expect(abs(upright.image.height - 1684) <= 1)

        let turned = try #require(renderPagePreview(source, stamp: nil, extraRotation: 90))
        #expect(turned.pointSize == CGSize(width: 842, height: 595))
        #expect(turned.image.width == upright.image.height)
        #expect(turned.image.height == upright.image.width)
    }

    @Test("the preview shows the crop box, so an A3 half isn't shown whole")
    func previewHonoursCropBox() throws {
        let folder = temporaryFolder("preview")
        let url = folder.appendingPathComponent("A3.pdf")
        writeDrawnPDF(pages: 1, size: CGSize(width: 1191, height: 842), to: url)
        let document = try #require(PDFDocument(url: url))
        let page = try #require(document.page(at: 0))
        page.setBounds(CGRect(x: 0, y: 0, width: 595.5, height: 842), for: .cropBox)
        let source = try #require(page.scanRenderSource)
        let preview = try #require(renderPagePreview(source, stamp: nil, extraRotation: 0))
        #expect(preview.pointSize == CGSize(width: 595.5, height: 842))
    }

    @Test("a stamp is drawn into the preview")
    func previewCarriesStamp() throws {
        let folder = temporaryFolder("preview")
        let url = folder.appendingPathComponent("Page.pdf")
        writeDrawnPDF(pages: 1, to: url)
        let source = try #require(PDFDocument(url: url)?.page(at: 0)?.scanRenderSource)
        let plain = try #require(renderPagePreview(source, stamp: nil, extraRotation: 0))
        let stamped = try #require(renderPagePreview(source, stamp: Stamp(name: "T", text: "Example School Band"),
                                                     extraRotation: 0))
        #expect(plain.pointSize == stamped.pointSize)
        let a = try #require(plain.image.dataProvider?.data as Data?)
        let b = try #require(stamped.image.dataProvider?.data as Data?)
        #expect(a != b)
    }
}
