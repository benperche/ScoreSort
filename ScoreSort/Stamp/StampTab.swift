//
//  StampTab.swift
//  ScoreSort
//
//  Tab 4 — Stamp. Designs the named stamps held by `StampStore` and applies them to PDFs
//  that already exist. The same saved stamps are used by the Combine and Split tabs via
//  `StampMenuButton`, so a design made here is immediately available when exporting there.
//
//  The preview draws the stamp through the same `drawStamp` routine as the flattener, so
//  what's shown here is what gets written.
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
    /// Page 1 of the first queued file, held so the preview doesn't reload it per redraw.
    @State private var previewPage: PDFPage?
    @State private var previewDocument: PDFDocument?
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
        .onChange(of: items) {
            refreshPreviewPage()
            DispatchQueue.main.async { syncTabCommands() }
        }
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

                // Portrait proportions inside a page-like outline, so the grid reads as
                // "where on the page" rather than as nine anonymous buttons.
                VStack(spacing: 3) {
                    ForEach(Array(StampAnchor.grid.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 3) {
                            ForEach(row) { anchor in
                                Button {
                                    draft?.move(to: anchor)
                                } label: {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(stamp.matches(anchor) ? Color.accentColor : Color.secondary.opacity(0.14))
                                        .frame(width: 30, height: 38)
                                }
                                .buttonStyle(.plain)
                                .help(anchor.label)
                            }
                        }
                    }
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.35))
                )

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
        VStack(spacing: 8) {
            // The preview takes every point the bottom section doesn't need.
            if let binding = draftBinding {
                StampPreviewCanvas(stamp: binding, page: previewPage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 12)
                    .padding(.horizontal, 12)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(Text("Nothing to preview").foregroundColor(.secondary))
                    .padding(12)
            }

            Text(previewCaption)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)

            Divider()

            filesSection
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Driven by `items`, never by `previewPage` — the two are briefly out of step when the
    /// list changes (the body re-runs before `.onChange` clears the page), and indexing
    /// `items` on the strength of `previewPage` crashed when the last file was removed.
    private var previewCaption: String {
        if let name = items.first?.url.lastPathComponent {
            return "Page 1 of \(name) — drag the stamp to move it."
        }
        return "Blank A4 page — drag the stamp to move it. Add a PDF below to preview on a real page."
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stamp existing files")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button("Add Files\u{2026}") { chooseFiles() }
                    .controlSize(.small)
            }

            if items.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.gray.opacity(0.35),
                                  style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .frame(height: 44)
                    .overlay(Text("Drop PDFs here").font(.callout).foregroundColor(.secondary))
                    .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                        loadDroppedFiles(providers)
                        return true
                    }
            } else {
                fileList
            }

            // The two choices sit side by side rather than as four stacked rows, spread
            // across the width with the action at the trailing edge. No Spacer may be
            // *vertical* here — a greedy one stretches this whole section and steals the
            // height the preview should be getting.
            HStack(alignment: .top, spacing: 16) {
                Picker("Stamp on", selection: $scope) {
                    ForEach(StampScope.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .fixedSize()

                Spacer(minLength: 12)

                Picker("Output", selection: $outputMode) {
                    ForEach(StampOutputMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .fixedSize()

                Spacer(minLength: 12)

                Button(outputMode == .replaceOriginal ? "Stamp Files" : "Stamp Files\u{2026}") {
                    stampFiles()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStamp)
            }

            if let problem = nameProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .help("Each file is one part, so “first page of each part” stamps page 1 only.")
    }

    /// One row per queued file. Names are editable only when saving as new files —
    /// when replacing, the file keeps its own name by definition.
    private var fileList: some View {
        // Top-aligned scroll so one file doesn't float in the middle of a tall box, and a
        // long list stays scrollable without pushing the preview out of the window.
        ScrollView {
            VStack(spacing: 2) {
                ForEach($items) { $item in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .foregroundColor(.secondary)

                        if outputMode == .saveAsNew {
                            TextField("Filename", text: $item.outputName)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                            Text(".pdf")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        } else {
                            Text(item.url.lastPathComponent)
                                .font(.callout)
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
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
        }
        .frame(height: min(CGFloat(items.count) * 28 + 8, 92))
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

    /// Loads page 1 of the first queued file for the preview. Cached in `previewPage` rather
    /// than computed per redraw — reading the PDF off disk on every frame made dragging the
    /// stamp crawl. `previewDocument` is retained because a PDFPage can't be drawn once its
    /// document is released.
    private func refreshPreviewPage() {
        guard let url = items.first?.url else {
            previewDocument = nil
            previewPage = nil
            return
        }
        guard url != previewDocument?.documentURL else { return }
        previewDocument = PDFDocument(url: url)
        previewPage = previewDocument?.page(at: 0)
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

/// The page preview with the stamp on top and a drag handle over the stamp, so it can be
/// dragged anywhere rather than only to the nine presets.
///
/// Deliberately three layers, for drag performance: the **page** is a bitmap rendered once
/// per page and cached (rendering a dense score page costs tens of milliseconds — doing it
/// per frame made dragging crawl); the **stamp** is a `Canvas` calling the same `drawStamp`
/// the flattener uses, so it stays faithful while being cheap to redraw; the **handle** is
/// transparent and only tracks the gesture.
private struct StampPreviewCanvas: View {
    @Binding var stamp: Stamp
    let page: PDFPage?

    /// Fractional position when the current drag began.
    @State private var dragOrigin: (x: Double, y: Double)?
    @State private var isHovering = false
    /// Cached page bitmap, re-rendered only when the page itself changes.
    @State private var pageImage: NSImage?
    @State private var renderedPage: PDFPage?

    var body: some View {
        GeometryReader { geo in
            let pageBox = visualPageBox(for: page)
            let scale = min(geo.size.width / pageBox.width, geo.size.height / pageBox.height)
            let viewSize = CGSize(width: pageBox.width * scale, height: pageBox.height * scale)

            ZStack(alignment: .topLeading) {
                if let pageImage {
                    Image(nsImage: pageImage)
                        .resizable()
                        .frame(width: viewSize.width, height: viewSize.height)
                } else {
                    Rectangle().fill(Color.white)
                        .frame(width: viewSize.width, height: viewSize.height)
                }

                stampLayer(pageBox: pageBox, scale: scale, viewSize: viewSize)

                handle(pageBox: pageBox, scale: scale)
            }
            .frame(width: viewSize.width, height: viewSize.height)
            .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.3)))
            .shadow(radius: 2, y: 1)
            // Centre the page inside whatever space the layout gave us.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { refreshPageImage() }
        .onChange(of: page) { _, _ in refreshPageImage() }
    }

    private func refreshPageImage() {
        guard page !== renderedPage || pageImage == nil else { return }
        renderedPage = page
        pageImage = stampPagePreviewImage(page: page)
    }

    /// The stamp itself, drawn through the shared `drawStamp` so the preview can't drift from
    /// the written PDF. Only this layer redraws while dragging.
    private func stampLayer(pageBox: CGRect, scale: CGFloat, viewSize: CGSize) -> some View {
        Canvas { context, _ in
            context.withCGContext { cg in
                // Canvas is y-down from the top-left; PDF space is y-up from the bottom-left.
                cg.translateBy(x: 0, y: viewSize.height)
                cg.scaleBy(x: 1, y: -1)
                cg.scaleBy(x: scale, y: scale)
                drawStamp(stamp, in: cg, pageBox: pageBox)
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .allowsHitTesting(false)
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
