//
//  StampDesignerView.swift
//  ScoreSort
//
//  The "Stamp…" sheet (File ▸ Stamp…, ⌥⌘S, or the Edit button beside the Combine/Split
//  stamp toggles). Designs the named stamps held by `StampStore`, previews them live, and
//  can batch-stamp existing PDFs on its own.
//
//  The preview is rendered by `stampPreviewImage`, which shares its drawing routine with
//  the flattener — so what's shown here is what gets written.
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Token for `.sheet(item:)` — `.sheet(isPresented:)` is avoided app-wide because of the
/// blank-sheet bug.
struct StampSheetToken: Identifiable {
    let id = UUID()
}

struct StampDesignerView: View {
    @EnvironmentObject private var stampStore: StampStore
    @Environment(\.dismiss) private var dismiss

    /// Working copy of the selected stamp. Edits are pushed back to the store on change.
    @State private var draft: Stamp?
    /// Files dropped in for the standalone batch-stamp path.
    @State private var batchFiles: [URL] = []
    @State private var isTargeted = false

    /// Computed once — enumerating font families on every redraw is noticeably slow.
    private static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                controlsColumn
                    .frame(width: 360)
                Divider()
                previewColumn
                    .frame(minWidth: 320)
            }

            Divider()

            HStack {
                Text("Stamps are saved automatically and shared by every tool.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 800, height: 620)
        .onAppear { draft = stampStore.selectedStamp }
        .onChange(of: stampStore.selectedStampId) { _, _ in draft = stampStore.selectedStamp }
        .onChange(of: draft) { _, newValue in
            if let newValue { stampStore.updateStamp(newValue) }
        }
    }

    // MARK: - Controls

    private var controlsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                stampPickerSection

                if draft != nil {
                    Divider()
                    textSection
                    Divider()
                    appearanceSection
                    Divider()
                    placementSection
                    Divider()
                    scopeSection
                }
            }
            .padding(16)
        }
    }

    private var stampPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stamp")
                .font(.headline)

            HStack(spacing: 6) {
                Picker("", selection: Binding(
                    get: { stampStore.selectedStampId ?? stampStore.stamps.first?.id },
                    set: { stampStore.selectedStampId = $0 }
                )) {
                    ForEach(stampStore.stamps) { stamp in
                        Text(stamp.name.isEmpty ? "Untitled" : stamp.name).tag(Optional(stamp.id))
                    }
                }
                .labelsHidden()

                Button {
                    let new = stampStore.addStamp(name: "New Stamp", text: "")
                    draft = new
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a stamp")

                Button {
                    if let id = stampStore.selectedStampId { stampStore.duplicateStamp(id) }
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .help("Duplicate this stamp")
                .disabled(stampStore.selectedStampId == nil)

                Button {
                    if let id = stampStore.selectedStampId { stampStore.deleteStamp(id) }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this stamp")
                .disabled(stampStore.stamps.count <= 1)
            }

            if let binding = draftBinding {
                TextField("Stamp name", text: binding.name)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder
    private var textSection: some View {
        if let binding = draftBinding {
            VStack(alignment: .leading, spacing: 8) {
                Text("Text")
                    .font(.headline)
                TextField("e.g. Example School Band", text: binding.text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                Text("Press ⌥⏎ for a second line.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var appearanceSection: some View {
        if let binding = draftBinding, let stamp = draft {
            VStack(alignment: .leading, spacing: 10) {
                Text("Appearance")
                    .font(.headline)

                Picker("Font", selection: binding.fontFamily) {
                    ForEach(fontFamilyOptions(current: stamp.fontFamily), id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                HStack(spacing: 12) {
                    Toggle("Bold", isOn: binding.isBold)
                    Toggle("Italic", isOn: binding.isItalic)
                }

                HStack {
                    Text("Size")
                    Stepper(value: binding.fontSize, in: 6...48, step: 1) {
                        Text("\(Int(stamp.fontSize)) pt")
                            .monospacedDigit()
                    }
                }

                ColorPicker("Colour", selection: colourBinding, supportsOpacity: false)

                Toggle("Draw a box around the text", isOn: binding.hasBorder)
            }
        }
    }

    @ViewBuilder
    private var placementSection: some View {
        if let binding = draftBinding, let stamp = draft {
            VStack(alignment: .leading, spacing: 10) {
                Text("Position")
                    .font(.headline)

                VStack(spacing: 4) {
                    ForEach(Array(StampAnchor.grid.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 4) {
                            ForEach(row) { anchor in
                                Button {
                                    draft?.anchor = anchor
                                } label: {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(stamp.anchor == anchor ? Color.accentColor : Color.secondary.opacity(0.15))
                                        .frame(width: 34, height: 24)
                                }
                                .buttonStyle(.plain)
                                .help(anchorHelp(anchor))
                            }
                        }
                    }
                }

                HStack {
                    Text("Margin")
                    Stepper(value: binding.margin, in: 0...144, step: 2) {
                        Text("\(Int(stamp.margin)) pt")
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var scopeSection: some View {
        if let binding = draftBinding {
            VStack(alignment: .leading, spacing: 8) {
                Text("Stamp on")
                    .font(.headline)
                Picker("", selection: binding.scope) {
                    ForEach(StampScope.allCases) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("In a combined PDF, a “part” is each file you added; in a split, each file written out.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Preview + batch

    private var previewColumn: some View {
        VStack(spacing: 12) {
            Text("Preview")
                .font(.headline)
                .padding(.top, 16)

            if let stamp = draft, let image = stampPreviewImage(stamp, page: previewPage) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 320)
                    .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.3)))
                    .shadow(radius: 2, y: 1)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 320)
                    .overlay(Text("Nothing to preview").foregroundColor(.secondary))
            }

            Text(previewPage == nil
                 ? "Shown on a blank A4 page. Drop a PDF below to preview on a real page."
                 : "Shown on page 1 of \(batchFiles.first?.lastPathComponent ?? "the dropped file").")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            Divider()

            batchSection
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private var batchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stamp existing files")
                .font(.headline)

            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTargeted ? Color.accentColor : Color.gray.opacity(0.35),
                              style: StrokeStyle(lineWidth: 2, dash: [6]))
                .frame(height: 64)
                .overlay(
                    Text(batchFiles.isEmpty
                         ? "Drop PDFs here"
                         : "\(batchFiles.count) file(s) ready")
                        .foregroundColor(.secondary)
                )
                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                    loadDroppedFiles(providers)
                    return true
                }

            HStack {
                Button("Choose Files\u{2026}") { chooseBatchFiles() }
                Button("Clear") { batchFiles = [] }
                    .disabled(batchFiles.isEmpty)
                Spacer()
                Button("Stamp Files\u{2026}") { stampBatchFiles() }
                    .buttonStyle(.borderedProminent)
                    .disabled(batchFiles.isEmpty || !(draft?.isDrawable ?? false))
            }
        }
    }

    // MARK: - Bindings & helpers

    /// A non-optional binding into `draft`, so the controls can bind to its fields directly.
    private var draftBinding: Binding<Stamp>? {
        guard draft != nil else { return nil }
        return Binding(get: { draft ?? Stamp(name: "", text: "") },
                       set: { draft = $0 })
    }

    private var colourBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: nsColor(fromHex: draft?.colourHex ?? "#000000")) },
            set: { draft?.colourHex = hexString(from: NSColor($0)) }
        )
    }

    /// The page shown behind the stamp in the preview: page 1 of the first dropped file.
    private var previewPage: PDFPage? {
        guard let url = batchFiles.first, let doc = PDFDocument(url: url) else { return nil }
        return doc.page(at: 0)
    }

    /// Keeps the saved family in the list even if it isn't installed on this Mac, so the
    /// picker never appears blank.
    private func fontFamilyOptions(current: String) -> [String] {
        Self.fontFamilies.contains(current) ? Self.fontFamilies : [current] + Self.fontFamilies
    }

    private func anchorHelp(_ anchor: StampAnchor) -> String {
        switch anchor {
        case .topLeft:      return "Top left"
        case .topCentre:    return "Top centre"
        case .topRight:     return "Top right"
        case .middleLeft:   return "Middle left"
        case .centre:       return "Centre"
        case .middleRight:  return "Middle right"
        case .bottomLeft:   return "Bottom left"
        case .bottomCentre: return "Bottom centre"
        case .bottomRight:  return "Bottom right"
        }
    }

    // MARK: - Batch stamping

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                DispatchQueue.main.async {
                    if !batchFiles.contains(url) { batchFiles.append(url) }
                }
            }
        }
    }

    private func chooseBatchFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.title = "Select PDFs to Stamp"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            DispatchQueue.main.async {
                for url in urls where !batchFiles.contains(url) { batchFiles.append(url) }
            }
        }
    }

    private func stampBatchFiles() {
        guard let stamp = draft, stamp.isDrawable, !batchFiles.isEmpty else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Output Folder"
        panel.message = "Choose where to save the stamped PDFs"
        panel.directoryURL = outputDirectory(forSourceFile: batchFiles.first)

        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            let files = batchFiles
            DispatchQueue.main.async {
                writeStampedFiles(files, stamp: stamp, to: folder) { title, message, isError in
                    showNSAlert(title: title, message: message, isError: isError)
                }
            }
        }
    }

    /// Writes a stamped copy of each file into `folder`. Files landing back in their own
    /// folder get a " (stamped)" suffix rather than overwriting the original.
    private func writeStampedFiles(_ urls: [URL], stamp: Stamp, to folder: URL,
                                   completion: PDFAlertHandler) {
        var written = 0
        var failed: [String] = []

        for url in urls {
            guard let doc = PDFDocument(url: url) else {
                failed.append(url.lastPathComponent); continue
            }
            // A standalone file is one "part", so first-page scope means page 1 only.
            let indices = stampPageIndices(for: stamp, pageCount: doc.pageCount, partFirstPages: [0])
            guard let stamped = stampedDocument(doc, stamp: stamp, pageIndices: indices) else {
                failed.append(url.lastPathComponent); continue
            }

            let base = url.deletingPathExtension().lastPathComponent
            let sameFolder = url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
            let name = sameFolder ? "\(base) (stamped).pdf" : "\(base).pdf"
            if stamped.write(to: folder.appendingPathComponent(name)) {
                written += 1
            } else {
                failed.append(name)
            }
        }

        if failed.isEmpty {
            completion("Files Stamped",
                       "Stamped \(written) file(s) into:\n\(folder.path)", false)
        } else {
            completion(written > 0 ? "Partial Success" : "Error",
                       "Stamped \(written) file(s); \(failed.count) failed:\n\(failed.joined(separator: ", "))",
                       true)
        }
    }
}

// MARK: - Shared "Stamp output" option row

/// The checkbox shown in the Combine and Split controls: switches stamping on for that
/// tool's output, names the active stamp, and opens the designer.
struct StampOptionRow: View {
    @Binding var isEnabled: Bool
    @EnvironmentObject private var stampStore: StampStore
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $isEnabled) {
                Text(label)
            }
            .toggleStyle(.checkbox)

            Button("Edit\u{2026}") { appState.stampSheet = StampSheetToken() }
                .buttonStyle(.link)
                .controlSize(.small)

            Spacer()
        }
    }

    private var label: String {
        guard let stamp = stampStore.selectedStamp, stamp.isDrawable else {
            return "Stamp output (no stamp text set yet)"
        }
        let scope = stamp.scope == .everyPage ? "every page" : "first page of each part"
        return "Stamp output with “\(stamp.name)” on \(scope)"
    }
}
