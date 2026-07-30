//
//  ViewSmokeTests.swift
//  ScoreSortTests
//
//  Smoke tests: host each tab (and the whole ContentView) off-screen and force a
//  layout pass so SwiftUI evaluates their `body`. These don't assert behaviour —
//  they catch the class of regression the file-splitting refactors risk: a view
//  that no longer constructs (missing environment object, a crash in a subview,
//  etc.). Drag-and-drop and file panels are deliberately out of scope.
//

import Testing
import SwiftUI
import AppKit
@testable import ScoreSort

@MainActor
@Suite("View smoke tests")
struct ViewSmokeTests {

    /// Hosts `view` in an off-screen NSHostingView (with every app-level environment
    /// object injected, as ContentView does) and forces layout so its `body` (and its
    /// children's) is evaluated. A construction crash fails the test.
    private func render<V: View>(_ view: V) {
        let host = NSHostingView(
            rootView: view
                .environmentObject(AppState())
                .environmentObject(RenamerManager())
                .environmentObject(EnsemblePresetStore())
                .environmentObject(StampStore())
        )
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
    }

    @Test("Combine tab renders")
    func combineTab() {
        render(CombineView(showingKeyboardHelp: .constant(false), menuState: CombineMenuState()))
    }

    @Test("Rename tab renders")
    func renameTab() {
        render(RenamerView())
    }

    @Test("Split tab renders")
    func splitTab() {
        render(SplitView())
    }

    @Test("Rotate tab renders")
    func rotateTab() {
        render(RotateView())
    }

    @Test("stamp designer renders")
    func stampDesigner() {
        render(StampDesignerView())
    }

    @Test("full ContentView renders")
    func contentView() {
        render(ContentView())
    }
}
