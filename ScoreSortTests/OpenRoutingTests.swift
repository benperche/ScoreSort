//
//  OpenRoutingTests.swift
//  ScoreSortTests
//
//  #21: where files opened from Finder or the Dock go (`routeOpenedFiles`).
//

import Testing
import Foundation
@testable import ScoreSort

@MainActor
@Suite("Opening files from outside: which tab")
struct OpenRoutingTests {

    private let pdf = URL(fileURLWithPath: "/tmp/Holst Score.pdf")
    private let pdf2 = URL(fileURLWithPath: "/tmp/Flute.PDF")
    private let image = URL(fileURLWithPath: "/tmp/Scan.jpg")
    private let folder = URL(fileURLWithPath: "/tmp/Band Parts", isDirectory: true)
    private let text = URL(fileURLWithPath: "/tmp/Notes.txt")
    private func isFolder(_ url: URL) -> Bool { url == folder }

    private func route(_ urls: [URL], on tab: AppTab, busy: Bool = false) -> OpenRoute {
        routeOpenedFiles(urls, current: tab, currentTabHasContent: busy, isFolder: isFolder)
    }

    @Test("several files or a folder go to Combine, unless Stamp (or an idle Rename) is on screen")
    func batches() {
        for tab in [AppTab.combine, .split, .rotate] {
            #expect(route([pdf, pdf2], on: tab) == .open(.combine, [pdf, pdf2]))
            #expect(route([folder], on: tab, busy: true) == .open(.combine, [folder]))
        }
        #expect(route([pdf, image], on: .stamp, busy: true) == .open(.stamp, [pdf, image]))
        #expect(route([folder], on: .rename) == .open(.rename, [folder]))
        // Rename with a job under way isn't interrupted.
        #expect(route([folder], on: .rename, busy: true) == .open(.combine, [folder]))
    }

    @Test("a single PDF goes to the tab on screen when it can take it without losing work")
    func singlePDF() {
        #expect(route([pdf], on: .combine, busy: true) == .open(.combine, [pdf]))
        #expect(route([pdf], on: .stamp, busy: true) == .open(.stamp, [pdf]))
        #expect(route([pdf], on: .split) == .open(.split, [pdf]))
        #expect(route([pdf], on: .rotate) == .open(.rotate, [pdf]))
    }

    @Test("otherwise a single PDF asks where to go")
    func singlePDFAsks() {
        let all: [AppTab] = [.split, .rotate, .stamp, .combine]
        #expect(route([pdf], on: .split, busy: true) == .choose(pdf, all))
        #expect(route([pdf], on: .rotate, busy: true) == .choose(pdf, all))
        #expect(route([pdf], on: .rename) == .choose(pdf, all))
    }

    @Test("a single image goes to Combine or Stamp, or asks between them")
    func singleImage() {
        #expect(route([image], on: .combine) == .open(.combine, [image]))
        #expect(route([image], on: .stamp) == .open(.stamp, [image]))
        for tab in [AppTab.rename, .split, .rotate] {
            #expect(route([image], on: tab) == .choose(image, [.stamp, .combine]))
        }
    }

    @Test("things ScoreSort can't use are left out, and alone are refused")
    func unsupported() {
        #expect(route([text], on: .combine) == .unsupported)
        #expect(route([], on: .split) == .unsupported)
        #expect(route([text, pdf], on: .split) == .open(.split, [pdf]))
    }

    @Test("the queue hands over what arrived before the window, once")
    func queue() {
        let q = ExternalOpenQueue()
        q.receive([pdf])
        q.receive([image])
        #expect(q.take() == [pdf, image])
        #expect(q.take().isEmpty)
    }

    @Test("a tab takes files meant for it, once; other tabs don't")
    func handOver() {
        let state = AppState()
        state.deliver([pdf], to: .split)
        #expect(state.selectedTab == AppTab.split.rawValue)
        #expect(state.takePendingOpen(for: .rotate) == nil)
        #expect(state.takePendingOpen(for: .split) == [pdf])
        #expect(state.takePendingOpen(for: .split) == nil)
    }
}
