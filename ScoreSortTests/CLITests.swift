//
//  CLITests.swift
//  ScoreSortTests
//
//  ScoreSort's command line (CLI/): argument parsing, page lists, which arguments switch
//  the executable into command mode, and each command run directly through its `run…`
//  function on fixture PDFs.
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

/// A fresh empty folder in the temporary directory.
func temporaryFolder(_ label: String = "cli") -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A PDF drawn by Core Graphics — so pages have the Core Graphics page the renderer
/// uses — with `pages` pages of `size`, each with a black square near the top.
func writeDrawnPDF(pages: Int, size: CGSize = CGSize(width: 595, height: 842), to url: URL) {
    var box = CGRect(origin: .zero, size: size)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    for _ in 0..<pages {
        ctx.beginPDFPage(nil)
        ctx.fill(CGRect(x: 40, y: size.height - 120, width: 80, height: 80))
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

@Suite("Command-line arguments")
struct CLIArgumentTests {

    @Test("Values, repeated values, inline values and flags")
    func parsing() throws {
        let args = try CommandArguments.parse(
            ["in.pdf", "--part", "1-2=Flute 1", "--part=3-4=Flute 2", "--out", "/tmp/x", "--dry-run"],
            valueOptions: ["part", "out"], flagOptions: ["dry-run"])
        #expect(args.positionals == ["in.pdf"])
        #expect(args.all("part") == ["1-2=Flute 1", "3-4=Flute 2"])
        #expect(args.value("out") == "/tmp/x")
        #expect(args.has("dry-run"))
    }

    @Test("Unknown options and missing values are errors, not ignored")
    func strictParsing() {
        #expect(throws: CommandError.self) {
            try CommandArguments.parse(["--ovewrite"], valueOptions: [], flagOptions: ["overwrite"])
        }
        #expect(throws: CommandError.self) {
            try CommandArguments.parse(["--out"], valueOptions: ["out"], flagOptions: [])
        }
        #expect(throws: CommandError.self) {
            try CommandArguments.parse(["--dry-run=yes"], valueOptions: [], flagOptions: ["dry-run"])
        }
    }

    @Test("Page lists: ranges, open ends, all, order kept")
    func pageLists() throws {
        #expect(try parsePageList("1-3,5", pageCount: 10) == [0, 1, 2, 4])
        #expect(try parsePageList("8-", pageCount: 10) == [7, 8, 9])
        #expect(try parsePageList("all", pageCount: 3) == [0, 1, 2])
        #expect(try parsePageList("3,1,3", pageCount: 3) == [2, 0])
        #expect(throws: CommandError.self) { try parsePageList("0-2", pageCount: 3) }
        #expect(throws: CommandError.self) { try parsePageList("2-9", pageCount: 3) }
        #expect(throws: CommandError.self) { try parsePageList("x", pageCount: 3) }
        #expect(describePages([0, 1, 2, 4, 6, 7]) == "1-3, 5, 7-8")
    }

    @Test("Only explicit verbs switch the executable into command mode")
    func commandModeSwitch() {
        #expect(ScoreSortCLI.isCommandLineInvocation(["info", "a.pdf"]))
        #expect(ScoreSortCLI.isCommandLineInvocation(["help"]))
        #expect(ScoreSortCLI.isCommandLineInvocation(["mcp"]))
        #expect(!ScoreSortCLI.isCommandLineInvocation([]))
        #expect(!ScoreSortCLI.isCommandLineInvocation(["-NSDocumentRevisionsDebugMode", "YES"]))
        #expect(!ScoreSortCLI.isCommandLineInvocation(["/Users/someone/file.pdf"]))
    }

    @Test("Every command has help, and the general help lists it")
    func helpComplete() {
        for spec in ScoreSortCLI.commands {
            #expect(spec.help.contains("Usage: ScoreSort \(spec.name)"))
            #expect(ScoreSortCLI.generalHelp.contains(spec.name))
        }
    }
}

@Suite("Command: info and preview")
struct CLIInspectTests {

    @Test("info reports pages, bookmarks and their suggested names")
    func info() throws {
        let folder = temporaryFolder()
        let url = folder.appendingPathComponent("Suite.pdf")
        let doc = PDFDocument()
        for i in 0..<4 { doc.insert(PDFPage(), at: i) }
        let root = PDFOutline()
        for (label, page) in [("First Suite - Flute", 0), ("First Suite - Clarinet", 2)] {
            let item = PDFOutline()
            item.label = label
            item.destination = PDFDestination(page: doc.page(at: page)!, at: .zero)
            root.insertChild(item, at: root.numberOfChildren)
        }
        doc.outlineRoot = root
        #expect(doc.write(to: url))

        let result = try ScoreSortCLI.runInfo(file: url)
        #expect(result.json["pageCount"] as? Int == 4)
        let bookmarks = try #require(result.json["bookmarks"] as? [[String: Any]])
        #expect(bookmarks.count == 2)
        #expect(bookmarks[1]["pages"] as? String == "3-4")
        #expect(bookmarks[1]["suggestedName"] as? String == "Clarinet")
        #expect(result.json["suggestedBaseName"] as? String == "First Suite")
        #expect(result.json["looksLikeDoublePageScan"] as? Bool == false)
    }

    @Test("info flags a double-page scan")
    func infoDoublePages() throws {
        let url = temporaryFolder().appendingPathComponent("A3.pdf")
        writeDrawnPDF(pages: 3, size: CGSize(width: 1191, height: 842), to: url)
        let result = try ScoreSortCLI.runInfo(file: url)
        #expect(result.json["looksLikeDoublePageScan"] as? Bool == true)
        #expect(result.json["uniformSheets"] as? Bool == true)
    }

    @Test("preview writes one image per chosen page; --top keeps the top third")
    func preview() throws {
        let folder = temporaryFolder()
        let url = folder.appendingPathComponent("Part.pdf")
        writeDrawnPDF(pages: 3, to: url)
        let out = folder.appendingPathComponent("previews")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let full = try ScoreSortCLI.runPreview(file: url, folder: out, pages: "1,3", topOnly: false, width: 300, png: true)
        #expect(full.exitCode == 0)
        #expect(full.images.map(\.lastPathComponent) == ["Part-p001.png", "Part-p003.png"])

        let top = try ScoreSortCLI.runPreview(file: url, folder: out, pages: "2", topOnly: true, width: 300, png: false)
        let topURL = try #require(top.images.first)
        let image = try #require(NSImage(contentsOf: topURL))
        let rep = try #require(image.representations.first)
        #expect(rep.pixelsWide == 300)
        #expect(abs(rep.pixelsHigh - Int(300 * 842 / 595 / 3)) <= 1)
    }
}

@Suite("Split writing (shared by the Split tab and the command line)")
struct SplitWritingTests {

    @Test("Plans follow the page → file mapping, leaving out skipped pages and empty files")
    func plansFromMapping() {
        let plans = splitFilePlans(pageToFile: [0: 0, 1: 0, 2: 1, 3: 2], pageCount: 4, skippedPages: [3]) { "F\($0).pdf" }
        #expect(plans == [SplitFilePlan(name: "F0.pdf", pages: [0, 1]), SplitFilePlan(name: "F1.pdf", pages: [2])])
    }

    @Test("Writes each planned file with its pages, leaving the source alone")
    func writes() throws {
        let folder = temporaryFolder()
        let source = folder.appendingPathComponent("in.pdf")
        writeDrawnPDF(pages: 5, to: source)
        let doc = try #require(PDFDocument(url: source))
        let report = writeSplitFiles([SplitFilePlan(name: "A.pdf", pages: [0, 4]), SplitFilePlan(name: "B.pdf", pages: [2])],
                                     from: doc, to: folder, stampJob: nil)
        #expect(report.written == ["A.pdf", "B.pdf"])
        #expect(report.failures.isEmpty)
        #expect(PDFDocument(url: folder.appendingPathComponent("A.pdf"))?.pageCount == 2)
        #expect(doc.pageCount == 5)
    }

    @Test("Score-order file names: two-digit numbers, the separator, skipped items left out")
    func scoreOrderNames() {
        var items = [PrefixItem(id: 0, proposedName: "Suite - Score.pdf", page: nil, isScore: true),
                     PrefixItem(id: 1, proposedName: "Suite - Flute.pdf", page: nil),
                     PrefixItem(id: 2, proposedName: "Suite - Oboe.pdf", page: nil)]
        items[2].isSkipped = true
        #expect(scoreOrderFileNames(forOrderedItems: items, separator: "_") ==
                [0: "00_Suite - Score.pdf", 1: "01_Suite - Flute.pdf"])
    }
}

@Suite("Command: split")
struct CLISplitTests {

    private func fixture(pages: Int = 8) -> (URL, URL) {
        let folder = temporaryFolder()
        let url = folder.appendingPathComponent("Band.pdf")
        writeDrawnPDF(pages: pages, to: url)
        return (url, folder.appendingPathComponent("out"))
    }

    private func options(_ out: URL, _ parts: [(String, String)]) -> ScoreSortCLI.SplitOptions {
        var o = ScoreSortCLI.SplitOptions(out: out.path)
        o.parts = parts.map { (pages: $0.0, name: $0.1) }
        o.separator = " - "
        o.prefixSeparator = " - "
        return o
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".pdf") }.sorted()
    }

    @Test("Parts become files named base + separator + part, with their pages")
    func namedParts() throws {
        let (file, out) = fixture()
        var o = options(out, [("1-2", "Flute 1"), ("3,5", "Clarinet 1"), ("6-8", "Trumpet 1")])
        o.base = "Holst - First Suite"
        let result = try ScoreSortCLI.runSplit(file: file, options: o)
        #expect(result.exitCode == 0)
        #expect(names(in: out) == ["Holst - First Suite - Clarinet 1.pdf", "Holst - First Suite - Flute 1.pdf",
                                   "Holst - First Suite - Trumpet 1.pdf"])
        #expect(PDFDocument(url: out.appendingPathComponent("Holst - First Suite - Clarinet 1.pdf"))?.pageCount == 2)
        let warnings = try #require(result.json["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("Pages 4 aren't in any part") })
    }

    @Test("--score-order numbers the files as Step 3 would: score 00, then instrument order")
    func scoreOrder() throws {
        let (file, out) = fixture()
        var o = options(out, [("1-2", "Trumpet 1"), ("3-4", "Full Score"), ("5-6", "Flute"), ("7-8", "Kazoo")])
        o.scoreOrder = .band
        let result = try ScoreSortCLI.runSplit(file: file, options: o)
        #expect(result.exitCode == 0)
        #expect(names(in: out) == ["00 - Full Score.pdf", "01 - Flute.pdf", "02 - Trumpet 1.pdf", "03 - Kazoo.pdf"])
        let warnings = try #require(result.json["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("Kazoo") })
    }

    @Test("A dry run writes nothing")
    func dryRun() throws {
        let (file, out) = fixture()
        var o = options(out, [("1-8", "Flute")])
        o.dryRun = true
        let result = try ScoreSortCLI.runSplit(file: file, options: o)
        #expect(result.json["dryRun"] as? Bool == true)
        #expect(names(in: out).isEmpty)
    }

    @Test("Existing files stop the split unless --overwrite")
    func noSilentOverwrite() throws {
        let (file, out) = fixture()
        _ = try ScoreSortCLI.runSplit(file: file, options: options(out, [("1-8", "Flute")]))
        #expect(throws: CommandError.self) {
            try ScoreSortCLI.runSplit(file: file, options: options(out, [("1-8", "Flute")]))
        }
        var o = options(out, [("1-8", "Flute")])
        o.overwrite = true
        #expect(try ScoreSortCLI.runSplit(file: file, options: o).exitCode == 0)
    }

    @Test("Two parts with one name are refused")
    func duplicateNames() {
        let (file, out) = fixture()
        #expect(throws: CommandError.self) {
            try ScoreSortCLI.runSplit(file: file, options: options(out, [("1-2", "Flute"), ("3-4", "flute")]))
        }
    }

    @Test("Skipped pages are left out of their part")
    func skips() throws {
        let (file, out) = fixture()
        var o = options(out, [("1-8", "Flute")])
        o.skip = "2,7-8"
        _ = try ScoreSortCLI.runSplit(file: file, options: o)
        #expect(PDFDocument(url: out.appendingPathComponent("Flute.pdf"))?.pageCount == 5)
    }
}

@Suite("Command: split-scans")
struct CLISplitScansTests {

    @Test("Identical A3 sheets are all cut down the middle")
    func uniformSheets() throws {
        let folder = temporaryFolder()
        let file = folder.appendingPathComponent("A3.pdf")
        writeDrawnPDF(pages: 3, size: CGSize(width: 1191, height: 842), to: file)
        let out = folder.appendingPathComponent("pages.pdf")
        let result = try ScoreSortCLI.runSplitScans(file: file, out: out.path, mode: .automatic, leftFirst: true,
                                                    dropBlanks: false, dryRun: false, overwrite: false)
        #expect(result.json["sameCut"] as? Double == 0.5)
        let split = try #require(PDFDocument(url: out))
        #expect(split.pageCount == 6)
        #expect(abs((split.page(at: 0)?.bounds(for: .cropBox).width ?? 0) - 595.5) < 0.5)
    }

    @Test("Empty halves are reported for skipping, or dropped")
    func blanks() throws {
        let folder = temporaryFolder()
        let file = folder.appendingPathComponent("A3.pdf")
        writeDrawnPDF(pages: 2, size: CGSize(width: 1191, height: 842), to: file)   // the right half of each is empty
        let kept = try ScoreSortCLI.runSplitScans(file: file, out: folder.appendingPathComponent("a.pdf").path,
                                                  mode: .automatic, leftFirst: true, dropBlanks: false,
                                                  dryRun: false, overwrite: false)
        #expect(kept.json["suggestedSkip"] as? String == "2, 4")
        let dropped = try ScoreSortCLI.runSplitScans(file: file, out: folder.appendingPathComponent("b.pdf").path,
                                                     mode: .automatic, leftFirst: true, dropBlanks: true,
                                                     dryRun: false, overwrite: false)
        #expect(dropped.json["pageCount"] as? Int == 2)
    }

    @Test("Never writes over the scan itself")
    func notOverInput() {
        let folder = temporaryFolder()
        let file = folder.appendingPathComponent("A3.pdf")
        writeDrawnPDF(pages: 1, size: CGSize(width: 1191, height: 842), to: file)
        #expect(throws: CommandError.self) {
            try ScoreSortCLI.runSplitScans(file: file, out: file.path, mode: .automatic, leftFirst: true,
                                           dropBlanks: false, dryRun: false, overwrite: true)
        }
    }
}

@Suite("Command: rename")
@MainActor
struct CLIRenameTests {

    private func folder(with names: [String]) -> URL {
        let dir = temporaryFolder("rename")
        for name in names { writePDF(pages: 1, to: dir.appendingPathComponent(name)) }
        return dir
    }

    private func contents(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".pdf") }.sorted()
    }

    @Test("The command line plans a folder exactly as the Rename tab does")
    func sameAsRenameTab() {
        InstrumentOrders.setup()
        let dir = folder(with: ["Flute 1.pdf", "Score.pdf", "Trumpet 2.pdf", "Clarinet 1.pdf", "Kazoo.pdf", "01 - Oboe.pdf"])
        let manager = RenamerManager()   // (its separator is the user's setting — read, never set, here)
        manager.loadFolder(url: dir)
        let planned = planScoreOrderRename(files: renamableFiles(in: dir, recursive: false),
                                           order: manager.customInstrumentOrder, separator: manager.prefixSeparator)
        #expect(planned.map(\.originalName) == manager.operations.map(\.originalName))
        #expect(planned.map(\.newName) == manager.operations.map(\.newName))
        #expect(planned.map(\.type) == manager.operations.map(\.type))
    }

    @Test("Without --apply nothing is renamed")
    func planOnly() throws {
        let dir = folder(with: ["Flute 1.pdf", "Score.pdf"])
        let result = try ScoreSortCLI.runRename(paths: [dir.path], ensemble: .band, separator: " - ", apply: false)
        #expect(result.json["applied"] as? Bool == false)
        #expect(contents(dir) == ["Flute 1.pdf", "Score.pdf"])
    }

    @Test("--apply renames into score order; --number places an unrecognised part")
    func apply() throws {
        let dir = folder(with: ["Flute 1.pdf", "Score.pdf", "Trumpet 2.pdf", "Kazoo.pdf"])
        let result = try ScoreSortCLI.runRename(paths: [dir.path], ensemble: .band, overrides: ["Kazoo.pdf": 9],
                                                separator: " - ", apply: true)
        #expect(result.exitCode == 0)
        #expect(contents(dir) == ["00 - Score.pdf", "01 - Flute 1.pdf", "02 - Trumpet 2.pdf", "09 - Kazoo.pdf"])
    }

    @Test("Unrecognised files are reported and left alone")
    func unrecognised() throws {
        let dir = folder(with: ["Flute 1.pdf", "Kazoo.pdf"])
        let result = try ScoreSortCLI.runRename(paths: [dir.path], ensemble: .band, separator: " - ", apply: true)
        #expect(result.json["unrecognised"] as? [String] == ["Kazoo.pdf"])
        #expect(contents(dir) == ["01 - Flute 1.pdf", "Kazoo.pdf"])
    }

    @Test("--number or --exclude for a file that isn't there is an error")
    func unknownFile() {
        let dir = folder(with: ["Flute 1.pdf"])
        #expect(throws: CommandError.self) {
            try ScoreSortCLI.runRename(paths: [dir.path], ensemble: .band, overrides: ["Flute.pdf": 3], apply: false)
        }
    }

    @Test("--rescan re-numbers files that already have numbers")
    func rescan() throws {
        let dir = folder(with: ["02 - Flute 1.pdf", "01 - Trumpet 1.pdf"])
        _ = try ScoreSortCLI.runRename(paths: [dir.path], ensemble: .band, rescan: true, separator: " - ", apply: true)
        #expect(contents(dir) == ["01 - Flute 1.pdf", "02 - Trumpet 1.pdf"])
    }
}
