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
    /// The page being previewed, held so the preview doesn't reload it per redraw.
    @State private var previewPage: PDFPage?
    @State private var previewDocument: PDFDocument?
    /// Which queued file, and which of its pages, the preview is showing.
    @State private var fileIndex = 0
    @State private var pageIndex = 0
    @FocusState private var isViewFocused: Bool
    /// Scope for *this* tab's batch job — a per-job choice, not part of the saved design.
    @AppStorage("stampTabScope") private var scope: StampScope = .everyPage

    /// Computed once — enumerating font families on every redraw is noticeably slow.

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
        // Drop anywhere in the tab, not just on the drop zone.
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in handleDrop(providers) }
        .focusable()
        .focused($isViewFocused)
        // Same key map as the Split and Rotate tabs: ← → step pages, ⌘← ⌘→ jump to the ends,
        // ↑ ↓ move between files.
        .onKeyPress { press in
            guard appState.selectedTab == 4 else { return .ignored }   // Stamp tab only
            // The stamp text editor is an NSTextView — arrows belong to it while it's being
            // typed in, so never intercept them then.
            guard !(NSApp.keyWindow?.firstResponder is NSTextView) else { return .ignored }
            guard !items.isEmpty else { return .ignored }

            switch press.key {
            case .leftArrow:
                if press.modifiers.contains(.command) { firstPage() } else { previousPage() }
                return .handled
            case .rightArrow:
                if press.modifiers.contains(.command) { lastPage() } else { nextPage() }
                return .handled
            case .upArrow:
                previousFile()
                return .handled
            case .downArrow:
                nextFile()
                return .handled
            default:
                return .ignored
            }
        }
        .onAppear {
            draft = stampStore.selectedStamp
            isViewFocused = true
            DispatchQueue.main.async { syncTabCommands() }
        }
        .onChange(of: appState.selectedTab) {
            // Leaving the tab: write out any edit still sitting in the debounce window.
            if appState.selectedTab != 4 { stampStore.flushPendingSave() }
            DispatchQueue.main.async { syncTabCommands() }
        }
        .onChange(of: items) {
            clampPreviewPosition()
            DispatchQueue.main.async { syncTabCommands() }
        }
        .onChange(of: fileIndex) { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: pageIndex) { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: stampStore.selectedStampId) { _, _ in draft = stampStore.selectedStamp }
        .onChange(of: draft) { _, newValue in
            guard let newValue else { return }
            // Deferred so the store's @Published write can never land inside a SwiftUI view
            // update — the editor writes back to `draft` from AppKit callbacks, and those
            // can fire mid-update. updateStamp finds its target by id, so a late write still
            // reaches the right stamp after switching.
            DispatchQueue.main.async { stampStore.updateStamp(newValue) }
        }
    }

    // MARK: - Designer

    private var designerColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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

            Text("Shared with Combine and Split — switch stamping on from their **Stamp** button.")
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
                StampTextEditor(stamp: binding, formatter: appState.stampFormatter)
                    .frame(height: 54)
                    .help("Select text and use the style buttons below (or ⌘B / ⌘I) to format part of the stamp. Return starts a new line.")
            }
        }
    }

    @ViewBuilder
    private var appearanceSection: some View {
        if let binding = draftBinding, let stamp = draft {
            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.headline)

                FontFamilyPicker(family: stamp.fontFamily) { newValue in
                    draft?.fontFamily = newValue
                    appState.stampFormatter.apply(fontFamily: newValue)
                }
                .equatable()

                // Toggle buttons rather than checkboxes — this is text formatting, and it
                // acts on the selection (or the whole stamp when nothing is selected).
                HStack(spacing: 8) {
                    Text("Style")
                    Toggle(isOn: Binding(
                        get: { appState.stampFormatter.isBold },
                        set: { _ in appState.stampFormatter.toggleBold() }
                    )) {
                        Image(systemName: "bold")
                    }
                    .toggleStyle(.button)
                    .help("Bold (⌘B) — applies to the selected text")

                    Toggle(isOn: Binding(
                        get: { appState.stampFormatter.isItalic },
                        set: { _ in appState.stampFormatter.toggleItalic() }
                    )) {
                        Image(systemName: "italic")
                    }
                    .toggleStyle(.button)
                    .help("Italic (⌘I) — applies to the selected text")

                    Divider()
                        .frame(height: 16)

                    // Alignment of the stamp's own lines. Explicit rather than inferred from
                    // where the stamp sits, so dragging it doesn't re-flow the text.
                    Picker("", selection: binding.alignment) {
                        ForEach(StampTextAlignment.allCases) { option in
                            Image(systemName: option.symbolName)
                                .help(option.label)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("How the stamp’s lines line up with each other")
                }

                HStack {
                    Text("Size")
                    Stepper(value: Binding(
                        get: { stamp.fontSize },
                        set: { newValue in
                            draft?.fontSize = newValue
                            appState.stampFormatter.apply(fontSize: newValue)
                        }
                    ), in: 6...48, step: 1) {
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
            VStack(alignment: .leading, spacing: 8) {
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

                HStack {
                    Text("Margin")
                    Stepper(value: binding.margin, in: 0...144, step: 2) {
                        Text("\(Int(stamp.margin)) pt")
                            .monospacedDigit()
                    }
                }
                Text("Minimum gap from the page edge; also limits dragging.")
                    .font(.caption)
                    .foregroundColor(.secondary)
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

            if items.isEmpty {
                Text(previewCaption)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 12)
            } else {
                pageNavigationBar
                    .padding(.horizontal, 12)
            }

            Divider()

            filesSection
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewCaption: String {
        "Blank A4 page — drag the stamp to move it. Add a PDF below to preview on a real page."
    }

    /// Page/file navigation over the queued files, laid out like the Split and Rotate tabs:
    /// jump-to-end and step buttons flanking the position label.
    private var pageNavigationBar: some View {
        HStack(spacing: 6) {
            Button(action: firstPage) { Image(systemName: "chevron.backward.to.line") }
                .disabled(!canGoBack)
                .help("First page (⌘←)")
            Button(action: previousPage) { Image(systemName: "chevron.left") }
                .disabled(!canGoBack)
                .help("Previous page (←)")

            Spacer()

            VStack(spacing: 1) {
                Text(items.count > 1
                     ? "Page \(pageIndex + 1) of \(pageCount) — file \(fileIndex + 1) of \(items.count)"
                     : "Page \(pageIndex + 1) of \(pageCount)")
                    .font(.callout)
                    .monospacedDigit()
                // In first-page mode the stamp is still drawn on later pages (so it can be
                // positioned from any of them), but say plainly that they won't get one.
                if pageWillBeStamped {
                    Text(currentFileName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("This page won’t be stamped — only page 1 of each file")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button(action: nextPage) { Image(systemName: "chevron.right") }
                .disabled(!canGoForward)
                .help("Next page (→)")
            Button(action: lastPage) { Image(systemName: "chevron.forward.to.line") }
                .disabled(!canGoForward)
                .help("Last page (⌘→)")
        }
    }

    // MARK: - Preview navigation

    private var pageCount: Int { previewDocument?.pageCount ?? 0 }
    /// Whether the page on screen is one the current scope would actually stamp.
    private var pageWillBeStamped: Bool { scope == .everyPage || pageIndex == 0 }
    private var currentFileName: String { previewFileURL?.lastPathComponent ?? "" }
    /// The file the preview is currently on — also what "Show in Finder" reveals.
    private var previewFileURL: URL? {
        items.indices.contains(fileIndex) ? items[fileIndex].url : nil
    }
    /// Navigation runs over the whole queue, so the ends are the first page of the first file
    /// and the last page of the last.
    private var canGoBack: Bool { pageIndex > 0 || fileIndex > 0 }
    private var canGoForward: Bool { pageIndex < pageCount - 1 || fileIndex < items.count - 1 }

    private func previousPage() {
        if pageIndex > 0 {
            pageIndex -= 1
        } else if fileIndex > 0 {
            // Step back into the previous file, landing on its last page.
            fileIndex -= 1
            loadPreviewDocument()
            pageIndex = max(0, pageCount - 1)
        }
        refreshPreviewPage()
    }

    private func nextPage() {
        if pageIndex < pageCount - 1 {
            pageIndex += 1
        } else if fileIndex < items.count - 1 {
            fileIndex += 1
            pageIndex = 0
            loadPreviewDocument()
        }
        refreshPreviewPage()
    }

    private func firstPage() {
        fileIndex = 0
        pageIndex = 0
        loadPreviewDocument()
        refreshPreviewPage()
    }

    private func lastPage() {
        fileIndex = max(0, items.count - 1)
        loadPreviewDocument()
        pageIndex = max(0, pageCount - 1)
        refreshPreviewPage()
    }

    private func previousFile() {
        guard fileIndex > 0 else { return }
        fileIndex -= 1
        pageIndex = 0
        loadPreviewDocument()
        refreshPreviewPage()
    }

    private func nextFile() {
        guard fileIndex < items.count - 1 else { return }
        fileIndex += 1
        pageIndex = 0
        loadPreviewDocument()
        refreshPreviewPage()
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
                    .overlay(Text("Drop PDFs or a folder here")
                        .font(.callout).foregroundColor(.secondary))
            } else {
                fileList
            }

            // Side by side when there's room, stacked when there isn't — the window can be
            // narrower than the two radio groups plus the button.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    scopePicker
                    Spacer(minLength: 12)
                    outputPicker
                    Spacer(minLength: 12)
                    stampButton
                }

                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        scopePicker
                        outputPicker
                    }
                    Spacer(minLength: 8)
                    stampButton
                }
            }

            if let problem = nameProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .help("Each file is one part, so “first page of each part” stamps page 1 only.")
    }

    private var scopePicker: some View {
        Picker("Stamp on", selection: $scope) {
            ForEach(StampScope.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.radioGroup)
        .fixedSize()
    }

    private var outputPicker: some View {
        Picker("Output", selection: $outputMode) {
            ForEach(StampOutputMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.radioGroup)
        .fixedSize()
    }

    private var stampButton: some View {
        Button(outputMode == .replaceOriginal ? "Stamp Files" : "Stamp Files\u{2026}") {
            stampFiles()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        // Without fixedSize the Spacers take all the slack and squeeze the button to a sliver.
        .fixedSize()
        .disabled(!canStamp)
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
            set: { newValue in
                let colour = NSColor(newValue)
                draft?.colourHex = hexString(from: colour)
                appState.stampFormatter.apply(colour: colour)
            }
        )
    }

    /// Loads the document for `fileIndex`, unless it's already loaded. Retained in
    /// `previewDocument` because a `PDFPage` can't be drawn once its document is released.
    private func loadPreviewDocument() {
        guard items.indices.contains(fileIndex) else {
            previewDocument = nil
            previewPage = nil
            return
        }
        let url = items[fileIndex].url
        guard url != previewDocument?.documentURL else { return }
        previewDocument = PDFDocument(url: url)
    }

    /// Points `previewPage` at the current file/page. Cached rather than computed per redraw —
    /// reading the PDF off disk on every frame made dragging the stamp crawl.
    private func refreshPreviewPage() {
        loadPreviewDocument()
        guard let doc = previewDocument, doc.pageCount > 0 else {
            previewPage = nil
            return
        }
        pageIndex = min(max(pageIndex, 0), doc.pageCount - 1)
        previewPage = doc.page(at: pageIndex)
    }

    /// Keeps the preview pointing somewhere valid after the queue changes (files added,
    /// removed, or cleared).
    private func clampPreviewPosition() {
        guard !items.isEmpty else {
            fileIndex = 0
            pageIndex = 0
            previewDocument = nil
            previewPage = nil
            return
        }
        if !items.indices.contains(fileIndex) {
            fileIndex = min(fileIndex, items.count - 1)
            pageIndex = 0
        }
        refreshPreviewPage()
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
        // ⌘N and ⌘D are free app-wide (File ▸ New is replaced by "Add Files…" on ⌘O), and
        // these rows only exist while Stamp is the active tab, so they can't fire elsewhere.
        slice.tabActions = [
            MenuAction(title: "New Stamp", key: KeyEquivalent("n"), perform: { addStamp() }),
            MenuAction(title: "Duplicate Stamp", key: KeyEquivalent("d"),
                       isEnabled: stampStore.selectedStampId != nil,
                       perform: { duplicateStamp() }),
            MenuAction(title: "Delete Stamp", isEnabled: stampStore.stamps.count > 1,
                       perform: { deleteStamp() }),
            // Page nav stays bare-key (← →) like the other tabs; these rows exist for
            // discoverability, without shortcuts that would fire app-wide.
            MenuAction(title: "Previous Page", isEnabled: canGoBack, perform: { previousPage() }),
            MenuAction(title: "Next Page", isEnabled: canGoForward, perform: { nextPage() }),
            MenuAction(title: "Show in Finder", key: KeyEquivalent("f"), modifiers: [.command, .shift],
                       isEnabled: items.indices.contains(fileIndex),
                       perform: { revealInFinder(previewFileURL) }),
        ]
        appState.tabCommands.slice = slice
    }

    // MARK: - Batch stamping

    /// Queues PDFs, expanding any dropped/chosen folders (recursively, name-sorted) the same
    /// way the Combine tab and the Renamer do. Duplicates are ignored, so re-dropping a
    /// folder doesn't double the queue.
    private func addInput(_ urls: [URL]) {
        let pdfs = expandToFiles(urls, extensions: ["pdf"])
        guard !pdfs.isEmpty else {
            showNSAlert(title: "No PDFs Found",
                        message: urls.contains(where: urlIsDirectory)
                            ? "That folder doesn’t contain any PDFs."
                            : "The Stamp tab works on PDFs. The dropped item(s) weren’t PDFs.",
                        isError: true)
            return
        }
        for url in pdfs where !items.contains(where: { $0.url == url }) {
            items.append(StampFileItem(url: url))
        }
        // Take focus so the arrow keys page through straight away — unless the user is
        // mid-sentence in the stamp text, in which case leave them alone.
        if !(NSApp.keyWindow?.firstResponder is NSTextView) {
            isViewFocused = true
        }
    }

    /// Accepts a drop anywhere in the tab, not just on the drop zone.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        collectDroppedFileURLs(from: providers) { urls in
            guard !urls.isEmpty else { return }
            addInput(urls)
        }
        return true
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        // Folders are allowed here too, matching the drop behaviour.
        panel.canChooseDirectories = true
        panel.title = "Select PDFs or a Folder to Stamp"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            DispatchQueue.main.async { addInput(urls) }
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

// MARK: - Font family picker

/// The font popup, extracted and `Equatable` so SwiftUI can skip it.
///
/// It holds ~300 rows, and rebuilding them on every keystroke elsewhere in the tab was the
/// main reason typing felt sluggish. Gated on the family alone, it's rebuilt only when the
/// font actually changes.
private struct FontFamilyPicker: View, Equatable {
    let family: String
    let onChange: (String) -> Void

    /// Enumerated once per launch — `availableFontFamilies` is not cheap.
    private static let families: [String] = NSFontManager.shared.availableFontFamilies.sorted()

    static func == (lhs: FontFamilyPicker, rhs: FontFamilyPicker) -> Bool {
        lhs.family == rhs.family
    }

    var body: some View {
        Picker("Font", selection: Binding(get: { family }, set: onChange)) {
            ForEach(options, id: \.self) { family in
                Text(family).tag(family)
            }
        }
    }

    /// Keeps the saved family in the list even if it isn't installed on this Mac, so the
    /// picker never appears blank.
    private var options: [String] {
        Self.families.contains(family) ? Self.families : [family] + Self.families
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
