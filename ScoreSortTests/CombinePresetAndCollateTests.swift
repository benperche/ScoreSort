//
//  CombinePresetAndCollateTests.swift
//  ScoreSortTests
//
//  CombineManager.applyPreset (moved out of CombineView for #14) and the page order of
//  collated output: a collate group's files are interleaved, set by set.
//

import Testing
import Foundation
import PDFKit
@testable import ScoreSort

@MainActor
@Suite("Combine: applying a preset")
struct CombineApplyPresetTests {

    private func manager(_ names: [String]) -> CombineManager {
        let m = CombineManager()
        m.files = names.map { CombineFile(url: URL(fileURLWithPath: "/tmp/\($0).pdf"), name: $0, pageCount: 1, copies: 1) }
        return m
    }

    private func copies(_ m: CombineManager) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: m.files.map { ($0.name, $0.copies) })
    }

    @Test("copies are set from the preset; files matching nothing keep theirs and are reported")
    func setsCopies() {
        let m = manager(["01 Flute", "02 Bass Clarinet", "03 Clarinet", "Notes"])
        let result = m.applyPreset(parts: [PresetPart(name: "Flute", copies: 4),
                                           PresetPart(name: "Clarinet", copies: 6),
                                           PresetPart(name: "Bass Clarinet", copies: 2),
                                           PresetPart(name: "Tuba", copies: 1)],
                                   undoManager: nil)
        // Longest name first: "Bass Clarinet" isn't taken by "Clarinet".
        #expect(copies(m) == ["01 Flute": 4, "02 Bass Clarinet": 2, "03 Clarinet": 6, "Notes": 1])
        #expect(result.matchedCount == 3)
        #expect(result.unmatchedFileIds == [m.files[3].id])
        #expect(result.unmatchedPartNames == ["Tuba"])
    }

    @Test("one entry over numbered parts is shared out, and marked as the app's guess")
    func sharesOut() {
        let m = manager(["Trumpet 1", "Trumpet 2"])
        let result = m.applyPreset(parts: [PresetPart(name: "Trumpet", copies: 7)], undoManager: nil)
        #expect(copies(m).values.sorted() == [3, 4])
        #expect(result.splitFileIds == Set(m.files.map(\.id)))
    }

    @Test("applying a preset can be undone")
    func undoable() {
        let m = manager(["Flute", "Oboe"])
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        m.applyPreset(parts: [PresetPart(name: "Flute", copies: 5), PresetPart(name: "Oboe", copies: 3)],
                      undoManager: undo)
        undo.endUndoGrouping()
        #expect(copies(m) == ["Flute": 5, "Oboe": 3])
        undo.undo()
        #expect(copies(m) == ["Flute": 1, "Oboe": 1])
    }
}

@MainActor
@Suite("Combine: collated output order")
struct CombineCollatedOutputTests {

    @Test("a collate group's files are interleaved, one set per copy")
    func interleaved() throws {
        let folder = temporaryFolder("collate")
        // Page widths identify each file in the output.
        let a = folder.appendingPathComponent("A.pdf"), b = folder.appendingPathComponent("B.pdf")
        let c = folder.appendingPathComponent("C.pdf")
        writeDrawnPDF(pages: 1, size: CGSize(width: 500, height: 842), to: a)
        writeDrawnPDF(pages: 2, size: CGSize(width: 520, height: 842), to: b)
        writeDrawnPDF(pages: 1, size: CGSize(width: 540, height: 842), to: c)

        let m = CombineManager()
        m.addFiles(urls: [a, b, c], undoManager: nil)
        m.createCollateGroup(fileIds: [m.files[0].id, m.files[1].id], undoManager: nil)
        let group = try #require(m.files[0].collateGroupId)
        m.updateGroupCopies(id: group, copies: 2, undoManager: nil)

        let out = folder.appendingPathComponent("out.pdf")
        var failed = false
        m.createCombinedPDF(to: out, options: CombineOutputOptions()) { _, _, isError in failed = isError }
        #expect(!failed)
        let doc = try #require(PDFDocument(url: out))
        let widths = (0..<doc.pageCount).map { Int(doc.page(at: $0)!.bounds(for: .mediaBox).width) }
        // A, B, B (set 1), A, B, B (set 2), then C on its own.
        #expect(widths == [500, 520, 520, 500, 520, 520, 540])
    }
}
