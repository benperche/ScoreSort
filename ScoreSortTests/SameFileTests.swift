//
//  SameFileTests.swift
//  ScoreSortTests
//
//  #30: "would this replace the original?" is decided by the file's identity on disk, not by
//  comparing paths, so `Part.PDF` and `part.pdf`, or a path through a symlinked folder, count
//  as the same file — and the commands that promise never to replace their source keep it.
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

/// Whether the temporary folder's disk ignores case, as Mac disks normally do. The case tests
/// check the right answer for whichever kind of disk they run on.
private func caseInsensitiveDisk(_ folder: URL) -> Bool {
    (try? folder.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) == false
}

private func symlinkedFolder(to folder: URL) throws -> URL {
    let link = temporaryFolder("link").appendingPathComponent("Linked folder")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
    return link
}

@Suite("Same file on disk")
struct IsSameFileTests {

    @Test("the same path, and different files")
    func basics() throws {
        let folder = temporaryFolder("same")
        let a = folder.appendingPathComponent("A.pdf"), b = folder.appendingPathComponent("B.pdf")
        writeDrawnPDF(pages: 1, to: a)
        writeDrawnPDF(pages: 1, to: b)
        #expect(isSameFile(a, a))
        #expect(isSameFile(a, URL(fileURLWithPath: folder.path + "/./A.pdf")))
        #expect(!isSameFile(a, b))
    }

    @Test("a file that doesn't exist is never the same file")
    func missing() {
        let folder = temporaryFolder("same")
        let a = folder.appendingPathComponent("A.pdf")
        writeDrawnPDF(pages: 1, to: a)
        let nothing = folder.appendingPathComponent("Nothing.pdf")
        #expect(!isSameFile(a, nothing))
        #expect(!isSameFile(nothing, a))
        #expect(!isSameFile(nothing, nothing))
    }

    @Test("a different case is the same file on a case-insensitive disk, and not otherwise")
    func differentCase() {
        let folder = temporaryFolder("same")
        let upper = folder.appendingPathComponent("Part.PDF")
        writeDrawnPDF(pages: 1, to: upper)
        let lower = folder.appendingPathComponent("part.pdf")
        #expect(isSameFile(upper, lower) == caseInsensitiveDisk(folder))
    }

    @Test("a path through a symlinked folder, and a hard link, are the same file")
    func linked() throws {
        let folder = temporaryFolder("same")
        let file = folder.appendingPathComponent("Part.pdf")
        writeDrawnPDF(pages: 1, to: file)
        let link = try symlinkedFolder(to: folder)
        #expect(isSameFile(link.appendingPathComponent("Part.pdf"), file))
        let hard = folder.appendingPathComponent("Hard link.pdf")
        try FileManager.default.linkItem(at: file, to: hard)
        #expect(isSameFile(hard, file))
    }

    @Test("Split's replace-the-original check follows case and symlinks")
    func splitCheck() throws {
        let folder = temporaryFolder("same")
        let source = folder.appendingPathComponent("Holst.PDF")
        writeDrawnPDF(pages: 1, to: source)
        let other = temporaryFolder("same")
        #expect(splitOutputReplacesSource(names: ["holst.pdf"], folder: folder, source: source) == caseInsensitiveDisk(folder))
        #expect(splitOutputReplacesSource(names: ["Holst.PDF"], folder: try symlinkedFolder(to: folder), source: source))
        #expect(!splitOutputReplacesSource(names: ["Holst.PDF"], folder: other, source: source))
        #expect(!splitOutputReplacesSource(names: ["Flute.pdf"], folder: folder, source: source))
    }
}

@Suite("Commands never replace their source")
struct NeverReplaceSourceTests {

    private func expectRefusal(_ fragment: String, _ body: () throws -> Void) {
        do {
            try body()
            Issue.record("Expected a refusal mentioning “\(fragment)”")
        } catch let error as CommandError {
            #expect(error.message.contains(fragment), "\(error.message)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("stamp: Part.PDF isn't replaced by its stamped Part.pdf, even with --overwrite")
    func stampDifferentCase() throws {
        let folder = temporaryFolder("stamp")
        let source = folder.appendingPathComponent("Part.PDF")
        writeDrawnPDF(pages: 1, to: source)
        let before = try Data(contentsOf: source)
        guard caseInsensitiveDisk(folder) else { return }   // on a case-sensitive disk they're different files
        expectRefusal("would replace it") {
            _ = try ScoreSortCLI.runStamp(files: [source], stamp: "zz-no-such-stamp-\(UUID().uuidString)",
                                          scope: .everyPage, out: folder.path, dryRun: false, overwrite: true)
        }
        #expect(try Data(contentsOf: source) == before)
    }

    @Test("stamp: a symlinked path to the same folder is refused too")
    func stampThroughSymlink() throws {
        let folder = temporaryFolder("stamp")
        let source = folder.appendingPathComponent("Part.pdf")
        writeDrawnPDF(pages: 1, to: source)
        let link = try symlinkedFolder(to: folder)
        expectRefusal("would replace it") {
            _ = try ScoreSortCLI.runStamp(files: [source], stamp: "zz-no-such-stamp-\(UUID().uuidString)",
                                          scope: .everyPage, out: link.path, dryRun: false, overwrite: true)
        }
    }

    @Test("stamp: another folder passes the guard")
    func stampOtherFolder() throws {
        let folder = temporaryFolder("stamp")
        let source = folder.appendingPathComponent("Part.PDF")
        writeDrawnPDF(pages: 1, to: source)
        do {
            // It then stops at the stamp name, which doesn't exist — after the guard.
            _ = try ScoreSortCLI.runStamp(files: [source], stamp: "zz-no-such-stamp-\(UUID().uuidString)",
                                          scope: .everyPage, out: temporaryFolder("stamp-out").path,
                                          dryRun: true, overwrite: false)
        } catch let error as CommandError {
            #expect(!error.message.contains("would replace"))
        }
    }

    @Test("split-scans: --out in another case is still the scan itself")
    func splitScansDifferentCase() throws {
        let folder = temporaryFolder("scans")
        let scan = folder.appendingPathComponent("Scan.PDF")
        writeDrawnPDF(pages: 1, size: CGSize(width: 1191, height: 842), to: scan)
        let before = try Data(contentsOf: scan)
        guard caseInsensitiveDisk(folder) else { return }
        expectRefusal("not the scan itself") {
            _ = try ScoreSortCLI.runSplitScans(file: scan, out: folder.appendingPathComponent("scan.pdf").path,
                                               mode: .automatic, leftFirst: true, dropBlanks: false,
                                               dryRun: false, overwrite: true)
        }
        #expect(try Data(contentsOf: scan) == before)
    }

    @Test("split: a part named like the source, in its folder, is refused even with --overwrite")
    func splitOverSource() throws {
        let folder = temporaryFolder("split")
        let source = folder.appendingPathComponent("Holst.pdf")
        writeDrawnPDF(pages: 4, to: source)
        let before = try Data(contentsOf: source)
        for (name, dryRun) in [("Holst", false), ("Holst", true)] + (caseInsensitiveDisk(folder) ? [("HOLST", false)] : []) {
            var options = ScoreSortCLI.SplitOptions(out: folder.path)
            options.parts = [(pages: "1-2", name: name), (pages: "3-4", name: "Flute")]
            options.overwrite = true
            options.dryRun = dryRun
            expectRefusal("the PDF being split") { _ = try ScoreSortCLI.runSplit(file: source, options: options) }
        }
        #expect(try Data(contentsOf: source) == before)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Flute.pdf").path))
    }
}
