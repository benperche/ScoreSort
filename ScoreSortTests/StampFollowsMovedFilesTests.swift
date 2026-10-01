//
//  StampFollowsMovedFilesTests.swift
//  ScoreSortTests
//
//  The Stamp tab reads its queued files only when it previews or stamps them, so a file moved
//  or renamed in Finder after being queued has to be followed — the same bookmark mechanism
//  Combine uses (`FollowsMovedFile`).
//

import Testing
import Foundation
@testable import ScoreSort

@Suite("Stamp follows moved files")
struct StampFollowsMovedFilesTests {
    let dir: URL
    let fm = FileManager.default

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func queued(_ name: String) -> StampFileItem {
        let url = dir.appendingPathComponent("\(name).pdf")
        writePDF(pages: 1, to: url)
        return StampFileItem(url: url)
    }

    @Test func movedAndRenamedFileIsFollowedAndItsOutputNameToo() throws {
        var item = queued("Flute")
        let elsewhere = dir.appendingPathComponent("Moved")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let newURL = elsewhere.appendingPathComponent("Flute 1.pdf")
        try fm.moveItem(at: item.url, to: newURL)

        item.refreshLocation()
        #expect(item.url.standardizedFileURL == newURL.standardizedFileURL)
        #expect(item.outputName == "Flute 1")
    }

    @Test func anEditedOutputNameSurvivesARename() throws {
        var item = queued("Flute")
        item.outputName = "Flute — stamped"
        try fm.moveItem(at: item.url, to: dir.appendingPathComponent("Flute 1.pdf"))

        item.refreshLocation()
        #expect(item.url.lastPathComponent == "Flute 1.pdf")
        #expect(item.outputName == "Flute — stamped")
    }

    /// Replace mode writes back to `url`, so a binned file must not be followed into the Trash.
    @Test func fileMovedToTheTrashKeepsItsOldPath() throws {
        var item = queued("Flute")
        let original = item.url
        let trash = dir.appendingPathComponent(".Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try fm.moveItem(at: original, to: trash.appendingPathComponent("Flute.pdf"))

        item.refreshLocation()
        #expect(item.url == original)
    }

    @Test func unmovedFileIsLeftAlone() {
        var item = queued("Flute")
        let before = item
        item.refreshLocation()
        #expect(item.url == before.url && item.outputName == before.outputName)
    }
}
