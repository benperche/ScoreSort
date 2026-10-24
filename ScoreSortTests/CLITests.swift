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

@Suite("Preset matching (shared by the Combine tab and the command line)")
struct PresetMatchingTests {

    private func files(_ names: [String]) -> [(id: UUID, name: String)] { names.map { (UUID(), $0) } }

    @Test("Each file takes the longest part name it contains")
    func longestWins() {
        let f = files(["Bass Clarinet.pdf", "Clarinet 1.pdf"])
        let result = matchPreset(parts: [PresetPart(name: "Clarinet 1", copies: 6), PresetPart(name: "Bass Clarinet", copies: 1)],
                                 files: f)
        let copies = Dictionary(uniqueKeysWithValues: result.copies.map { ($0.fileId, $0.copies) })
        #expect(copies[f[0].id] == 1)
        #expect(copies[f[1].id] == 6)
        #expect(result.unmatchedFileIds.isEmpty)
    }

    @Test("One entry matching several files has its copies shared, not repeated")
    func sharedEntry() {
        let f = files(["Trumpet 1.pdf", "Trumpet 2.pdf"])
        let result = matchPreset(parts: [PresetPart(name: "Trumpet", copies: 7)], files: f)
        #expect(result.copies.map(\.copies).reduce(0, +) == 7)
        #expect(result.splitFileIds == Set(f.map(\.id)))
    }

    @Test("Numbered parts with one combined file are summed onto it")
    func consolidation() {
        let f = files(["Horns.pdf"])
        let result = matchPreset(parts: [PresetPart(name: "Horn 1", copies: 2), PresetPart(name: "Horn 2", copies: 3)], files: f)
        #expect(result.copies.first?.copies == 5)
        #expect(result.unmatchedPartNames.isEmpty)
    }

    @Test("Unmatched files and parts are reported")
    func unmatched() {
        let f = files(["Kazoo.pdf", "Flute.pdf"])
        let result = matchPreset(parts: [PresetPart(name: "Flute", copies: 4), PresetPart(name: "Oboe", copies: 2)], files: f)
        #expect(result.unmatchedFileIds == [f[0].id])
        #expect(result.unmatchedPartNames == ["Oboe"])
        #expect(result.matchedCount == 1)
    }
}

@Suite("Command: combine and stamp")
@MainActor
struct CLICombineTests {

    private func parts(_ names: [String], pages: Int = 2) -> URL {
        let dir = temporaryFolder("combine")
        for name in names { writeDrawnPDF(pages: pages, to: dir.appendingPathComponent(name)) }
        return dir
    }

    @Test("Combines a folder in name order, with copies, and a bookmark per copy")
    func combine() throws {
        let dir = parts(["01 - Flute.pdf", "02 - Trumpet.pdf"])
        let out = dir.appendingPathComponent("out/All.pdf")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = try ScoreSortCLI.runCombine(paths: [dir.path], out: out.path, preset: nil, copies: ["Trumpet=3"],
                                                 options: CombineOutputOptions(), stamp: nil, stampScope: .everyPage,
                                                 dryRun: false, overwrite: false)
        #expect(result.exitCode == 0)
        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 8)
        #expect(bookmarkSections(in: doc)?.count == 4)
    }

    @Test("A dry run writes nothing; an existing output needs --overwrite")
    func safety() throws {
        let dir = parts(["Flute.pdf"])
        let out = dir.appendingPathComponent("All.pdf")
        let dry = try ScoreSortCLI.runCombine(paths: [dir.path], out: out.path, preset: nil, copies: [],
                                              options: CombineOutputOptions(), stamp: nil, stampScope: .everyPage,
                                              dryRun: true, overwrite: false)
        #expect(dry.json["readingPages"] as? Int == 2)
        #expect(!FileManager.default.fileExists(atPath: out.path))
        writePDF(pages: 1, to: out)
        #expect(throws: CommandError.self) {
            try ScoreSortCLI.runCombine(paths: [dir.appendingPathComponent("Flute.pdf").path], out: out.path, preset: nil,
                                        copies: [], options: CombineOutputOptions(), stamp: nil, stampScope: .everyPage,
                                        dryRun: false, overwrite: false)
        }
    }

    @Test("--copies that matches several files asks for more of the name")
    func ambiguousCopies() {
        let dir = parts(["Flute 1.pdf", "Flute 2.pdf"])
        #expect(throws: CommandError.self) {
            try ScoreSortCLI.runCombine(paths: [dir.path], out: dir.appendingPathComponent("x.pdf").path, preset: nil,
                                        copies: ["Flute=2"], options: CombineOutputOptions(), stamp: nil,
                                        stampScope: .everyPage, dryRun: true, overwrite: false)
        }
    }

    @Test("stamp never writes over the original, even with --overwrite")
    func stampKeepsOriginal() throws {
        let dir = parts(["Flute.pdf"])
        do {
            _ = try ScoreSortCLI.runStamp(files: [dir.appendingPathComponent("Flute.pdf")], stamp: "any",
                                          scope: .everyPage, out: dir.path, dryRun: false, overwrite: true)
            Issue.record("Expected an error")
        } catch let error as CommandError {
            #expect(error.message.contains("would replace it"))
        }
    }
}

@Suite("Step 2 preview area")
struct InstrumentPreviewAreaTests {

    private let a4 = CGSize(width: 595, height: 842)

    @Test("A wide strip shows the full 200 pt width and as much height as its shape allows")
    func wideStrip() {
        let crop = instrumentPreviewCrop(pageSize: a4, stripSize: CGSize(width: 900, height: 150))
        #expect(crop.width == 200)
        #expect(abs(crop.height - 200 / 6) < 0.001)
    }

    @Test("A narrow strip shows the full 100 pt height and less width")
    func narrowStrip() {
        let crop = instrumentPreviewCrop(pageSize: a4, stripSize: CGSize(width: 150, height: 150))
        #expect(crop == CGSize(width: 100, height: 100))
    }

    @Test("The shown area keeps the strip's shape, so nothing on screen is clipped away")
    func matchesStripShape() {
        for strip in [CGSize(width: 900, height: 150), CGSize(width: 300, height: 150), CGSize(width: 100, height: 150)] {
            let crop = instrumentPreviewCrop(pageSize: a4, stripSize: strip)
            #expect(abs(crop.width / crop.height - strip.width / strip.height) < 0.001)
        }
    }

    @Test("Panning stays on the page, and can reach its bottom")
    func origin() {
        let crop = CGSize(width: 200, height: 33)
        #expect(instrumentPreviewOrigin(offset: .zero, pageSize: a4, crop: crop) == .zero)
        #expect(instrumentPreviewOrigin(offset: CGPoint(x: 150, y: -300), pageSize: a4, crop: crop) == CGPoint(x: 150, y: 300))
        #expect(instrumentPreviewOrigin(offset: CGPoint(x: 9999, y: -9999), pageSize: a4, crop: crop) == CGPoint(x: 395, y: 809))
        #expect(instrumentPreviewOrigin(offset: CGPoint(x: -50, y: 50), pageSize: a4, crop: crop) == .zero)
    }
}

@Suite("Naming preview page")
struct FirstKeptPageTests {
    @Test("A skipped first page gives way to the first page that's kept")
    func skipsSkipped() {
        #expect(firstKeptPage(fileStart: 10, fileSize: 8, skippedPages: [10]) == 11)
        #expect(firstKeptPage(fileStart: 10, fileSize: 8, skippedPages: [10, 11, 12]) == 13)
        #expect(firstKeptPage(fileStart: 10, fileSize: 8, skippedPages: [3, 14]) == 10)
    }

    @Test("Every page skipped: the file's first page")
    func allSkipped() {
        #expect(firstKeptPage(fileStart: 4, fileSize: 2, skippedPages: [4, 5]) == 4)
        #expect(firstKeptPage(fileStart: 4, fileSize: 0, skippedPages: []) == 4)
    }
}

@Suite("Ensemble allocation (allocate / combine --allocate)")
@MainActor
struct AllocationTests {

    private func files(_ names: [String]) -> [AllocationFile] {
        names.map { AllocationFile(id: UUID(), name: $0, pages: 2) }
    }

    private let preset = EnsemblePreset(name: "Band", parts: [
        PresetPart(name: "Flute", copies: 6),
        PresetPart(name: "Clarinet", copies: 9),
        PresetPart(name: "Bass Guitar", copies: 2),
    ])

    private func copies(_ a: EnsembleAllocation, _ f: [AllocationFile], _ name: String) -> Int? {
        f.first { $0.name == name }.flatMap { a.copies[$0.id] }
    }

    @Test("Choices parse as PART=FILE or PART=FILE:N")
    func parsing() throws {
        let a = try AllocationChoice("Bass Guitar=Tuba")
        #expect(a.part == "Bass Guitar" && a.file == "Tuba" && a.copies == nil)
        let b = try AllocationChoice("Clarinet=Clarinet 1:5")
        #expect(b.file == "Clarinet 1" && b.copies == 5)
        #expect(throws: CommandError.self) { try AllocationChoice("Tuba") }
        #expect(throws: CommandError.self) { try AllocationChoice("=Tuba") }
    }

    @Test("The matcher records which group each file was given")
    func assignmentsRecorded() {
        let f = files(["Flute 1.pdf", "Flute 2.pdf"])
        let result = matchPreset(parts: [PresetPart(name: "Flute", copies: 5)], files: f.map { ($0.id, $0.name) })
        #expect(result.assignments.map(\.part) == ["Flute", "Flute"])
        #expect(result.assignments.map(\.copies).reduce(0, +) == 5)
    }

    @Test("Automatic matching leaves a group with no part, reported to decide")
    func groupWithoutPart() throws {
        let f = files(["Flute.pdf", "Clarinet 1.pdf", "Clarinet 2.pdf", "Tuba.pdf"])
        let a = try ScoreSortCLI.buildAllocation(files: f, preset: preset, choices: [], copies: [])
        #expect(copies(a, f, "Flute.pdf") == 6)
        #expect((copies(a, f, "Clarinet 1.pdf") ?? 0) + (copies(a, f, "Clarinet 2.pdf") ?? 0) == 9)
        #expect(copies(a, f, "Tuba.pdf") == 1)   // nobody in the preset: one spare
        let described = ScoreSortCLI.describeAllocation(a, files: f)
        #expect(described.toDecide.contains { $0.contains("Bass Guitar") })
    }

    @Test("--allocate gives a group's players a file, adding to what that file already has")
    func allocateToExistingPart() throws {
        let f = files(["Flute.pdf", "Clarinet.pdf", "Tuba.pdf"])
        let a = try ScoreSortCLI.buildAllocation(files: f, preset: preset,
                                                 choices: [try AllocationChoice("Bass Guitar=Tuba")], copies: [])
        #expect(copies(a, f, "Tuba.pdf") == 2)
        #expect(!a.withoutPlayers.contains(f[2].id))
        #expect(ScoreSortCLI.describeAllocation(a, files: f).toDecide.isEmpty)
    }

    @Test("A group split by hand: fixed numbers, and the rest shared")
    func manualSplit() throws {
        let f = files(["Flute.pdf", "Clarinet 1.pdf", "Clarinet 2.pdf", "Clarinet 3.pdf"])
        let a = try ScoreSortCLI.buildAllocation(files: f, preset: preset, choices: [
            try AllocationChoice("Clarinet=Clarinet 1:5"),
            try AllocationChoice("Clarinet=Clarinet 2"),
            try AllocationChoice("Clarinet=Clarinet 3"),
        ], copies: [])
        #expect(copies(a, f, "Clarinet 1.pdf") == 5)
        #expect(copies(a, f, "Clarinet 2.pdf") == 2)
        #expect(copies(a, f, "Clarinet 3.pdf") == 2)
    }

    @Test("--copies sets a total last; 0 leaves a file out")
    func copiesOverride() throws {
        let f = files(["Flute.pdf", "Clarinet.pdf", "Harp.pdf"])
        let a = try ScoreSortCLI.buildAllocation(files: f, preset: preset, choices: [],
                                                 copies: ["Harp=0", "Flute=8"])
        #expect(copies(a, f, "Harp.pdf") == 0)
        #expect(copies(a, f, "Flute.pdf") == 8)
    }

    @Test("Unknown parts, and --allocate without a preset, are errors")
    func errors() {
        let f = files(["Flute.pdf"])
        #expect(throws: CommandError.self) {
            try ScoreSortCLI.buildAllocation(files: f, preset: preset, choices: [try AllocationChoice("Kazoo=Flute")], copies: [])
        }
        #expect(throws: CommandError.self) {
            try ScoreSortCLI.buildAllocation(files: f, preset: nil, choices: [try AllocationChoice("Flute=Flute")], copies: [])
        }
    }

    @Test("combine leaves out a file given 0 copies")
    func combineLeavesOut() throws {
        let dir = temporaryFolder("alloc")
        for name in ["Flute.pdf", "Harp.pdf"] { writeDrawnPDF(pages: 2, to: dir.appendingPathComponent(name)) }
        let out = dir.appendingPathComponent("out/All.pdf")
        let result = try ScoreSortCLI.runCombine(paths: [dir.path], out: out.path, preset: nil, copies: ["Harp=0"],
                                                 options: CombineOutputOptions(), stamp: nil, stampScope: .everyPage,
                                                 dryRun: false, overwrite: false)
        #expect(result.exitCode == 0)
        #expect(PDFDocument(url: out)?.pageCount == 2)
    }

    @Test("MCP allocations become --allocate options")
    func mcpAllocations() throws {
        let tool = try #require(ScoreSortMCPServer.tools.first { $0.name == "scoresort_allocate" })
        let argv = try ScoreSortMCPServer.argv(for: tool, arguments: [
            "paths": ["/x/Parts"], "preset": "Band",
            "allocations": [["part": "Bass Guitar", "file": "Tuba"], ["part": "Clarinet", "file": "Clarinet 1", "copies": 5]]])
        #expect(argv == ["--preset", "Band", "--allocate", "Bass Guitar=Tuba", "--allocate", "Clarinet=Clarinet 1:5", "--", "/x/Parts"])
    }
}

@Suite("Command: find")
struct CLIFindTests {

    @Test("Every word must appear; prefixes and longer fragments match; punctuation ignored")
    func matching() {
        let words = ScoreSortCLI.searchWords("holst scan")
        #expect(ScoreSortCLI.nameMatches("Holst_First-Suite (scan)", words: words))
        #expect(!ScoreSortCLI.nameMatches("Holst First Suite", words: words))
        #expect(ScoreSortCLI.nameMatches("Clarinet 2", words: ScoreSortCLI.searchWords("clar")))
        #expect(ScoreSortCLI.nameMatches("AltoSaxes", words: ScoreSortCLI.searchWords("saxe")))
        #expect(ScoreSortCLI.nameMatches("Élégie", words: ScoreSortCLI.searchWords("elegie")))
    }

    @Test("Finds PDFs and folders by name, newest first, skipping developer folders")
    func finds() throws {
        let root = temporaryFolder("find")
        let parts = root.appendingPathComponent("Holst Parts")
        let junk = root.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        writeDrawnPDF(pages: 3, to: parts.appendingPathComponent("Holst Flute.pdf"))
        writeDrawnPDF(pages: 1, to: root.appendingPathComponent("Holst Scan.pdf"))
        writeDrawnPDF(pages: 1, to: junk.appendingPathComponent("Holst Hidden.pdf"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)],
                                              ofItemAtPath: parts.appendingPathComponent("Holst Flute.pdf").path)

        let pdfs = try ScoreSortCLI.runFind(words: ["holst"], folders: [root.path], kind: "pdf", limit: 20)
        let results = try #require(pdfs.json["results"] as? [[String: Any]])
        #expect(results.compactMap { $0["name"] as? String } == ["Holst Scan.pdf", "Holst Flute.pdf"])
        #expect(results.last?["pages"] as? Int == 3)

        let folders = try ScoreSortCLI.runFind(words: ["holst", "parts"], folders: [root.path], kind: "folder", limit: 20)
        let folder = try #require((folders.json["results"] as? [[String: Any]])?.first)
        #expect(folder["name"] as? String == "Holst Parts")
        #expect(folder["files"] as? Int == 1)
    }

    @Test("With no folders shared, nothing is searched — it says how to give a path instead")
    func nothingShared() throws {
        let result = try ScoreSortCLI.runFind(words: ["holst"], folders: [], kind: "pdf", limit: 20, shared: [])
        #expect(result.json["noSharedFolders"] as? Bool == true)
        #expect((result.json["results"] as? [Any])?.isEmpty == true)
        #expect(result.text.contains("⌥⌘C"))
    }

    @Test("Without --in, only the shared folders are searched")
    func sharedFoldersOnly() throws {
        let shared = temporaryFolder("shared")
        let private_ = temporaryFolder("private")
        writeDrawnPDF(pages: 1, to: shared.appendingPathComponent("Holst Scan.pdf"))
        writeDrawnPDF(pages: 1, to: private_.appendingPathComponent("Holst Other.pdf"))
        let result = try ScoreSortCLI.runFind(words: ["holst"], folders: [], kind: "pdf", limit: 20,
                                              shared: [shared, shared.appendingPathComponent("gone")])
        let names = (result.json["results"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names == ["Holst Scan.pdf"])
        #expect(result.json["searched"] as? [String] == [shared.standardizedFileURL.path])
    }

    @Test("A file dated in the future doesn't jump to the top")
    func futureDates() throws {
        let root = temporaryFolder("find")
        writeDrawnPDF(pages: 1, to: root.appendingPathComponent("Old Suite.pdf"))
        writeDrawnPDF(pages: 1, to: root.appendingPathComponent("New Suite.pdf"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(86_400 * 365 * 50),
                                               .creationDate: Date().addingTimeInterval(-86_400)],
                                              ofItemAtPath: root.appendingPathComponent("Old Suite.pdf").path)
        let result = try ScoreSortCLI.runFind(words: ["suite"], folders: [root.path], kind: "pdf", limit: 20)
        let names = (result.json["results"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names == ["New Suite.pdf", "Old Suite.pdf"])
    }
}

@Suite("Connecting AI assistants")
struct AIConnectionTests {

    private func dict(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Adding ScoreSort keeps every other setting and server")
    func addKeepsEverything() throws {
        let existing = Data(#"{"preferences":{"menuBarEnabled":false},"mcpServers":{"other":{"command":"/bin/other"}}}"#.utf8)
        let entry = AIConnection.serverEntry(executable: "/Applications/ScoreSort.app/Contents/MacOS/ScoreSort", debugBuild: false)
        let updated = try dict(AIConnection.settingsAdding(entry, to: existing))
        #expect((updated["preferences"] as? [String: Any])?["menuBarEnabled"] as? Bool == false)
        let servers = try #require(updated["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil)
        let scoresort = try #require(servers["scoresort"] as? [String: Any])
        #expect(scoresort["args"] as? [String] == ["mcp"])
        #expect(scoresort["env"] == nil)
        #expect(AIConnection.configuredExecutable(in: try AIConnection.settingsAdding(entry, to: existing))
                == "/Applications/ScoreSort.app/Contents/MacOS/ScoreSort")
    }

    @Test("A missing or empty settings file is started fresh")
    func freshFile() throws {
        let entry = AIConnection.serverEntry(executable: "/x/ScoreSort", debugBuild: true)
        for data in [nil, Data(), Data("  \n".utf8)] as [Data?] {
            let updated = try dict(AIConnection.settingsAdding(entry, to: data))
            let scoresort = (updated["mcpServers"] as? [String: Any])?["scoresort"] as? [String: Any]
            #expect((scoresort?["env"] as? [String: String])?["LLVM_PROFILE_FILE"] == "/dev/null")
        }
    }

    @Test("A settings file that isn't JSON is never overwritten")
    func unreadableFileRefused() {
        #expect(throws: CommandError.self) {
            try AIConnection.settingsAdding([:], to: Data("not json {".utf8))
        }
        #expect(throws: CommandError.self) {
            try AIConnection.settingsRemoving(from: Data("[1,2]".utf8))
        }
    }

    @Test("Removing ScoreSort leaves the other servers")
    func remove() throws {
        let existing = Data(#"{"mcpServers":{"other":{"command":"/bin/other"},"scoresort":{"command":"/x"}}}"#.utf8)
        let updated = try dict(AIConnection.settingsRemoving(from: existing))
        let servers = try #require(updated["mcpServers"] as? [String: Any])
        #expect(servers["other"] != nil && servers["scoresort"] == nil)
        #expect(AIConnection.configuredExecutable(in: try AIConnection.settingsRemoving(from: existing)) == nil)
    }

    @Test("The command script runs this copy, and is recognised again — even with quotes in the path")
    func wrapperScript() {
        for path in ["/Applications/ScoreSort.app/Contents/MacOS/ScoreSort", "/Users/me/Ben's Apps/ScoreSort.app/Contents/MacOS/ScoreSort"] {
            let script = AIConnection.wrapperScript(executable: path)
            #expect(script.hasPrefix("#!/bin/sh\n"))
            #expect(AIConnection.wrapperExecutable(script) == path)
        }
        #expect(AIConnection.wrapperExecutable("#!/bin/sh\necho hello\n") == nil)
    }

    @Test("A translocated app is spotted")
    func translocation() {
        #expect(AIConnection.isTranslocated("/private/var/folders/x/AppTranslocation/ABC/d/ScoreSort.app/Contents/MacOS/ScoreSort"))
        #expect(!AIConnection.isTranslocated("/Applications/ScoreSort.app/Contents/MacOS/ScoreSort"))
    }

    @Test("The setup snippet is valid MCP config")
    func snippet() throws {
        let text = AIConnection.setupSnippet(executable: "/Applications/ScoreSort.app/Contents/MacOS/ScoreSort", debugBuild: false)
        let parsed = try dict(Data(text.utf8))
        #expect(((parsed["mcpServers"] as? [String: Any])?["scoresort"] as? [String: Any])?["command"] as? String
                == "/Applications/ScoreSort.app/Contents/MacOS/ScoreSort")
    }
}
