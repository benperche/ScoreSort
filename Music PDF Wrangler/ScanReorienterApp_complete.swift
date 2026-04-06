//
//  MusicPDFManager.swift
//  Music PDF Manager
//
//  A macOS app for managing music PDFs:
//  - Renaming sheet music files with sequential prefixes
//  - Splitting PDFs into separate files
//  - Rotating odd or even pages in PDF files
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import Combine

// MARK: - App State
class AppState: ObservableObject {
    @Published var selectedTab = 0
    @Published var showingKeyboardHelp = false
    let combineMenuState = CombineMenuState()
}

// MARK: - Combine Menu State
// Shared object observed by CombinerCommands. Updated from CombineView via
// .onChange/.onAppear (after body completes) to avoid mid-update publishing.
class CombineMenuState: ObservableObject {
    @Published var canRemove  = false
    @Published var canMoveUp  = false
    @Published var canMoveDown = false
    @Published var hasFiles   = false

    var removeSelected:          () -> Void = {}
    var moveUp:                  () -> Void = {}
    var moveDown:                () -> Void = {}
    var selectAll:               () -> Void = {}
    var selectPrevious:          () -> Void = {}
    var selectNext:              () -> Void = {}
    var selectPreviousExtending: () -> Void = {}
    var selectNextExtending:     () -> Void = {}
}

// MARK: - Navigate Commands (tab switching — separate struct avoids double View menu)
struct NavigateCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("Combine PDFs") { appState.selectedTab = 0 }
                .keyboardShortcut("1", modifiers: .command)
            Button("Rename Files") { appState.selectedTab = 1 }
                .keyboardShortcut("2", modifiers: .command)
            Button("Split PDF") { appState.selectedTab = 2 }
                .keyboardShortcut("3", modifiers: .command)
            Button("Rotate Pages") { appState.selectedTab = 3 }
                .keyboardShortcut("4", modifiers: .command)
        }
    }
}

// MARK: - Combiner Commands (file list shortcuts — active whenever the window is frontmost)
struct CombinerCommands: Commands {
    @ObservedObject var state: CombineMenuState

    var body: some Commands {
        CommandMenu("Combiner") {
            Button("Select Previous") { state.selectPrevious() }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(!state.hasFiles)

            Button("Extend Selection Up") { state.selectPreviousExtending() }
                .keyboardShortcut(.upArrow, modifiers: .shift)
                .disabled(!state.hasFiles)

            Button("Select Next") { state.selectNext() }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(!state.hasFiles)

            Button("Extend Selection Down") { state.selectNextExtending() }
                .keyboardShortcut(.downArrow, modifiers: .shift)
                .disabled(!state.hasFiles)

            Divider()

            Button("Move Up") { state.moveUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!state.canMoveUp)

            Button("Move Down") { state.moveDown() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!state.canMoveDown)

            Divider()

            Button("Remove Selected Files") { state.removeSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!state.canRemove)

            Divider()

            Button("Select All Files") { state.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!state.hasFiles)
        }
    }
}

// MARK: - Help Commands
struct HelpCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts\u{2026}") {
                appState.showingKeyboardHelp = true
            }
            .keyboardShortcut("`", modifiers: .command)
        }
    }
}

// MARK: - Main App
@main
struct MusicPDFManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            NavigateCommands(appState: appState)
            CombinerCommands(state: appState.combineMenuState)
            HelpCommands(appState: appState)
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        InstrumentOrders.setup()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    
    var body: some View {
        TabView(selection: $appState.selectedTab) {
            CombineView(showingKeyboardHelp: $appState.showingKeyboardHelp,
                        menuState: appState.combineMenuState)
                .tabItem {
                    Label("Combine PDFs", systemImage: "doc.on.doc")
                }
                .tag(0)
            
            RenamerView()
                .tabItem {
                    Label("Rename Files", systemImage: "folder.badge.gearshape")
                }
                .tag(1)
            
            SplitView()
                .tabItem {
                    Label("Split PDF", systemImage: "scissors")
                }
                .tag(2)
            
            RotateView()
                .tabItem {
                    Label("Rotate Pages", systemImage: "rotate.right")
                }
                .tag(3)
        }
        .frame(minWidth: 900, minHeight: 700)
        .sheet(isPresented: $appState.showingKeyboardHelp) {
            ShortcutsHelpView()
        }
    }
}

// MARK: - Combine View
struct CombineView: View {
    @Binding var showingKeyboardHelp: Bool
    let menuState: CombineMenuState
    @StateObject private var combineManager = CombineManager()
    @State private var addBlankPages = false
    @State private var isTargeted = false
    @State private var selectedFiles: Set<UUID> = []
    @State private var removalNoticeVisible = false
    @State private var removalNoticeCount = 1
    @State private var focusedFileId: UUID?     // keyboard navigation cursor
    @State private var anchorFileId: UUID?      // anchor for shift-range selection
    @FocusState private var listFocused: Bool
    @Environment(\.undoManager) var undoManager
    
    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack {
                Text("Combine PDFs")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Button(action: { showingKeyboardHelp = true }) {
                    Image(systemName: "keyboard")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Keyboard Shortcuts")

                if !combineManager.files.isEmpty {
                    Button(action: { combineManager.clearAll(undoManager: undoManager) }) {
                        Label("Clear All", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Main content area
            if combineManager.files.isEmpty {
                // Empty state - drop zone
                emptyStateView
            } else {
                // File list
                VStack(spacing: 0) {
                    // Control buttons
                    HStack {
                        Button(action: selectFiles) {
                            Label("Add Files", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: removeSelected) {
                            Label("Remove", systemImage: "minus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedFiles.isEmpty)
                        
                        Divider()
                            .frame(height: 20)
                        
                        Button(action: moveUp) {
                            Label("Move Up", systemImage: "arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canMoveUp)
                        
                        Button(action: moveDown) {
                            Label("Move Down", systemImage: "arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canMoveDown)
                        
                        Divider()
                            .frame(height: 20)
                        
                        Button(action: selectAll) {
                            Text("Select All")
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: selectNone) {
                            Text("Select None")
                        }
                        .buttonStyle(.bordered)
                        
                        Spacer()
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    
                    Divider()
                    
                    // Column headers
                    HStack {
                        Text("Name")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.headline)
                        
                        Text("Pages")
                            .frame(width: 80, alignment: .center)
                            .font(.headline)
                        
                        Text("# Copies")
                            .frame(width: 100, alignment: .center)
                            .font(.headline)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.controlBackgroundColor))
                    
                    Divider()
                    
                    // File list — focusable so arrow-key navigation works after a click
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(combineManager.files) { file in
                                CombineFileRow(
                                    file: file,
                                    isSelected: selectedFiles.contains(file.id),
                                    isFocused: focusedFileId == file.id,
                                    onToggleSelect: { toggleSelection(file.id) },
                                    onCopiesChanged: { newValue in
                                        combineManager.updateCopies(for: file.id, copies: newValue, undoManager: undoManager)
                                    },
                                    onRemove: {
                                        selectedFiles.remove(file.id)
                                        combineManager.removeFiles(ids: [file.id], undoManager: undoManager)
                                        showRemovalNotice(undoManager: undoManager)
                                    }
                                )
                                Divider()
                            }
                        }
                    }
                    .focusable()
                    .focused($listFocused)
                    .onKeyPress { press in
                        let isShift = press.modifiers.contains(.shift)
                        switch press.key {
                        case .upArrow:
                            navigateSelection(direction: -1, extending: isShift)
                            return .handled
                        case .downArrow:
                            navigateSelection(direction: 1, extending: isShift)
                            return .handled
                        default:
                            return .ignored
                        }
                    }
                    
                    Divider()
                    
                    // Bottom controls
                    VStack(spacing: 12) {
                        // Removal notice (shown briefly when minus removes a file)
                        if removalNoticeVisible {
                            HStack(spacing: 8) {
                                Image(systemName: "trash")
                                    .foregroundColor(.secondary)
                                Text(removalNoticeCount == 1 ? "File removed" : "\(removalNoticeCount) files removed")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Undo") {
                                    undoManager?.undo()
                                    removalNoticeVisible = false
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(NSColor.controlBackgroundColor))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(Color.secondary.opacity(0.2))
                                    )
                            )
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        Toggle("For double-sided printing: add blank page after files with an odd number of pages", isOn: $addBlankPages)
                            .toggleStyle(.checkbox)
                        
                        HStack {
                            Text("\(combineManager.totalFiles) file(s) • \(combineManager.totalPages) total page(s)")
                                .font(.callout)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button(action: openInPreview) {
                                Label("Open in Preview", systemImage: "doc.text.magnifyingglass")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            
                            Button(action: createPDF) {
                                Label("Create PDF", systemImage: "arrow.down.doc")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        // Wire closures once on appear; update flags after every relevant state change.
        // Using onAppear/onChange (post-body) avoids the "publishing during view update" warning
        // that .focusedValue triggered.
        .onAppear { syncMenuClosures() }
        .onChange(of: selectedFiles)          { _ in syncMenuFlags() }
        .onChange(of: combineManager.files)   { _ in syncMenuFlags() }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 64))
                .foregroundColor(isTargeted ? .accentColor : .secondary)
            
            Text("Drop PDF files here to combine")
                .font(.title2)
                .fontWeight(.medium)
            
            Text("or")
                .foregroundColor(.secondary)
            
            Button(action: selectFiles) {
                Label("Choose Files", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.gray.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [10])
                )
                .padding()
        )
    }
    
    private var canMoveUp: Bool {
        guard !selectedFiles.isEmpty else { return false }
        // Enabled if at least one selected item can actually shift up —
        // i.e. it's not at index 0, and the item above it is not also selected
        // (which would make them a pinned block).
        return combineManager.files.indices.contains { index in
            guard selectedFiles.contains(combineManager.files[index].id) else { return false }
            guard index > 0 else { return false }
            return !selectedFiles.contains(combineManager.files[index - 1].id)
        }
    }

    private var canMoveDown: Bool {
        guard !selectedFiles.isEmpty else { return false }
        return combineManager.files.indices.contains { index in
            guard selectedFiles.contains(combineManager.files[index].id) else { return false }
            guard index < combineManager.files.count - 1 else { return false }
            return !selectedFiles.contains(combineManager.files[index + 1].id)
        }
    }
    
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.title = "Select PDF Files"
        
        panel.begin { response in
            if response == .OK {
                combineManager.addFiles(urls: panel.urls, undoManager: undoManager)
            }
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url, url.pathExtension.lowercased() == "pdf" {
                    DispatchQueue.main.async {
                        combineManager.addFiles(urls: [url], undoManager: undoManager)
                    }
                }
            }
        }
    }
    
    private func toggleSelection(_ id: UUID) {
        if selectedFiles.contains(id) {
            selectedFiles.remove(id)
            if focusedFileId == id { focusedFileId = nil; anchorFileId = nil }
        } else {
            selectedFiles.insert(id)
            focusedFileId = id
            anchorFileId = id
        }
        listFocused = true  // pull keyboard focus to the list after a click
    }

    private func selectAll() {
        selectedFiles = Set(combineManager.files.map { $0.id })
        anchorFileId = combineManager.files.first?.id
        focusedFileId = combineManager.files.last?.id
    }

    private func selectNone() {
        selectedFiles.removeAll()
        focusedFileId = nil
        anchorFileId = nil
    }

    private func removeSelected() {
        guard !selectedFiles.isEmpty else { return }
        let count = selectedFiles.count
        combineManager.removeFiles(ids: selectedFiles, undoManager: undoManager)
        selectedFiles.removeAll()
        focusedFileId = nil
        anchorFileId = nil
        showRemovalNotice(count: count, undoManager: undoManager)
    }

    /// Keyboard navigation: moves the cursor by `direction` (±1), extending the
    /// selection from the anchor when `extending` is true (Shift held).
    private func navigateSelection(direction: Int, extending: Bool) {
        let files = combineManager.files
        guard !files.isEmpty else { return }

        let currentIndex: Int
        if let id = focusedFileId, let idx = files.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
        } else {
            // No cursor yet — start from the logical edge
            currentIndex = direction > 0 ? -1 : files.count
        }

        let newIndex = max(0, min(files.count - 1, currentIndex + direction))
        let newId = files[newIndex].id
        focusedFileId = newId

        if extending {
            // Extend selection from anchor to cursor
            let anchorIndex = anchorFileId.flatMap { id in
                files.firstIndex(where: { $0.id == id })
            } ?? newIndex
            let lo = min(anchorIndex, newIndex)
            let hi = max(anchorIndex, newIndex)
            selectedFiles = Set(files[lo...hi].map { $0.id })
        } else {
            anchorFileId = newId
            selectedFiles = [newId]
        }
    }

    private func moveUp() {
        combineManager.moveUp(ids: selectedFiles, undoManager: undoManager)
    }

    private func moveDown() {
        combineManager.moveDown(ids: selectedFiles, undoManager: undoManager)
    }

    private func showRemovalNotice(count: Int = 1, undoManager: UndoManager?) {
        removalNoticeCount = count
        withAnimation(.easeInOut(duration: 0.2)) { removalNoticeVisible = true }
        // Auto-dismiss after 5 s; pressing Undo dismisses it immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            withAnimation(.easeInOut(duration: 0.2)) { removalNoticeVisible = false }
        }
    }
    
    private func createPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Combined.pdf"
        panel.title = "Save Combined PDF"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                combineManager.createCombinedPDF(to: url, addBlankPages: addBlankPages)
            }
        }
    }
    
    private func openInPreview() {
        combineManager.openInPreview(addBlankPages: addBlankPages)
    }

    // MARK: - Menu state sync
    private func syncMenuClosures() {
        menuState.removeSelected          = removeSelected
        menuState.moveUp                  = moveUp
        menuState.moveDown                = moveDown
        menuState.selectAll               = selectAll
        menuState.selectPrevious          = { navigateSelection(direction: -1, extending: false) }
        menuState.selectNext              = { navigateSelection(direction:  1, extending: false) }
        menuState.selectPreviousExtending = { navigateSelection(direction: -1, extending: true)  }
        menuState.selectNextExtending     = { navigateSelection(direction:  1, extending: true)  }
        syncMenuFlags()
    }

    private func syncMenuFlags() {
        menuState.canRemove  = !selectedFiles.isEmpty
        menuState.canMoveUp  = canMoveUp
        menuState.canMoveDown = canMoveDown
        menuState.hasFiles   = !combineManager.files.isEmpty
    }
}

// MARK: - Combine File Row
struct CombineFileRow: View {
    let file: CombineFile
    let isSelected: Bool
    let isFocused: Bool
    let onToggleSelect: () -> Void
    let onCopiesChanged: (Int) -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundColor(isSelected ? .accentColor : .secondary)
            
            Text(file.name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Text("\(file.pageCount)")
                .frame(width: 80, alignment: .center)
                .foregroundColor(.secondary)
            
            HStack(spacing: 4) {
                Button(action: {
                    if file.copies > 1 {
                        onCopiesChanged(file.copies - 1)
                    } else {
                        onRemove()
                    }
                }) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                
                Text("\(file.copies)")
                    .frame(width: 40, alignment: .center)
                    .font(.system(.body, design: .monospaced))
                
                Button(action: {
                    onCopiesChanged(file.copies + 1)
                }) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
            }
            .frame(width: 100, alignment: .center)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(
            isSelected
                ? Color.accentColor.opacity(isFocused ? 0.18 : 0.1)
                : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onToggleSelect()
        }
    }
}


// MARK: - Keyboard Shortcuts Help
struct ShortcutsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Keyboard Shortcuts")
                .font(.title2)
                .fontWeight(.semibold)

            shortcutSection("File List Navigation") {
                shortcutRow("↑ / ↓", "Select previous / next file")
                shortcutRow("⇧↑ / ⇧↓", "Extend selection up / down")
                shortcutRow("⌘A", "Select all files")
            }

            shortcutSection("File Management") {
                shortcutRow("⌫", "Remove selected files")
                shortcutRow("⌘↑", "Move selected files up")
                shortcutRow("⌘↓", "Move selected files down")
                shortcutRow("⌘Z", "Undo")
                shortcutRow("⌘⇧Z", "Redo")
            }

            shortcutSection("Tabs") {
                shortcutRow("⌘1", "Combine PDFs")
                shortcutRow("⌘2", "Rename Files")
                shortcutRow("⌘3", "Split PDF")
                shortcutRow("⌘4", "Rotate Pages")
            }

            shortcutSection("Split PDF & Rotate Pages") {
                shortcutRow("← / →", "Previous / next page")
                shortcutRow("⌘← / ⌘→", "First / last page")
                shortcutRow("Space", "Toggle split marker (Split tab)")
            }

            shortcutSection("Renamer") {
                shortcutRow("⌘,", "Open Preferences")
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(36)
        .frame(width: 460, height: 660)
    }

    private func shortcutSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            content()
        }
    }

    private func shortcutRow(_ shortcut: String, _ description: String) -> some View {
        HStack {
            Text(shortcut)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(description)
        }
        .padding(.leading, 8)
    }
}

// MARK: - Combine File Model
struct CombineFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let name: String
    let pageCount: Int
    var copies: Int
}

// MARK: - Combine Manager
class CombineManager: ObservableObject {
    @Published var files: [CombineFile] = []

    var totalFiles: Int { files.reduce(0) { $0 + $1.copies } }
    var totalPages: Int { files.reduce(0) { $0 + ($1.pageCount * $1.copies) } }

    // Snapshot-based undo: captures the post-action state so the undo handler
    // can register a redo by snapshotting back the other way.
    private func registerUndo(undoManager: UndoManager?, actionName: String, restoring snapshot: [CombineFile]) {
        let postActionState = files
        undoManager?.setActionName(actionName)
        undoManager?.registerUndo(withTarget: self) { manager in
            manager.files = snapshot
            manager.registerUndo(undoManager: undoManager, actionName: actionName, restoring: postActionState)
        }
    }

    func addFiles(urls: [URL], undoManager: UndoManager?) {
        let before = files
        for url in urls {
            guard let document = PDFDocument(url: url) else { continue }
            files.append(CombineFile(url: url, name: url.lastPathComponent, pageCount: document.pageCount, copies: 1))
        }
        if files.count != before.count {
            registerUndo(undoManager: undoManager, actionName: "Add Files", restoring: before)
        }
    }

    func removeFiles(ids: Set<UUID>, undoManager: UndoManager?) {
        let before = files
        files.removeAll { ids.contains($0.id) }
        registerUndo(undoManager: undoManager, actionName: "Remove File", restoring: before)
    }

    func clearAll(undoManager: UndoManager?) {
        let before = files
        files.removeAll()
        registerUndo(undoManager: undoManager, actionName: "Clear All", restoring: before)
    }

    func updateCopies(for id: UUID, copies: Int, undoManager: UndoManager?) {
        let before = files
        if let index = files.firstIndex(where: { $0.id == id }) {
            files[index].copies = max(1, copies)
        }
        registerUndo(undoManager: undoManager, actionName: "Change Copies", restoring: before)
    }

    func moveUp(ids: Set<UUID>, undoManager: UndoManager?) {
        let before = files
        // Process ascending (lowest index first) so adjacent selected items
        // move as a block rather than passing through each other.
        let selectedIndices = files.indices
            .filter { ids.contains(files[$0].id) }
            .sorted()
        for index in selectedIndices {
            guard index > 0 else { continue }
            guard !ids.contains(files[index - 1].id) else { continue }
            files.swapAt(index, index - 1)
        }
        if files.map(\.id) != before.map(\.id) {
            registerUndo(undoManager: undoManager, actionName: "Move Up", restoring: before)
        }
    }

    func moveDown(ids: Set<UUID>, undoManager: UndoManager?) {
        let before = files
        // Process descending (highest index first) for the same block-preservation reason.
        let selectedIndices = files.indices
            .filter { ids.contains(files[$0].id) }
            .sorted()
            .reversed()
        for index in selectedIndices {
            guard index < files.count - 1 else { continue }
            guard !ids.contains(files[index + 1].id) else { continue }
            files.swapAt(index, index + 1)
        }
        if files.map(\.id) != before.map(\.id) {
            registerUndo(undoManager: undoManager, actionName: "Move Down", restoring: before)
        }
    }
    
    func createCombinedPDF(to url: URL, addBlankPages: Bool) {
        let combinedDocument = PDFDocument()
        var currentPageIndex = 0
        
        for file in files {
            guard let sourceDocument = PDFDocument(url: file.url) else { continue }
            
            for _ in 0..<file.copies {
                // Add all pages from this document
                for pageIndex in 0..<sourceDocument.pageCount {
                    if let page = sourceDocument.page(at: pageIndex) {
                        combinedDocument.insert(page, at: currentPageIndex)
                        currentPageIndex += 1
                    }
                }
                
                // Add blank page if needed (odd page count and blank pages enabled)
                if addBlankPages && sourceDocument.pageCount % 2 == 1 {
                    if let blankPage = createBlankPage() {
                        combinedDocument.insert(blankPage, at: currentPageIndex)
                        currentPageIndex += 1
                    }
                }
            }
        }
        
        if combinedDocument.write(to: url) {
            let alert = NSAlert()
            alert.messageText = "PDF Created Successfully"
            alert.informativeText = "Combined PDF with \(currentPageIndex) pages saved to:\n\(url.path)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else {
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = "Failed to create PDF"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    func openInPreview(addBlankPages: Bool) {
        let combinedDocument = PDFDocument()
        var currentPageIndex = 0
        
        for file in files {
            guard let sourceDocument = PDFDocument(url: file.url) else { continue }
            
            for _ in 0..<file.copies {
                // Add all pages from this document
                for pageIndex in 0..<sourceDocument.pageCount {
                    if let page = sourceDocument.page(at: pageIndex) {
                        combinedDocument.insert(page, at: currentPageIndex)
                        currentPageIndex += 1
                    }
                }
                
                // Add blank page if needed
                if addBlankPages && sourceDocument.pageCount % 2 == 1 {
                    if let blankPage = createBlankPage() {
                        combinedDocument.insert(blankPage, at: currentPageIndex)
                        currentPageIndex += 1
                    }
                }
            }
        }
        
        // Save to temporary file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("CombinedForPrint.pdf")
        
        guard combinedDocument.write(to: tempURL) else {
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = "Failed to create temporary PDF"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        
        // Open in Preview
        NSWorkspace.shared.open(tempURL)
    }
    
    private func createBlankPage() -> PDFPage? {
        // Create a blank Letter-size page
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // 8.5" x 11" at 72 DPI
        let blankPage = PDFPage()
        blankPage.setBounds(pageRect, for: .mediaBox)
        return blankPage
    }
}

// MARK: - Renamer View
struct RenamerView: View {
    @StateObject private var renamerManager = RenamerManager()
    @State private var showingPreferences = false
    @State private var selectedFileForAssignment: RenameOperation?
    @State private var isFolderTargeted = false
    @State private var sortColumn: SortColumn = .newName
    @State private var sortAscending = true
    
    enum SortColumn {
        case originalName
        case newName
        case status
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack {
                Text("Sheet Music Renamer")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if renamerManager.folderURL != nil {
                    Button(action: { renamerManager.rescanFolder() }) {
                        Label("Check for Errors", systemImage: "checkmark.circle")
                    }
                    .help("Rescan all files and suggest corrections")
                    
                    Button(action: { showingPreferences = true }) {
                        Label("Preferences", systemImage: "gearshape")
                    }
                    
                    Button(action: { renamerManager.clearFolder() }) {
                        Label("Clear", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Main content area
            if renamerManager.folderURL != nil {
                VStack(spacing: 0) {
                    // File list
                    fileListView
                    
                    Divider()
                    
                    // Bottom controls
                    bottomControlsView
                }
            } else {
                // Folder selection
                folderSelectionView
            }
        }
        .sheet(isPresented: $showingPreferences) {
            PreferencesView(
                ensembleType: $renamerManager.ensembleType,
                instrumentOrder: $renamerManager.customInstrumentOrder
            )
        }
        .sheet(item: $selectedFileForAssignment) { operation in
            ManualAssignmentView(
                operation: operation,
                existingNumbers: renamerManager.getExistingNumbers(),
                onAssign: { number in
                    renamerManager.setManualOverride(for: operation.originalName, number: number)
                    selectedFileForAssignment = nil
                }
            )
        }
        .onAppear {
            // Workaround for SwiftUI sheet initialization bug
            // This "warms up" the sheet system so the first popup renders correctly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Just accessing the sheet system is enough
                _ = showingPreferences
            }
        }
        // ⌘, always opens preferences regardless of whether a folder is loaded
        .background(
            Button("") { showingPreferences = true }
                .keyboardShortcut(",", modifiers: .command)
                .hidden()
        )
    }
    
    private var folderSelectionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 64))
                .foregroundColor(isFolderTargeted ? .accentColor : .secondary)
            
            Text("Select a Folder with PDF Files")
                .font(.title2)
                .fontWeight(.medium)
            
            Text("This tool will add sequential prefixes to your sheet music files\nbased on detected instrument names")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Text("Drag a folder here")
                .font(.callout)
                .foregroundColor(isFolderTargeted ? .accentColor : .secondary)
            
            Text("or")
                .foregroundColor(.secondary)
            
            Button(action: selectFolder) {
                Label("Choose Folder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            // Ensemble type selector
            VStack(alignment: .leading, spacing: 8) {
                Text("Ensemble Type:")
                    .font(.headline)
                
                Picker("Ensemble Type", selection: $renamerManager.ensembleType) {
                    Text("Wind Band").tag(EnsembleType.band)
                    Text("Jazz Band").tag(EnsembleType.jazz)
                    Text("Orchestra").tag(EnsembleType.orchestra)
                }
                .pickerStyle(.segmented)
                .frame(width: 400)
            }
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isFolderTargeted ? Color.accentColor : Color.gray.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [10])
                )
                .padding()
        )
        .onDrop(of: [.fileURL], isTargeted: $isFolderTargeted) { providers in
            guard let provider = providers.first else { return false }
            
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                       isDirectory.boolValue {
                        DispatchQueue.main.async {
                            renamerManager.loadFolder(url: url)
                        }
                    }
                }
            }
            
            return true
        }
    }
    
    private var fileListView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { sortBy(.originalName) }) {
                    HStack(spacing: 4) {
                        Text("Original Filename")
                            .font(.headline)
                        if sortColumn == .originalName {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                
                Button(action: { sortBy(.newName) }) {
                    HStack(spacing: 4) {
                        Text("New Filename")
                            .font(.headline)
                        if sortColumn == .newName {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                
                Button(action: { sortBy(.status) }) {
                    HStack(spacing: 4) {
                        Text("Status")
                            .font(.headline)
                        if sortColumn == .status {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.caption)
                        }
                    }
                    .frame(width: 200, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // File list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sortedOperations) { operation in
                        FileRowView(operation: operation) {
                            selectedFileForAssignment = operation
                        }
                        Divider()
                    }
                }
            }
        }
    }
    
    private var sortedOperations: [RenameOperation] {
        renamerManager.operations.sorted { op1, op2 in
            let result: Bool
            switch sortColumn {
            case .originalName:
                result = op1.originalName.localizedCaseInsensitiveCompare(op2.originalName) == .orderedAscending
            case .newName:
                // Empty new names go to the end
                if op1.newName.isEmpty && !op2.newName.isEmpty {
                    result = false
                } else if !op1.newName.isEmpty && op2.newName.isEmpty {
                    result = true
                } else if op1.newName.isEmpty && op2.newName.isEmpty {
                    result = op1.originalName.localizedCaseInsensitiveCompare(op2.originalName) == .orderedAscending
                } else {
                    result = op1.newName.localizedCaseInsensitiveCompare(op2.newName) == .orderedAscending
                }
            case .status:
                result = op1.statusText.localizedCaseInsensitiveCompare(op2.statusText) == .orderedAscending
            }
            return sortAscending ? result : !result
        }
    }
    
    private func sortBy(_ column: SortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
    }
    
    private var bottomControlsView: some View {
        VStack(spacing: 12) {
            // Status text
            Text(renamerManager.statusText)
                .font(.callout)
                .foregroundColor(.secondary)
            
            // Action button
            HStack {
                Spacer()
                
                Button(action: { renamerManager.executeRename() }) {
                    Label("Rename Files", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(renamerManager.renameCount == 0)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Select Folder with PDF Files"
        panel.message = "Choose a folder containing sheet music PDF files to rename"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                renamerManager.loadFolder(url: url)
            }
        }
    }
}

// MARK: - File Row View
struct FileRowView: View {
    let operation: RenameOperation
    let onDoubleClick: () -> Void
    
    var body: some View {
        HStack {
            Text(operation.originalName)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(operation.color)
            
            Text(operation.newName)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(operation.color)
            
            Text(operation.statusText)
                .frame(width: 200, alignment: .leading)
                .foregroundColor(operation.color)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Allow manual override on any file
            onDoubleClick()
        }
    }
}

// MARK: - Manual Assignment View
struct ManualAssignmentView: View {
    let operation: RenameOperation
    let existingNumbers: [Int]
    let onAssign: (Int) -> Void
    
    @State private var selectedNumber: Int = 1
    @Environment(\.dismiss) private var dismiss
    
    var willShiftOthers: Bool {
        existingNumbers.contains(selectedNumber)
    }
    
    var shiftDescription: String {
        if willShiftOthers {
            let affectedNumbers = existingNumbers.filter { $0 >= selectedNumber }.sorted()
            if affectedNumbers.isEmpty {
                return ""
            }
            let first = affectedNumbers.first!
            let last = affectedNumbers.last!
            if first == last {
                return "File currently numbered \(String(format: "%02d", first)) will become \(String(format: "%02d", first + 1))"
            } else {
                return "Files numbered \(String(format: "%02d", first))-\(String(format: "%02d", last)) will shift to \(String(format: "%02d", first + 1))-\(String(format: "%02d", last + 1))"
            }
        }
        return ""
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            VStack(spacing: 8) {
                Text("Assign Number Manually")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("File: \(operation.originalName)")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                
                Text("This will override any automatic detection")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
            
            Divider()
            
            // Number input section
            VStack(alignment: .leading, spacing: 12) {
                Text("Assign sequential number:")
                    .font(.headline)
                
                HStack(spacing: 12) {
                    TextField("Number", value: $selectedNumber, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    
                    Stepper("", value: $selectedNumber, in: 0...99)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            
            // Info section
            VStack(alignment: .leading, spacing: 8) {
                Text("The file will be prefixed with \(String(format: "%02d", selectedNumber))")
                    .font(.caption)
                    .foregroundColor(.primary)
                
                if willShiftOthers {
                    Text("⚠️ " + shiftDescription)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Spacer()
                .frame(minHeight: 20)
            
            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Assign") {
                    onAssign(selectedNumber)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500, height: 400)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Preferences View
struct PreferencesView: View {
    @Binding var ensembleType: EnsembleType
    @Binding var instrumentOrder: [String]
    
    @State private var editableOrder: [String]
    @State private var newInstrument: String = ""
    @Environment(\.dismiss) private var dismiss
    
    init(ensembleType: Binding<EnsembleType>, instrumentOrder: Binding<[String]>) {
        self._ensembleType = ensembleType
        self._instrumentOrder = instrumentOrder
        self._editableOrder = State(initialValue: instrumentOrder.wrappedValue)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Instrument Order Preferences")
                .font(.title2)
                .fontWeight(.semibold)
            
            // Ensemble type selector
            VStack(alignment: .leading, spacing: 8) {
                Text("Ensemble Type:")
                    .font(.headline)
                
                Picker("Ensemble Type", selection: $ensembleType) {
                    Text("Wind Band").tag(EnsembleType.band)
                    Text("Jazz Band").tag(EnsembleType.jazz)
                    Text("Orchestra").tag(EnsembleType.orchestra)
                }
                .pickerStyle(.segmented)
                .onChange(of: ensembleType) { newType in
                    editableOrder = InstrumentOrders.getOrder(for: newType)
                }
            }
            
            Divider()
            
            // Instrument list
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Instruments (in order):")
                        .font(.headline)
                    
                    Spacer()
                    
                    Button("Reset to Default") {
                        editableOrder = InstrumentOrders.getOrder(for: ensembleType)
                    }
                    .font(.caption)
                }
                
                Text("Files are numbered sequentially based on this order. Drag to reorder.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                List {
                    ForEach(Array(editableOrder.enumerated()), id: \.element) { index, instrument in
                        HStack(spacing: 8) {
                            // Up/down arrows on the left, away from the scrollbar
                            VStack(spacing: 2) {
                                Button(action: {
                                    if index > 0 {
                                        editableOrder.swapAt(index, index - 1)
                                    }
                                }) {
                                    Image(systemName: "chevron.up")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .disabled(index == 0)

                                Button(action: {
                                    if index < editableOrder.count - 1 {
                                        editableOrder.swapAt(index, index + 1)
                                    }
                                }) {
                                    Image(systemName: "chevron.down")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .disabled(index == editableOrder.count - 1)
                            }
                            .padding(.leading, 4)

                            Text("\(index + 1).")
                                .foregroundColor(.secondary)
                                .frame(width: 36, alignment: .trailing)

                            Text(instrument)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button(action: {
                                editableOrder.remove(at: index)
                            }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 4)
                        }
                    }
                    .onMove { source, destination in
                        editableOrder.move(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.bordered)
                .frame(height: 300)
                
                // Add new instrument
                HStack {
                    TextField("Add new instrument...", text: $newInstrument)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addInstrument()
                        }
                    
                    Button(action: addInstrument) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newInstrument.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            
            Spacer()
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Save") {
                    instrumentOrder = editableOrder
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 16)
        }
        .padding(28)
        .frame(width: 650, height: 660)
    }
    
    private func addInstrument() {
        let trimmed = newInstrument.trimmingCharacters(in: .whitespaces).lowercased()
        if !trimmed.isEmpty && !editableOrder.contains(trimmed) {
            editableOrder.append(trimmed)
            newInstrument = ""
        }
    }
}

// MARK: - Renamer Manager
class RenamerManager: ObservableObject {
    @Published var folderURL: URL?
    @Published var operations: [RenameOperation] = []
    @Published var ensembleType: EnsembleType = .band {
        didSet {
            if !hasCustomOrder {
                customInstrumentOrder = InstrumentOrders.getOrder(for: ensembleType)
            }
            if folderURL != nil {
                scanFolder()
            }
        }
    }
    @Published var customInstrumentOrder: [String] = InstrumentOrders.getOrder(for: .band) {
        didSet {
            hasCustomOrder = true
            if folderURL != nil {
                scanFolder()
            }
        }
    }
    
    private var hasCustomOrder = false
    private var manualOverrides: [String: Int] = [:]
    private var isRescanMode = false
    
    var statusText: String {
        let total = operations.count
        let willRename = renameCount
        let willSkip = operations.filter { $0.type == .skip || $0.type == .alreadyPrefixed }.count
        let corrections = operations.filter { $0.type == .correct }.count
        
        if isRescanMode && corrections > 0 {
            return "Found \(total) PDFs: \(corrections) need correction, \(willRename - corrections) will be renamed, \(willSkip) are correct/will be skipped"
        } else {
            return "Found \(total) PDFs: \(willRename) will be renamed, \(willSkip) will be skipped"
        }
    }
    
    var renameCount: Int {
        operations.filter { $0.type == .rename || $0.type == .correct || $0.type == .manual }.count
    }
    
    func loadFolder(url: URL) {
        self.folderURL = url
        self.manualOverrides = [:]
        self.isRescanMode = false
        scanFolder()
    }
    
    func clearFolder() {
        self.folderURL = nil
        self.operations = []
        self.manualOverrides = [:]
        self.isRescanMode = false
    }
    
    func rescanFolder() {
        let alert = NSAlert()
        alert.messageText = "Check for Errors"
        alert.informativeText = "This will check all files (including already numbered ones) and suggest corrections.\n\nFiles will be renumbered sequentially based on instrument detection.\n\nContinue?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            isRescanMode = true
            manualOverrides = [:]
            scanFolder()
        }
    }
    
    func setManualOverride(for filename: String, number: Int) {
        // Build the set of numbers currently in use by everything except this file's
        // existing override (so re-assigning the same file doesn't falsely conflict).
        var takenNumbers = Set(getExistingNumbers())
        if let currentNumber = manualOverrides[filename] {
            takenNumbers.remove(currentNumber)
        }

        if takenNumbers.contains(number) {
            // Shift all manual overrides at >= number up by 1 to make room.
            // Auto-detected numbers will be re-derived by scanFolder() afterward.
            var updatedOverrides: [String: Int] = [:]
            for (key, value) in manualOverrides {
                if key == filename { continue }
                updatedOverrides[key] = value >= number ? value + 1 : value
            }
            manualOverrides = updatedOverrides
        }

        manualOverrides[filename] = number
        scanFolder()
    }
    
    func getExistingNumbers() -> [Int] {
        var numbers: [Int] = []
        
        // Add manual override numbers
        numbers.append(contentsOf: manualOverrides.values)
        
        // Add auto-detected numbers by scanning current operations
        for operation in operations {
            if operation.type == .rename || operation.type == .correct {
                // Extract the number prefix from the new name
                if let match = operation.newName.range(of: "^(\\d{2})", options: .regularExpression),
                   let number = Int(operation.newName[match]) {
                    numbers.append(number)
                }
            }
        }
        
        return Array(Set(numbers)).sorted()
    }
    
    private func scanFolder() {
        guard let folderURL = folderURL else { return }

        operations = []
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }
        
        var pdfFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "pdf" {
                pdfFiles.append(fileURL)
            }
        }
        
        pdfFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
        
        // Group files
        var detectedFiles: [(order: Int, url: URL, originalName: String, instrument: String)] = []
        var scoreFiles: [(url: URL, originalName: String, instrument: String)] = []
        var undetectedFiles: [(url: URL, originalName: String)] = []
        var manuallyAssigned: [(number: Int, url: URL, originalName: String)] = []
        
        for fileURL in pdfFiles {
            let filename = fileURL.lastPathComponent
            let originalFilename = filename
            
            // Strip existing prefix for rescan mode
            let filenameWithoutPrefix: String
            if isRescanMode, let match = filename.range(of: "^\\d{2}[-_\\s]", options: .regularExpression) {
                filenameWithoutPrefix = String(filename[match.upperBound...])
            } else {
                filenameWithoutPrefix = filename
            }
            
            // Skip already prefixed in normal mode
            if !isRescanMode, filename.range(of: "^\\d{2}[-_\\s]", options: .regularExpression) != nil {
                let op = RenameOperation(
                    originalURL: fileURL,
                    originalName: filename,
                    newName: "",
                    type: .alreadyPrefixed
                )
                operations.append(op)
                continue
            }
            
            // Check manual override
            if let manualNumber = manualOverrides[originalFilename] {
                manuallyAssigned.append((manualNumber, fileURL, originalFilename))
                continue
            }
            
            // Detect instrument
            if let (order, instrument) = detectInstrument(in: filenameWithoutPrefix) {
                if instrument == "score" {
                    scoreFiles.append((fileURL, originalFilename, instrument))
                } else {
                    detectedFiles.append((order, fileURL, originalFilename, instrument))
                }
            } else {
                undetectedFiles.append((fileURL, originalFilename))
            }
        }
        
        // Sort and assign numbers
        detectedFiles.sort { $0.order < $1.order }
        
        // Process score files (all get 00)
        for (url, originalName, _) in scoreFiles {
            let prefix = "00"
            let cleanName: String
            let oldPrefix: String?
            
            if isRescanMode, let match = originalName.range(of: "^(\\d{2})", options: .regularExpression) {
                oldPrefix = String(originalName[match])
                cleanName = String(originalName[originalName.index(match.upperBound, offsetBy: 0)...])
                    .replacingOccurrences(of: "^[-_\\s]+", with: "", options: .regularExpression)
            } else {
                oldPrefix = nil
                cleanName = originalName
            }
            
            let newFilename = "\(prefix) - \(cleanName)"
            let newURL = folderURL.appendingPathComponent(newFilename)
            
            if oldPrefix == prefix {
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: "",
                    type: .skip
                )
                operations.append(op)
            } else if fileManager.fileExists(atPath: newURL.path) && newURL != url {
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: newFilename,
                    type: .skip,
                    statusOverride: "Target exists"
                )
                operations.append(op)
            } else {
                let type: RenameOperationType = oldPrefix != nil ? .correct : .rename
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: newFilename,
                    newURL: newURL,
                    type: type,
                    oldPrefix: oldPrefix
                )
                operations.append(op)
            }
        }
        
        // Process detected files (start from 01), skipping any numbers reserved by manual overrides
        let reservedNumbers = Set(manualOverrides.values)
        var nextNumber = 1
        for (_, url, originalName, _) in detectedFiles {
            while reservedNumbers.contains(nextNumber) { nextNumber += 1 }
            let prefix = String(format: "%02d", nextNumber)
            nextNumber += 1
            let cleanName: String
            let oldPrefix: String?
            
            if isRescanMode, let match = originalName.range(of: "^(\\d{2})", options: .regularExpression) {
                oldPrefix = String(originalName[match])
                cleanName = String(originalName[originalName.index(match.upperBound, offsetBy: 0)...])
                    .replacingOccurrences(of: "^[-_\\s]+", with: "", options: .regularExpression)
            } else {
                oldPrefix = nil
                cleanName = originalName
            }
            
            let newFilename = "\(prefix) - \(cleanName)"
            let newURL = folderURL.appendingPathComponent(newFilename)
            
            if oldPrefix == prefix {
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: "",
                    type: .skip
                )
                operations.append(op)
            } else if fileManager.fileExists(atPath: newURL.path) && newURL != url {
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: newFilename,
                    type: .skip,
                    statusOverride: "Target exists"
                )
                operations.append(op)
            } else {
                let type: RenameOperationType = oldPrefix != nil ? .correct : .rename
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: newFilename,
                    newURL: newURL,
                    type: type,
                    oldPrefix: oldPrefix
                )
                operations.append(op)
            }
        }
        
        // Process manually assigned
        manuallyAssigned.sort { $0.number < $1.number }
        for (number, url, originalName) in manuallyAssigned {
            let prefix = String(format: "%02d", number)
            let cleanName: String
            
            if isRescanMode, let match = originalName.range(of: "^\\d{2}[-_\\s]", options: .regularExpression) {
                cleanName = String(originalName[match.upperBound...])
            } else {
                cleanName = originalName
            }
            
            let newFilename = "\(prefix) - \(cleanName)"
            let newURL = folderURL.appendingPathComponent(newFilename)
            
            if fileManager.fileExists(atPath: newURL.path) && newURL != url {
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: newFilename,
                    type: .skip,
                    statusOverride: "Target exists"
                )
                operations.append(op)
            } else {
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: newFilename,
                    newURL: newURL,
                    type: .manual
                )
                operations.append(op)
            }
        }
        
        // Add undetected files
        for (url, originalName) in undetectedFiles {
            let op = RenameOperation(
                originalURL: url,
                originalName: originalName,
                newName: "",
                type: .undetected
            )
            operations.append(op)
        }
        
        // Sort by new filename
        operations.sort { op1, op2 in
            if op1.newName.isEmpty && !op2.newName.isEmpty {
                return false
            } else if !op1.newName.isEmpty && op2.newName.isEmpty {
                return true
            } else if op1.newName.isEmpty && op2.newName.isEmpty {
                return op1.originalName < op2.originalName
            } else {
                return op1.newName < op2.newName
            }
        }
    }
    
    private func detectInstrument(in filename: String) -> (Int, String)? {
        let lowerFilename = filename.lowercased()
        
        // Create array of (originalIndex, instrument) and sort by length (longest first)
        // This ensures "bass clarinet" matches before "clarinet"
        let sortedInstruments = customInstrumentOrder.enumerated().map { ($0.offset, $0.element) }
            .sorted { $0.1.count > $1.1.count }
        
        // Find all matches with their position in the filename
        var matches: [(index: Int, instrument: String, position: Int)] = []
        for (originalIndex, instrument) in sortedInstruments {
            if let range = lowerFilename.range(of: instrument.lowercased()) {
                let position = lowerFilename.distance(from: lowerFilename.startIndex, to: range.lowerBound)
                matches.append((originalIndex, instrument, position))
            }
        }
        
        // Return the match that appears FIRST in the filename (leftmost position)
        // This handles cases like "Baritone BC Bassoon" -> should use "baritone" not "bassoon"
        if let firstMatch = matches.min(by: { $0.position < $1.position }) {
            return (firstMatch.index, firstMatch.instrument)
        }
        return nil
    }
    
    func executeRename() {
        let toRename = operations.filter { $0.type == .rename || $0.type == .correct || $0.type == .manual }
        
        guard !toRename.isEmpty else { return }
        
        var successCount = 0
        var errors: [String] = []
        
        for operation in toRename {
            guard let newURL = operation.newURL else { continue }
            
            do {
                try FileManager.default.moveItem(at: operation.originalURL, to: newURL)
                successCount += 1
            } catch {
                errors.append("\(operation.originalName): \(error.localizedDescription)")
            }
        }
        
        if !errors.isEmpty {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Partial Success"
            let errorList = errors.prefix(5).joined(separator: "\n")
            var message = "Renamed \(successCount) file(s), but \(errors.count) failed:\n\n\(errorList)"
            if errors.count > 5 {
                message += "\n... and \(errors.count - 5) more"
            }
            errorAlert.informativeText = message
            errorAlert.alertStyle = .warning
            errorAlert.runModal()
        }
        
        scanFolder()
    }
}

// MARK: - Supporting Types for Renamer
enum EnsembleType: String, CaseIterable {
    case band = "Band"
    case jazz = "Jazz"
    case orchestra = "Orchestra"
}

struct InstrumentOrders {

    // MARK: - External file location
    // Users can edit this file to customise instrument ordering.
    // Changes take effect the next time the app is launched.
    static var fileURL: URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = appSupport.appendingPathComponent("Music PDF Manager", isDirectory: true)
        return dir.appendingPathComponent("instrument-orders.json")
    }

    // Bump this whenever the built-in defaults change so existing JSON files
    // are automatically regenerated on next launch.
    private static let defaultsVersion = 2

    // MARK: - Loaded state (populated by setup())
    private static var loaded: [String: [String]] = [:]

    // MARK: - Public accessors
    static var band:      [String] { loaded["band"]      ?? bandDefault      }
    static var jazz:      [String] { loaded["jazz"]      ?? jazzDefault      }
    static var orchestra: [String] { loaded["orchestra"] ?? orchestraDefault }

    static func getOrder(for type: EnsembleType) -> [String] {
        switch type {
        case .band:      return band
        case .jazz:      return jazz
        case .orchestra: return orchestra
        }
    }

    // MARK: - Setup (call once at launch from AppDelegate)
    static func setup() {
        guard let url = fileURL else { return }

        // Create the Application Support directory if needed
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Rewrite defaults if the file is missing OR was built with an older version.
        // _version is stored as ["2"] so the file stays as [String: [String]].
        let needsRewrite: Bool
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let dict = try? JSONDecoder().decode([String: [String]].self, from: data),
           let versionStr = dict["_version"]?.first,
           let version = Int(versionStr),
           version >= defaultsVersion {
            needsRewrite = false
        } else {
            needsRewrite = true
        }

        if needsRewrite {
            writeDefaults(to: url)
        }

        load(from: url)
    }

    // MARK: - Private helpers
    private static func load(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return }
        // Strip the version sentinel so it doesn't appear as an instrument order
        loaded = dict.filter { $0.key != "_version" }
    }

    private static func writeDefaults(to url: URL) {
        // _version is written as a string list with a single sentinel entry so the
        // file stays as [String: [String]] and remains hand-editable.
        let defaults: [String: [String]] = [
            "_version":  [String(defaultsVersion)],
            "band":      bandDefault,
            "jazz":      jazzDefault,
            "orchestra": orchestraDefault,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(defaults) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Built-in defaults (used as fallback if the file is missing or unreadable)
    private static let bandDefault = [
        "score",
        "instrumentation",
        "piccolo",
        "flute",
        "oboe",
        "cor anglais",
        "english horn",
        "bassoon",
        "contrabassoon",
        "eb clarinet",
        "eflat clarinet",
        "clarinet",
        "alto clarinet",
        "bass clarinet",
        "contrabass clarinet",
        "soprano sax",
        "sop sax",
        "sop saxophone",
        "soprano saxophone",
        "alto saxophone",
        "saxophone alto",
        "alto sax",
        "sax alto",
        "tenor sax",
        "tenor saxophone",
        "saxophone tenor",
        "sax tenor",
        "bari sax",
        "baritone sax",
        "baritone saxophone",
        "bari saxophone",
        "sax bari",
        "saxophone bari",
        "sax baritone",
        "bass sax",
        "bass saxophone",
        "cornet",
        "trumpet",
        "horn",
        "trombone",
        "bass trombone",
        "trombone bass",
        "euphonium",
        "eupho",
        "baritone",
        "tuba",
        "guitar",
        "electric guitar",
        "keyboard",
        "piano",
        "harp",
        "string bass",
        "bass",
        "timpani",
        "mallet",
        "mallets",
        "mallet percussion",
        "bells",
        "chimes",
        "glockenspiel",
        "xylophone",
        "vibraphone",
        "marimba",
        "drums",
        "drum set",
        "percussion",
        "snare drum",
        "bass drum",
        "cymbals",
        "tambourine",
        "auxiliary",
        "violin",
        "viola",
        "cello",
        "double bass",
    ]

    private static let jazzDefault = [
        "score",
        "instrumentation",
        "voice",
        "vocal",
        "vocals",
        "solo alto sax",
        "solo alto saxophone",
        "solo saxophone alto",
        "solo eb",
        "solo eflat",
        "solo e flat",
        "solo tenor sax",
        "solo tenor saxophone",
        "solo bari sax",
        "solo baritone sax",
        "solo bb",
        "solo b flat",
        "solo bflat",
        "solo trumpet",
        "solo trombone",
        "solo",
        "soli",
        "alto saxophone",
        "saxophone alto",
        "alto sax",
        "sax alto",
        "alto",
        "tenor sax",
        "sax tenor",
        "tenor saxophone",
        "saxophone tenor",
        "tenor",
        "bari sax",
        "baritone sax",
        "bari saxophone",
        "sax bari",
        "saxophone bari",
        "sax baritone",
        "baritone saxophone",
        "baritone",
        "bari",
        "trumpet",
        "cornet",
        "flugelhorn",
        "trombone",
        "bass trombone",
        "trombone bass",
        "guitar",
        "guitar chords",
        "guitar chord",
        "chords",
        "piano",
        "keyboard",
        "bass",
        "string bass",
        "electric bass",
        "double bass",
        "drums",
        "drum set",
        "aux percussion",
        "auxiliary percussion",
        "congas",
        "bongos",
        "percussion",
        "mallets",
        "vibraphone",
        "vibes",
        "flute",
        "clarinet",
        "horn",
        "baritone horn",
        "eupho",
        "euphonium",
        "tuba",
    ]

    private static let orchestraDefault = [
        "score",
        "instrumentation",
        "piccolo",
        "flute",
        "oboe",
        "cor anglais",
        "english horn",
        "clarinet",
        "eb clarinet",
        "eflat clarinet",
        "alto clarinet",
        "bass clarinet",
        "contrabass clarinet",
        "bassoon",
        "contrabassoon",
        "soprano sax",
        "sop sax",
        "sop saxophone",
        "soprano saxophone",
        "alto saxophone",
        "alto sax",
        "sax alto",
        "tenor sax",
        "tenor saxophone",
        "sax tenor",
        "bari sax",
        "baritone sax",
        "bari saxophone",
        "sax bari",
        "saxophone bari",
        "sax baritone",
        "bass sax",
        "bass saxophone",
        "horn",
        "trumpet",
        "cornet",
        "trombone",
        "bass trombone",
        "trombone bass",
        "euphonium",
        "eupho",
        "baritone",
        "tuba",
        "timpani",
        "mallet",
        "mallets",
        "mallet percussion",
        "percussion",
        "drums",
        "guitar",
        "keyboard",
        "piano",
        "harp",
        "violin",
        "viola",
        "cello",
        "double bass",
        "string bass",
        "bass",
    ]
}

enum RenameOperationType {
    case rename
    case skip
    case alreadyPrefixed
    case undetected
    case correct
    case manual
}

struct RenameOperation: Identifiable {
    let id = UUID()
    let originalURL: URL
    let originalName: String
    let newName: String
    var newURL: URL?
    let type: RenameOperationType
    var statusOverride: String?
    var oldPrefix: String?
    
    init(originalURL: URL, originalName: String, newName: String, newURL: URL? = nil,
         type: RenameOperationType, statusOverride: String? = nil, oldPrefix: String? = nil) {
        self.originalURL = originalURL
        self.originalName = originalName
        self.newName = newName
        self.newURL = newURL
        self.type = type
        self.statusOverride = statusOverride
        self.oldPrefix = oldPrefix
    }
    
    var statusText: String {
        if let override = statusOverride {
            return override
        }
        
        switch type {
        case .rename:
            return "Will rename"
        case .skip:
            return "Already correct"
        case .alreadyPrefixed:
            return "Already prefixed"
        case .undetected:
            return "No instrument found (double-click to assign)"
        case .correct:
            if let old = oldPrefix {
                let new = String(newName.prefix(2))
                return "Will correct (\(old) → \(new))"
            }
            return "Will correct"
        case .manual:
            return "Will rename (manual)"
        }
    }
    
    var color: Color {
        switch type {
        case .rename:
            return Color.green
        case .skip, .alreadyPrefixed:
            return Color.secondary
        case .undetected:
            return Color.secondary
        case .correct:
            return Color.orange
        case .manual:
            return Color.blue
        }
    }
}

// MARK: - Rotate View
struct RotateView: View {
    @StateObject private var pdfManager = PDFManager()
    @State private var baseRotation: RotationAngle = .none
    @State private var additionalRotationMode: RotationMode = .none
    @State private var additionalRotationAngle: RotationAngle = .rotate180
    @State private var currentPage: Int = 0
    @State private var isShowingSavePanel = false
    @FocusState private var isViewFocused: Bool

    var totalPages: Int { pdfManager.pdfDocument?.pageCount ?? 0 }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack {
                Text("Rotate Pages")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if pdfManager.pdfDocument != nil {
                    Button(action: { pdfManager.clearPDF() }) {
                        Label("Clear", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Main content area
            if let document = pdfManager.pdfDocument {
                // PDF loaded - show preview and controls
                VStack(spacing: 16) {
                    // Preview area
                    RotatePreviewSection(
                        document: document,
                        currentPage: $currentPage,
                        baseRotation: baseRotation,
                        additionalRotationMode: additionalRotationMode,
                        additionalRotationAngle: additionalRotationAngle
                    )
                    
                    Divider()
                    
                    // Controls
                    VStack(spacing: 16) {
                        // Base rotation options
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Step 1: Base Rotation (All Pages)")
                                .font(.headline)
                            
                            HStack {
                                Text("Rotate all pages:")
                                Picker("Base rotation", selection: $baseRotation) {
                                    Text("None").tag(RotationAngle.none)
                                    Text("90°").tag(RotationAngle.rotate90)
                                    Text("180°").tag(RotationAngle.rotate180)
                                    Text("270°").tag(RotationAngle.rotate270)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 280)
                                
                                Spacer()
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                        
                        // Additional rotation options
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Step 2: Additional Rotation (Optional)")
                                .font(.headline)
                            
                            HStack(spacing: 20) {
                                Picker("Then also rotate:", selection: $additionalRotationMode) {
                                    Text("No additional rotation").tag(RotationMode.none)
                                    Text("Odd pages (1, 3, 5...)").tag(RotationMode.odd)
                                    Text("Even pages (2, 4, 6...)").tag(RotationMode.even)
                                }
                                .pickerStyle(.radioGroup)
                                
                                Spacer()
                                
                                if additionalRotationMode != .none {
                                    HStack {
                                        Text("by:")
                                        Picker("Additional rotation angle", selection: $additionalRotationAngle) {
                                            Text("90°").tag(RotationAngle.rotate90)
                                            Text("180°").tag(RotationAngle.rotate180)
                                            Text("270°").tag(RotationAngle.rotate270)
                                        }
                                        .pickerStyle(.segmented)
                                        .frame(width: 200)
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                        
                        // Action buttons
                        HStack {
                            Spacer()
                            
                            Button(action: { isShowingSavePanel = true }) {
                                Label("Save Rotated PDF", systemImage: "arrow.down.doc.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                    .padding()
                }
            } else {
                // No PDF loaded - show drop zone
                DropZoneView(pdfManager: pdfManager)
            }
        }
        .focusable()
        .focused($isViewFocused)
        .onAppear { isViewFocused = true }
        .onChange(of: pdfManager.pdfDocument) { newValue in
            if newValue != nil { isViewFocused = true }
        }
        .onKeyPress { press in
            guard pdfManager.pdfDocument != nil else { return .ignored }
            switch press.key {
            case .leftArrow:
                if press.modifiers.contains(.command) { currentPage = 0 }
                else if currentPage > 0 { currentPage -= 1 }
                return .handled
            case .rightArrow:
                if press.modifiers.contains(.command) { currentPage = totalPages - 1 }
                else if currentPage < totalPages - 1 { currentPage += 1 }
                return .handled
            default:
                return .ignored
            }
        }
        .onChange(of: isShowingSavePanel) { newValue in
            if newValue, let document = pdfManager.pdfDocument {
                saveRotatedPDF(document: document)
            }
        }
    }

    private func saveRotatedPDF(document: PDFDocument) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = (pdfManager.currentFileName ?? "document") + "_rotated.pdf"
        savePanel.title = "Save Rotated PDF"
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                pdfManager.saveRotatedPDF(
                    to: url,
                    baseRotation: baseRotation,
                    additionalRotationMode: additionalRotationMode,
                    additionalRotationAngle: additionalRotationAngle
                )
            }
            isShowingSavePanel = false
        }
    }
}

// MARK: - Split View
struct SplitView: View {
    @StateObject private var pdfManager = PDFManager()
    // fileSizes stores the page count for each output file in order.
    // e.g. [2, 2, 1, 3] means 4 files with 2, 2, 1, and 3 pages respectively.
    // This makes split point manipulation natural: adding a split just partitions
    // an existing entry, removing one merges two adjacent entries.
    @State private var fileSizes: [Int] = []
    @State private var stride: Int = 2
    @State private var currentPage: Int = 0
    @State private var showingNamingStage: Bool = false
    @State private var baseFileName: String = ""
    @State private var customFileNames: [Int: String] = [:]
    @FocusState private var isViewFocused: Bool

    var totalPages: Int {
        pdfManager.pdfDocument?.pageCount ?? 0
    }

    // Split markers derived from fileSizes: the page that starts each file (except the first).
    var splitMarkers: Set<Int> {
        var markers: Set<Int> = []
        var pos = 0
        for size in fileSizes.dropLast() {
            pos += size
            markers.insert(pos)
        }
        return markers
    }

    var pageToFileMapping: [Int: Int] {
        guard !fileSizes.isEmpty else { return [:] }
        var mapping: [Int: Int] = [:]
        var pos = 0
        for (fileIndex, size) in fileSizes.enumerated() {
            for pageIndex in pos..<(pos + size) {
                mapping[pageIndex] = fileIndex
            }
            pos += size
        }
        return mapping
    }

    var numberOfFiles: Int {
        fileSizes.count
    }
    
    var body: some View {
        if showingNamingStage, let document = pdfManager.pdfDocument {
            SplitNamingStageView(
                pdfDocument: document,
                fileSizes: fileSizes,
                baseFileName: $baseFileName,
                customFileNames: $customFileNames,
                onBack: { showingNamingStage = false },
                onSave: { saveSplitPDF() }
            )
        } else {
        splitStageBody
        }
    }

    @ViewBuilder
    private var splitStageBody: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack {
                Text("Split PDF — Step 1: Set Split Points")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if pdfManager.pdfDocument != nil {
                    Button(action: clearAllMarkers) {
                        Label("Clear All Splits", systemImage: "trash")
                    }
                    .disabled(splitMarkers.isEmpty)

                    Button(action: { pdfManager.clearPDF() }) {
                        Label("Clear", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Main content area
            if let document = pdfManager.pdfDocument {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        // Left: Page preview and controls
                        VStack(spacing: 16) {
                            // Page navigation and controls
                            SplitControlsSection(
                                currentPage: $currentPage,
                                splitMarkers: splitMarkers,
                                fileSizes: fileSizes,
                                totalPages: totalPages,
                                onToggleMarker: { toggleSplitAt(page: currentPage) }
                            )

                            Divider()

                            // Preview
                            PDFPageView(
                                page: document.page(at: currentPage),
                                rotation: 0
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                isViewFocused = true
                            }
                        }
                        .frame(width: geometry.size.width * 0.5)
                        .focusable()
                        .focused($isViewFocused)
                        
                        Divider()
                        
                        // Right: Stride controls + file preview
                        VStack(alignment: .leading, spacing: 12) {
                            // ── Stride / pattern controls ─────────────────────
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Split Pattern")
                                    .font(.headline)

                                HStack(spacing: 8) {
                                    Text("Stride:")
                                        .foregroundColor(.secondary)
                                    Stepper(value: $stride, in: 1...20, label: {
                                        Text("\(stride) \(stride == 1 ? "page" : "pages")")
                                            .frame(minWidth: 55, alignment: .leading)
                                    })
                                    Button("Apply") {
                                        applyStride()
                                    }
                                    .buttonStyle(.bordered)
                                    .help("Re-apply stride from scratch, clearing any manual adjustments")
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("**Stride** is the default number of pages per output file. When you load a PDF or press **Apply**, split markers are placed every N pages automatically.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("Then navigate with ← → and press **Space** to fine-tune. Pressing Space in the *middle* of a file adds a split there. Pressing Space at the *start* of a file (highlighted in orange) removes that split and merges the file with the one above.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.controlBackgroundColor))
                            )

                            // ── Output files list ─────────────────────────────
                            HStack {
                                Text("Output Files (\(numberOfFiles))")
                                    .font(.headline)
                                Spacer()
                                if !baseFileName.isEmpty {
                                    Text("Base: \(baseFileName)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(0..<numberOfFiles, id: \.self) { fileIndex in
                                        FilePreviewCard(
                                            fileIndex: fileIndex,
                                            pageToFileMapping: pageToFileMapping,
                                            totalPages: totalPages,
                                            baseFileName: baseFileName,
                                            customFileNames: customFileNames,
                                            onNavigate: { pageIndex in
                                                currentPage = pageIndex
                                            }
                                        )
                                    }
                                }
                            }

                            // Action button
                            HStack {
                                Spacer()
                                Button(action: { showingNamingStage = true }) {
                                    Label("Next: Name Files", systemImage: "arrow.right.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(numberOfFiles < 2)
                            }
                        }
                        .padding()
                        .frame(width: geometry.size.width * 0.5)
                    }
                    .onKeyPress { press in
                        switch press.key {
                        case .leftArrow:
                            if press.modifiers.contains(.command) {
                                currentPage = 0
                            } else if currentPage > 0 {
                                currentPage -= 1
                            }
                            return .handled
                        case .rightArrow:
                            if press.modifiers.contains(.command) {
                                currentPage = totalPages - 1
                            } else if currentPage < totalPages - 1 {
                                currentPage += 1
                            }
                            return .handled
                        case .space:
                            if currentPage > 0 {
                                toggleSplitAt(page: currentPage)
                            }
                            return .handled
                        default:
                            return .ignored
                        }
                    }
                }
            } else {
                // No PDF loaded - show drop zone
                DropZoneView(pdfManager: pdfManager)
            }
        }
        .focused($isViewFocused)
        .onAppear {
            isViewFocused = true
        }
        .onChange(of: pdfManager.pdfDocument) { newValue in
            if newValue != nil {
                baseFileName = pdfManager.currentFileName ?? ""
                isViewFocused = true
                applyStride()
            } else {
                fileSizes = []
                currentPage = 0
                customFileNames.removeAll()
            }
        }
    } // end splitStageBody
    
    private func clearAllMarkers() {
        fileSizes = totalPages > 0 ? [totalPages] : []
        customFileNames.removeAll()
    }

    private func applyStride() {
        guard totalPages > 0 else { return }
        var sizes: [Int] = []
        var remaining = totalPages
        while remaining > 0 {
            let chunk = min(stride, remaining)
            sizes.append(chunk)
            remaining -= chunk
        }
        fileSizes = sizes
        customFileNames.removeAll()
    }

    /// Toggle a split point at `page`. If `page` is the start of a file (an existing
    /// split marker), the file is merged with the one before it. Otherwise, the file
    /// containing `page` is split at that position.
    private func toggleSplitAt(page: Int) {
        guard page > 0, !fileSizes.isEmpty else { return }
        var pos = 0
        for (i, size) in fileSizes.enumerated() {
            if page >= pos && page < pos + size {
                let localPos = page - pos
                if localPos == 0 {
                    // page is the start of file i (an existing split marker): merge with previous
                    if i > 0 {
                        fileSizes[i - 1] += fileSizes[i]
                        fileSizes.remove(at: i)
                    }
                } else {
                    // page is in the middle: split file i here
                    let firstPart = localPos
                    let secondPart = size - localPos
                    fileSizes[i] = firstPart
                    fileSizes.insert(secondPart, at: i + 1)
                }
                return
            }
            pos += size
        }
    }

    func saveSplitPDF() {
        guard let _ = pdfManager.pdfDocument, numberOfFiles >= 2 else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Select Output Folder"
        panel.message = "Choose where to save the split PDF files"

        panel.begin { response in
            if response == .OK, let folderURL = panel.url {
                pdfManager.saveSplitPDF(
                    to: folderURL,
                    splitMarkers: splitMarkers,
                    baseFileName: baseFileName,
                    customFileNames: customFileNames,
                    pageToFileMapping: pageToFileMapping
                )
            }
        }
    }
}

// MARK: - Split Controls Section
struct SplitControlsSection: View {
    @Binding var currentPage: Int
    let splitMarkers: Set<Int>
    let fileSizes: [Int]
    let totalPages: Int
    let onToggleMarker: () -> Void

    /// Returns which file index the current page belongs to, and the size of that file.
    private var currentFileInfo: (fileIndex: Int, fileStart: Int, fileSize: Int)? {
        var pos = 0
        for (i, size) in fileSizes.enumerated() {
            if currentPage >= pos && currentPage < pos + size {
                return (i, pos, size)
            }
            pos += size
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 12) {
            // Navigation controls
            HStack {
                Button(action: firstPage) {
                    Image(systemName: "chevron.backward.to.line")
                }
                .disabled(currentPage == 0)

                Button(action: previousPage) {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPage == 0)

                Spacer()

                VStack(spacing: 2) {
                    Text("Page \(currentPage + 1) of \(totalPages)")
                        .font(.headline)
                    // Show which output file this page belongs to
                    if let info = currentFileInfo {
                        let isAtStart = currentPage == info.fileStart
                        let endPage = info.fileStart + info.fileSize - 1
                        let rangeText = info.fileStart == endPage
                            ? "p.\(info.fileStart + 1)"
                            : "pp.\(info.fileStart + 1)–\(endPage + 1)"
                        Text("File \(info.fileIndex + 1) (\(rangeText), \(info.fileSize) \(info.fileSize == 1 ? "page" : "pages"))\(isAtStart && currentPage > 0 ? " — split marker" : "")")
                            .font(.caption)
                            .foregroundColor(isAtStart && currentPage > 0 ? .orange : .secondary)
                    }
                }

                Spacer()

                Button(action: nextPage) {
                    Image(systemName: "chevron.right")
                }
                .disabled(currentPage >= totalPages - 1)

                Button(action: lastPage) {
                    Image(systemName: "chevron.forward.to.line")
                }
                .disabled(currentPage >= totalPages - 1)
            }
            .padding(.horizontal)

            // Split marker controls
            HStack(spacing: 12) {
                Button(action: onToggleMarker) {
                    if splitMarkers.contains(currentPage) {
                        Label("Remove Split (merge with previous)", systemImage: "xmark.circle")
                    } else {
                        Label("Add Split Here", systemImage: "scissors")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(currentPage == 0)

                Text("Space to toggle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    private func firstPage() { currentPage = 0 }
    private func lastPage()  { currentPage = totalPages - 1 }

    private func previousPage() {
        if currentPage > 0 { currentPage -= 1 }
    }

    private func nextPage() {
        if currentPage < totalPages - 1 { currentPage += 1 }
    }
}

// MARK: - File Preview Card
struct FilePreviewCard: View {
    let fileIndex: Int
    let pageToFileMapping: [Int: Int]
    let totalPages: Int
    let baseFileName: String
    let customFileNames: [Int: String]
    let onNavigate: (Int) -> Void
    
    var pagesInFile: [Int] {
        pageToFileMapping.filter { $0.value == fileIndex }.keys.sorted()
    }
    
    var fileName: String {
        if let customSuffix = customFileNames[fileIndex], !customSuffix.isEmpty {
            return "\(baseFileName)\(customSuffix).pdf"
        } else {
            return "\(baseFileName)_\(fileIndex + 1).pdf"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.fill")
                    .foregroundColor(.blue)
                
                Text(fileName)
                    .font(.headline)
                
                Spacer()
                
                Text("\(pagesInFile.count) page\(pagesInFile.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 4) {
                ForEach(pagesInFile.prefix(10), id: \.self) { pageIndex in
                    Button(action: {
                        onNavigate(pageIndex)
                    }) {
                        Text("\(pageIndex + 1)")
                            .font(.caption2)
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor.opacity(0.2))
                            )
                    }
                    .buttonStyle(.plain)
                }
                
                if pagesInFile.count > 10 {
                    Text("+ \(pagesInFile.count - 10) more")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

// MARK: - Split Naming Stage (Step 2)
/// Full-window Step 2: lets users set the base filename and per-file name suffixes,
/// with a large first-page thumbnail for each output file.
struct SplitNamingStageView: View {
    let pdfDocument: PDFDocument
    let fileSizes: [Int]
    @Binding var baseFileName: String
    @Binding var customFileNames: [Int: String]
    let onBack: () -> Void
    let onSave: () -> Void

    @FocusState private var focusedField: Int?

    var numberOfFiles: Int { fileSizes.count }

    /// Page index of the first page in a given file.
    private func firstPageIndex(for fileIndex: Int) -> Int {
        fileSizes.prefix(fileIndex).reduce(0, +)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar (title only) ─────────────────────────────────────
            HStack {
                Spacer()
                Text("Step 2: Name Files")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // ── Base filename ─────────────────────────────────────────────
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Base Filename:")
                    .font(.headline)
                    .fixedSize()

                TextField("e.g. Symphony No. 5", text: $baseFileName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 380)

                Text("Suffixes are appended directly: \(baseFileName.isEmpty ? "basename" : baseFileName)Flute.pdf  ·  Leave blank for auto-numbering: \(baseFileName.isEmpty ? "basename" : baseFileName)_1.pdf")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // ── File list ─────────────────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<numberOfFiles, id: \.self) { fileIndex in
                            SplitFileNamingRow(
                                fileIndex: fileIndex,
                                fileSizes: fileSizes,
                                firstPageIndex: firstPageIndex(for: fileIndex),
                                pdfDocument: pdfDocument,
                                baseFileName: baseFileName,
                                suffix: Binding(
                                    get: { customFileNames[fileIndex] ?? "" },
                                    set: { customFileNames[fileIndex] = $0.isEmpty ? nil : $0 }
                                ),
                                fieldFocus: $focusedField
                            )
                            .id(fileIndex)
                            if fileIndex < numberOfFiles - 1 { Divider() }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: focusedField) { newValue in
                    if let field = newValue {
                        withAnimation { proxy.scrollTo(field, anchor: .center) }
                    }
                }
            }

            Divider()

            // ── Bottom bar ───────────────────────────────────────────────
            HStack {
                Button(action: onBack) {
                    Label("Back to Split", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(action: onSave) {
                    Label("Save Split Files", systemImage: "arrow.down.doc.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(numberOfFiles < 2)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

// MARK: - Split File Naming Row
/// One row in the naming stage: large page thumbnail on the left, file info and
/// suffix text field on the right.
struct SplitFileNamingRow: View {
    let fileIndex: Int
    let fileSizes: [Int]
    let firstPageIndex: Int
    let pdfDocument: PDFDocument
    let baseFileName: String
    @Binding var suffix: String
    /// The parent's FocusState binding — passed directly so that Tab/click
    /// both update the parent (triggering auto-scroll) without a local copy.
    var fieldFocus: FocusState<Int?>.Binding

    private var fileSize: Int {
        fileIndex < fileSizes.count ? fileSizes[fileIndex] : 0
    }

    private var pageRangeText: String {
        let start = firstPageIndex + 1
        let end = firstPageIndex + fileSize
        return start == end ? "Page \(start)" : "Pages \(start)–\(end)"
    }

    private var finalFileName: String {
        suffix.isEmpty
            ? "\(baseFileName)_\(fileIndex + 1).pdf"
            : "\(baseFileName)\(suffix).pdf"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── File header ───────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "doc.fill")
                    .foregroundColor(.accentColor)
                Text("File \(fileIndex + 1)")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("·")
                    .foregroundColor(.secondary)
                Text(pageRangeText)
                    .foregroundColor(.secondary)
                Text("·")
                    .foregroundColor(.secondary)
                Text("\(fileSize) \(fileSize == 1 ? "page" : "pages")")
                    .foregroundColor(.secondary)
                Spacer()
            }

            // ── Instrument name crop (full-width, zoomed in) ─────────
            // Shows the top-left corner of the page where instrument names live.
            // .allowsHitTesting(false) is essential: with .fill content mode the
            // image's hit-test area can grow beyond its visible frame and silently
            // absorb clicks meant for the text field below.
            if let page = pdfDocument.page(at: firstPageIndex) {
                PageInstrumentPreview(page: page)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
                    .allowsHitTesting(false)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.12))
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .allowsHitTesting(false)
            }

            // ── Name field ────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Custom suffix (optional — leave blank for automatic numbering)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    Text(baseFileName.isEmpty ? "basename" : baseFileName)
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                    TextField("Flute", text: $suffix)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .focused(fieldFocus, equals: fileIndex)
                    Text(".pdf")
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                }

                // Live filename preview
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                    Text(finalFileName)
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(suffix.isEmpty ? .secondary : .accentColor)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(fieldFocus.wrappedValue == fileIndex ? Color.accentColor.opacity(0.05) : Color.clear)
    }
}

// MARK: - Page Instrument Preview
struct PageInstrumentPreview: View {
    let page: PDFPage
    
    var body: some View {
        if let image = renderInstrumentNameArea(from: page) {
            // Use .fill so the crop fills its parent frame completely.
            // The instrument name sits at the left of the crop, so any overflow
            // clipped on the right is just whitespace.
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipped()
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
        }
    }

    // Render just the top-left portion where instrument names typically appear
    private func renderInstrumentNameArea(from page: PDFPage) -> NSImage? {
        let pageBounds = page.bounds(for: .mediaBox)
        
        // Calculate the crop area.
        // Start at the very top of the page (instrument names sit right at the top)
        // and capture ~1.4 inches (100 pt) of height — enough to show the name box.
        let cropHeight: CGFloat = 100    // ~1.4 inches
        let cropWidth: CGFloat = min(pageBounds.width * 0.4, 200) // Left 40%, max 200 pt

        // Account for page rotation
        let rotation = page.rotation
        var actualBounds = pageBounds
        if rotation == 90 || rotation == 270 {
            actualBounds = CGRect(x: pageBounds.origin.x, y: pageBounds.origin.y,
                                width: pageBounds.height, height: pageBounds.width)
        }

        // In PDF coords Y grows upward; the top of the page is at origin.y + height.
        let cropRect = CGRect(
            x: actualBounds.origin.x,
            y: actualBounds.origin.y + actualBounds.height - cropHeight,
            width: cropWidth,
            height: cropHeight
        )
        
        // Create image
        let scale: CGFloat = 2.0 // Retina resolution
        let imageSize = NSSize(width: cropRect.width * scale, height: cropRect.height * scale)
        
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(imageSize.width),
            pixelsHigh: Int(imageSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            return nil
        }
        NSGraphicsContext.current = context
        
        let cgContext = context.cgContext
        
        // Fill white background
        cgContext.setFillColor(NSColor.white.cgColor)
        cgContext.fill(CGRect(origin: .zero, size: imageSize))
        
        // Set up transform for cropped area
        cgContext.scaleBy(x: scale, y: scale)
        cgContext.translateBy(x: -cropRect.origin.x, y: -cropRect.origin.y)
        
        // Draw the page
        page.draw(with: .mediaBox, to: cgContext)
        
        NSGraphicsContext.restoreGraphicsState()
        
        let image = NSImage(size: cropRect.size)
        image.addRepresentation(bitmapRep)
        return image
    }
}

// MARK: - Drop Zone View (Shared)
struct DropZoneView: View {
    @ObservedObject var pdfManager: PDFManager
    @State private var isTargeted = false
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 64))
                .foregroundColor(isTargeted ? .accentColor : .secondary)
            
            Text("Drop a PDF here")
                .font(.title2)
                .fontWeight(.medium)
            
            Text("or")
                .foregroundColor(.secondary)
            
            Button(action: selectPDF) {
                Label("Choose PDF", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.gray.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [10])
                )
                .padding()
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url, url.pathExtension.lowercased() == "pdf" {
                    DispatchQueue.main.async {
                        pdfManager.loadPDF(from: url)
                    }
                }
            }
            
            return true
        }
    }
    
    private func selectPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.title = "Select PDF"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                pdfManager.loadPDF(from: url)
            }
        }
    }
}

// MARK: - Rotate Preview Section
struct RotatePreviewSection: View {
    let document: PDFDocument
    @Binding var currentPage: Int
    let baseRotation: RotationAngle
    let additionalRotationMode: RotationMode
    let additionalRotationAngle: RotationAngle
    
    var totalPages: Int {
        document.pageCount
    }
    
    var totalRotationForCurrentPage: Int {
        let pageNumber = currentPage + 1
        var rotation = baseRotation.degrees
        
        let shouldApplyAdditional: Bool
        switch additionalRotationMode {
        case .odd:
            shouldApplyAdditional = pageNumber % 2 == 1
        case .even:
            shouldApplyAdditional = pageNumber % 2 == 0
        case .none, .all:
            shouldApplyAdditional = false
        }
        
        if shouldApplyAdditional {
            rotation += additionalRotationAngle.degrees
        }
        
        return rotation % 360
    }
    
    var rotationDescription: String {
        if totalRotationForCurrentPage == 0 {
            return "No rotation"
        } else if baseRotation.degrees == 0 {
            return "Rotated \(additionalRotationAngle.degrees)°"
        } else if additionalRotationMode == .none {
            return "Rotated \(baseRotation.degrees)°"
        } else {
            return "Rotated \(additionalRotationAngle.degrees)°"
        }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Page navigation
            HStack {
                Button(action: firstPage) {
                    Image(systemName: "chevron.backward.to.line")
                }
                .disabled(currentPage == 0)

                Button(action: previousPage) {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPage == 0)

                Spacer()

                VStack(spacing: 4) {
                    Text("Page \(currentPage + 1) of \(totalPages)")
                        .font(.headline)

                    Text(rotationDescription)
                        .font(.caption)
                        .foregroundColor(totalRotationForCurrentPage > 0 ? .orange : .secondary)
                        .fontWeight(totalRotationForCurrentPage > 0 ? .semibold : .regular)
                }

                Spacer()

                Button(action: nextPage) {
                    Image(systemName: "chevron.right")
                }
                .disabled(currentPage >= totalPages - 1)

                Button(action: lastPage) {
                    Image(systemName: "chevron.forward.to.line")
                }
                .disabled(currentPage >= totalPages - 1)
            }
            .padding(.horizontal)
            
            // Preview images
            HStack(spacing: 16) {
                // Before
                VStack {
                    Text("Before")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    PDFPageView(
                        page: document.page(at: currentPage),
                        rotation: 0
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                Image(systemName: "arrow.right")
                    .font(.title2)
                    .foregroundColor(.secondary)
                
                // After
                VStack {
                    Text(totalRotationForCurrentPage > 0 ? "After (Rotated)" : "After (No Change)")
                        .font(.caption)
                        .foregroundColor(totalRotationForCurrentPage > 0 ? .orange : .secondary)
                        .fontWeight(totalRotationForCurrentPage > 0 ? .semibold : .regular)
                    
                    PDFPageView(
                        page: document.page(at: currentPage),
                        rotation: totalRotationForCurrentPage
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .padding()
        }
    }
    
    private func firstPage() { currentPage = 0 }
    private func lastPage()  { currentPage = totalPages - 1 }

    private func previousPage() {
        if currentPage > 0 { currentPage -= 1 }
    }

    private func nextPage() {
        if currentPage < totalPages - 1 { currentPage += 1 }
    }
}

// MARK: - PDF Page View using native PDFView
struct PDFPageView: NSViewRepresentable {
    let page: PDFPage?
    let rotation: Int
    
    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = NSColor.white
        return pdfView
    }
    
    func updateNSView(_ pdfView: PDFView, context: Context) {
        guard let page = page else {
            pdfView.document = nil
            return
        }
        
        let document = PDFDocument()
        if let image = renderFullImage(from: page), let clonedPage = PDFPage(image: image) {
            clonedPage.rotation = rotation
            document.insert(clonedPage, at: 0)
        } else {
            // Fallback: insert original page without rotation to avoid mutating shared state
            document.insert(page, at: 0)
        }
        pdfView.document = document
        if let first = document.page(at: 0) {
            pdfView.go(to: first)
        }
    }
    
    // Render the full PDF page into an NSImage for safe preview cloning
    private func renderFullImage(from page: PDFPage) -> NSImage? {
        let bounds = page.bounds(for: .mediaBox)
        let size = NSSize(width: bounds.width, height: bounds.height)
        let image = NSImage(size: size)
        image.lockFocus()
        
        NSGraphicsContext.current?.imageInterpolation = .high
        
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            // Draw the page directly without flipping - PDFKit handles orientation
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        
        image.unlockFocus()
        return image
    }
}

// MARK: - PDF Manager
class PDFManager: ObservableObject {
    @Published var pdfDocument: PDFDocument?
    @Published var currentFileName: String?
    
    func loadPDF(from url: URL) {
        guard let document = PDFDocument(url: url) else {
            print("Failed to load PDF")
            return
        }
        
        self.pdfDocument = document
        self.currentFileName = url.deletingPathExtension().lastPathComponent
    }
    
    func clearPDF() {
        pdfDocument = nil
        currentFileName = nil
    }
    
    func saveRotatedPDF(to url: URL, baseRotation: RotationAngle, additionalRotationMode: RotationMode, additionalRotationAngle: RotationAngle) {
        guard let document = pdfDocument else { return }
        
        let newDocument = PDFDocument()
        
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            
            let pageNumber = pageIndex + 1
            
            if baseRotation.degrees != 0 {
                page.rotation += baseRotation.degrees
            }
            
            let shouldApplyAdditional: Bool
            switch additionalRotationMode {
            case .odd:
                shouldApplyAdditional = pageNumber % 2 == 1
            case .even:
                shouldApplyAdditional = pageNumber % 2 == 0
            case .none, .all:
                shouldApplyAdditional = false
            }
            
            if shouldApplyAdditional {
                page.rotation += additionalRotationAngle.degrees
            }
            
            newDocument.insert(page, at: pageIndex)
        }
        
        newDocument.write(to: url)
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "PDF Saved Successfully"
            alert.informativeText = "Your rotated PDF has been saved to:\n\(url.path)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    func saveSplitPDF(to folderURL: URL, splitMarkers: Set<Int>, baseFileName: String, customFileNames: [Int: String], pageToFileMapping: [Int: Int]) {
        guard let document = pdfDocument else { return }
        
        let numberOfFiles = (pageToFileMapping.values.max() ?? 0) + 1
        var fileDocuments: [Int: PDFDocument] = [:]
        
        // Initialize PDF documents for each file
        for fileIndex in 0..<numberOfFiles {
            fileDocuments[fileIndex] = PDFDocument()
        }
        
        // Distribute pages to files
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let fileIndex = pageToFileMapping[pageIndex],
                  let targetDoc = fileDocuments[fileIndex] else {
                continue
            }
            
            targetDoc.insert(page, at: targetDoc.pageCount)
        }
        
        // Save each file
        var savedFiles: [String] = []
        var errors: [String] = []
        
        for fileIndex in 0..<numberOfFiles {
            guard let doc = fileDocuments[fileIndex] else { continue }
            
            let fileName: String
            if let customSuffix = customFileNames[fileIndex], !customSuffix.isEmpty {
                fileName = "\(baseFileName)\(customSuffix).pdf"
            } else {
                fileName = "\(baseFileName)_\(fileIndex + 1).pdf"
            }
            
            let fileURL = folderURL.appendingPathComponent(fileName)
            
            if doc.write(to: fileURL) {
                savedFiles.append(fileName)
            } else {
                errors.append(fileName)
            }
        }
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            if errors.isEmpty {
                alert.messageText = "PDF Split Successfully"
                alert.informativeText = "Created \(savedFiles.count) file(s) in:\n\(folderURL.path)"
                alert.alertStyle = .informational
            } else {
                alert.messageText = "Partial Success"
                alert.informativeText = "Created \(savedFiles.count) file(s), but \(errors.count) failed:\n\(errors.joined(separator: ", "))"
                alert.alertStyle = .warning
            }
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

// MARK: - Supporting Types
enum RotationMode {
    case odd
    case even
    case all
    case none
}

enum RotationAngle: Int {
    case none = 0
    case rotate90 = 90
    case rotate180 = 180
    case rotate270 = 270
    
    var degrees: Int {
        self.rawValue
    }
}
