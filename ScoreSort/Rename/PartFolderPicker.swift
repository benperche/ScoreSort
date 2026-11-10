//
//  PartFolderPicker.swift
//  ScoreSort
//
//  The "Sort into folders" menu shown beside Split's and the Rename tab's save/rename
//  buttons. Each starts from the default in Settings ▸ Renamer (`PartFolderMode`,
//  Logic/PartFolders.swift).
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
        .help("Put each part in a folder for its section (Woodwind, Brass, Percussion…) or its instrument (Flute, Clarinet…), so each group of players can be given just their own folder. The score, and any part ScoreSort doesn't recognise, stay at the top. Set the default in Settings ▸ Renamer.")
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
