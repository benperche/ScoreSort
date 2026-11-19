//
//  PresetViews.swift
//  ScoreSort
//
//  The preset views: PresetPartRow (shared with the Combiner preferences pane),
//  NewPresetSheet with its template cards, and the Combine tab's PresetSidebarView.
//  Moved out of CombineTab.swift.
//

import SwiftUI
import AppKit
@preconcurrency import PDFKit
import UniformTypeIdentifiers
import Combine

// MARK: - Preset Part Row (shared by sidebar and preferences)
/// One row in a parts list. Minus at copies == 1 deletes the part.
/// Double-click the copy count to type a number directly.
struct PresetPartRow: View {
    @Binding var part: PresetPart
    var isUnmatched: Bool = false
    var onMarkDirty: () -> Void
    var onDelete: () -> Void
    /// Pass non-nil to show up/down reorder buttons (preferences panel).
    /// Leave nil to hide them (sidebar).
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil

    // Name editing
    @State private var isEditingName = false
    @State private var nameText = ""
    @FocusState private var nameFocused: Bool

    // Copies editing
    @State private var isEditingCopies = false
    @State private var copiesText = ""
    @FocusState private var copiesFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            // Up / down reorder buttons (preferences only)
            if onMoveUp != nil || onMoveDown != nil {
                VStack(spacing: 1) {
                    Button { onMoveUp?() } label: {
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(onMoveUp == nil)

                    Button { onMoveDown?() } label: {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(onMoveDown == nil)
                }
                .foregroundColor(.secondary)
                .padding(.trailing, 2)
            }

            // Name — double-click to rename inline
            if isEditingName {
                TextField("", text: $nameText)
                    .frame(maxWidth: .infinity)
                    .font(.callout)
                    .focused($nameFocused)
                    .onSubmit { commitNameEdit() }
                    .onExitCommand { isEditingName = false }
                    .onTapGesture {}
            } else {
                Text(part.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .font(.callout)
                    .onTapGesture(count: 2) {
                        nameText = part.name
                        isEditingName = true
                        nameFocused = true
                    }
            }

            HStack(spacing: 2) {
                Button {
                    if part.copies > 1 {
                        part.copies -= 1
                        onMarkDirty()
                    } else {
                        onDelete()
                    }
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)

                if isEditingCopies {
                    TextField("", text: $copiesText)
                        .frame(width: 32)
                        .multilineTextAlignment(.center)
                        .font(.system(.callout, design: .monospaced))
                        .focused($copiesFocused)
                        .onSubmit { commitCopiesEdit() }
                        .onExitCommand { isEditingCopies = false }
                        .onTapGesture {}
                } else {
                    Text("\(part.copies)")
                        .frame(width: 28, alignment: .center)
                        .font(.system(.callout, design: .monospaced))
                        .onTapGesture(count: 2) {
                            copiesText = "\(part.copies)"
                            isEditingCopies = true
                            copiesFocused = true
                        }
                }

                Button {
                    part.copies += 1
                    onMarkDirty()
                } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 1)
        .background(isUnmatched ? Color.orange.opacity(0.12) : Color.clear)
        .onChange(of: nameFocused) { _, focused in
            if !focused && isEditingName { commitNameEdit() }
        }
        .onChange(of: copiesFocused) { _, focused in
            if !focused && isEditingCopies { commitCopiesEdit() }
        }
    }

    private func commitNameEdit() {
        let trimmed = nameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            part.name = trimmed
            onMarkDirty()
        }
        isEditingName = false
    }

    private func commitCopiesEdit() {
        if let v = Int(copiesText), v >= 1 {
            part.copies = v
            onMarkDirty()
        }
        isEditingCopies = false
    }
}

// MARK: - New Preset Sheet
/// Modal sheet for creating a new preset. Lets the user pick one of three
/// starting templates and give it a custom name before confirming.
struct NewPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (_ name: String, _ parts: [PresetPart]) -> Void

    enum PresetTemplate: String, CaseIterable, Identifiable {
        case windBand   = "Wind Band"
        case jazzBand   = "Jazz Band"
        case orchestra  = "Orchestra"
        var id: Self { self }

        var parts: [PresetPart] {
            switch self {
            case .windBand:  return EnsemblePresetStore.windBandTemplate
            case .jazzBand:  return EnsemblePresetStore.jazzTemplate
            case .orchestra: return EnsemblePresetStore.orchestraTemplate
            }
        }
        var subtitle: String {
            switch self {
            case .windBand:  return "Concert band — woodwinds, brass & percussion"
            case .jazzBand:  return "Big band — saxes, brass & rhythm section"
            case .orchestra: return "Strings, woodwinds, brass & percussion"
            }
        }
    }

    @State private var selected: PresetTemplate = .windBand
    @State private var name: String = PresetTemplate.windBand.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Preset")
                .font(.title2)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Choose a starting template:")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 10) {
                ForEach(PresetTemplate.allCases) { template in
                    TemplateCard(
                        title: template.rawValue,
                        subtitle: template.subtitle,
                        isSelected: selected == template
                    ) {
                        selected = template
                        // Auto-fill name when it still matches a template name
                        if PresetTemplate.allCases.map(\.rawValue).contains(name) {
                            name = template.rawValue
                        }
                    }
                }
            }

            HStack {
                Text("Name:")
                    .fontWeight(.medium)
                TextField("Preset name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create Preset") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    onCreate(n, selected.parts)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 500)
    }
}

private struct TemplateCard: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                Text(title)
                    .fontWeight(.semibold)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preset Sidebar View
struct PresetSidebarView: View {
    @EnvironmentObject var presetStore: EnsemblePresetStore
    let onApply: (_ parts: [PresetPart], _ stampId: UUID?) -> (matched: Int, unmatched: Int, unmatchedPartNames: Set<String>)

    /// Local draft — changes aren't committed to the preset until "Save to Preset"
    @State private var draftParts: [PresetPart] = []
    @State private var isDirty = false
    @State private var showingNewPreset = false
    @State private var applyResult: (matched: Int, unmatched: Int, unmatchedPartNames: Set<String>)? = nil

    private var selectedPreset: EnsemblePreset? { presetStore.selectedPreset }

    var body: some View {
        VStack(spacing: 0) {
            // Header + preset picker (only shown when presets exist)
            if !presetStore.presets.isEmpty {
                VStack(spacing: 6) {
                    HStack {
                        Text("Presets")
                            .font(.headline)
                        Spacer()
                        Button {
                            showingNewPreset = true
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New Preset")
                    }

                    Picker("", selection: Binding(
                        get: { presetStore.selectedPresetId },
                        set: { switchPreset(to: $0) }
                    )) {
                        ForEach(presetStore.presets) { preset in
                            Text(preset.name).tag(Optional(preset.id))
                        }
                    }
                    .labelsHidden()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

                if let preset = selectedPreset {
                    PresetStampPicker(stampId: Binding(
                        get: { preset.stampId },
                        set: { newValue in
                            var updated = preset
                            updated.stampId = newValue
                            presetStore.updatePreset(updated)
                        }
                    ))
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }

                Divider()
            }

            if presetStore.presets.isEmpty {
                // Empty state — prompt to create first preset
                VStack(spacing: 14) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No presets yet")
                        .font(.headline)
                    Text("Create a preset to store copy counts for an ensemble.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("New Preset…") {
                        showingNewPreset = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else if !draftParts.isEmpty {
                // Parts list
                List {
                    ForEach($draftParts) { $part in
                        PresetPartRow(
                            part: $part,
                            isUnmatched: applyResult?.unmatchedPartNames.contains(part.name) ?? false,
                            onMarkDirty: { isDirty = true; applyResult = nil },
                            onDelete: {
                                draftParts.removeAll { $0.id == part.id }
                                draftParts = renumberAfterDeletion(draftParts)
                                isDirty = true
                                applyResult = nil
                            }
                        )
                    }
                }
                .listStyle(.plain)

                Divider()

                // Action area
                VStack(spacing: 8) {
                    if isDirty {
                        HStack(spacing: 8) {
                            Button("Revert") {
                                draftParts = selectedPreset?.parts ?? []
                                isDirty = false
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Save to Preset") {
                                if var p = selectedPreset {
                                    p.parts = draftParts
                                    presetStore.updatePreset(p)
                                    isDirty = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    Button {
                        applyResult = onApply(draftParts, selectedPreset?.stampId)
                    } label: {
                        Label("Apply to Files", systemImage: "arrow.left.to.line")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    // Apply result summary
                    if let result = applyResult {
                        if result.unmatched == 0 {
                            Label("\(result.matched) file\(result.matched == 1 ? "" : "s") matched", systemImage: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            VStack(spacing: 2) {
                                Label("\(result.matched) matched", systemImage: "checkmark.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.green)
                                Label("\(result.unmatched) not matched — see orange rows", systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear { loadDraft() }
        .onChange(of: presetStore.selectedPresetId) { loadDraft() }
        // Keep the parts list in sync when the selected preset is edited
        // elsewhere (e.g. the Preferences window) — but never clobber unsaved
        // local edits, so we skip the reload while this sidebar is dirty.
        .onChange(of: presetStore.selectedPreset) { _, fresh in
            guard !isDirty, let fresh, fresh.parts != draftParts else { return }
            draftParts = fresh.parts
            applyResult = nil
        }
        .sheet(isPresented: $showingNewPreset) {
            NewPresetSheet { name, parts in
                presetStore.addPreset(name: name, parts: parts)
                loadDraft()
            }
        }
    }

    private func loadDraft() {
        draftParts = selectedPreset?.parts ?? []
        isDirty = false
        applyResult = nil
    }

    private func switchPreset(to newId: UUID?) {
        if isDirty {
            let alert = NSAlert()
            alert.messageText = "Unsaved Changes"
            alert.informativeText = "Discard changes to this preset?"
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        presetStore.selectedPresetId = newId
        isDirty = false
    }
}
