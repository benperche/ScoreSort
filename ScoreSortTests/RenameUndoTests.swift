//
//  RenameUndoTests.swift
//  ScoreSortTests
//
//  #19: every rename is recorded in a journal, and `undoLastRename` puts it back — only
//  what's still where the rename left it, with its old name free. Journals live in
//  temporary folders here; the real one's location is nil under tests.
//

import Testing
import Foundation
@testable import ScoreSort

@MainActor
@Suite("Undo the last rename")
struct RenameUndoTests {

    private func folderWith(_ names: [String]) -> URL {
        let folder = temporaryFolder("undo")
        for name in names { writeDrawnPDF(pages: 1, to: folder.appendingPathComponent(name)) }
        return folder
    }

    private func journal(_ folder: URL) -> URL { folder.appendingPathComponent("journal/last-rename.json") }

    /// A rename of `from` to `to` (a path inside `folder`, folders allowed).
    private func op(_ folder: URL, _ from: String, _ to: String) -> RenameOperation {
        RenameOperation(originalURL: folder.appendingPathComponent(from), originalName: from,
                        newName: (to as NSString).lastPathComponent,
                        newURL: folder.appendingPathComponent(to), type: .rename)
    }

    private func names(in folder: URL) -> Set<String> {
        let all = FileManager.default.enumerator(atPath: folder.path)?.allObjects as? [String] ?? []
        return Set(all.filter { $0.hasSuffix(".pdf") })
    }

    @Test("the real journal's location is nil under tests")
    func noRealJournalInTests() {
        #expect(RenameJournal.defaultURL == nil)
        #expect(undoLastRename(apply: false).nothingToUndo)
    }

    @Test("a rename is put back, its new folders removed, and the journal cleared")
    func roundTrip() throws {
        let folder = folderWith(["Flute.pdf", "Trumpet.pdf", "Score.pdf"])
        let j = journal(folder)
        let report = performRenames([op(folder, "Score.pdf", "00 - Score.pdf"),
                                     op(folder, "Flute.pdf", "Woodwind/01 - Flute.pdf"),
                                     op(folder, "Trumpet.pdf", "Brass/02 - Trumpet.pdf")], journalAt: j)
        #expect(report.renamed.count == 3)
        #expect(names(in: folder) == ["00 - Score.pdf", "Woodwind/01 - Flute.pdf", "Brass/02 - Trumpet.pdf"])
        #expect(canUndoLastRename(journalAt: j))

        // Planning moves nothing.
        let plan = undoLastRename(apply: false, journalAt: j)
        #expect(plan.restored.count == 3 && plan.problems.isEmpty)
        #expect(names(in: folder).contains("00 - Score.pdf"))

        let undone = undoLastRename(apply: true, journalAt: j)
        #expect(undone.restored.count == 3)
        #expect(names(in: folder) == ["Flute.pdf", "Trumpet.pdf", "Score.pdf"])
        #expect(Set(undone.removedFolders.map(\.lastPathComponent)) == ["Woodwind", "Brass"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Woodwind").path))
        #expect(!canUndoLastRename(journalAt: j))
        #expect(undoLastRename(apply: true, journalAt: j).nothingToUndo)
    }

    @Test("a file moved since, or an old name now taken, is left alone and kept for later")
    func problems() throws {
        let folder = folderWith(["Flute.pdf", "Oboe.pdf", "Horn.pdf"])
        let j = journal(folder)
        performRenames([op(folder, "Flute.pdf", "01 - Flute.pdf"),
                        op(folder, "Oboe.pdf", "02 - Oboe.pdf"),
                        op(folder, "Horn.pdf", "03 - Horn.pdf")], journalAt: j)
        // Flute was moved away; a new file took Oboe's old name.
        let away = temporaryFolder("away").appendingPathComponent("01 - Flute.pdf")
        try FileManager.default.moveItem(at: folder.appendingPathComponent("01 - Flute.pdf"), to: away)
        writeDrawnPDF(pages: 2, to: folder.appendingPathComponent("Oboe.pdf"))

        let report = undoLastRename(apply: true, journalAt: j)
        #expect(report.restored.map(\.to.lastPathComponent) == ["Horn.pdf"])
        #expect(Set(report.problems.map(\.name)) == ["01 - Flute.pdf", "02 - Oboe.pdf"])
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("02 - Oboe.pdf").path))
        // What couldn't be undone stays undoable: put Flute back where it was and try again.
        try FileManager.default.moveItem(at: away, to: folder.appendingPathComponent("01 - Flute.pdf"))
        let again = undoLastRename(apply: true, journalAt: j)
        #expect(again.restored.map(\.to.lastPathComponent) == ["Flute.pdf"])
        #expect(again.problems.map(\.name) == ["02 - Oboe.pdf"])
    }

    @Test("the later folders of a batch add to the journal, so one undo covers the batch")
    func batches() throws {
        let one = folderWith(["Flute.pdf"]), two = folderWith(["Tuba.pdf"])
        let j = journal(one)
        performRenames([op(one, "Flute.pdf", "01 - Flute.pdf")], journalAt: j)
        performRenames([op(two, "Tuba.pdf", "09 - Tuba.pdf")], appendToJournal: true, journalAt: j)
        let report = undoLastRename(apply: true, journalAt: j)
        #expect(report.restored.count == 2)
        #expect(names(in: one) == ["Flute.pdf"] && names(in: two) == ["Tuba.pdf"])
    }

    @Test("a new rename replaces the journal; one that moved nothing keeps it")
    func replacing() throws {
        let folder = folderWith(["Flute.pdf", "Oboe.pdf"])
        let j = journal(folder)
        performRenames([op(folder, "Flute.pdf", "01 - Flute.pdf")], journalAt: j)
        performRenames([op(folder, "Oboe.pdf", "02 - Oboe.pdf")], journalAt: j)
        performRenames([op(folder, "Missing.pdf", "03 - Missing.pdf")], journalAt: j)   // fails, moves nothing
        let saved = try #require(RenameJournal.load(from: j))
        #expect(saved.moves.map { ($0.to as NSString).lastPathComponent } == ["02 - Oboe.pdf"])
        let report = undoLastRename(apply: true, journalAt: j)
        #expect(report.restored.map(\.to.lastPathComponent) == ["Oboe.pdf"])
        #expect(names(in: folder) == ["01 - Flute.pdf", "Oboe.pdf"])
    }

    @Test("a rename that only changed the case can be undone")
    func caseOnly() throws {
        let folder = folderWith(["flute.pdf"])
        let j = journal(folder)
        let report = performRenames([op(folder, "flute.pdf", "Flute.pdf")], journalAt: j)
        guard report.errors.isEmpty else { return }   // a case-sensitive disk may refuse nothing here; either way
        let undone = undoLastRename(apply: true, journalAt: j)
        #expect(undone.problems.isEmpty)
        #expect(names(in: folder) == ["flute.pdf"])
    }

    @Test("folders made outside the rename's own aren't removed, nor ones with files left in them")
    func keepsFoldersInUse() throws {
        let folder = folderWith(["Flute.pdf"])
        let j = journal(folder)
        performRenames([op(folder, "Flute.pdf", "Woodwind/01 - Flute.pdf")], journalAt: j)
        writeDrawnPDF(pages: 1, to: folder.appendingPathComponent("Woodwind/Piccolo.pdf"))
        let report = undoLastRename(apply: true, journalAt: j)
        #expect(report.restored.count == 1)
        #expect(report.removedFolders.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Woodwind/Piccolo.pdf").path))
    }

    @Test("the command line plans, then puts back")
    func commandLine() throws {
        let folder = folderWith(["Flute.pdf"])
        let j = journal(folder)
        #expect(ScoreSortCLI.runUndoRename(apply: false, journalAt: j).json["nothingToUndo"] as? Bool == true)
        performRenames([op(folder, "Flute.pdf", "01 - Flute.pdf")], journalAt: j)
        let plan = ScoreSortCLI.runUndoRename(apply: false, journalAt: j)
        #expect(plan.exitCode == 0)
        #expect((plan.json["files"] as? [[String: Any]])?.count == 1)
        #expect(names(in: folder) == ["01 - Flute.pdf"])
        let done = ScoreSortCLI.runUndoRename(apply: true, journalAt: j)
        #expect(done.json["applied"] as? Bool == true)
        #expect(names(in: folder) == ["Flute.pdf"])
    }

    @Test("undo-rename takes no files, and its MCP tool exists")
    func commandShape() throws {
        let spec = try #require(ScoreSortCLI.command(named: "undo-rename"))
        #expect(spec.flagOptions.contains("apply"))
        #expect(ScoreSortMCPServer.tools.contains { $0.name == "scoresort_undo_rename" && $0.command == "undo-rename" })
    }
}
