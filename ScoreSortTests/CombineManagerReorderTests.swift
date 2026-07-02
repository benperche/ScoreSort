//
//  CombineManagerReorderTests.swift
//  ScoreSortTests
//
//  View-model tests for CombineManager — the drag-to-reorder and collate-group
//  logic behind the Combine tab. These mutate the manager's model directly (the
//  same mutations the drag gestures produce), so they cover the behaviour without
//  driving any UI.
//

import Testing
import Foundation
@testable import ScoreSort

@MainActor
@Suite("CombineManager reorder & collate")
struct CombineManagerReorderTests {

    private func mkFile(_ name: String, pages: Int = 1, copies: Int = 1) -> CombineFile {
        CombineFile(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, pageCount: pages, copies: copies)
    }

    // ── Reordering ──────────────────────────────────────────────────────────

    @Test("move a file before another reorders in place")
    func moveBefore() {
        let m = CombineManager()
        let a = mkFile("a"), b = mkFile("b"), c = mkFile("c")
        m.files = [a, b, c]
        m.move(ids: [a.id], before: c.id, undoManager: nil)
        #expect(m.files.map(\.name) == ["b", "a", "c"])
    }

    @Test("move with nil target appends to the end")
    func moveToEnd() {
        let m = CombineManager()
        let a = mkFile("a"), b = mkFile("b"), c = mkFile("c")
        m.files = [a, b, c]
        m.move(ids: [a.id], before: nil, undoManager: nil)
        #expect(m.files.map(\.name) == ["b", "c", "a"])
    }

    @Test("move preserves the order of a multi-file block")
    func moveBlock() {
        let m = CombineManager()
        let a = mkFile("a"), b = mkFile("b"), c = mkFile("c"), d = mkFile("d")
        m.files = [a, b, c, d]
        m.move(ids: [a.id, c.id], before: nil, undoManager: nil)
        #expect(m.files.map(\.name) == ["b", "d", "a", "c"])
    }

    @Test("moveUp moves a selected block up as a unit")
    func moveUpBlock() {
        let m = CombineManager()
        let a = mkFile("a"), b = mkFile("b"), c = mkFile("c")
        m.files = [a, b, c]
        m.moveUp(ids: [b.id, c.id], undoManager: nil)
        #expect(m.files.map(\.name) == ["b", "c", "a"])
    }

    // ── Collate groups ──────────────────────────────────────────────────────

    @Test("createCollateGroup pulls selected files together at the first's position")
    func createGroup() {
        let m = CombineManager()
        let a = mkFile("a"), b = mkFile("b"), c = mkFile("c")
        m.files = [a, b, c]
        m.createCollateGroup(fileIds: [a.id, c.id], undoManager: nil)
        #expect(m.files.map(\.name) == ["a", "c", "b"])
        #expect(m.collateGroups.count == 1)
        let gid = m.collateGroups.keys.first
        #expect(m.files[0].collateGroupId == gid)
        #expect(m.files[1].collateGroupId == gid)
        #expect(m.files[2].collateGroupId == nil)
    }

    @Test("createCollateGroup needs at least two files")
    func createGroupSingle() {
        let m = CombineManager()
        let a = mkFile("a")
        m.files = [a]
        m.createCollateGroup(fileIds: [a.id], undoManager: nil)
        #expect(m.collateGroups.isEmpty)
        #expect(m.files[0].collateGroupId == nil)
    }

    @Test("dissolveGroup restores files as standalone entries")
    func dissolve() {
        let m = CombineManager()
        let a = mkFile("a"), b = mkFile("b")
        m.files = [a, b]
        m.createCollateGroup(fileIds: [a.id, b.id], undoManager: nil)
        let gid = m.collateGroups.keys.first!
        m.dissolveGroup(id: gid, undoManager: nil)
        #expect(m.collateGroups.isEmpty)
        #expect(m.files.allSatisfy { $0.collateGroupId == nil })
    }

    @Test("addToGroup pulls a file into an existing group, contiguously")
    func addToGroup() {
        let m = CombineManager()
        let a = mkFile("a"), b = mkFile("b"), c = mkFile("c")
        m.files = [a, b, c]
        m.createCollateGroup(fileIds: [a.id, b.id], undoManager: nil)
        let gid = m.collateGroups.keys.first!
        m.addToGroup(ids: [c.id], groupId: gid, undoManager: nil)
        #expect(m.files.map(\.name) == ["a", "b", "c"])
        #expect(m.files.allSatisfy { $0.collateGroupId == gid })
    }

    @Test("removing a file dissolves a group left with a single member")
    func removeDissolvesSmallGroup() {
        let m = CombineManager()
        let a = mkFile("a"), b = mkFile("b")
        m.files = [a, b]
        m.createCollateGroup(fileIds: [a.id, b.id], undoManager: nil)
        m.removeFiles(ids: [a.id], undoManager: nil)
        #expect(m.files.map(\.name) == ["b"])
        #expect(m.collateGroups.isEmpty)
        #expect(m.files[0].collateGroupId == nil)
    }

    // ── Copies & totals ─────────────────────────────────────────────────────

    @Test("updateCopies clamps to a minimum of one")
    func copiesClamp() {
        let m = CombineManager()
        let a = mkFile("a")
        m.files = [a]
        m.updateCopies(for: a.id, copies: 0, undoManager: nil)
        #expect(m.files[0].copies == 1)
    }

    @Test("totals account for collate groups and copies")
    func totals() {
        let m = CombineManager()
        let a = mkFile("a", pages: 2), b = mkFile("b", pages: 3)
        let solo = mkFile("solo", pages: 5, copies: 2)
        m.files = [a, b, solo]
        m.createCollateGroup(fileIds: [a.id, b.id], undoManager: nil)
        let gid = m.collateGroups.keys.first!
        m.updateGroupCopies(id: gid, copies: 4, undoManager: nil)
        // group: (2+3) pages × 4 sets = 20 pages, 2 files × 4 = 8 files
        // solo: 5 pages × 2 copies = 10 pages, 2 files
        #expect(m.totalPages == 30)
        #expect(m.totalFiles == 10)
    }
}
