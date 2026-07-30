//
//  StampTab.swift
//  ScoreSort
//
//  Tab 4 — Stamp. Designs the named stamps held by `StampStore` and applies them to PDFs
//  that already exist. The same saved stamps are used by the Combine and Split tabs via
//  `StampMenuButton`, so a design made here is immediately available when exporting there.
//
//  The preview is rendered by `stampPreviewImage`, which shares its drawing routine with
//  the flattener — so what's shown here is what gets written.
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct StampView: View {
    @EnvironmentObject private var stampStore: StampStore
    @EnvironmentObject private var appState: AppState

    /// Working copy of the selected stamp. Edits are pushed back to the store on change.
    @State private var draft: Stamp?
    /// Files to stamp.
    @State private var files: [URL] = []
    @State private var isTargeted = false
    /// Scope for *this* tab's batch job — a per-job choice, not part of the saved design.
    @AppStorage("stampTabScope") private var scope: StampScope = .everyPage

    /// Computed once — enumerating font families on every redraw is noticeably slow.
    private static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack {
                Text("Stamp PDFs")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                if !files.isEmpty {
                    Button(action: { files = [] }) {
                        Label("Clear Files", systemImage: "xmark.circle.fill")
                    }
                    .help("Remove all files and start over")
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            HStack(alignment: .top, spacing: 0) {
                designerColumn
                    .frame(width: 360)
                Divider()
                previewColumn
                    .frame(minWidth: 340)
            }
        }
        .onAppear {
            draft = stampStore.selectedStamp
            DispatchQueue.main.async { syncTabCommands() }
        }
        .onChange(of: appState.selectedTab) { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: files) { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: stampStore.selectedStampId) { _, _ in draft = stampStore.selectedStamp }
        .onChange(of: draft) { _, newValue in
            if let newValue { stampStore.updateStamp(newValue) }
        }
    }

    // MARK: - Designer

    private var designerColumn: some View {
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

                Button { addStamp() } label: { Image(systemName: "plus") }
                    .help("Add a stamp")

                Button { duplicateStamp() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate this stamp")
                    .disabled(stampStore.selectedStampId == nil)

                Button { deleteStamp() } label: { Image(systemName: "trash") }
                    .help("Delete this stamp")
                    .disabled(stampStore.stamps.count <= 1)
            }

            if let binding = draftBinding {
                TextField("Stamp name", text: binding.name)
                    .textFieldStyle(.roundedBorder)
            }

            Text("Saved stamps are shared: switch stamping on from the **Stamp** button in the Combine and Split tabs to apply one as those tools write their files.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Preview + files

    private var previewColumn: some View {
        VStack(spacing: 12) {
            Text("Preview")
                .font(.headline)
                .padding(.top, 16)

            if let stamp = draft, let image = stampPreviewImage(stamp, page: previewPage) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 300)
                    .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.3)))
                    .shadow(radius: 2, y: 1)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 300)
                    .overlay(Text("Nothing to preview").foregroundColor(.secondary))
            }

            Text(previewPage == nil
                 ? "Shown on a blank A4 page. Add a PDF below to preview on a real page."
                 : "Shown on page 1 of \(files[0].lastPathComponent).")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            Divider()

            filesSection
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stamp existing files")
                .font(.headline)

            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTargeted ? Color.accentColor : Color.gray.opacity(0.35),
                              style: StrokeStyle(lineWidth: 2, dash: [6]))
                .frame(height: 60)
                .overlay(
                    Text(files.isEmpty ? "Drop PDFs here" : "\(files.count) file(s) ready")
                        .foregroundColor(.secondary)
                )
                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                    loadDroppedFiles(providers)
                    return true
                }

            Picker("Stamp on", selection: $scope) {
                ForEach(StampScope.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            Text("Each file is one part, so “first page of each part” stamps page 1 only.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button("Choose Files\u{2026}") { chooseFiles() }
                Spacer()
                Button("Stamp Files\u{2026}") { stampFiles() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStamp)
            }
        }
    }

    // MARK: - Bindings & helpers

    private var canStamp: Bool {
        !files.isEmpty && (draft?.isDrawable ?? false)
    }

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

    /// The page shown behind the stamp in the preview: page 1 of the first file added.
    private var previewPage: PDFPage? {
        guard let url = files.first, let doc = PDFDocument(url: url) else { return nil }
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

    // MARK: - Stamp list actions

    private func addStamp() {
        draft = stampStore.addStamp(name: "New Stamp", text: "")
    }

    private func duplicateStamp() {
        guard let id = stampStore.selectedStampId else { return }
        stampStore.duplicateStamp(id)
    }

    private func deleteStamp() {
        guard let id = stampStore.selectedStampId else { return }
        stampStore.deleteStamp(id)
    }

    // MARK: - Menu bridge

    private func syncTabCommands() {
        guard appState.selectedTab == 4 else { return }
        var slice = TabSlice()
        slice.openTitle    = "Add Files\u{2026}"
        slice.open         = { chooseFiles() }
        slice.primaryTitle = "Stamp Files\u{2026}"
        slice.primarySave  = canStamp ? { stampFiles() } : nil
        slice.clearTitle   = "Clear Files"
        slice.clear        = files.isEmpty ? nil : { files = [] }
        slice.tabActions = [
            MenuAction(title: "New Stamp", perform: { addStamp() }),
            MenuAction(title: "Duplicate Stamp", isEnabled: stampStore.selectedStampId != nil,
                       perform: { duplicateStamp() }),
            MenuAction(title: "Delete Stamp", isEnabled: stampStore.stamps.count > 1,
                       perform: { deleteStamp() }),
            MenuAction(title: "Show in Finder", key: KeyEquivalent("f"), modifiers: [.command, .shift],
                       isEnabled: files.first != nil, perform: { revealInFinder(files.first) }),
        ]
        appState.tabCommands.slice = slice
    }

    // MARK: - Batch stamping

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                DispatchQueue.main.async {
                    if !files.contains(url) { files.append(url) }
                }
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.title = "Select PDFs to Stamp"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            DispatchQueue.main.async {
                for url in urls where !files.contains(url) { files.append(url) }
            }
        }
    }

    private func stampFiles() {
        guard let stamp = draft, stamp.isDrawable, !files.isEmpty else { return }
        let job = StampJob(stamp: stamp, scope: scope)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Output Folder"
        panel.message = "Choose where to save the stamped PDFs"
        panel.directoryURL = outputDirectory(forSourceFile: files.first)

        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            let urls = files
            DispatchQueue.main.async {
                writeStampedFiles(urls, job: job, to: folder) { title, message, isError in
                    showNSAlert(title: title, message: message, isError: isError)
                }
            }
        }
    }

    /// Writes a stamped copy of each file into `folder`. Files landing back in their own
    /// folder get a " (stamped)" suffix rather than overwriting the original.
    private func writeStampedFiles(_ urls: [URL], job: StampJob, to folder: URL,
                                   completion: PDFAlertHandler) {
        var written = 0
        var failed: [String] = []

        for url in urls {
            guard let doc = PDFDocument(url: url) else {
                failed.append(url.lastPathComponent); continue
            }
            // A standalone file is one "part", so first-page scope means page 1 only.
            let stamped = applyingStamp(job, to: doc, partFirstPages: [0])

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

// MARK: - Shared "Stamp" toolbar button

/// The pull-down button in the Combine and Split toolbars: switches stamping on for that
/// tool's output, picks which saved stamp to use and which pages it lands on, and jumps to
/// the Stamp tab to edit the designs.
struct StampMenuButton: View {
    @Binding var isEnabled: Bool
    @Binding var scope: StampScope
    @EnvironmentObject private var stampStore: StampStore
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Menu {
            Toggle("Stamp this output", isOn: $isEnabled)

            Divider()

            Picker("Stamp", selection: Binding(
                get: { stampStore.selectedStampId ?? stampStore.stamps.first?.id },
                set: { stampStore.selectedStampId = $0 }
            )) {
                ForEach(stampStore.stamps) { stamp in
                    Text(stamp.name.isEmpty ? "Untitled" : stamp.name).tag(Optional(stamp.id))
                }
            }
            .pickerStyle(.inline)

            Divider()

            Picker("Pages", selection: $scope) {
                ForEach(StampScope.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button("Edit Stamps\u{2026}") { appState.selectedTab = 4 }
        } label: {
            Label(label, systemImage: isEnabled ? "seal.fill" : "seal")
        }
        .help(isEnabled
              ? "This tool's output will be stamped. Click to change the stamp or which pages it lands on."
              : "Add a text stamp to this tool's output")
    }

    private var label: String {
        guard isEnabled, let stamp = stampStore.selectedStamp else { return "Stamp" }
        return "Stamp: \(stamp.name.isEmpty ? "Untitled" : stamp.name)"
    }
}
