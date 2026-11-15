//
//  PartFolderPicker.swift
//  ScoreSort
//
//  The "Sort into folders" menu shown beside Split's and the Rename tab's save/rename
//  buttons. They all show one remembered setting, also in Settings ▸ Renamer
//  (`PartFolderMode`, Logic/PartFolders.swift).
//

import SwiftUI
import AppKit

struct PartFolderPicker: View {
    @Binding var mode: PartFolderMode

    var body: some View {
        Picker("Sort into folders:", selection: $mode) {
            ForEach(PartFolderMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Put each part in a folder for its section (Woodwind, Brass, Percussion…) or its instrument (Flute, Clarinet…), so each group of players can be given just their own folder. The score, and any part ScoreSort doesn't recognise, stay at the top. It stays as you last set it (also in Settings ▸ Renamer).")
    }
}

extension Color {
    /// The tint for "Sort into folders" groups in the Score Order Sorter.
    static let partFolder = Color.teal
}

/// The header above each folder's files in the Score Order Sorter while sorting into folders
/// (styled like Combine's collate groups): the folder, how many files, and a spine down its
/// files. The top-level group (the score, files staying put) is plain.
struct PartFolderGroupHeader: View {
    let folder: String
    let fileCount: Int
    /// Some of these were put here with "Move to Folder".
    var isChosenByHand: Bool = false
    /// Parts are being dragged over this folder.
    var isDropTarget: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: folder.isEmpty ? "tray" : "folder.fill")
                .foregroundColor(folder.isEmpty ? .secondary : .partFolder)
            Text(folder.isEmpty ? "Top Level" : folder)
                .fontWeight(.semibold)
            Text(folder.isEmpty ? "— not in a folder (\(fileCount) file\(fileCount == 1 ? "" : "s"))"
                                : "(\(fileCount) file\(fileCount == 1 ? "" : "s"))")
                .foregroundColor(.secondary)
                .font(.callout)
            if isChosenByHand {
                Text("Includes your changes")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(folder.isEmpty ? Color(NSColor.controlBackgroundColor) : Color.partFolder.opacity(0.09))
        .overlay(alignment: .leading) {
            if !folder.isEmpty { Rectangle().fill(Color.partFolder.opacity(0.55)).frame(width: 3) }
        }
        .overlay {
            if isDropTarget { Rectangle().fill(Color.accentColor.opacity(0.15)).allowsHitTesting(false) }
        }
    }
}

/// Asks for a new folder's name (Move to Folder ▸ New Folder…); nil if cancelled.
func askForPartFolderName() -> String? {
    let alert = NSAlert()
    alert.messageText = "New Folder"
    alert.informativeText = "The selected files will go into a folder with this name, beside the others."
    alert.addButton(withTitle: "Move")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.placeholderString = "e.g. Low Brass"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    while alert.runModal() == .alertFirstButtonReturn {
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let problem = partFolderNameError(name) else { return name }
        alert.informativeText = problem
    }
    return nil
}

/// The folders Move to Folder offers: the ensemble's sections (By Section), then any other
/// folder already in use.
func partFolderChoices(mode: PartFolderMode, ensemble: EnsembleType, inUse: [String]) -> [String] {
    var choices = mode == .section ? partFolderSections(for: ensemble) : []
    for folder in inUse
    where !folder.isEmpty && !choices.contains(where: { $0.caseInsensitiveCompare(folder) == .orderedSame }) {
        choices.append(folder)
    }
    return choices
}

/// Move to Folder's items (a menu or a right-click): the folders, New Folder…, Top Level, and
/// ScoreSort's Choice. `choose` gets the folder — "" for the top level, nil to go back to
/// ScoreSort's guess. Used by the Score Order Sorter and Split's Step 3.
struct PartFolderMenuItems: View {
    let choices: [String]
    /// Some of the files were put in a folder by hand, so ScoreSort's Choice can undo it.
    let canRestore: Bool
    let choose: (String?) -> Void

    var body: some View {
        ForEach(choices, id: \.self) { folder in
            Button(folder) { choose(folder) }
        }
        Divider()
        Button("New Folder\u{2026}") {
            if let folder = askForPartFolderName() { choose(folder) }
        }
        Button("Top Level (No Folder)") { choose("") }
        Divider()
        Button("ScoreSort\u{2019}s Choice") { choose(nil) }
            .disabled(!canRestore)
    }
}

/// What a part being dragged to another folder looks like: its name, or "N parts".
func partFolderDragPreview(name: String, count: Int) -> some View {
    Label(count > 1 ? "\(count) parts" : name, systemImage: count > 1 ? "doc.on.doc" : "doc")
        .lineLimit(1)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
}

/// Makes a row draggable to another folder, and a place to drop parts into its folder —
/// only while sorting into folders (`payload` nil otherwise).
struct PartFolderDragDrop<Preview: View>: ViewModifier {
    let payload: String?
    let preview: () -> Preview
    let onDrop: ([String]) -> Bool
    let onTargeted: (Bool) -> Void

    func body(content: Content) -> some View {
        if let payload {
            content
                .draggable(payload) { preview() }
                .dropDestination(for: String.self) { items, _ in onDrop(items) } isTargeted: { onTargeted($0) }
        } else {
            content
        }
    }
}
