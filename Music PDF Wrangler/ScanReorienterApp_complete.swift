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
    @Published var canRemove   = false
    @Published var canMoveUp   = false
    @Published var canMoveDown = false
    @Published var canGroup    = false
    @Published var hasFiles    = false
    @Published var isPanelOpen = false  // disables menu shortcuts while a file panel is open

    var removeSelected:          () -> Void = {}
    var moveUp:                  () -> Void = {}
    var moveDown:                () -> Void = {}
    var selectAll:               () -> Void = {}
    var group:                   () -> Void = {}
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
                .disabled(state.isPanelOpen || !state.hasFiles)

            Button("Extend Selection Up") { state.selectPreviousExtending() }
                .keyboardShortcut(.upArrow, modifiers: .shift)
                .disabled(state.isPanelOpen || !state.hasFiles)

            Button("Select Next") { state.selectNext() }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(state.isPanelOpen || !state.hasFiles)

            Button("Extend Selection Down") { state.selectNextExtending() }
                .keyboardShortcut(.downArrow, modifiers: .shift)
                .disabled(state.isPanelOpen || !state.hasFiles)

            Divider()

            Button("Move Up") { state.moveUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(state.isPanelOpen || !state.canMoveUp)

            Button("Move Down") { state.moveDown() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(state.isPanelOpen || !state.canMoveDown)

            Divider()

            Button("Remove Selected Files") { state.removeSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(state.isPanelOpen || !state.canRemove)

            Divider()

            Button("Group Selected Files") { state.group() }
                .keyboardShortcut("c", modifiers: [])
                .disabled(state.isPanelOpen || !state.canGroup)

            Divider()

            Button("Select All Files") { state.selectAll() }
                .disabled(state.isPanelOpen || !state.hasFiles)
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
    @StateObject private var renamerManager = RenamerManager()
    @StateObject private var presetStore = EnsemblePresetStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(renamerManager)
                .environmentObject(presetStore)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Music PDF Manager") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(replacing: .newItem) { }
            NavigateCommands(appState: appState)
            CombinerCommands(state: appState.combineMenuState)
            HelpCommands(appState: appState)
        }

        Settings {
            AppPreferencesView()
                .environmentObject(renamerManager)
                .environmentObject(presetStore)
        }

        Window("About Music PDF Manager", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

// MARK: - About View
struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text("Music PDF Manager")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .foregroundStyle(.secondary)

            Text("Developed by Ben Perche and Claude")

            Link("github.com/benperche/music-pdf-manager",
                 destination: URL(string: "https://github.com/benperche/music-pdf-manager")!)
                .font(.callout)
        }
        .padding(32)
        .frame(width: 340)
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
        ZStack {
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

            // Keyboard shortcuts overlay — tap the backdrop or press Escape/⏎ to close
            if appState.showingKeyboardHelp {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { appState.showingKeyboardHelp = false }
                    .transition(.opacity)

                ShortcutsHelpView(onDismiss: { appState.showingKeyboardHelp = false })
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .center)))

                // Invisible button so Escape dismisses the overlay
                Button("") { appState.showingKeyboardHelp = false }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: appState.showingKeyboardHelp)
    }
}

// MARK: - Combine View
struct CombineView: View {
    @Binding var showingKeyboardHelp: Bool
    let menuState: CombineMenuState
    @EnvironmentObject var presetStore: EnsemblePresetStore
    @StateObject private var combineManager = CombineManager()
    @State private var addBlankPages = false
    @State private var isTargeted = false
    @State private var selectedFiles: Set<UUID> = []
    @State private var removalNoticeVisible = false
    @State private var removalNoticeCount = 1
    @State private var focusedFileId: UUID?     // keyboard navigation cursor
    @State private var anchorFileId: UUID?      // anchor for shift-range selection
    @State private var showPresetSidebar = false
    @State private var unmatchedFileIds: Set<UUID> = []
    @FocusState private var listFocused: Bool
    @Environment(\.undoManager) var undoManager
    
    var body: some View {
        HStack(spacing: 0) {
            mainContent
            if showPresetSidebar {
                Divider()
                PresetSidebarView(onApply: applyPreset)
                    .frame(width: 260)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showPresetSidebar)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .onAppear { syncMenuClosures() }
        .onChange(of: selectedFiles)          { _ in syncMenuFlags() }
        .onChange(of: combineManager.files)   { _ in syncMenuFlags() }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack {
                Text("Combine PDFs")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Button {
                    withAnimation { showPresetSidebar.toggle() }
                } label: {
                    Label("Presets", systemImage: "sidebar.right")
                }
                .buttonStyle(.plain)
                .foregroundColor(showPresetSidebar ? .accentColor : .secondary)
                .help(showPresetSidebar ? "Hide Presets" : "Show Presets")

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

                        Button(action: groupSelected) {
                            Label("Collate", systemImage: "rectangle.stack")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canGroup)
                        .help("Group selected files into a collate set — copies of the whole set are printed interleaved (C)")

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
                                // If this file is the first member of a collate group,
                                // emit a group header row before it.
                                if let gid = file.collateGroupId,
                                   let group = combineManager.collateGroups[gid],
                                   combineManager.files.first(where: { $0.collateGroupId == gid })?.id == file.id {
                                    let groupFiles = combineManager.files.filter { $0.collateGroupId == gid }
                                    CollateGroupHeaderRow(
                                        group: group,
                                        fileCount: groupFiles.count,
                                        totalPages: groupFiles.reduce(0) { $0 + $1.pageCount },
                                        onCopiesChanged: { newValue in
                                            combineManager.updateGroupCopies(id: gid, copies: newValue, undoManager: undoManager)
                                        },
                                        onUngroup: {
                                            combineManager.dissolveGroup(id: gid, undoManager: undoManager)
                                        }
                                    )
                                    Divider()
                                }
                                CombineFileRow(
                                    file: file,
                                    isSelected: selectedFiles.contains(file.id),
                                    isFocused: focusedFileId == file.id,
                                    isUnmatched: unmatchedFileIds.contains(file.id),
                                    isGrouped: file.collateGroupId != nil,
                                    onToggleSelect: { toggleSelection(file.id) },
                                    onCopiesChanged: { newValue in
                                        combineManager.updateCopies(for: file.id, copies: newValue, undoManager: undoManager)
                                    },
                                    onRemove: {
                                        selectedFiles.remove(file.id)
                                        unmatchedFileIds.remove(file.id)
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
                        guard !menuState.isPanelOpen else { return .ignored }
                        let isShift = press.modifiers.contains(.shift)
                        switch press.key {
                        case .upArrow:
                            navigateSelection(direction: -1, extending: isShift)
                            return .handled
                        case .downArrow:
                            navigateSelection(direction: 1, extending: isShift)
                            return .handled
                        case KeyEquivalent("a") where press.modifiers == .command:
                            selectAll()
                            return .handled
                        case KeyEquivalent("c") where press.modifiers == []:
                            if canGroup { groupSelected(); return .handled }
                            return .ignored
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
    
    // Expand the selection to include all group-mates of any selected grouped file,
    // so that move-up/down always treats a collate group as an indivisible block.
    private func expandForGroups(_ ids: Set<UUID>) -> Set<UUID> {
        var expanded = ids
        for id in ids {
            if let gid = combineManager.files.first(where: { $0.id == id })?.collateGroupId {
                combineManager.files.filter { $0.collateGroupId == gid }.forEach { expanded.insert($0.id) }
            }
        }
        return expanded
    }

    private var canMoveUp: Bool {
        guard !selectedFiles.isEmpty else { return false }
        let effective = expandForGroups(selectedFiles)
        // Enabled if at least one item in the effective set can actually shift up.
        return combineManager.files.indices.contains { index in
            guard effective.contains(combineManager.files[index].id) else { return false }
            guard index > 0 else { return false }
            return !effective.contains(combineManager.files[index - 1].id)
        }
    }

    private var canMoveDown: Bool {
        guard !selectedFiles.isEmpty else { return false }
        let effective = expandForGroups(selectedFiles)
        return combineManager.files.indices.contains { index in
            guard effective.contains(combineManager.files[index].id) else { return false }
            guard index < combineManager.files.count - 1 else { return false }
            return !effective.contains(combineManager.files[index + 1].id)
        }
    }

    /// True when 2+ selected files are all ungrouped — they can be collated together.
    private var canGroup: Bool {
        guard selectedFiles.count >= 2 else { return false }
        return selectedFiles.allSatisfy { id in
            combineManager.files.first(where: { $0.id == id })?.collateGroupId == nil
        }
    }
    
    private func selectFiles() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        menuState.isPanelOpen = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.title = "Select PDF Files or Folders"
        panel.message = "Select PDF files, or select a folder to add all PDFs inside it"

        panel.beginSheetModal(for: window) { response in
            self.menuState.isPanelOpen = false
            if response == .OK {
                let expanded = Self.expandToPDFs(panel.urls)
                self.combineManager.addFiles(urls: expanded, undoManager: self.undoManager)
            }
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url else { return }
                let expanded = Self.expandToPDFs([url])
                guard !expanded.isEmpty else { return }
                DispatchQueue.main.async {
                    self.combineManager.addFiles(urls: expanded, undoManager: self.undoManager)
                }
            }
        }
    }

    /// Expands a mixed list of file and folder URLs into a flat, sorted list of PDF URLs.
    /// Folders are enumerated recursively; non-PDF files are ignored.
    static func expandToPDFs(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let enumerator = fm.enumerator(at: url,
                                                     includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                for case let fileURL as URL in enumerator
                where fileURL.pathExtension.lowercased() == "pdf" {
                    result.append(fileURL)
                }
            } else if url.pathExtension.lowercased() == "pdf" {
                result.append(url)
            }
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    
    private func toggleSelection(_ id: UUID) {
        let isShiftHeld = NSEvent.modifierFlags.contains(.shift)

        if isShiftHeld,
           let anchor = anchorFileId,
           let anchorIndex = combineManager.files.firstIndex(where: { $0.id == anchor }),
           let clickedIndex = combineManager.files.firstIndex(where: { $0.id == id }) {
            // Range selection: select everything from anchor to clicked item.
            // Anchor stays fixed so further shift+clicks extend/shrink the range.
            let lo = min(anchorIndex, clickedIndex)
            let hi = max(anchorIndex, clickedIndex)
            selectedFiles = Set(combineManager.files[lo...hi].map { $0.id })
            focusedFileId = id
        } else {
            // Plain click: toggle this item and set it as the new anchor.
            if selectedFiles.contains(id) {
                selectedFiles.remove(id)
                if focusedFileId == id { focusedFileId = nil; anchorFileId = nil }
            } else {
                selectedFiles.insert(id)
                focusedFileId = id
                anchorFileId = id
            }
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
        unmatchedFileIds.subtract(selectedFiles)
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
        // Expand so entire collate groups always move as one block
        combineManager.moveUp(ids: expandForGroups(selectedFiles), undoManager: undoManager)
    }

    private func moveDown() {
        combineManager.moveDown(ids: expandForGroups(selectedFiles), undoManager: undoManager)
    }

    private func groupSelected() {
        guard canGroup else { return }
        combineManager.createCollateGroup(fileIds: selectedFiles, undoManager: undoManager)
        selectedFiles = []
        focusedFileId = nil
        anchorFileId = nil
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
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        menuState.isPanelOpen = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Combined.pdf"
        panel.title = "Save Combined PDF"

        panel.beginSheetModal(for: window) { response in
            menuState.isPanelOpen = false
            if response == .OK, let url = panel.url {
                combineManager.createCombinedPDF(to: url, addBlankPages: addBlankPages) { title, message, isError in
                    if isError {
                        showNSAlert(title: title, message: message, isError: true)
                    } else {
                        let alert = NSAlert()
                        alert.messageText = title
                        alert.informativeText = message
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        alert.addButton(withTitle: "Open in Preview")
                        if alert.runModal() == .alertSecondButtonReturn {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }
    
    private func openInPreview() {
        combineManager.openInPreview(addBlankPages: addBlankPages) { title, message, isError in
            showNSAlert(title: title, message: message, isError: isError)
        }
    }

    // MARK: - Menu state sync
    private func syncMenuClosures() {
        menuState.removeSelected          = removeSelected
        menuState.moveUp                  = moveUp
        menuState.moveDown                = moveDown
        menuState.selectAll               = selectAll
        menuState.group                   = groupSelected
        menuState.selectPrevious          = { navigateSelection(direction: -1, extending: false) }
        menuState.selectNext              = { navigateSelection(direction:  1, extending: false) }
        menuState.selectPreviousExtending = { navigateSelection(direction: -1, extending: true)  }
        menuState.selectNextExtending     = { navigateSelection(direction:  1, extending: true)  }
        syncMenuFlags()
    }

    private func syncMenuFlags() {
        menuState.canRemove   = !selectedFiles.isEmpty
        menuState.canMoveUp   = canMoveUp
        menuState.canMoveDown = canMoveDown
        menuState.canGroup    = canGroup
        menuState.hasFiles    = !combineManager.files.isEmpty
    }

    // MARK: - Apply Preset
    /// Applies copy counts from the given preset parts to the file list.
    /// Parts are matched against file names via case-insensitive substring search,
    /// longest part name first so "Bass Clarinet" wins over "Clarinet".
    /// Files that don't match any part are highlighted orange.
    @discardableResult
    private func applyPreset(parts: [PresetPart]) -> (matched: Int, unmatched: Int, unmatchedPartNames: Set<String>) {
        // Sort longest-name-first so "Bass Clarinet" wins over "Clarinet"
        let sortedParts = parts.sorted { $0.name.count > $1.name.count }
        var newUnmatched: Set<UUID> = []
        var matched = 0
        var matchedPartNames: Set<String> = []

        // ── Phase 1: direct match (with roman-numeral normalisation) ──────────
        for file in combineManager.files {
            let filename = normalizeRomanNumerals(file.name.lowercased())
            if let match = sortedParts.first(where: {
                filename.contains(normalizeRomanNumerals($0.name.lowercased()))
            }) {
                combineManager.updateCopies(for: file.id, copies: match.copies, undoManager: undoManager)
                matched += 1
                matchedPartNames.insert(match.name)
            } else {
                newUnmatched.insert(file.id)
            }
        }

        // ── Phase 2: consolidation ────────────────────────────────────────────
        // When ALL numbered siblings of a base name went unmatched AND exactly
        // one file contains that base name, sum their copies and apply to that file.
        // (Any more complex situation — 2 files vs 3 parts etc. — stays orange.)
        let unmatchedParts = parts.filter { !matchedPartNames.contains($0.name) }

        // Group unmatched parts by their (normalised) base name
        var baseGroups: [String: [PresetPart]] = [:]
        for part in unmatchedParts {
            if let base = numberedBase(of: part.name) {
                baseGroups[base, default: []].append(part)
            }
        }

        for (base, group) in baseGroups {
            // All preset parts with this base must be in the unmatched group
            let allWithBase = parts.filter { numberedBase(of: $0.name) == base }
            guard group.count == allWithBase.count else { continue }

            // Find still-unmatched files that contain the base name
            let candidates = newUnmatched.filter { id in
                guard let file = combineManager.files.first(where: { $0.id == id }) else { return false }
                return normalizeRomanNumerals(file.name.lowercased()).contains(base)
            }
            guard candidates.count == 1, let fileId = candidates.first else { continue }

            // Apply summed copies and mark everything resolved
            let total = group.reduce(0) { $0 + $1.copies }
            combineManager.updateCopies(for: fileId, copies: total, undoManager: undoManager)
            newUnmatched.remove(fileId)
            matched += 1
            for part in group { matchedPartNames.insert(part.name) }
        }

        unmatchedFileIds = newUnmatched
        let unmatchedPartNames = Set(parts.map(\.name)).subtracting(matchedPartNames)
        return (matched: matched, unmatched: newUnmatched.count, unmatchedPartNames: unmatchedPartNames)
    }
}

// MARK: - Combine File Row
struct CombineFileRow: View {
    let file: CombineFile
    let isSelected: Bool
    let isFocused: Bool
    let isUnmatched: Bool
    /// True when this file belongs to a collate group (indents row, hides copies stepper).
    var isGrouped: Bool = false
    let onToggleSelect: () -> Void
    let onCopiesChanged: (Int) -> Void
    let onRemove: () -> Void

    @State private var isEditingCopies = false
    @State private var copiesText = ""
    @FocusState private var copiesFieldFocused: Bool

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundColor(isSelected ? .accentColor : .secondary)

            Text(file.name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
                // Indent grouped files so they visually sit under the group header
                .padding(.leading, isGrouped ? 14 : 0)

            Text("\(file.pageCount)")
                .frame(width: 80, alignment: .center)
                .foregroundColor(.secondary)

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
        .background(
            isSelected
                ? Color.accentColor.opacity(isFocused ? 0.18 : 0.1)
                : isUnmatched ? Color.orange.opacity(0.12) : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture { onToggleSelect() }
        .onChange(of: copiesFieldFocused) { focused in
            if !focused && isEditingCopies { commitCopiesEdit() }
        }
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
                    .foregroundColor(.accentColor)
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
        .background(Color.accentColor.opacity(0.07))
        .onChange(of: copiesFocused) { focused in
            if !focused && isEditingCopies { commitEdit() }
        }
    }

    private func commitEdit() {
        if let value = Int(copiesText), value >= 1 { onCopiesChanged(value) }
        isEditingCopies = false
    }
}


// MARK: - Preset Part Row (shared by sidebar and preferences)
/// One row in a parts list. Minus at copies == 1 deletes the part.
/// Double-click the copy count to type a number directly.
struct PresetPartRow: View {
    @Binding var part: PresetPart
    var isUnmatched: Bool = false
    var onMarkDirty: () -> Void
    var onDelete: () -> Void

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
        .onChange(of: nameFocused) { focused in
            if !focused && isEditingName { commitNameEdit() }
        }
        .onChange(of: copiesFocused) { focused in
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

/// When a numbered part is deleted, any sibling that is now the sole survivor of its
/// base name loses its trailing number.
/// Example: delete "Horn 2" → "Horn 1" becomes "Horn".
/// Does nothing if siblings remain (e.g. deleting "Clarinet 3" while "Clarinet 1/2" still exist).
// MARK: - Preset matching helpers

/// Converts a trailing roman numeral part number (I/II/III/IV) to arabic (1/2/3/4).
/// Input must already be lowercased. Checks longest suffix first to avoid IV→I collision.
/// Only matches when preceded by a space, preventing false hits on words like "celli".
func normalizeRomanNumerals(_ s: String) -> String {
    let pairs: [(String, String)] = [(" iv", " 4"), (" iii", " 3"), (" ii", " 2"), (" i", " 1")]
    for (roman, arabic) in pairs {
        if s.hasSuffix(roman) { return String(s.dropLast(roman.count)) + arabic }
    }
    return s
}

/// Returns the base name (lowercased) if the name ends with a trailing part number
/// (arabic or roman numeral), otherwise nil.
/// E.g. "Violin II" → "violin",  "Flute 1" → "flute",  "Tuba" → nil
func numberedBase(of name: String) -> String? {
    let normalized = normalizeRomanNumerals(name.lowercased())
    let words = normalized.split(separator: " ")
    guard words.count >= 2, Int(String(words.last!)) != nil else { return nil }
    return words.dropLast().joined(separator: " ")
}

/// After removing a part, strips the trailing number/numeral from any sibling that is now
/// the sole survivor of its base name.
/// E.g. delete "Horn 2" → "Horn 1" becomes "Horn"; delete "Violin II" → "Violin I" becomes "Violin".
func renumberAfterDeletion(_ parts: [PresetPart]) -> [PresetPart] {
    // Count remaining parts per base name (using normalised comparison)
    var baseCounts: [String: Int] = [:]
    for part in parts {
        if let base = numberedBase(of: part.name) {
            baseCounts[base, default: 0] += 1
        }
    }
    // Strip the trailing word (the number or numeral) from solo survivors
    return parts.map { part in
        if let base = numberedBase(of: part.name), baseCounts[base] == 1 {
            var renamed = part
            // Drop the last word from the *original* name to preserve capitalisation
            let words = part.name.split(separator: " ", omittingEmptySubsequences: true)
            renamed.name = words.dropLast().joined(separator: " ")
            return renamed
        }
        return part
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
    let onApply: (_ parts: [PresetPart]) -> (matched: Int, unmatched: Int, unmatchedPartNames: Set<String>)

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
                .padding(.vertical, 10)

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
                        applyResult = onApply(draftParts)
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
        .onChange(of: presetStore.selectedPresetId) { _ in loadDraft() }
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

// MARK: - Keyboard Shortcuts Help
struct ShortcutsHelpView: View {
    var onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Keyboard Shortcuts")
                    .font(.title2)
                    .fontWeight(.semibold)

                shortcutSection("Combine — File List Navigation") {
                    shortcutRow("↑ / ↓", "Select previous / next file")
                    shortcutRow("⇧↑ / ⇧↓", "Extend selection up / down")
                    shortcutRow("⌘A", "Select all files")
                }

                shortcutSection("Combine — File Management") {
                    shortcutRow("⌫", "Remove selected files")
                    shortcutRow("⌘↑ / ⌘↓", "Move selected files up / down")
                    shortcutRow("C", "Group selected files into a collate set")
                    shortcutRow("⌘Z / ⌘⇧Z", "Undo / Redo")
                }

                shortcutSection("Combine — Collate Groups") {
                    shortcutRow("C", "Create group from selected files")
                    shortcutRow("↗ button", "Dissolve group (restore files individually)")
                }

                shortcutSection("Combine — Ensemble Presets") {
                    shortcutRow("Presets button", "Toggle preset sidebar (top-right of toolbar)")
                    shortcutRow("⌘,", "Open Preferences — create & edit presets")
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

                HStack {
                    Spacer()
                    Button("Done") { onDismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 4)
            }
            .padding(36)
        }
        .frame(width: 460)
        .frame(maxHeight: 580)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 8)
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

// MARK: - Ensemble Preset Model

struct PresetPart: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var copies: Int
}

struct EnsemblePreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var parts: [PresetPart]
}

class EnsemblePresetStore: ObservableObject {
    @Published var presets: [EnsemblePreset] = []
    @Published var selectedPresetId: UUID?

    var selectedPreset: EnsemblePreset? {
        presets.first { $0.id == selectedPresetId }
    }

    private var storeURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = dir.appendingPathComponent("Music PDF Manager", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("ensemble-presets.json")
    }

    init() {
        load()
        if selectedPresetId == nil { selectedPresetId = presets.first?.id }
    }

    func save() {
        guard let url = storeURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(presets) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        guard let url = storeURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([EnsemblePreset].self, from: data)
        else { return }
        presets = decoded
        selectedPresetId = presets.first?.id
    }

    func addPreset(name: String, parts: [PresetPart]) {
        let p = EnsemblePreset(name: name, parts: parts)
        presets.append(p)
        selectedPresetId = p.id
        save()
    }

    func updatePreset(_ preset: EnsemblePreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
            save()
        }
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if selectedPresetId == id {
            selectedPresetId = presets.first?.id
        }
        save()
    }

    func movePresets(from: IndexSet, to: Int) {
        presets.move(fromOffsets: from, toOffset: to)
        save()
    }

    // MARK: - Built-in templates

    static let windBandTemplate: [PresetPart] = [
        "Score",
        "Piccolo", "Flute 1", "Flute 2",
        "Oboe", "Bassoon",
        "Clarinet 1", "Clarinet 2", "Clarinet 3",
        "Bass Clarinet",
        "Alto Saxophone 1", "Alto Saxophone 2",
        "Tenor Saxophone", "Baritone Saxophone",
        "Trumpet 1", "Trumpet 2", "Trumpet 3",
        "Horn 1", "Horn 2",
        "Trombone 1", "Trombone 2", "Bass Trombone",
        "Euphonium", "Tuba",
        "Timpani",
        "Percussion 1", "Percussion 2", "Percussion 3",
    ].map { PresetPart(name: $0, copies: 1) }

    static let jazzTemplate: [PresetPart] = [
        "Score",
        "Alto Saxophone 1", "Alto Saxophone 2",
        "Tenor Saxophone 1", "Tenor Saxophone 2",
        "Baritone Saxophone",
        "Trumpet 1", "Trumpet 2", "Trumpet 3", "Trumpet 4",
        "Trombone 1", "Trombone 2", "Trombone 3", "Bass Trombone",
        "Guitar", "Piano", "Bass", "Drums",
    ].map { PresetPart(name: $0, copies: 1) }

    static let orchestraTemplate: [PresetPart] = [
        "Score",
        "Flute 1", "Flute 2", "Piccolo",
        "Oboe 1", "Oboe 2",
        "Clarinet 1", "Clarinet 2",
        "Bassoon 1", "Bassoon 2",
        "Horn 1", "Horn 2", "Horn 3", "Horn 4",
        "Trumpet 1", "Trumpet 2",
        "Trombone 1", "Trombone 2", "Bass Trombone",
        "Tuba",
        "Timpani", "Percussion",
        "Harp",
        "Violin I", "Violin II",
        "Viola", "Cello", "Double Bass",
    ].map { PresetPart(name: $0, copies: 1) }
}

// MARK: - Combine File Model

/// A named group of files whose pages are interleaved (collated) when combining.
/// e.g. 4 copies of [Perc1, Perc2, Timpani] → Perc1, Perc2, Timp, Perc1, Perc2, Timp, …
struct CollateGroup: Identifiable, Equatable {
    let id: UUID
    var copies: Int
}

struct CombineFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let name: String
    let pageCount: Int
    var copies: Int
    /// Non-nil when this file is part of a collate group.
    var collateGroupId: UUID? = nil
}

// MARK: - Combine Manager
class CombineManager: ObservableObject {
    @Published var files: [CombineFile] = []
    @Published var collateGroups: [UUID: CollateGroup] = [:]

    // ── Totals ────────────────────────────────────────────────────────────────
    // Collate groups: N copies of the whole set  (fileCount × copies pages).
    // Standalone files: copies × their own page count.
    var totalFiles: Int {
        var count = 0
        var i = 0
        while i < files.count {
            if let gid = files[i].collateGroupId, let g = collateGroups[gid] {
                var n = 0
                while i < files.count && files[i].collateGroupId == gid { n += 1; i += 1 }
                count += n * g.copies
            } else {
                count += files[i].copies; i += 1
            }
        }
        return count
    }

    var totalPages: Int {
        var count = 0
        var i = 0
        while i < files.count {
            if let gid = files[i].collateGroupId, let g = collateGroups[gid] {
                var p = 0
                while i < files.count && files[i].collateGroupId == gid { p += files[i].pageCount; i += 1 }
                count += p * g.copies
            } else {
                count += files[i].pageCount * files[i].copies; i += 1
            }
        }
        return count
    }

    // ── Undo ──────────────────────────────────────────────────────────────────
    // Snapshots both files and collateGroups so undo/redo always restores a
    // consistent pair.
    private func registerUndo(undoManager: UndoManager?, actionName: String,
                              restoringFiles beforeFiles: [CombineFile],
                              restoringGroups beforeGroups: [UUID: CollateGroup]) {
        let postFiles  = files
        let postGroups = collateGroups
        undoManager?.setActionName(actionName)
        undoManager?.registerUndo(withTarget: self) { manager in
            manager.files         = beforeFiles
            manager.collateGroups = beforeGroups
            manager.registerUndo(undoManager: undoManager, actionName: actionName,
                                 restoringFiles: postFiles, restoringGroups: postGroups)
        }
    }

    // ── File management ───────────────────────────────────────────────────────
    func addFiles(urls: [URL], undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        for url in urls {
            guard let document = PDFDocument(url: url) else { continue }
            files.append(CombineFile(url: url, name: url.lastPathComponent, pageCount: document.pageCount, copies: 1))
        }
        if files.count != bf.count {
            registerUndo(undoManager: undoManager, actionName: "Add Files",
                         restoringFiles: bf, restoringGroups: bg)
        }
    }

    func removeFiles(ids: Set<UUID>, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        files.removeAll { ids.contains($0.id) }
        // Dissolve any group that now has fewer than 2 members
        var toDissolve: [UUID] = []
        for gid in collateGroups.keys {
            if files.filter({ $0.collateGroupId == gid }).count < 2 { toDissolve.append(gid) }
        }
        for gid in toDissolve {
            for i in files.indices where files[i].collateGroupId == gid { files[i].collateGroupId = nil }
            collateGroups.removeValue(forKey: gid)
        }
        registerUndo(undoManager: undoManager, actionName: "Remove File",
                     restoringFiles: bf, restoringGroups: bg)
    }

    func clearAll(undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        files.removeAll()
        collateGroups.removeAll()
        registerUndo(undoManager: undoManager, actionName: "Clear All",
                     restoringFiles: bf, restoringGroups: bg)
    }

    func updateCopies(for id: UUID, copies: Int, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        if let index = files.firstIndex(where: { $0.id == id }) {
            files[index].copies = max(1, copies)
        }
        registerUndo(undoManager: undoManager, actionName: "Change Copies",
                     restoringFiles: bf, restoringGroups: bg)
    }

    // ── Reordering ────────────────────────────────────────────────────────────
    func moveUp(ids: Set<UUID>, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        // Process ascending so adjacent items move as a block.
        let selectedIndices = files.indices.filter { ids.contains(files[$0].id) }.sorted()
        for index in selectedIndices {
            guard index > 0 else { continue }
            guard !ids.contains(files[index - 1].id) else { continue }
            files.swapAt(index, index - 1)
        }
        if files.map(\.id) != bf.map(\.id) {
            registerUndo(undoManager: undoManager, actionName: "Move Up",
                         restoringFiles: bf, restoringGroups: bg)
        }
    }

    func moveDown(ids: Set<UUID>, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        // Process descending for the same block-preservation reason.
        let selectedIndices = files.indices.filter { ids.contains(files[$0].id) }.sorted().reversed()
        for index in selectedIndices {
            guard index < files.count - 1 else { continue }
            guard !ids.contains(files[index + 1].id) else { continue }
            files.swapAt(index, index + 1)
        }
        if files.map(\.id) != bf.map(\.id) {
            registerUndo(undoManager: undoManager, actionName: "Move Down",
                         restoringFiles: bf, restoringGroups: bg)
        }
    }

    // ── Collate groups ────────────────────────────────────────────────────────
    /// Groups the given files into a collate set, pulling them together
    /// contiguously at the position of the first selected file.
    func createCollateGroup(fileIds: Set<UUID>, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        let orderedIndices = files.indices.filter { fileIds.contains(files[$0].id) }
        guard orderedIndices.count >= 2 else { return }

        let insertionIndex = orderedIndices.first!
        let groupFilesInOrder = orderedIndices.map { files[$0] }

        // Remove in reverse order so lower indices stay stable
        for idx in orderedIndices.reversed() { files.remove(at: idx) }

        // All removed files had index >= insertionIndex, so insertionIndex is unchanged
        let newGroupId = UUID()
        for (offset, var file) in groupFilesInOrder.enumerated() {
            file.collateGroupId = newGroupId
            files.insert(file, at: insertionIndex + offset)
        }
        collateGroups[newGroupId] = CollateGroup(id: newGroupId, copies: 1)

        registerUndo(undoManager: undoManager, actionName: "Group Files",
                     restoringFiles: bf, restoringGroups: bg)
    }

    /// Dissolves a collate group, restoring its files as independent entries.
    func dissolveGroup(id: UUID, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        for i in files.indices where files[i].collateGroupId == id { files[i].collateGroupId = nil }
        collateGroups.removeValue(forKey: id)
        registerUndo(undoManager: undoManager, actionName: "Ungroup Files",
                     restoringFiles: bf, restoringGroups: bg)
    }

    func updateGroupCopies(id: UUID, copies: Int, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        collateGroups[id]?.copies = max(1, copies)
        registerUndo(undoManager: undoManager, actionName: "Change Copies",
                     restoringFiles: bf, restoringGroups: bg)
    }

    // ── PDF output ────────────────────────────────────────────────────────────
    // Standalone files: all copies of that file together (existing behaviour).
    // Collate groups: the set of files repeats N times interleaved —
    //   [file1, file2, file3] × 4 → f1,f2,f3, f1,f2,f3, f1,f2,f3, f1,f2,f3
    func createCombinedPDF(to url: URL, addBlankPages: Bool, completion: PDFAlertHandler) {
        let doc = PDFDocument()
        var idx = 0

        func addPages(from file: CombineFile) {
            guard let src = PDFDocument(url: file.url) else { return }
            for p in 0..<src.pageCount {
                if let page = src.page(at: p) { doc.insert(page, at: idx); idx += 1 }
            }
            if addBlankPages && src.pageCount % 2 == 1 {
                if let blank = createBlankPage() { doc.insert(blank, at: idx); idx += 1 }
            }
        }

        var i = 0
        while i < files.count {
            if let gid = files[i].collateGroupId, let group = collateGroups[gid] {
                var groupFiles: [CombineFile] = []
                while i < files.count && files[i].collateGroupId == gid { groupFiles.append(files[i]); i += 1 }
                for _ in 0..<group.copies { for f in groupFiles { addPages(from: f) } }
            } else {
                let file = files[i]; i += 1
                for _ in 0..<file.copies { addPages(from: file) }
            }
        }

        if doc.write(to: url) {
            completion("PDF Created Successfully",
                       "Combined PDF with \(idx) pages saved to:\n\(url.path)", false)
        } else {
            completion("Error", "Failed to create PDF", true)
        }
    }

    func openInPreview(addBlankPages: Bool, onError: PDFAlertHandler) {
        let doc = PDFDocument()
        var idx = 0

        func addPages(from file: CombineFile) {
            guard let src = PDFDocument(url: file.url) else { return }
            for p in 0..<src.pageCount {
                if let page = src.page(at: p) { doc.insert(page, at: idx); idx += 1 }
            }
            if addBlankPages && src.pageCount % 2 == 1 {
                if let blank = createBlankPage() { doc.insert(blank, at: idx); idx += 1 }
            }
        }

        var i = 0
        while i < files.count {
            if let gid = files[i].collateGroupId, let group = collateGroups[gid] {
                var groupFiles: [CombineFile] = []
                while i < files.count && files[i].collateGroupId == gid { groupFiles.append(files[i]); i += 1 }
                for _ in 0..<group.copies { for f in groupFiles { addPages(from: f) } }
            } else {
                let file = files[i]; i += 1
                for _ in 0..<file.copies { addPages(from: file) }
            }
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("CombinedForPrint.pdf")
        guard doc.write(to: tempURL) else { onError("Error", "Failed to create temporary PDF", true); return }
        NSWorkspace.shared.open(tempURL)
    }

    private func createBlankPage() -> PDFPage? {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let blankPage = PDFPage()
        blankPage.setBounds(pageRect, for: .mediaBox)
        return blankPage
    }
}

// MARK: - Renamer View
struct RenamerView: View {
    @EnvironmentObject private var renamerManager: RenamerManager
    @Environment(\.openSettings) private var openSettings
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
                
                if renamerManager.hasContent {
                    Button(action: { renamerManager.rescanFolder() }) {
                        Label("Check for Errors", systemImage: "checkmark.circle")
                    }
                    .help("Rescan all files and suggest corrections")
                    
                    Button(action: { openSettings() }) {
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
            if renamerManager.hasContent {
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
    }
    
    private var folderSelectionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 64))
                .foregroundColor(isFolderTargeted ? .accentColor : .secondary)

            Text("Select Files or Folder")
                .font(.title2)
                .fontWeight(.medium)

            Text("This tool will add sequential prefixes to your sheet music files\nbased on detected instrument names")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Text("Drag a folder or PDF files here")
                .font(.callout)
                .foregroundColor(isFolderTargeted ? .accentColor : .secondary)

            Text("or")
                .foregroundColor(.secondary)

            Button(action: selectFolder) {
                Label("Choose Files or Folder", systemImage: "folder")
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
            // Collect all dropped URLs, then decide: folder → loadFolder, files → loadFiles
            var collectedURLs: [URL] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { collectedURLs.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                guard !collectedURLs.isEmpty else { return }
                // If the first URL is a directory, treat it as a folder load
                var isDirectory: ObjCBool = false
                if collectedURLs.count == 1,
                   FileManager.default.fileExists(atPath: collectedURLs[0].path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    renamerManager.loadFolder(url: collectedURLs[0])
                } else {
                    renamerManager.loadFiles(urls: collectedURLs)
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
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .folder]
        panel.canCreateDirectories = false
        panel.title = "Select PDF Files or Folder"
        panel.message = "Choose a folder, or select individual PDF files to rename"

        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            // If a single directory was chosen, use folder mode
            var isDirectory: ObjCBool = false
            if urls.count == 1,
               FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                renamerManager.loadFolder(url: urls[0])
            } else {
                renamerManager.loadFiles(urls: urls)
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
            guard let first = affectedNumbers.first, let last = affectedNumbers.last else {
                return ""
            }
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

// MARK: - App Preferences View (Settings scene root — two tabs)
struct AppPreferencesView: View {
    @EnvironmentObject var renamerManager: RenamerManager
    @EnvironmentObject var presetStore: EnsemblePresetStore

    var body: some View {
        TabView {
            PreferencesView(
                ensembleType: $renamerManager.ensembleType,
                instrumentOrder: $renamerManager.customInstrumentOrder
            )
            .tabItem { Label("Renamer", systemImage: "folder.badge.gearshape") }

            CombinerPreferencesView()
                .tabItem { Label("Combiner", systemImage: "doc.on.doc") }
        }
        .frame(width: 680, height: 720)
    }
}

// MARK: - Combiner Preferences View
struct CombinerPreferencesView: View {
    @EnvironmentObject var presetStore: EnsemblePresetStore
    @State private var selectedId: UUID?
    @State private var editingPreset: EnsemblePreset?
    @State private var newPartName: String = ""
    @State private var showingAddPreset = false

    var body: some View {
        HSplitView {
            // Left panel: preset list
            VStack(spacing: 0) {
                List(selection: $selectedId) {
                    ForEach(presetStore.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                    .onMove { from, to in
                        presetStore.movePresets(from: from, to: to)
                    }
                }
                .listStyle(.bordered)

                Divider()

                HStack(spacing: 0) {
                    Button { showingAddPreset = true } label: {
                        Image(systemName: "plus")
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain)

                    Button {
                        if let id = selectedId {
                            presetStore.deletePreset(id)
                            selectedId = presetStore.presets.first?.id
                            editingPreset = presetStore.selectedPreset
                        }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(presetStore.presets.count <= 1)

                    Divider()
                        .frame(height: 16)
                        .padding(.horizontal, 2)

                    // Up / Down reorder buttons
                    Button {
                        guard let id = selectedId,
                              let idx = presetStore.presets.firstIndex(where: { $0.id == id }),
                              idx > 0 else { return }
                        presetStore.movePresets(from: [idx], to: idx - 1)
                    } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled({
                        guard let id = selectedId,
                              let idx = presetStore.presets.firstIndex(where: { $0.id == id })
                        else { return true }
                        return idx == 0
                    }())

                    Button {
                        guard let id = selectedId,
                              let idx = presetStore.presets.firstIndex(where: { $0.id == id }),
                              idx < presetStore.presets.count - 1 else { return }
                        presetStore.movePresets(from: [idx], to: idx + 2)
                    } label: {
                        Image(systemName: "chevron.down")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled({
                        guard let id = selectedId,
                              let idx = presetStore.presets.firstIndex(where: { $0.id == id })
                        else { return true }
                        return idx == presetStore.presets.count - 1
                    }())

                    Spacer()
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .frame(minWidth: 160, idealWidth: 180, maxWidth: 220)

            // Right panel: edit selected preset
            if editingPreset != nil {
                VStack(alignment: .leading, spacing: 0) {
                    // Name
                    HStack {
                        Text("Name:")
                            .fontWeight(.medium)
                        TextField("Preset name", text: Binding(
                            get: { editingPreset?.name ?? "" },
                            set: { editingPreset?.name = $0; saveEditing() }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    .padding(12)

                    Divider()

                    Text("Parts (drag to reorder):")
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                    List {
                        ForEach(editingPreset?.parts ?? [], id: \.id) { part in
                            PresetPartRow(
                                part: Binding(
                                    get: {
                                        editingPreset?.parts.first { $0.id == part.id } ?? part
                                    },
                                    set: { newVal in
                                        if let idx = editingPreset?.parts.firstIndex(where: { $0.id == part.id }) {
                                            editingPreset?.parts[idx] = newVal
                                        }
                                    }
                                ),
                                onMarkDirty: { saveEditing() },
                                onDelete: {
                                    editingPreset?.parts.removeAll { $0.id == part.id }
                                    if let updated = editingPreset?.parts {
                                        editingPreset?.parts = renumberAfterDeletion(updated)
                                    }
                                    saveEditing()
                                }
                            )
                        }
                        .onMove { from, to in
                            editingPreset?.parts.move(fromOffsets: from, toOffset: to)
                            saveEditing()
                        }
                    }
                    .listStyle(.bordered)

                    // Add part
                    HStack {
                        TextField("Add part...", text: $newPartName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addPart() }
                        Button(action: addPart) {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newPartName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(12)

                    Divider()

                    HStack {
                        Menu("Reset to Template…") {
                            Button("Wind Band") {
                                editingPreset?.parts = EnsemblePresetStore.windBandTemplate
                                saveEditing()
                            }
                            Button("Jazz Band") {
                                editingPreset?.parts = EnsemblePresetStore.jazzTemplate
                                saveEditing()
                            }
                            Button("Orchestra") {
                                editingPreset?.parts = EnsemblePresetStore.orchestraTemplate
                                saveEditing()
                            }
                        }
                        .buttonStyle(.bordered)
                        .fixedSize()
                        Spacer()
                    }
                    .padding(12)
                }
            } else {
                VStack {
                    Text(presetStore.presets.isEmpty
                         ? "No presets — click + to create one"
                         : "Select a preset to edit")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            selectedId = presetStore.presets.first?.id
            editingPreset = presetStore.presets.first
        }
        .onChange(of: selectedId) { newId in
            editingPreset = presetStore.presets.first { $0.id == newId }
        }
        // Keep the right panel in sync when the store is changed externally
        // (e.g. "Save to Preset" from the sidebar while preferences is open).
        // Since saveEditing() always writes before this fires, reloading is safe.
        .onChange(of: presetStore.presets) { updated in
            guard let id = selectedId,
                  let fresh = updated.first(where: { $0.id == id }),
                  fresh != editingPreset else { return }
            editingPreset = fresh
        }
        .sheet(isPresented: $showingAddPreset) {
            NewPresetSheet { name, parts in
                presetStore.addPreset(name: name, parts: parts)
                selectedId = presetStore.presets.last?.id
                editingPreset = presetStore.presets.last
            }
        }
    }

    private func addPart() {
        let trimmed = newPartName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        editingPreset?.parts.append(PresetPart(name: trimmed, copies: 1))
        saveEditing()
        newPartName = ""
    }

    private func saveEditing() {
        if let p = editingPreset { presetStore.updatePreset(p) }
    }
}

// MARK: - Renamer Manager
class RenamerManager: ObservableObject {
    @Published var folderURL: URL?
    /// Files loaded directly (when the user drags in individual PDFs rather than a folder).
    @Published private(set) var directFiles: [URL] = []
    @Published var operations: [RenameOperation] = []
    @Published var ensembleType: EnsembleType = .band {
        didSet {
            if !hasCustomOrder {
                customInstrumentOrder = InstrumentOrders.getOrder(for: ensembleType)
            }
            if hasContent {
                scanFolder()
            }
        }
    }
    @Published var customInstrumentOrder: [String] = InstrumentOrders.getOrder(for: .band) {
        didSet {
            hasCustomOrder = true
            if hasContent {
                scanFolder()
            }
        }
    }

    /// True when there is either a folder loaded or direct files loaded.
    var hasContent: Bool { folderURL != nil || !directFiles.isEmpty }

    private var hasCustomOrder = false
    var manualOverrides: [String: Int] = [:]
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
        self.directFiles = []
        self.manualOverrides = [:]
        self.isRescanMode = false
        scanFolder()
    }

    /// Load individual PDF files directly (no enclosing folder required).
    func loadFiles(urls: [URL]) {
        self.folderURL = nil
        self.directFiles = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        self.manualOverrides = [:]
        self.isRescanMode = false
        scanFolder()
    }

    func clearFolder() {
        self.folderURL = nil
        self.directFiles = []
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
    
    /// In rescan mode, strips an existing `NN - ` / `NN_` / `NN ` prefix and
    /// returns the clean name plus the old two-digit prefix string.
    /// In normal mode returns the filename unchanged with a nil prefix.
    private func stripRescanPrefix(from filename: String) -> (clean: String, oldPrefix: String?) {
        if isRescanMode, let match = filename.range(of: "^(\\d{2})", options: .regularExpression) {
            let oldPrefix = String(filename[match])
            let clean = String(filename[match.upperBound...])
                .replacingOccurrences(of: "^[-_\\s]+", with: "", options: .regularExpression)
            return (clean, oldPrefix)
        }
        return (filename, nil)
    }

    private func scanFolder() {
        operations = []

        // Build the list of PDF files to process: either directly-supplied URLs
        // or everything enumerated from the chosen folder.
        var pdfFiles: [URL]
        if !directFiles.isEmpty {
            pdfFiles = directFiles
        } else if let folderURL = folderURL {
            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(at: folderURL,
                                                          includingPropertiesForKeys: [.isRegularFileKey]) else {
                return
            }
            pdfFiles = []
            for case let fileURL as URL in enumerator
            where fileURL.pathExtension.lowercased() == "pdf" {
                pdfFiles.append(fileURL)
            }
            pdfFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
        } else {
            return
        }
        
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

        let fileManager = FileManager.default

        // Process score files (all get 00)
        for (url, originalName, _) in scoreFiles {
            let prefix = "00"
            let (cleanName, oldPrefix) = stripRescanPrefix(from: originalName)

            let newFilename = "\(prefix) - \(cleanName)"
            let newURL = url.deletingLastPathComponent().appendingPathComponent(newFilename)
            
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
            while reservedNumbers.contains(nextNumber) && nextNumber < 100 { nextNumber += 1 }
            let prefix = String(format: "%02d", nextNumber)
            nextNumber += 1
            let (cleanName, oldPrefix) = stripRescanPrefix(from: originalName)
            
            let newFilename = "\(prefix) - \(cleanName)"
            let newURL = url.deletingLastPathComponent().appendingPathComponent(newFilename)

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
            let (cleanName, _) = stripRescanPrefix(from: originalName)
            
            let newFilename = "\(prefix) - \(cleanName)"
            let newURL = url.deletingLastPathComponent().appendingPathComponent(newFilename)

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
    
    func detectInstrument(in filename: String) -> (Int, String)? {
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
                ) { title, message, isError in
                    showNSAlert(title: title, message: message, isError: isError)
                }
            }
            isShowingSavePanel = false
        }
    }
}

// MARK: - Split Logic (pure functions, extracted for testability)

/// Returns a new sizes array with a split toggled at `page` (0-based).
/// If `page` is the start of an existing file, that file merges with the one before it.
/// If `page` is mid-file, the file containing it is split at that position.
func toggleSplit(in sizes: [Int], at page: Int) -> [Int] {
    guard page > 0, !sizes.isEmpty else { return sizes }
    var result = sizes
    var pos = 0
    for (i, size) in result.enumerated() {
        if page >= pos && page < pos + size {
            let localPos = page - pos
            if localPos == 0 {
                if i > 0 {
                    result[i - 1] += result[i]
                    result.remove(at: i)
                }
            } else {
                let firstPart = localPos
                let secondPart = size - localPos
                result[i] = firstPart
                result.insert(secondPart, at: i + 1)
            }
            return result
        }
        pos += size
    }
    return result
}

/// Returns a sizes array that evenly divides `totalPages` into chunks of `stride`,
/// with the last chunk taking any remainder.
func splitSizes(totalPages: Int, stride: Int) -> [Int] {
    guard totalPages > 0, stride > 0 else { return [] }
    var sizes: [Int] = []
    var remaining = totalPages
    while remaining > 0 {
        let chunk = min(stride, remaining)
        sizes.append(chunk)
        remaining -= chunk
    }
    return sizes
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
    /// Shared pan offset for all naming-stage previews (PDF points from the default top-left position).
    /// Reset whenever a new PDF is loaded so it always starts at the instrument-name corner.
    @State private var previewOffset: CGPoint = .zero
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
                previewOffset: $previewOffset,
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
                previewOffset = .zero
            } else {
                fileSizes = []
                currentPage = 0
                customFileNames.removeAll()
                previewOffset = .zero
            }
        }
    } // end splitStageBody
    
    private func clearAllMarkers() {
        fileSizes = totalPages > 0 ? [totalPages] : []
        customFileNames.removeAll()
    }

    private func applyStride() {
        fileSizes = splitSizes(totalPages: totalPages, stride: stride)
        customFileNames.removeAll()
    }

    private func toggleSplitAt(page: Int) {
        fileSizes = toggleSplit(in: fileSizes, at: page)
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
                ) { title, message, isError in
                    showNSAlert(title: title, message: message, isError: isError)
                }
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

/// Shared validation used by SplitNamingStageView and SplitFileNamingRow.
func pdfFilenameError(for text: String) -> String? {
    guard !text.isEmpty else { return nil }
    let illegal = CharacterSet(charactersIn: "/:\\\0")
    if text.unicodeScalars.contains(where: { illegal.contains($0) }) {
        return "Cannot contain / : or \\"
    }
    return nil
}

// MARK: - Split Naming Stage (Step 2)
/// Full-window Step 2: lets users set the base filename and per-file name suffixes,
/// with a large first-page thumbnail for each output file.
struct SplitNamingStageView: View {
    let pdfDocument: PDFDocument
    let fileSizes: [Int]
    @Binding var baseFileName: String
    @Binding var customFileNames: [Int: String]
    @Binding var previewOffset: CGPoint
    let onBack: () -> Void
    let onSave: () -> Void

    /// Step sizes in PDF points. Vertical = half of the 100 pt crop height;
    /// horizontal = half of the 200 pt max crop width → 50% overlap each step.
    private let stepV: CGFloat = 50
    private let stepH: CGFloat = 100

    @FocusState private var focusedField: Int?

    var numberOfFiles: Int { fileSizes.count }

    /// Page index of the first page in a given file.
    private func firstPageIndex(for fileIndex: Int) -> Int {
        fileSizes.prefix(fileIndex).reduce(0, +)
    }

    /// Ordered, deduplicated instrument name list built from InstrumentOrders
    /// (orchestra → band → jazz), capitalised first letter only.
    private var instrumentNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in InstrumentOrders.orchestra + InstrumentOrders.band + InstrumentOrders.jazz {
            let key = name.lowercased()
            if seen.insert(key).inserted {
                result.append(name.capitalized)
            }
        }
        return result
    }

    private var baseNameError: String? {
        filenameError(for: baseFileName)
    }

    private var anySuffixError: Bool {
        customFileNames.values.contains { filenameError(for: $0) != nil }
    }

    private var canSave: Bool {
        numberOfFiles >= 2 && baseNameError == nil && !anySuffixError
    }

    private func filenameError(for text: String) -> String? { pdfFilenameError(for: text) }

    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar ──────────────────────────────────────────────────
            HStack {
                Text("Step 2: Name Files")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                // Pan controls — move the crop window on ALL preview strips simultaneously
                HStack(spacing: 2) {
                    Text("Preview:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button { previewOffset.y += stepV } label: {
                        Image(systemName: "arrow.up")
                    }
                    .help("Shift previews up")
                    Button { previewOffset.y -= stepV } label: {
                        Image(systemName: "arrow.down")
                    }
                    .help("Shift previews down")
                    Button { previewOffset.x -= stepH } label: {
                        Image(systemName: "arrow.left")
                    }
                    .help("Shift previews left")
                    Button { previewOffset.x += stepH } label: {
                        Image(systemName: "arrow.right")
                    }
                    .help("Shift previews right")
                    if previewOffset != .zero {
                        Button { previewOffset = .zero } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .help("Reset preview position")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // ── Base filename ─────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Base Filename:")
                        .font(.headline)
                        .fixedSize()

                    TextField("e.g. Symphony No. 5", text: $baseFileName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 380)

                    Text("Suffixes appended directly: \(baseFileName.isEmpty ? "basename" : baseFileName)Flute.pdf  ·  Leave blank for auto-numbering: \(baseFileName.isEmpty ? "basename" : baseFileName)_1.pdf")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()
                }

                if let err = baseNameError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
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
                                fieldFocus: $focusedField,
                                instrumentNames: instrumentNames,
                                allSuffixes: customFileNames,
                                previewOffset: previewOffset
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
                .disabled(!canSave)
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
    let instrumentNames: [String]   // ordered, deduplicated, capitalised
    let allSuffixes: [Int: String]  // snapshot of all rows' current suffixes
    var previewOffset: CGPoint = .zero

    private var isFieldFocused: Bool { fieldFocus.wrappedValue == fileIndex }

    // Arrow-key selection index into the suggestions list (nil = field, not dropdown)
    @State private var selectedSuggestionIndex: Int? = nil

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

    // ── Validation ──────────────────────────────────────────────────────────
    private var suffixError: String? { pdfFilenameError(for: suffix) }

    // ── Autocomplete ─────────────────────────────────────────────────────────
    /// Index in `instrumentNames` to start suggestions from — the entry just
    /// after the most recently used instrument in the rows above this one.
    private var nextExpectedIndex: Int {
        for i in Swift.stride(from: fileIndex - 1, through: 0, by: -1) {
            let prev = (allSuffixes[i] ?? "").lowercased()
            if !prev.isEmpty,
               let idx = instrumentNames.firstIndex(where: { $0.lowercased() == prev }) {
                return min(idx + 1, instrumentNames.count - 1)
            }
        }
        return 0
    }

    /// If the nearest previous suffix is "InstrumentName N" (e.g. "Flute 1"),
    /// returns "InstrumentName N+1" ("Flute 2") as the top-priority suggestion.
    private var numberedSuggestion: String? {
        for i in Swift.stride(from: fileIndex - 1, through: 0, by: -1) {
            let prev = (allSuffixes[i] ?? "").trimmingCharacters(in: .whitespaces)
            guard !prev.isEmpty else { continue }
            let parts = prev.components(separatedBy: " ")
            // Must have at least two tokens and last token must be a positive integer
            if parts.count >= 2, let n = Int(parts.last!), n > 0 {
                let basePart = parts.dropLast().joined(separator: " ")
                return "\(basePart) \(n + 1)"
            }
            break  // only consider the closest non-empty row
        }
        return nil
    }

    private var suggestions: [String] {
        // Rotate the base instrument list so "next expected" comes first
        let start = nextExpectedIndex
        let rotated = Array(instrumentNames.suffix(from: start))
                    + Array(instrumentNames.prefix(start))

        var result: [String]
        if suffix.isEmpty {
            result = Array(rotated.prefix(8))
        } else {
            let q = suffix.lowercased()
            let prefixMatches  = rotated.filter { $0.lowercased().hasPrefix(q) }
            let containsMatches = rotated.filter { $0.lowercased().contains(q) && !$0.lowercased().hasPrefix(q) }
            result = Array((prefixMatches + containsMatches).prefix(8))
        }

        // Prepend numbered suggestion ("Flute 2") when relevant
        if let numbered = numberedSuggestion {
            let show = suffix.isEmpty || numbered.lowercased().hasPrefix(suffix.lowercased())
            if show {
                result.removeAll { $0.lowercased() == numbered.lowercased() }
                result.insert(numbered, at: 0)
                result = Array(result.prefix(8))
            }
        }

        return result
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
                PageInstrumentPreview(page: page, offset: previewOffset)
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
                        // Arrow-key navigation through suggestions
                        .onKeyPress(.downArrow) {
                            guard !suggestions.isEmpty else { return .ignored }
                            selectedSuggestionIndex = min(
                                (selectedSuggestionIndex ?? -1) + 1,
                                suggestions.count - 1
                            )
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            if let idx = selectedSuggestionIndex, idx > 0 {
                                selectedSuggestionIndex = idx - 1
                            } else {
                                selectedSuggestionIndex = nil
                            }
                            return .handled
                        }
                        .onKeyPress(.return) {
                            if let idx = selectedSuggestionIndex {
                                // Accept the highlighted suggestion
                                suffix = suggestions[idx]
                                selectedSuggestionIndex = nil
                                return .handled
                            }
                            // No selection active: advance focus to next field
                            fieldFocus.wrappedValue = fileIndex + 1
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            selectedSuggestionIndex = nil
                            return .handled
                        }
                        .onChange(of: suffix) { _ in
                            // Reset arrow-key position whenever text changes
                            selectedSuggestionIndex = nil
                        }
                    Text(".pdf")
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                }

                // Validation error
                if let err = suffixError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                // Live filename preview
                if suffixError == nil {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                        Text(finalFileName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(suffix.isEmpty ? .secondary : .accentColor)
                }

                // ── Autocomplete dropdown ────────────────────────────
                if isFieldFocused && !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.offset) { idx, name in
                            SuggestionButton(
                                label: name,
                                isSelected: selectedSuggestionIndex == idx
                            ) {
                                suffix = name
                                selectedSuggestionIndex = nil
                            }
                            if idx < suggestions.count - 1 {
                                Divider().padding(.leading, 10)
                            }
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    .frame(maxWidth: 340, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(isFieldFocused ? Color.accentColor.opacity(0.05) : Color.clear)
    }
}

// ── Suggestion button (hover + arrow-key selection highlight) ────────────────
private struct SuggestionButton: View {
    let label: String
    var isSelected: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.20)
                : (isHovered ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Page Instrument Preview
struct PageInstrumentPreview: View {
    let page: PDFPage
    /// Pan offset in PDF points from the default top-left position.
    /// Positive y = shifted up; negative y = shifted down.
    /// Positive x = shifted right; negative x = shifted left.
    var offset: CGPoint = .zero

    var body: some View {
        if let image = renderInstrumentNameArea(from: page, offset: offset) {
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

    // Render the crop window defined by the current pan offset.
    // Default position: top-left corner (instrument name area).
    // Clamped so the crop never extends outside the page.
    private func renderInstrumentNameArea(from page: PDFPage, offset: CGPoint) -> NSImage? {
        let pageBounds = page.bounds(for: .mediaBox)

        // Crop dimensions stay constant; only the position changes.
        let cropHeight: CGFloat = 100    // ~1.4 inches
        let cropWidth: CGFloat = min(pageBounds.width * 0.4, 200) // Left 40%, max 200 pt

        // Account for page rotation (swap axes for 90°/270°)
        let rotation = page.rotation
        var actualBounds = pageBounds
        if rotation == 90 || rotation == 270 {
            actualBounds = CGRect(x: pageBounds.origin.x, y: pageBounds.origin.y,
                                width: pageBounds.height, height: pageBounds.width)
        }

        // Default anchor: top-left of the page in PDF coords (Y grows upward).
        let defaultX = actualBounds.origin.x
        let defaultY = actualBounds.origin.y + actualBounds.height - cropHeight

        // Apply pan offset, then clamp so the crop stays within the page.
        let minX = actualBounds.origin.x
        let maxX = actualBounds.origin.x + actualBounds.width - cropWidth
        let minY = actualBounds.origin.y
        let maxY = defaultY   // can only move down from the top

        let cropX = min(max(defaultX + offset.x, minX), maxX)
        let cropY = min(max(defaultY + offset.y, minY), maxY)

        let cropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
        
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
        case .none:
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
    
    // Render the full PDF page into an NSImage for safe preview cloning.
    // Uses page.thumbnail(of:for:) which correctly accounts for the page's
    // rotation property — pages stored as landscape+rotation render portrait.
    private func renderFullImage(from page: PDFPage) -> NSImage? {
        let mediaBox = page.bounds(for: .mediaBox)
        let rotation = ((page.rotation % 360) + 360) % 360

        // For 90°/270° rotated pages the visual size is the media box transposed
        let displaySize: NSSize
        if rotation == 90 || rotation == 270 {
            displaySize = NSSize(width: mediaBox.height, height: mediaBox.width)
        } else {
            displaySize = NSSize(width: mediaBox.width, height: mediaBox.height)
        }

        return page.thumbnail(of: displaySize, for: .mediaBox)
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
    
    func saveRotatedPDF(to url: URL, baseRotation: RotationAngle, additionalRotationMode: RotationMode, additionalRotationAngle: RotationAngle, completion: PDFAlertHandler) {
        guard let document = pdfDocument else { return }

        let newDocument = PDFDocument()

        for pageIndex in 0..<document.pageCount {
            guard let originalPage = document.page(at: pageIndex),
                  let page = originalPage.copy() as? PDFPage else { continue }

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
            case .none:
                shouldApplyAdditional = false
            }

            if shouldApplyAdditional {
                page.rotation += additionalRotationAngle.degrees
            }

            newDocument.insert(page, at: pageIndex)
        }

        if newDocument.write(to: url) {
            completion("PDF Saved Successfully", "Your rotated PDF has been saved to:\n\(url.path)", false)
        } else {
            completion("Error", "Failed to save rotated PDF", true)
        }
    }
    
    func saveSplitPDF(to folderURL: URL, splitMarkers: Set<Int>, baseFileName: String, customFileNames: [Int: String], pageToFileMapping: [Int: Int], completion: PDFAlertHandler) {
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

        if errors.isEmpty {
            completion("PDF Split Successfully",
                       "Created \(savedFiles.count) file(s) in:\n\(folderURL.path)",
                       false)
        } else {
            completion("Partial Success",
                       "Created \(savedFiles.count) file(s), but \(errors.count) failed:\n\(errors.joined(separator: ", "))",
                       true)
        }
    }
}

// MARK: - Supporting Types

/// Completion handler for PDF save/export operations. Called with a title, message, and
/// a flag indicating whether the operation failed. The caller is responsible for presenting
/// the alert — managers never show UI directly.
typealias PDFAlertHandler = (_ title: String, _ message: String, _ isError: Bool) -> Void

/// Convenience wrapper so call sites don't repeat the NSAlert boilerplate.
private func showNSAlert(title: String, message: String, isError: Bool) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = isError ? .critical : .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

enum RotationMode {
    case odd
    case even
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
