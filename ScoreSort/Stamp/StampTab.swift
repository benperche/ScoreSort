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

/// One file queued for stamping, with the name it should be written under.
struct StampFileItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// Output filename without the ".pdf" extension. Editable when saving as new files.
    var outputName: String

    init(url: URL) {
        self.url = url
        self.outputName = url.deletingPathExtension().lastPathComponent
    }
}

/// What happens to the file being stamped.
enum StampOutputMode: String, CaseIterable, Identifiable {
    /// Overwrite the file in place — the common case when marking up your own library.
    case replaceOriginal
    /// Write copies into a folder you choose, under names you can edit.
    case saveAsNew

    var id: String { rawValue }

    var label: String {
        switch self {
        case .replaceOriginal: return "Replace the original files"
        case .saveAsNew:       return "Save as new files\u{2026}"
        }
    }
}

struct StampView: View {
    @EnvironmentObject private var stampStore: StampStore
    @EnvironmentObject private var appState: AppState

    /// Working copy of the selected stamp. Edits are pushed back to the store on change.
    @State private var draft: Stamp?
    /// Files to stamp, with their output names.
    @State private var items: [StampFileItem] = []
    @State private var isTargeted = false
    @AppStorage("stampOutputMode") private var outputMode: StampOutputMode = .replaceOriginal
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

                if !items.isEmpty {
                    Button(action: { items = [] }) {
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
        .onChange(of: items) { DispatchQueue.main.async { syncTabCommands() } }
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
                                    draft?.move(to: anchor)
                                } label: {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(stamp.matches(anchor) ? Color.accentColor : Color.secondary.opacity(0.15))
                                        .frame(width: 34, height: 24)
                                }
                                .buttonStyle(.plain)
                                .help(anchor.label)
                            }
                        }
                    }
                }

                Text("Or drag the stamp around on the preview.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Margin")
                    Stepper(value: binding.margin, in: 0...144, step: 2) {
                        Text("\(Int(stamp.margin)) pt")
                            .monospacedDigit()
                    }
                }
                Text("The smallest gap allowed between the stamp and the page edge — it also limits how far the stamp can be dragged.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Preview + files

    private var previewColumn: some View {
        VStack(spacing: 12) {
            Text("Preview")
                .font(.headline)
                .padding(.top, 16)

            if let binding = draftBinding {
                StampPreviewCanvas(stamp: binding, page: previewPage, height: 300)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 300)
                    .overlay(Text("Nothing to preview").foregroundColor(.secondary))
            }

            Text(previewPage == nil
                 ? "Shown on a blank A4 page — drag the stamp to move it. Add a PDF below to preview on a real page."
                 : "Shown on page 1 of \(items[0].url.lastPathComponent) — drag the stamp to move it.")
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

            if items.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.gray.opacity(0.35),
                                  style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .frame(height: 60)
                    .overlay(Text("Drop PDFs here").foregroundColor(.secondary))
                    .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                        loadDroppedFiles(providers)
                        return true
                    }
            } else {
                fileList
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

            Picker("Output", selection: $outputMode) {
                ForEach(StampOutputMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            if let problem = nameProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack {
                Button("Add Files\u{2026}") { chooseFiles() }
                Spacer()
                Button(outputMode == .replaceOriginal ? "Stamp Files" : "Stamp Files\u{2026}") {
                    stampFiles()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStamp)
            }
        }
    }

    /// One row per queued file. Names are editable only when saving as new files —
    /// when replacing, the file keeps its own name by definition.
    private var fileList: some View {
        VStack(spacing: 0) {
            ForEach($items) { $item in
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundColor(.secondary)

                    if outputMode == .saveAsNew {
                        TextField("Filename", text: $item.outputName)
                            .textFieldStyle(.roundedBorder)
                        Text(".pdf")
                            .foregroundColor(.secondary)
                    } else {
                        Text(item.url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }

                    Button {
                        items.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Remove this file")
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            }
        }
        .frame(maxHeight: 140)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            loadDroppedFiles(providers)
            return true
        }
    }

    // MARK: - Bindings & helpers

    private var canStamp: Bool {
        !items.isEmpty && (draft?.isDrawable ?? false) && nameProblem == nil
    }

    /// The first thing wrong with the output names, or nil when they're all usable.
    /// Only meaningful when saving as new files — replacing keeps the originals' names.
    private var nameProblem: String? {
        guard outputMode == .saveAsNew else { return nil }
        for item in items {
            let name = item.outputName.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { return "Every file needs a name." }
            if let error = pdfFilenameError(for: name) { return "“\(name)”: \(error.lowercased())" }
        }
        let names = items.map { $0.outputName.trimmingCharacters(in: .whitespaces).lowercased() }
        if Set(names).count != names.count {
            return "Two files would be saved under the same name."
        }
        return nil
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
        guard let url = items.first?.url, let doc = PDFDocument(url: url) else { return nil }
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
        slice.clear        = items.isEmpty ? nil : { items = [] }
        slice.tabActions = [
            MenuAction(title: "New Stamp", perform: { addStamp() }),
            MenuAction(title: "Duplicate Stamp", isEnabled: stampStore.selectedStampId != nil,
                       perform: { duplicateStamp() }),
            MenuAction(title: "Delete Stamp", isEnabled: stampStore.stamps.count > 1,
                       perform: { deleteStamp() }),
            MenuAction(title: "Show in Finder", key: KeyEquivalent("f"), modifiers: [.command, .shift],
                       isEnabled: items.first != nil, perform: { revealInFinder(items.first?.url) }),
        ]
        appState.tabCommands.slice = slice
    }

    // MARK: - Batch stamping

    private func addFiles(_ urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            items.append(StampFileItem(url: url))
        }
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "pdf" else { return }
                DispatchQueue.main.async { addFiles([url]) }
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
            DispatchQueue.main.async { addFiles(urls) }
        }
    }

    private func stampFiles() {
        guard let stamp = draft, stamp.isDrawable, !items.isEmpty, nameProblem == nil else { return }
        let job = StampJob(stamp: stamp, scope: scope)

        switch outputMode {
        case .replaceOriginal:
            // Irreversible: the stamped file lands on top of the original.
            let count = items.count
            guard confirmNSAlert(
                title: count == 1 ? "Stamp and replace the original?" : "Stamp and replace \(count) originals?",
                message: "The stamp will be written into \(count == 1 ? "this file" : "these files") in place. The unstamped version can't be recovered afterwards.",
                confirmTitle: "Stamp and Replace") else { return }

            let destinations = items.map { (item: $0, destination: $0.url) }
            write(destinations, job: job)

        case .saveAsNew:
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.title = "Select Output Folder"
            panel.message = "Choose where to save the stamped PDFs"
            panel.directoryURL = outputDirectory(forSourceFile: items.first?.url)

            panel.begin { response in
                guard response == .OK, let folder = panel.url else { return }
                DispatchQueue.main.async {
                    let destinations = items.map { item in
                        let name = item.outputName.trimmingCharacters(in: .whitespaces)
                        return (item: item, destination: folder.appendingPathComponent("\(name).pdf"))
                    }
                    // Includes the case where a name matches a source file in that folder.
                    let clashes = destinations.filter {
                        FileManager.default.fileExists(atPath: $0.destination.path)
                    }
                    if !clashes.isEmpty {
                        let names = clashes.map { $0.destination.lastPathComponent }.joined(separator: ", ")
                        guard confirmNSAlert(
                            title: clashes.count == 1 ? "A file with that name already exists" : "\(clashes.count) files already exist",
                            message: "Replace \(names) in \(folder.lastPathComponent)?",
                            confirmTitle: "Replace") else { return }
                    }
                    write(destinations, job: job)
                }
            }
        }
    }

    /// Writes a stamped copy of each queued file to its destination, then reports once.
    private func write(_ destinations: [(item: StampFileItem, destination: URL)], job: StampJob) {
        var written: [String] = []
        var failed: [String] = []

        for (item, destination) in destinations {
            guard let doc = PDFDocument(url: item.url) else {
                failed.append(item.url.lastPathComponent); continue
            }
            // A standalone file is one "part", so first-page scope means page 1 only.
            let stamped = applyingStamp(job, to: doc, partFirstPages: [0])
            if stamped.write(to: destination) {
                written.append(destination.lastPathComponent)
            } else {
                failed.append(destination.lastPathComponent)
            }
        }

        let folder = destinations.first?.destination.deletingLastPathComponent()
        if failed.isEmpty {
            showNSAlert(title: "Files Stamped",
                        message: "Stamped \(written.count) file(s)\(folder.map { " in:\n\($0.path)" } ?? "").",
                        isError: false)
            // Replacing leaves nothing to do; the queue is done either way.
            items = []
        } else {
            showNSAlert(title: written.isEmpty ? "Error" : "Partial Success",
                        message: "Stamped \(written.count) file(s); \(failed.count) failed:\n\(failed.joined(separator: ", "))",
                        isError: true)
        }
    }
}

// MARK: - Draggable preview

/// The page preview with the stamp drawn on it (by `stampPreviewImage`, the same routine
/// the flattener uses) plus an invisible drag handle over the stamp itself, so the stamp can
/// be dragged to any position rather than only the nine presets.
private struct StampPreviewCanvas: View {
    @Binding var stamp: Stamp
    let page: PDFPage?
    let height: CGFloat

    /// Fractional position when the current drag began.
    @State private var dragOrigin: (x: Double, y: Double)?
    @State private var isHovering = false

    var body: some View {
        let pageBox = visualPageBox(for: page)
        let scale = height / pageBox.height
        let viewSize = CGSize(width: pageBox.width * scale, height: height)

        ZStack(alignment: .topLeading) {
            if let image = stampPreviewImage(stamp, page: page, maxDimension: max(viewSize.width, viewSize.height) * 2) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: viewSize.width, height: viewSize.height)
            } else {
                Rectangle().fill(Color.white)
                    .frame(width: viewSize.width, height: viewSize.height)
            }

            handle(pageBox: pageBox, scale: scale)
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.3)))
        .shadow(radius: 2, y: 1)
    }

    /// A transparent hit area sitting exactly over the drawn stamp. Highlighted on hover so
    /// it's discoverable that the stamp can be moved.
    @ViewBuilder
    private func handle(pageBox: CGRect, scale: CGFloat) -> some View {
        let textSize = stampTextSize(stamp, in: pageBox)
        let rect = stampRect(for: stamp, textSize: textSize, in: pageBox)
        // PDF space is y-up, the view is y-down.
        let viewRect = CGRect(x: (rect.minX - pageBox.minX) * scale,
                              y: (pageBox.maxY - rect.maxY) * scale,
                              width: rect.width * scale,
                              height: rect.height * scale)

        if stamp.isDrawable, viewRect.width > 0, viewRect.height > 0 {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(isHovering || dragOrigin != nil ? 0.18 : 0.001))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.accentColor.opacity(isHovering || dragOrigin != nil ? 0.9 : 0),
                                      style: StrokeStyle(lineWidth: 1, dash: [3]))
                )
                // Padded outwards so small stamps stay easy to grab.
                .frame(width: max(viewRect.width, 16), height: max(viewRect.height, 16))
                .position(x: viewRect.midX, y: viewRect.midY)
                .onHover { isHovering = $0 }
                .gesture(dragGesture(pageBox: pageBox, textSize: textSize, scale: scale))
                .help("Drag to move the stamp")
        }
    }

    private func dragGesture(pageBox: CGRect, textSize: CGSize, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragOrigin ?? (stamp.positionX, stamp.positionY)
                if dragOrigin == nil { dragOrigin = start }

                let boxSize = stampBoxSize(for: stamp, textSize: textSize)
                let travel = stampTravel(for: stamp, boxSize: boxSize, in: pageBox)

                // View points → page points → fraction of the available travel.
                if travel.width > 0 {
                    let dx = value.translation.width / scale / travel.width
                    stamp.positionX = min(max(start.x + Double(dx), 0), 1)
                }
                if travel.height > 0 {
                    // Dragging down in the view decreases the page's y.
                    let dy = -value.translation.height / scale / travel.height
                    stamp.positionY = min(max(start.y + Double(dy), 0), 1)
                }
            }
            .onEnded { _ in dragOrigin = nil }
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
