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
