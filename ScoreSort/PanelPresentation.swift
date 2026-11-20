//
//  PanelPresentation.swift
//  ScoreSort
//
//  Open and save panels are sheets on the app's window, never free-standing windows.
//

import AppKit

/// Shows `panel` (an `NSOpenPanel` or `NSSavePanel`) as a sheet on the key window, which greys
/// out and locks the window behind it — the Word-style behaviour Ben asked for — and keeps
/// keystrokes in the panel instead of reaching the tab underneath. A free-standing panel
/// (`begin {}`) let a Delete in its file list skip pages in Split or drop files in Rename.
///
/// The key window, not the main one, so a panel opened from inside a sheet attaches to that
/// sheet rather than queueing behind it. With no window at all it runs app-modal.
func beginPanelSheet(_ panel: NSSavePanel,
                     completion: @escaping (NSApplication.ModalResponse) -> Void) {
    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        panel.beginSheetModal(for: window, completionHandler: completion)
    } else {
        completion(panel.runModal())
    }
}
