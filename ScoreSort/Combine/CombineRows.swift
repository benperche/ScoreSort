//
//  CombineRows.swift
//  ScoreSort
//
//  The Combine list's rows: CombineFileRow (one file, its pages and copies) and
//  CollateGroupHeaderRow (a collate group's header), plus the list's fixed colours.
//  Moved out of CombineTab.swift.
//

import SwiftUI
import AppKit
@preconcurrency import PDFKit
import UniformTypeIdentifiers
import Combine

extension Color {
    /// Chrome colour for collate groups — deliberately a fixed hue distinct from the
    /// system accent (which drives row selection) so a group doesn't read as "selected".
    /// Indigo isn't one of macOS's selectable accent colours, so it never collides with
    /// the selection tint whatever accent the user has chosen.
    static let collateGroup = Color.indigo
    /// Copies the app divided between parts rather than reading off the preset.
    static let presetSplit = Color.blue
}

// MARK: - Combine File Row

struct CombineFileRow: View {
    let file: CombineFile
    let isSelected: Bool
    let isFocused: Bool
    let isUnmatched: Bool
    /// True when the app divided a preset entry's copies across this file and its siblings.
    var hasSplitCopies: Bool = false
    /// True when this file belongs to a collate group (indents row, hides copies stepper).
    var isGrouped: Bool = false
    /// True when this is the last member of its collate group (draws the closing border).
    var isLastInGroup: Bool = false
    /// True while a drag is hovering this file's collate group (highlight as merge target).
    var isMergeTarget: Bool = false
    /// Tapping the tick box always adds/removes this file from the selection.
    let onToggleSelect: () -> Void
    /// Tapping anywhere else on the row selects just this file (⌘ toggles, ⇧ extends).
    let onRowTap: () -> Void
    let onCopiesChanged: (Int) -> Void
    let onRemove: () -> Void
    /// True while booklet output is selected — the layout column is meaningless otherwise.
    var showsBookletLayout: Bool = false
    var onBookletLayoutChanged: ((BookletPartLayout) -> Void)? = nil

    @State private var isEditingCopies = false
    @State private var copiesText = ""
    @FocusState private var copiesFieldFocused: Bool

    var body: some View {
        HStack {
            // The tick box is its own hit target: it always toggles membership, so you can
            // build up a multi-selection without holding ⌘.
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .contentShape(Rectangle())
                .onTapGesture { onToggleSelect() }

            Text(file.name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(file.isBlankPage ? .secondary : .primary)
                .italic(file.isBlankPage)
                // Indent grouped files so they visually sit under the group header
                .padding(.leading, isGrouped ? 14 : 0)

            Text("\(file.pageCount)")
                .frame(width: 80, alignment: .center)
                .foregroundColor(.secondary)

            if showsBookletLayout {
                // Labelled by the pages that end up facing each other rather than by the format,
                // because that's what tells a player where they'll have to turn.
                Menu {
                    ForEach(BookletPartLayout.allCases) { option in
                        Button {
                            onBookletLayoutChanged?(option)
                        } label: {
                            if option == file.effectiveBookletLayout {
                                Label("\(option.label) — \(option.spreadDescription(pageCount: file.pageCount))",
                                      systemImage: "checkmark")
                            } else {
                                Text("\(option.label) — \(option.spreadDescription(pageCount: file.pageCount))")
                            }
                        }
                    }
                } label: {
                    Text(file.effectiveBookletLayout.spreadDescription(pageCount: file.pageCount))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 150)
                .disabled(file.isBlankPage)
                .help("Where the page turns fall in this part's booklet")
            }

            // Grouped files don't have their own copy count — the group header owns it
            if isGrouped {
                Spacer().frame(width: 100)
            } else {
                HStack(spacing: 4) {
                    Button(action: {
                        if file.copies > 1 { onCopiesChanged(file.copies - 1) } else { onRemove() }
                    }) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)

                    if isEditingCopies {
                        TextField("", text: $copiesText)
                            .frame(width: 40)
                            .multilineTextAlignment(.center)
                            .font(.system(.body, design: .monospaced))
                            .focused($copiesFieldFocused)
                            .onSubmit { commitCopiesEdit() }
                            .onExitCommand { isEditingCopies = false }
                            .onTapGesture {}
                    } else {
                        Text("\(file.copies)")
                            .frame(width: 40, alignment: .center)
                            .font(.system(.body, design: .monospaced))
                            .onTapGesture(count: 2) {
                                copiesText = "\(file.copies)"
                                isEditingCopies = true
                                copiesFieldFocused = true
                            }
                    }

                    Button(action: { onCopiesChanged(file.copies + 1) }) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 100, alignment: .center)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(rowBackground)
        // Continuous collate-colour spine down the left edge of a collate group, plus a
        // closing border under the last member so the group's extent is obvious.
        .overlay(alignment: .leading) {
            if isGrouped {
                Rectangle().fill(Color.collateGroup.opacity(0.55)).frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) {
            if isLastInGroup {
                Rectangle().fill(Color.collateGroup.opacity(0.55)).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onRowTap() }
        .onChange(of: copiesFieldFocused) { _, focused in
            if !focused && isEditingCopies { commitCopiesEdit() }
        }
    }

    private var rowBackground: Color {
        if isMergeTarget { return Color.collateGroup.opacity(0.22) }   // drag merge highlight
        if isSelected { return Color.accentColor.opacity(isFocused ? 0.18 : 0.1) }
        if isUnmatched { return Color.orange.opacity(0.12) }
        // Distinct from the orange of "couldn't match this" — the app did match it, but had to
        // guess how to divide the players, so the number is worth a second look.
        if hasSplitCopies { return Color.presetSplit.opacity(0.14) }
        if isGrouped { return Color.collateGroup.opacity(0.08) }   // faint group fill
        if file.isBlankPage { return Color.gray.opacity(0.08) }
        return Color.clear
    }

    private func commitCopiesEdit() {
        if let value = Int(copiesText), value >= 1 { onCopiesChanged(value) }
        isEditingCopies = false
    }
}

// MARK: - Collate Group Header Row
/// The header row displayed above the files in a collate group.
/// Shows the group's total-pages-per-set and the group-level copy count.
struct CollateGroupHeaderRow: View {
    let group: CollateGroup
    let fileCount: Int
    let totalPages: Int
    /// True while a drag is hovering this group (highlight as merge target).
    var isMergeTarget: Bool = false
    var onCopiesChanged: (Int) -> Void
    var onUngroup: () -> Void

    @State private var isEditingCopies = false
    @State private var copiesText = ""
    @FocusState private var copiesFocused: Bool

    var body: some View {
        HStack {
            // Name column ─ icon + label + ungroup button
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundColor(.collateGroup)
                Text("Collate Group")
                    .fontWeight(.semibold)
                Text("(\(fileCount) file\(fileCount == 1 ? "" : "s"))")
                    .foregroundColor(.secondary)
                    .font(.callout)
                Spacer()
                Button(action: onUngroup) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Dissolve group — restore files individually")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Pages column ─ total pages for one complete set
            Text("\(totalPages)")
                .frame(width: 80, alignment: .center)
                .foregroundColor(.secondary)

            // Copies column ─ group-level stepper (double-click to type)
            HStack(spacing: 4) {
                Button { if group.copies > 1 { onCopiesChanged(group.copies - 1) } } label: {
                    Image(systemName: "minus.circle")
                }.buttonStyle(.plain)

                if isEditingCopies {
                    TextField("", text: $copiesText)
                        .frame(width: 40)
                        .multilineTextAlignment(.center)
                        .font(.system(.body, design: .monospaced))
                        .focused($copiesFocused)
                        .onSubmit { commitEdit() }
                        .onExitCommand { isEditingCopies = false }
                        .onTapGesture {}
                } else {
                    Text("\(group.copies)")
                        .frame(width: 40, alignment: .center)
                        .font(.system(.body, design: .monospaced))
                        .onTapGesture(count: 2) {
                            copiesText = "\(group.copies)"
                            isEditingCopies = true
                            copiesFocused = true
                        }
                }

                Button { onCopiesChanged(group.copies + 1) } label: {
                    Image(systemName: "plus.circle")
                }.buttonStyle(.plain)
            }
            .frame(width: 100, alignment: .center)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.collateGroup.opacity(isMergeTarget ? 0.22 : 0.09))
        // Top of the collate-colour spine that runs down the whole collate group.
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.collateGroup.opacity(0.55)).frame(width: 3)
        }
        .onChange(of: copiesFocused) { _, focused in
            if !focused && isEditingCopies { commitEdit() }
        }
    }

    private func commitEdit() {
        if let value = Int(copiesText), value >= 1 { onCopiesChanged(value) }
        isEditingCopies = false
    }
}
