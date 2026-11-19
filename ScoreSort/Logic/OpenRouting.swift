//
//  OpenRouting.swift
//  ScoreSort
//
//  Files opened from outside the window — Finder's Open With, or dropped on the Dock icon
//  (#21): which tab they go to. Pure, so it's tested; `ContentView` acts on the answer.
//
//  The rule Ben chose: the tab on screen takes them if it can without losing work; otherwise
//  several files or a folder go to Combine, and a single PDF or image asks where to go.
//

import Foundation

/// The five tabs, by their `TabView` tag.
nonisolated enum AppTab: Int, CaseIterable, Identifiable, Sendable {
    case combine = 0, rename, split, rotate, stamp
    var id: Int { rawValue }

    /// How the chooser names the tab.
    var openTitle: String {
        switch self {
        case .combine: return "Add to Combine"
        case .rename:  return "Rename Files"
        case .split:   return "Split PDF"
        case .rotate:  return "Rotate Pages"
        case .stamp:   return "Stamp"
        }
    }
}

/// Where opened files should go.
nonisolated enum OpenRoute: Equatable, Sendable {
    /// Straight to this tab, with these items (unsupported ones left out).
    case open(AppTab, [URL])
    /// Ask: one item, several tabs that could take it.
    case choose(URL, [AppTab])
    /// Nothing ScoreSort can use.
    case unsupported
}

/// Decides where `urls` go. `current` is the tab on screen; `currentTabHasContent` is whether
/// it has something loaded (a PDF in Split or Rotate would be replaced).
func routeOpenedFiles(_ urls: [URL], current: AppTab, currentTabHasContent: Bool,
                                  isFolder: (URL) -> Bool = urlIsDirectory) -> OpenRoute {
    let folders = urls.filter(isFolder)
    let files = urls.filter { !isFolder($0) }
    let pdfs = files.filter { $0.pathExtension.lowercased() == "pdf" }
    let images = files.filter { pageableFileExtensions.contains($0.pathExtension.lowercased()) && $0.pathExtension.lowercased() != "pdf" }
    let usable = urls.filter { isFolder($0) || pdfs.contains($0) || images.contains($0) }
    guard !usable.isEmpty else { return .unsupported }

    // Several things, or a folder: a batch.
    if usable.count > 1 || !folders.isEmpty {
        // Stamp adds to its list; Rename starts a new job, so only when it has none going.
        if current == .stamp { return .open(.stamp, usable) }
        if current == .rename && !currentTabHasContent { return .open(.rename, usable) }
        return .open(.combine, usable)
    }

    let item = usable[0]
    if pdfs.contains(item) {
        switch current {
        case .combine, .stamp:
            return .open(current, [item])   // they add to what's there
        case .split, .rotate:
            // They replace their PDF: only straight in when there's nothing to lose.
            return currentTabHasContent ? .choose(item, [.split, .rotate, .stamp, .combine]) : .open(current, [item])
        case .rename:
            return .choose(item, [.split, .rotate, .stamp, .combine])
        }
    }
    // A single image: only Combine and Stamp take pictures.
    switch current {
    case .combine, .stamp: return .open(current, [item])
    default:               return .choose(item, [.stamp, .combine])
    }
}
