//
//  ScoreSort.swift
//  ScoreSort
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
    @Published var showingWelcomeTour = false
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
    var togglePresetSidebar:     () -> Void = {}
}

// MARK: - Navigate Commands (tab switching — placed in the Window menu)
struct NavigateCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Divider()
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

            Divider()

            Button("Toggle Presets Panel") { state.togglePresetSidebar() }
                .keyboardShortcut("p", modifiers: [])
        }
    }
}

// MARK: - Help Commands
struct HelpCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        // Replace the default "AppName Help" item (which shows a "no help" error)
        // with our own entries.
        CommandGroup(replacing: .help) {
            Button("Welcome Tour\u{2026}") {
                appState.showingWelcomeTour = true
            }
            .keyboardShortcut("/", modifiers: .command)

            Button("Keyboard Shortcuts\u{2026}") {
                appState.showingKeyboardHelp = true
            }
            .keyboardShortcut("`", modifiers: .command)
        }
    }
}

// MARK: - Main App
@main
struct ScoreSortApp: App {
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
                Button("About ScoreSort") {
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

        Window("About ScoreSort", id: "about") {
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

            Text("ScoreSort")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .foregroundStyle(.secondary)

            Text("Developed by Ben Perche and Claude")
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
    @AppStorage("hasSeenWelcomeTour") private var hasSeenWelcomeTour = false

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
            .onAppear {
                if !hasSeenWelcomeTour {
                    hasSeenWelcomeTour = true
                    // Short delay lets the window finish rendering before the overlay appears
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        appState.showingWelcomeTour = true
                    }
                }
            }

            // Welcome tour overlay — shown on first launch and from Help menu
            if appState.showingWelcomeTour {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { appState.showingWelcomeTour = false }
                    .transition(.opacity)

                WelcomeTourView(onDismiss: { appState.showingWelcomeTour = false })
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))

                Button("") { appState.showingWelcomeTour = false }
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
            }

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
        .animation(.easeInOut(duration: 0.2), value: appState.showingWelcomeTour)
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
        menuState.togglePresetSidebar     = { withAnimation { showPresetSidebar.toggle() } }
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
    guard words.count >= 2, let lastWord = words.last, Int(String(lastWord)) != nil else { return nil }
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
                    shortcutRow("P", "Toggle preset sidebar")
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
                    shortcutRow("↑ / ↓", "Jump between output files (Split tab)")
                    shortcutRow(", / .", "Rotate current page left / right (Rotate tab)")
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

// MARK: - Welcome Tour

/// Data model for a single page of the welcome tour.
struct WelcomeTourPage {
    /// SF Symbols name for the header icon.
    let icon: String
    /// Accent colour for the icon.
    let iconColor: Color
    /// Keyboard shortcut badge shown top-right (e.g. "⌘1"), nil for the welcome page.
    let tabShortcut: String?
    /// Card title.
    let title: String
    /// One-line italicised use-case description shown below the title, nil for page 1.
    let useCase: String?
    /// Body paragraphs — each string supports inline Markdown (**bold**, `code`, *italic*).
    let bodyParagraphs: [String]
    /// Tip callout text (supports inline Markdown). Pass nil for no callout.
    let tipText: String?
    /// Asset-catalog image or GIF name to display at the top of the card.
    /// Leave nil until screenshots are ready — an SF Symbols illustration is shown instead.
    let imageName: String?

    static let all: [WelcomeTourPage] = [

        // ── Page 1: Welcome ───────────────────────────────────────────────
        WelcomeTourPage(
            icon: "music.note.list",
            iconColor: .accentColor,
            tabShortcut: nil,
            title: "Welcome to ScoreSort",
            useCase: nil,
            bodyParagraphs: [
                "This app contains a suite of tools for music librarians, music educators, publishers and copyists for working with scanned or digital music PDFs.",
                "Each tab handles a different stage of a typical workflow, arranged in order from most commonly used to least common — this short tour gives you a quick overview of each one.",
                "The app is designed to work closely with the macOS Finder. Usually the easiest way to get files into the app will be by dragging files or folders onto the relevant page of this app."
            ],
            tipText: "If your files live in Google Drive or Dropbox, you may want to install the relevant desktop app so your folders appear directly in Finder.",
            imageName: nil
        ),

        // ── Page 2: Combine PDFs ──────────────────────────────────────────
        WelcomeTourPage(
            icon: "doc.on.doc",
            iconColor: .blue,
            tabShortcut: "⌘1",
            title: "Combine PDFs",
            useCase: "You have separate PDF files — one per instrument part — and want to merge them into a single document, ready to print all in one go.",
            bodyParagraphs: [
                "Drag your files (or a whole folder) into the app, then reorder files with **⌘↑ / ⌘↓**. ",
                "You can save your usual instrument allocations as **Ensemble Presets** in Preferences.) These can be viewed in the Presets sidebar to help you remember the normal number of parts required. Use **Apply to Files** to attempt to automatically match your preset allocations to your filenames.",
                "When ready, click **Create PDF** to save the combined file, or **Open in Preview** to print directly without saving a new document.",
                "**Advanced: Collate Sets:** Select a group of parts and press **C** to interleave their pages in the output document. Ideal where you have a number of parts required for multiple players, for example in a percussion section, — each player's copies will print together in a  ready-to-distribute stack."
            ],
            tipText: "⌫ removes selected files · ⌘Z undoes any change · ⌘↑ / ⌘↓ reorders",
            imageName: nil
        ),

        // ── Page 3: Rename Files ──────────────────────────────────────────
        WelcomeTourPage(
            icon: "folder.badge.gearshape",
            iconColor: .orange,
            tabShortcut: "⌘2",
            title: "Rename Files",
            useCase: "You have a folder of parts with unhelpful filenames (e.g. `scan001.pdf`) and want to rename them consistently, or have them sort into score order.",
            bodyParagraphs: [
                "Drag a folder onto the **left side** to add score-order prefixes to already-named files (e.g. `01 - Beethoven - Flute.pdf`). Adjust the order as needed and re-number in one go.",
                "Drag a folder onto the **right side** to replace the filenames of multiple files at once — for example for  parts downloaded from IMSLP. The preview window will show the top left of each file by default so you can check which part you are renaming, and you can move this preview around for all parts at once if required.",
                "Enter a base name (e.g. `Beethoven Symphony 5`), then fill in each instrument name. The app intelligently suggests instrument names and numbers as you type, and you can accept suggestions with the arrow keys and Return.",
                "Once all names are filled in, toggle **Prefix score order** to step through the score-order flow described above, or else skip to output files to a specified folder."
            ],
            tipText: "Tab moves between instrument name fields · You can change the default score order in Preferences",
            imageName: nil
        ),

        // ── Page 4: Split PDF ─────────────────────────────────────────────
        WelcomeTourPage(
            icon: "scissors",
            iconColor: .green,
            tabShortcut: "⌘3",
            title: "Split PDF",
            useCase: "You have one large PDF — e.g. a complete scan of all parts bound together — and need to split it into separate instrument files.",
            bodyParagraphs: [
                "Drop the PDF and use **← →** to move through pages. Press **Space** to toggle a split marker, and **↑ ↓** to jump to the first page of each output file. Equally-spaced markers can be placed automatically using the **stride** control.",
                "In Step 2, name each output file — the same flow as Rename Files. Toggle **Prefix score order** to add score-order numbers automatically in Step 3."
            ],
            tipText: "⌘← / ⌘→ jumps to the first or last page · Space toggles a split marker",
            imageName: nil
        ),

        // ── Page 5: Rotate Pages ──────────────────────────────────────────
        WelcomeTourPage(
            icon: "rotate.right",
            iconColor: .purple,
            tabShortcut: "⌘4",
            title: "Rotate Pages",
            useCase: "Your scan has multiple pages that came out sideways or upside-down and need correcting before use.",
            bodyParagraphs: [
                "Drop a PDF and use **← →** to navigate pages. Rotate the current page, all pages, or all odd / even pages — handy for landscape-scanned scores where every other page is upside-down.",
                "Save the corrected PDF when you're done."
            ],
            tipText: "← → navigates pages · rotating odd/even pages is useful for two-sided landscape scans",
            imageName: nil
        ),
    ]
}

// MARK: - Welcome Tour View

struct WelcomeTourView: View {
    var onDismiss: () -> Void

    @State private var currentPage = 0
    @State private var goingForward = true

    private let pages = WelcomeTourPage.all

    var body: some View {
        VStack(spacing: 0) {

            // ── Scrollable content ────────────────────────────────────────
            ScrollView(.vertical, showsIndicators: false) {
                TourPageContentView(page: pages[currentPage])
                    .id(currentPage)
                    .transition(.asymmetric(
                        insertion: .move(edge: goingForward ? .trailing : .leading)
                                    .combined(with: .opacity),
                        removal:   .move(edge: goingForward ? .leading : .trailing)
                                    .combined(with: .opacity)
                    ))
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
            }
            // Grows up to 560 pt; tallens automatically when images are added
            .frame(maxHeight: 560)

            Divider()

            // ── Navigation bar ────────────────────────────────────────────
            HStack(alignment: .center) {

                // Back button
                Button {
                    goingForward = false
                    withAnimation(.easeInOut(duration: 0.25)) { currentPage -= 1 }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(currentPage == 0 ? .clear : .accentColor)
                .disabled(currentPage == 0)

                Spacer()

                // Page-dot indicators
                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { i in
                        Circle()
                            .fill(currentPage == i
                                  ? Color.accentColor
                                  : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                            .scaleEffect(currentPage == i ? 1.25 : 1.0)
                            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: currentPage)
                            .onTapGesture {
                                goingForward = i > currentPage
                                withAnimation(.easeInOut(duration: 0.25)) { currentPage = i }
                            }
                    }
                }

                Spacer()

                // Next / Get Started button
                if currentPage < pages.count - 1 {
                    Button {
                        goingForward = true
                        withAnimation(.easeInOut(duration: 0.25)) { currentPage += 1 }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Next")
                            Image(systemName: "chevron.right")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") { onDismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(width: 660)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(14)
        .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 10)
    }
}

// MARK: - Tour Page Content View

struct TourPageContentView: View {
    let page: WelcomeTourPage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Optional screenshot / GIF image ───────────────────────────
            if let name = page.imageName {
                TourImageView(imageName: name)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                    .padding(.bottom, 20)
            }

            // ── Header row ────────────────────────────────────────────────
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: page.icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(page.iconColor)
                    .frame(width: 32, alignment: .center)

                Text(page.title)
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                if let shortcut = page.tabShortcut {
                    Text(shortcut)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(5)
                }
            }

            // ── Use-case line ─────────────────────────────────────────────
            if let useCase = page.useCase {
                Text(useCase)
                    .font(.callout)
                    .italic()
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            Divider()
                .padding(.vertical, 14)

            // ── Body paragraphs ───────────────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                ForEach(page.bodyParagraphs.indices, id: \.self) { i in
                    Text(markdownString: page.bodyParagraphs[i])
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }
            }

            // ── Tip callout ───────────────────────────────────────────────
            if let tip = page.tipText {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(.yellow)
                        .font(.callout)
                        .padding(.top, 1)
                    Text(markdownString: tip)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.yellow.opacity(0.25), lineWidth: 1)
                )
                .cornerRadius(8)
                .padding(.top, 16)
            }
        }
    }
}

// MARK: - Tour Image View (supports PNG and animated GIF)

/// Wraps NSImageView so both static screenshots and animated GIFs display correctly.
/// Slot is ready — just add the image to the asset catalog and set `imageName` on the page.
struct TourImageView: NSViewRepresentable {
    let imageName: String

    func makeNSView(context: Context) -> NSImageView {
        let iv = NSImageView()
        iv.animates = true   // enables GIF animation automatically
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.image = NSImage(named: imageName)
        return iv
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = NSImage(named: imageName)
    }
}

// MARK: - Markdown Text helper

extension View {
    /// Renders a String containing inline Markdown (**bold**, *italic*, `code`) as a SwiftUI Text.
    func markdownText(_ string: String) -> Text {
        if let attr = try? AttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(string)
    }
}

extension Text {
    /// Initialises a Text view that renders inline Markdown in the string.
    init(markdownString string: String) {
        if let attr = try? AttributedString(
            markdown: string,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            self.init(attr)
        } else {
            self.init(string)
        }
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
        let folder = dir.appendingPathComponent("ScoreSort", isDirectory: true)
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

        let insertionIndex = orderedIndices[0]
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

// MARK: - Rename Tab (wrapper)
/// Hosts both panels side-by-side inside the "Rename Files" tab.
struct RenamerView: View {
    @EnvironmentObject private var renamerManager: RenamerManager
    @State private var bulkHasFiles: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Hide the Score Order Sorter (and divider) when Bulk Rename is
            // active — but keep BulkRenameView permanently in the tree so its
            // @State (loadedFiles etc.) survives the layout switch.
            if !bulkHasFiles {
                ScoreOrderSortView()
                if !renamerManager.hasContent {
                    Divider()
                }
            }
            if !renamerManager.hasContent {
                BulkRenameView(hasFiles: $bulkHasFiles)
            }
        }
    }
}

// MARK: - Score Order Sort View
struct ScoreOrderSortView: View {
    @EnvironmentObject private var renamerManager: RenamerManager
    @Environment(\.openSettings) private var openSettings
    @State private var selectedFileForAssignment: RenameOperation?
    @State private var isFolderTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Top toolbar ───────────────────────────────────────────────
            HStack {
                Text("Score Order Sorter")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if renamerManager.hasContent {
                    Toggle(isOn: Binding(
                        get: { renamerManager.isRescanMode },
                        set: { renamerManager.setRescanMode($0) }
                    )) {
                        Text("Renumber prefixed files")
                    }
                    .toggleStyle(.checkbox)
                    .help("When on, files that already have a numeric prefix are renumbered along with the rest")
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

            if renamerManager.hasContent {
                fileListView
                Divider()
                bottomControlsView
            } else {
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

    // ── Drop zone (shown when no files loaded) ────────────────────────────
    private var folderSelectionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 64))
                .foregroundColor(isFolderTargeted ? .accentColor : .secondary)
            Text("Select Files or Folder")
                .font(.title2)
                .fontWeight(.medium)
            Text("Adds sequential prefixes based on detected instrument names")
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

    // ── File list ─────────────────────────────────────────────────────────
    private var fileListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(renamerManager.operations) { operation in
                    ScoreOrderFileRow(operation: operation) {
                        selectedFileForAssignment = operation
                    }
                    Divider()
                }
            }
        }
    }

    // ── Bottom controls ───────────────────────────────────────────────────
    private var bottomControlsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Ensemble:")
                    .font(.headline)
                Picker("", selection: $renamerManager.ensembleType) {
                    Text("Wind Band").tag(EnsembleType.band)
                    Text("Jazz Band").tag(EnsembleType.jazz)
                    Text("Orchestra").tag(EnsembleType.orchestra)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Spacer()
            }
            HStack {
                Text(renamerManager.statusText)
                    .font(.callout)
                    .foregroundColor(.secondary)
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

    // ── Folder picker ─────────────────────────────────────────────────────
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

// MARK: - Score Order File Row
/// One row in the Score Order Sorter list — matches the visual style of PrefixOrderRow.
private struct ScoreOrderFileRow: View {
    let operation: RenameOperation
    let onDoubleClick: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // ── Left column: badge + original filename ────────────────────
            HStack(spacing: 12) {
                // Position badge or status icon
                Group {
                    switch operation.type {
                    case .alreadyPrefixed, .skip:
                        Image(systemName: "checkmark.circle")
                            .foregroundColor(.secondary)
                    case .undetected:
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundColor(.orange)
                    default:
                        let prefix = String(operation.newName.prefix(2))
                        Text(prefix.isEmpty ? "??" : prefix)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.semibold)
                            .foregroundColor(.accentColor)
                    }
                }
                .frame(width: 30, alignment: .center)

                Text(operation.originalName)
                    .lineLimit(1)
                    .foregroundColor(
                        (operation.type == .alreadyPrefixed || operation.type == .skip)
                        ? .secondary : .primary
                    )
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)

            // ── Right column: new filename or hint, status tag ────────────
            HStack(spacing: 8) {
                switch operation.type {
                case .undetected:
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Text("No instrument detected — double-click to assign")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    }
                case .alreadyPrefixed, .skip:
                    Text(operation.type == .alreadyPrefixed ? "Already prefixed — will skip" : "Already correct — will skip")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                default:
                    if !operation.newName.isEmpty {
                        Text(operation.newName)
                            .font(.body)
                            .foregroundColor(operation.color)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                switch operation.type {
                case .manual:
                    statusTag("Manual", color: .blue)
                case .correct:
                    statusTag("Correction", color: .orange)
                default:
                    EmptyView()
                }
            }
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .background(isHovered ? Color.accentColor.opacity(0.05) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleClick() }
        .onHover { isHovered = $0 }
    }

    private func statusTag(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .clipShape(Capsule())
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

// MARK: - Bulk Rename View
/// Right panel of the Rename Files tab.
/// Accepts a folder or individual PDFs, lets the user assign a shared base name
/// plus per-file instrument suffixes (with the same autocomplete as the Splitter),
/// then renames all files in place.
private enum BulkStage { case base, prefix, summary }

struct BulkRenameView: View {

    // ── Parent binding so RenamerView can react to file load/clear ────────
    @Binding var hasFiles: Bool

    // ── Loaded files ──────────────────────────────────────────────────────
    @State private var loadedFiles: [(url: URL, document: PDFDocument)] = []

    // ── Naming state ──────────────────────────────────────────────────────
    @State private var baseFileName: String = ""
    @State private var suffixes: [Int: String] = [:]
    @State private var previewOffset: CGPoint = .zero
    @FocusState private var focusedField: Int?

    // ── Drop zone ────────────────────────────────────────────────────────
    @State private var isTargeted = false

    // ── Prefix step ───────────────────────────────────────────────────────
    @State private var bulkStage: BulkStage = .base
    @State private var prefixItems: [PrefixItem] = []
    @State private var summaryNames: [String] = []

    // ── Settings ─────────────────────────────────────────────────────────
    @AppStorage("filenameSeparator") private var filenameSeparator: String = " - "
    @AppStorage("prefixEnabled") private var prefixEnabled: Bool = true
    @AppStorage("prefixEnsembleType") private var prefixEnsembleType: EnsembleType = .band

    // ── Instrument names (same union as the Splitter) ─────────────────────
    private var instrumentNames: [String] { InstrumentOrders.allNames }

    // ── Validation ────────────────────────────────────────────────────────
    private var baseNameError: String? { pdfFilenameError(for: baseFileName) }

    private var anySuffixError: Bool {
        suffixes.values.contains { pdfFilenameError(for: $0) != nil }
    }

    /// True when two or more output filenames would collide.
    private var hasDuplicateNames: Bool {
        var seen = Set<String>()
        for index in loadedFiles.indices {
            let sfx = suffixes[index] ?? ""
            let name = sfx.isEmpty
                ? "\(baseFileName)\(filenameSeparator)\(index + 1).pdf"
                : "\(baseFileName)\(filenameSeparator)\(sfx).pdf"
            if !seen.insert(name).inserted { return true }
        }
        return false
    }

    private var canRename: Bool {
        !loadedFiles.isEmpty
            && !baseFileName.isEmpty
            && baseNameError == nil
            && !anySuffixError
            && !hasDuplicateNames
    }

    // ── Body ──────────────────────────────────────────────────────────────
    var body: some View {
        switch bulkStage {
        case .summary:
            RenameSummaryView(
                finalNames: summaryNames,
                outputFolderURL: nil,
                onStartOver: {
                    bulkStage = .base
                    clearFiles()
                }
            )
        case .prefix:
            PrefixOrderStepView(
                stepLabel: "Step 2",
                initialItems: prefixItems,
                ensembleType: $prefixEnsembleType,
                onBack: { bulkStage = .base },
                onApply: { orderedItems in applyPrefixAndRenameBulk(orderedItems: orderedItems) }
            )
        case .base:
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Bulk Part Rename")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    if !loadedFiles.isEmpty {
                        Button(action: clearFiles) {
                            Label("Clear", systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                if loadedFiles.isEmpty {
                    dropZoneView
                } else {
                    fileListView
                }
            }
        }
    }

    // ── Drop zone ─────────────────────────────────────────────────────────
    private var dropZoneView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 56))
                .foregroundColor(isTargeted ? .accentColor : .secondary)

            Text("Bulk Part Rename")
                .font(.title3)
                .fontWeight(.medium)

            Text("Rename a set of separate PDF part files with a\nshared base name and instrument suffixes")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Text("Drag a folder or individual PDF files here")
                .font(.callout)
                .foregroundColor(isTargeted ? .accentColor : .secondary)

            Text("or")
                .foregroundColor(.secondary)

            Button(action: selectFiles) {
                Label("Choose Files or Folder", systemImage: "folder")
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
            var collected: [URL] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url = url { collected.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                guard !collected.isEmpty else { return }
                var isDir: ObjCBool = false
                if collected.count == 1,
                   FileManager.default.fileExists(atPath: collected[0].path, isDirectory: &isDir),
                   isDir.boolValue {
                    loadFromFolder(collected[0])
                } else {
                    loadFiles(collected.filter { $0.pathExtension.lowercased() == "pdf" })
                }
            }
            return true
        }
    }

    // ── File list (once loaded) ───────────────────────────────────────────
    private var fileListView: some View {
        VStack(spacing: 0) {
            // Base filename bar
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Base Filename:")
                        .font(.headline)
                        .fixedSize()

                    TextField("e.g. Beethoven Symphony 5", text: $baseFileName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)

                    Text("Files will be renamed: \(baseFileName.isEmpty ? "basename" : baseFileName)\(filenameSeparator)Flute.pdf")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()
                }
                if let err = baseNameError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.red)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Per-file naming rows — reuse SplitFileNamingRow directly
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(loadedFiles.indices, id: \.self) { index in
                            SplitFileNamingRow(
                                fileIndex: index,
                                page: loadedFiles[index].document.page(at: 0),
                                subtitle: loadedFiles[index].url.lastPathComponent,
                                baseFileName: baseFileName,
                                suffix: Binding(
                                    get: { suffixes[index] ?? "" },
                                    set: { suffixes[index] = $0.isEmpty ? nil : $0 }
                                ),
                                fieldFocus: $focusedField,
                                instrumentNames: instrumentNames,
                                allSuffixes: suffixes.mapValues { $0 },
                                previewOffset: $previewOffset
                            )
                            .id(index)
                            if index < loadedFiles.count - 1 { Divider() }
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

            // Bottom bar
            VStack(alignment: .leading, spacing: 6) {
                // Warning
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("This will rename the files in Finder. This cannot be undone.")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Spacer()
                }
                // Duplicate name error
                if hasDuplicateNames {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                        Text("Two or more files would get the same name — check your suffixes.")
                            .font(.caption)
                            .foregroundColor(.red)
                        Spacer()
                    }
                }
                // Prefix option row
                HStack(spacing: 12) {
                    Toggle("Prefix score order", isOn: $prefixEnabled)
                    Picker("", selection: $prefixEnsembleType) {
                        Text("Wind Band").tag(EnsembleType.band)
                        Text("Jazz Band").tag(EnsembleType.jazz)
                        Text("Orchestra").tag(EnsembleType.orchestra)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    .disabled(!prefixEnabled)
                    .opacity(prefixEnabled ? 1 : 0.5)
                    Spacer()
                }
                HStack {
                    Spacer()
                    Button(action: executeRename) {
                        Label(prefixEnabled
                              ? "Next: Prefix Order"
                              : "Rename \(loadedFiles.count) File\(loadedFiles.count == 1 ? "" : "s")",
                              systemImage: prefixEnabled ? "chevron.right" : "pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canRename)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    // ── File loading ──────────────────────────────────────────────────────
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]
        panel.title = "Select PDF Files or Folder"
        panel.message = "Choose a folder containing PDFs, or select individual PDF files"
        panel.begin { response in
            guard response == .OK else { return }
            var isDir: ObjCBool = false
            if panel.urls.count == 1,
               FileManager.default.fileExists(atPath: panel.urls[0].path, isDirectory: &isDir),
               isDir.boolValue {
                loadFromFolder(panel.urls[0])
            } else {
                loadFiles(panel.urls.filter { $0.pathExtension.lowercased() == "pdf" })
            }
        }
    }

    private func loadFromFolder(_ url: URL) {
        let pdfs = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ))?.filter { $0.pathExtension.lowercased() == "pdf" }
          .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        ?? []
        loadFiles(pdfs)
    }

    private func loadFiles(_ urls: [URL]) {
        loadedFiles = urls.compactMap { url in
            guard let doc = PDFDocument(url: url) else { return nil }
            return (url: url, document: doc)
        }
        suffixes = [:]
        previewOffset = .zero
        hasFiles = !loadedFiles.isEmpty
    }

    private func clearFiles() {
        loadedFiles = []
        baseFileName = ""
        suffixes = [:]
        previewOffset = .zero
        hasFiles = false
    }

    // ── Rename execution ──────────────────────────────────────────────────
    private func executeRename() {
        let sep = filenameSeparator

        if prefixEnabled {
            // Build PrefixItems (don't touch disk yet) and go to prefix step.
            prefixItems = loadedFiles.enumerated().map { index, item in
                let sfx = suffixes[index] ?? ""
                let proposed = sfx.isEmpty
                    ? "\(baseFileName)\(sep)\(index + 1).pdf"
                    : "\(baseFileName)\(sep)\(sfx).pdf"
                return PrefixItem(id: index,
                                  proposedName: proposed,
                                  page: item.document.page(at: 0),
                                  originalURL: item.url)
            }
            bulkStage = .prefix
        } else {
            // Rename directly to the base name + suffix (no prefix step).
            var errors: [String] = []
            var finalNames: [String] = []

            for (index, item) in loadedFiles.enumerated() {
                let sfx = suffixes[index] ?? ""
                let newName = sfx.isEmpty
                    ? "\(baseFileName)\(sep)\(index + 1).pdf"
                    : "\(baseFileName)\(sep)\(sfx).pdf"
                let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
                do {
                    try FileManager.default.moveItem(at: item.url, to: newURL)
                    finalNames.append(newName)
                } catch {
                    errors.append(item.url.lastPathComponent)
                }
            }

            if errors.isEmpty {
                summaryNames = finalNames
                bulkStage = .summary
            } else {
                let failed = errors.prefix(5).joined(separator: "\n")
                showNSAlert(
                    title: "Some Files Could Not Be Renamed",
                    message: "Failed to rename \(errors.count) file\(errors.count == 1 ? "" : "s"):\n\(failed)",
                    isError: true
                )
            }
        }
    }

    /// Called by PrefixOrderStepView when the user confirms ordering.
    /// Renames each file from its original URL to the final prefixed name in one pass.
    private func applyPrefixAndRenameBulk(orderedItems: [PrefixItem]) {
        let sep = UserDefaults.standard.string(forKey: "prefixSeparator") ?? " - "
        var errors: [String] = []
        var finalNames: [String] = []

        for (position, item) in orderedItems.enumerated() {
            guard let originalURL = item.originalURL else { continue }
            let prefix = String(format: "%02d", position + 1)
            let finalName = "\(prefix)\(sep)\(item.proposedName)"
            let targetURL = originalURL.deletingLastPathComponent()
                                       .appendingPathComponent(finalName)
            do {
                try FileManager.default.moveItem(at: originalURL, to: targetURL)
                finalNames.append(finalName)
            } catch {
                errors.append(item.proposedName)
            }
        }

        if errors.isEmpty {
            summaryNames = finalNames
            bulkStage = .summary
        } else {
            let failed = errors.prefix(5).joined(separator: "\n")
            showNSAlert(
                title: "Some Files Could Not Be Renamed",
                message: "Failed to rename \(errors.count) file\(errors.count == 1 ? "" : "s"):\n\(failed)",
                isError: true
            )
        }
    }
}

// MARK: - Preferences View
struct PreferencesView: View {
    @Binding var ensembleType: EnsembleType
    @Binding var instrumentOrder: [String]
    /// Separator between the numeric prefix and filename in the Score Order Sorter,
    /// e.g. " - " → "01 - Flute.pdf".
    @Binding var prefixSeparator: String

    @State private var editableOrder: [String]
    @State private var newInstrument: String = ""
    @Environment(\.dismiss) private var dismiss
    @AppStorage("filenameSeparator") private var filenameSeparator: String = " - "

    init(ensembleType: Binding<EnsembleType>, instrumentOrder: Binding<[String]>, prefixSeparator: Binding<String>) {
        self._ensembleType = ensembleType
        self._instrumentOrder = instrumentOrder
        self._prefixSeparator = prefixSeparator
        self._editableOrder = State(initialValue: instrumentOrder.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Instrument Order Preferences")
                .font(.title2)
                .fontWeight(.semibold)

            // ── Suffix separator (Splitter & Bulk Rename) ─────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("Suffix Separator:")
                    .font(.headline)
                HStack(spacing: 10) {
                    TextField("e.g.  - ", text: $filenameSeparator)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .font(.system(.body, design: .monospaced))
                    Text("Inserted between base name and suffix, e.g.  Beethoven\(filenameSeparator)Flute.pdf")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Reset") { filenameSeparator = " - " }
                        .font(.caption)
                }
                Text("Leave blank to join base name and suffix with no separator. Used by both the Splitter and Bulk Part Rename.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // ── Prefix separator (Score Order Sorter) ─────────────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("Prefix Separator:")
                    .font(.headline)
                HStack(spacing: 10) {
                    TextField("e.g.  - ", text: $prefixSeparator)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .font(.system(.body, design: .monospaced))
                    Text("Inserted between the number prefix and filename, e.g.  01\(prefixSeparator)Flute.pdf")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Reset") { prefixSeparator = " - " }
                        .font(.caption)
                }
                Text("Leave blank to join number and filename with no separator. Used by the Score Order Sorter.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

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
                instrumentOrder: $renamerManager.customInstrumentOrder,
                prefixSeparator: $renamerManager.prefixSeparator
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

    /// Separator inserted between the numeric prefix and the filename,
    /// e.g. " - " gives "01 - Flute.pdf".  Persisted in UserDefaults.
    @Published var prefixSeparator: String = UserDefaults.standard.string(forKey: "prefixSeparator") ?? " - " {
        didSet {
            UserDefaults.standard.set(prefixSeparator, forKey: "prefixSeparator")
            if hasContent { scanFolder() }
        }
    }

    /// True when there is either a folder loaded or direct files loaded.
    var hasContent: Bool { folderURL != nil || !directFiles.isEmpty }

    private var hasCustomOrder = false
    var manualOverrides: [String: Int] = [:]
    @Published private(set) var isRescanMode = false
    
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

    func setRescanMode(_ enabled: Bool) {
        isRescanMode = enabled
        if enabled { manualOverrides = [:] }
        if hasContent { scanFolder() }
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

            let newFilename = "\(prefix)\(prefixSeparator)\(cleanName)"
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
            
            let newFilename = "\(prefix)\(prefixSeparator)\(cleanName)"
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
            
            let newFilename = "\(prefix)\(prefixSeparator)\(cleanName)"
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
        let dir = appSupport.appendingPathComponent("ScoreSort", isDirectory: true)
        return dir.appendingPathComponent("instrument-orders.json")
    }

    // Bump this whenever the built-in defaults change so existing JSON files
    // are automatically regenerated on next launch.
    private static let defaultsVersion = 3

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

    /// Ordered, deduplicated union of orchestra + band + jazz, with each name
    /// capitalised. Used for instrument-name autocomplete in both the Splitter
    /// and the Bulk Renamer.
    static var allNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in orchestra + band + jazz {
            let key = name.lowercased()
            if seen.insert(key).inserted { result.append(name.capitalized) }
        }
        return result
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
        "euphonium treble clef",
        "euphonium t.c.",
        "euphonium tc",
        "euphonium bass clef",
        "euphonium b.c.",
        "euphonium bc",
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
        "euphonium treble clef",
        "euphonium t.c.",
        "euphonium tc",
        "euphonium bass clef",
        "euphonium b.c.",
        "euphonium bc",
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
    @State private var pageRotationOverrides: [Int: Int] = [:]
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
                        additionalRotationAngle: additionalRotationAngle,
                        pageRotationOverrides: pageRotationOverrides,
                        onRotateCurrentPageLeft:  rotateCurrentPageLeft,
                        onRotateCurrentPageRight: rotateCurrentPageRight
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
            case KeyEquivalent(","):
                rotateCurrentPageLeft()
                return .handled
            case KeyEquivalent("."):
                rotateCurrentPageRight()
                return .handled
            default:
                return .ignored
            }
        }
        .onChange(of: pdfManager.pdfDocument) { newValue in
            if newValue == nil { pageRotationOverrides = [:] }
        }
        .onChange(of: isShowingSavePanel) { newValue in
            if newValue, let document = pdfManager.pdfDocument {
                saveRotatedPDF(document: document)
            }
        }
    }

    private func rotateCurrentPageLeft() {
        let current = pageRotationOverrides[currentPage, default: 0]
        pageRotationOverrides[currentPage] = ((current - 90) % 360 + 360) % 360
    }

    private func rotateCurrentPageRight() {
        let current = pageRotationOverrides[currentPage, default: 0]
        pageRotationOverrides[currentPage] = ((current + 90) % 360 + 360) % 360
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
                    additionalRotationAngle: additionalRotationAngle,
                    pageRotationOverrides: pageRotationOverrides
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
private enum SplitStage { case split, naming, prefix, summary }

struct SplitView: View {
    @StateObject private var pdfManager = PDFManager()
    // fileSizes stores the page count for each output file in order.
    // e.g. [2, 2, 1, 3] means 4 files with 2, 2, 1, and 3 pages respectively.
    // This makes split point manipulation natural: adding a split just partitions
    // an existing entry, removing one merges two adjacent entries.
    @State private var fileSizes: [Int] = []
    @State private var stride: Int = 2
    @State private var currentPage: Int = 0
    @State private var splitStage: SplitStage = .split
    @State private var baseFileName: String = ""
    @State private var customFileNames: [Int: String] = [:]
    /// Shared pan offset for all naming-stage previews (PDF points from the default top-left position).
    /// Reset whenever a new PDF is loaded so it always starts at the instrument-name corner.
    @State private var previewOffset: CGPoint = .zero
    @State private var prefixItems: [PrefixItem] = []
    @State private var summaryNames: [String] = []
    @State private var pendingFolderURL: URL? = nil
    @FocusState private var isViewFocused: Bool
    @AppStorage("filenameSeparator") private var filenameSeparator: String = " - "
    @AppStorage("prefixEnabled") private var prefixEnabled: Bool = true
    @AppStorage("prefixEnsembleType") private var prefixEnsembleType: EnsembleType = .band

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
        switch splitStage {
        case .summary:
            RenameSummaryView(
                finalNames: summaryNames,
                outputFolderURL: pendingFolderURL,
                onStartOver: {
                    splitStage = .split
                    pdfManager.clearPDF()
                    baseFileName = ""
                    customFileNames = [:]
                    fileSizes = []
                    summaryNames = []
                    pendingFolderURL = nil
                }
            )
        case .prefix:
            PrefixOrderStepView(
                stepLabel: "Step 3",
                initialItems: prefixItems,
                ensembleType: $prefixEnsembleType,
                onBack: { splitStage = .naming },
                onApply: { orderedItems in
                    applyPrefixAndSaveSplit(orderedItems: orderedItems)
                }
            )
        case .naming:
            if let document = pdfManager.pdfDocument {
                SplitNamingStageView(
                    pdfDocument: document,
                    fileSizes: fileSizes,
                    baseFileName: $baseFileName,
                    customFileNames: $customFileNames,
                    previewOffset: $previewOffset,
                    onBack: { splitStage = .split },
                    onClear: {
                        splitStage = .split
                        pdfManager.clearPDF()
                    },
                    onSave: { saveSplitPDF() }
                )
            }
        case .split:
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
                                    Text("**Stride** is the number of pages per output file. Press **Apply** to place split markers every N pages automatically.")
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
                            Text("Output Files (\(numberOfFiles))")
                                .font(.headline)

                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(0..<numberOfFiles, id: \.self) { fileIndex in
                                        FilePreviewCard(
                                            fileIndex: fileIndex,
                                            pageToFileMapping: pageToFileMapping,
                                            totalPages: totalPages,
                                            baseFileName: baseFileName,
                                            customFileNames: customFileNames,
                                            currentPage: currentPage,
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
                                Button(action: { splitStage = .naming }) {
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
                        case .downArrow:
                            // Jump to the first page of the next output file
                            let fileStarts = ([0] + splitMarkers.sorted())
                            if let next = fileStarts.first(where: { $0 > currentPage }) {
                                currentPage = next
                            }
                            return .handled
                        case .upArrow:
                            // Jump to the first page of the previous output file
                            let fileStarts = ([0] + splitMarkers.sorted())
                            if let prev = fileStarts.last(where: { $0 < currentPage }) {
                                currentPage = prev
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
                // Load with no markers — user presses Apply to apply the stride
                fileSizes = totalPages > 0 ? [totalPages] : []
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
        guard let document = pdfManager.pdfDocument, numberOfFiles >= 2 else { return }

        if prefixEnabled {
            // Go straight to Step 3 — folder picker comes after the user confirms order.
            var items: [PrefixItem] = []
            var pagePos = 0
            for fileIndex in 0..<fileSizes.count {
                let suffix = customFileNames[fileIndex] ?? ""
                let proposed: String
                if suffix.isEmpty {
                    proposed = "\(baseFileName)\(filenameSeparator)\(fileIndex + 1).pdf"
                } else {
                    proposed = "\(baseFileName)\(filenameSeparator)\(suffix).pdf"
                }
                let firstPage = document.page(at: pagePos)
                items.append(PrefixItem(id: fileIndex, proposedName: proposed, page: firstPage))
                pagePos += fileSizes[fileIndex]
            }
            prefixItems = items
            splitStage = .prefix
        } else {
            // No prefix step — show folder picker now and save directly.
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.title = "Select Output Folder"
            panel.message = "Choose where to save the split PDF files"

            panel.begin { response in
                guard response == .OK, let folderURL = panel.url else { return }
                pdfManager.saveSplitPDF(
                    to: folderURL,
                    splitMarkers: splitMarkers,
                    baseFileName: baseFileName,
                    customFileNames: customFileNames,
                    pageToFileMapping: pageToFileMapping,
                    separator: filenameSeparator
                ) { title, message, isError in
                    if isError {
                        showNSAlert(title: title, message: message, isError: true)
                    } else {
                        var names: [String] = []
                        for i in 0..<fileSizes.count {
                            let sfx = customFileNames[i] ?? ""
                            if sfx.isEmpty {
                                names.append("\(baseFileName)\(filenameSeparator)\(i + 1).pdf")
                            } else {
                                names.append("\(baseFileName)\(filenameSeparator)\(sfx).pdf")
                            }
                        }
                        pendingFolderURL = folderURL
                        summaryNames = names
                        splitStage = .summary
                    }
                }
            }
        }
    }

    /// Called by PrefixOrderStepView when the user confirms the prefix ordering.
    /// Shows the folder picker, then writes all split files in one pass.
    private func applyPrefixAndSaveSplit(orderedItems: [PrefixItem]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Select Output Folder"
        panel.message = "Choose where to save the split PDF files"

        panel.begin { response in
            guard response == .OK, let folderURL = panel.url else { return }
            applyPrefixToFolder(folderURL, orderedItems: orderedItems)
        }
    }

    private func applyPrefixToFolder(_ folderURL: URL, orderedItems: [PrefixItem]) {
        let sep = UserDefaults.standard.string(forKey: "prefixSeparator") ?? " - "

        // Build customFileNames keyed by original fileIndex.
        // saveSplitPDF writes: "\(baseFileName)\(separator)\(suffix).pdf"
        // We pass baseFileName="" separator="" so the suffix IS the complete filename (without .pdf).
        var finalCustomNames: [Int: String] = [:]
        var finalNamesForSummary: [String] = []

        for (position, item) in orderedItems.enumerated() {
            let prefix = String(format: "%02d", position + 1)
            let fullName = "\(prefix)\(sep)\(item.proposedName)"  // e.g. "01 - Beethoven - Flute.pdf"
            let nameWithoutPdf = fullName.hasSuffix(".pdf")
                ? String(fullName.dropLast(4))
                : fullName
            finalCustomNames[item.id] = nameWithoutPdf
            finalNamesForSummary.append(fullName)
        }

        pdfManager.saveSplitPDF(
            to: folderURL,
            splitMarkers: splitMarkers,
            baseFileName: "",
            customFileNames: finalCustomNames,
            pageToFileMapping: pageToFileMapping,
            separator: ""
        ) { _, _, isError in
            if isError {
                showNSAlert(title: "Save Failed",
                            message: "Could not write one or more files to \(folderURL.path).",
                            isError: true)
            } else {
                pendingFolderURL = folderURL   // stored here so summary can offer "Show in Finder"
                summaryNames = finalNamesForSummary
                splitStage = .summary
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
    /// The page currently shown in the left preview — used to highlight the active card.
    let currentPage: Int
    let onNavigate: (Int) -> Void

    var pagesInFile: [Int] {
        pageToFileMapping.filter { $0.value == fileIndex }.keys.sorted()
    }

    /// True when the currently-previewed page belongs to this output file.
    var isActive: Bool {
        pagesInFile.contains(currentPage)
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
                    .foregroundColor(isActive ? .accentColor : .blue)

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
                .fill(isActive
                      ? Color.accentColor.opacity(0.08)
                      : Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isActive ? Color.accentColor.opacity(0.5) : Color.clear,
                                      lineWidth: 1.5)
                )
        )
        // Tapping anywhere on the card (outside the page-number buttons) jumps
        // the preview to the first page of this output file.
        .contentShape(Rectangle())
        .onTapGesture {
            if let firstPage = pagesInFile.first {
                onNavigate(firstPage)
            }
        }
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
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
    let onClear: () -> Void
    let onSave: () -> Void

    @FocusState private var focusedField: Int?
    @AppStorage("filenameSeparator") private var filenameSeparator: String = " - "
    @AppStorage("prefixEnabled") private var prefixEnabled: Bool = true
    @AppStorage("prefixEnsembleType") private var prefixEnsembleType: EnsembleType = .band

    var numberOfFiles: Int { fileSizes.count }

    /// Page index of the first page in a given file.
    private func firstPageIndex(for fileIndex: Int) -> Int {
        fileSizes.prefix(fileIndex).reduce(0, +)
    }

    /// Row subtitle: page range + page count, e.g. "Pages 3–5 · 3 pages".
    private func subtitle(for fileIndex: Int) -> String {
        let start = firstPageIndex(for: fileIndex)
        let size  = fileSizes[fileIndex]
        let end   = start + size - 1
        let range = (start == end) ? "Page \(start + 1)" : "Pages \(start + 1)–\(end + 1)"
        return "\(range) · \(size) \(size == 1 ? "page" : "pages")"
    }

    /// Ordered, deduplicated instrument name list (orchestra → band → jazz).
    private var instrumentNames: [String] { InstrumentOrders.allNames }

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
                Spacer()
                Text("Step 2: Name Files")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: onClear) {
                    Label("Clear", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
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

                    Text("Example: \(baseFileName.isEmpty ? "basename" : baseFileName)\(filenameSeparator)Flute.pdf  ·  Leave blank for auto-numbering: \(baseFileName.isEmpty ? "basename" : baseFileName)\(filenameSeparator)1.pdf")
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
                                page: pdfDocument.page(at: firstPageIndex(for: fileIndex)),
                                subtitle: subtitle(for: fileIndex),
                                baseFileName: baseFileName,
                                suffix: Binding(
                                    get: { customFileNames[fileIndex] ?? "" },
                                    set: { customFileNames[fileIndex] = $0.isEmpty ? nil : $0 }
                                ),
                                fieldFocus: $focusedField,
                                instrumentNames: instrumentNames,
                                allSuffixes: customFileNames,
                                previewOffset: $previewOffset
                            )
                            .id(fileIndex)
                            if fileIndex < numberOfFiles - 1 { Divider() }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onAppear { proxy.scrollTo(0, anchor: .top) }
                .onChange(of: focusedField) { newValue in
                    if let field = newValue {
                        withAnimation { proxy.scrollTo(field, anchor: .center) }
                    }
                }
            }

            Divider()

            // ── Bottom bar ───────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                // Prefix option row
                HStack(spacing: 12) {
                    Toggle("Prefix score order", isOn: $prefixEnabled)
                    Picker("", selection: $prefixEnsembleType) {
                        Text("Wind Band").tag(EnsembleType.band)
                        Text("Jazz Band").tag(EnsembleType.jazz)
                        Text("Orchestra").tag(EnsembleType.orchestra)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    .disabled(!prefixEnabled)
                    .opacity(prefixEnabled ? 1 : 0.5)
                    Spacer()
                }

                HStack {
                    Button(action: onBack) {
                        Label("Back to Split", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(action: onSave) {
                        Label(prefixEnabled ? "Next: Prefix Order" : "Save Split Files",
                              systemImage: prefixEnabled ? "chevron.right" : "arrow.down.doc.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSave)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

// MARK: - Split File Naming Row
/// One row in the naming stage: large page thumbnail on the left, file info and
/// suffix text field on the right.
/// Used by both SplitNamingStageView (one row per output file from a single PDF)
/// and BulkRenameView (one row per separate PDF file).
struct SplitFileNamingRow: View {
    let fileIndex: Int
    /// The PDF page to display in the thumbnail strip.
    /// SplitNamingStageView passes the first page of each output section;
    /// BulkRenameView passes page 0 of each individual document.
    let page: PDFPage?
    /// Short descriptor shown in the row header, e.g. "Pages 1–4 · 4 pages"
    /// (splitter) or the original filename (bulk rename).
    let subtitle: String
    let baseFileName: String
    @Binding var suffix: String
    /// The parent's FocusState binding — passed directly so that Tab/click
    /// both update the parent (triggering auto-scroll) without a local copy.
    var fieldFocus: FocusState<Int?>.Binding
    let instrumentNames: [String]   // ordered, deduplicated, capitalised
    let allSuffixes: [Int: String]  // snapshot of all rows' current suffixes
    @Binding var previewOffset: CGPoint

    /// Separator inserted between base name and suffix in output filenames.
    /// Mirrors the setting in Preferences → Renamer.
    @AppStorage("filenameSeparator") private var filenameSeparator: String = " - "

    /// Step sizes in PDF points.
    /// cropH = 100 pt; stepV = 25 pt → 75 % overlap between consecutive positions.
    /// cropW ≈ 200 pt; stepH = 100 pt → 50 % overlap horizontally.
    private let stepV: CGFloat = 25
    private let stepH: CGFloat = 100

    private var isFieldFocused: Bool { fieldFocus.wrappedValue == fileIndex }

    // Arrow-key selection index into the suggestions list (nil = field, not dropdown)
    @State private var selectedSuggestionIndex: Int? = nil

    private var finalFileName: String {
        suffix.isEmpty
            ? "\(baseFileName)\(filenameSeparator)\(fileIndex + 1).pdf"
            : "\(baseFileName)\(filenameSeparator)\(suffix).pdf"
    }

    // ── Pan overlay ─────────────────────────────────────────────────────────
    /// Arrow buttons overlaid on each preview strip; all rows share the same
    /// previewOffset binding so pressing any arrow moves every strip at once.
    ///
    /// Uses Color.clear + .overlay(alignment:) rather than VStack/HStack+Spacer
    /// so button positions are anchored directly — no Spacer needs a concrete
    /// height proposal, so buttons never collapse when the image finishes loading.
    private var panOverlay: some View {
        Color.clear
            .overlay(alignment: .top) {
                panButton("chevron.up")   { previewOffset.y += stepV }
                    .padding(.top, 6)
            }
            .overlay(alignment: .bottom) {
                panButton("chevron.down") { previewOffset.y -= stepV }
                    .padding(.bottom, 6)
            }
            .overlay(alignment: .leading) {
                panButton("chevron.left")  { previewOffset.x -= stepH }
                    .padding(.leading, 6)
            }
            .overlay(alignment: .trailing) {
                panButton("chevron.right") { previewOffset.x += stepH }
                    .padding(.trailing, 6)
            }
            // Reset button — top-right, only visible when panned away from default
            .overlay(alignment: .topTrailing) {
                if previewOffset != .zero {
                    panButton("arrow.uturn.backward") { previewOffset = .zero }
                        .padding(6)
                }
            }
    }

    private func panButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(.ultraThinMaterial)
                .foregroundColor(.secondary)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
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
            if parts.count >= 2, let last = parts.last, let n = Int(last), n > 0 {
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
                Text(subtitle)
                    .foregroundColor(.secondary)
                Spacer()
            }

            // ── Instrument name crop with pan overlay ────────────────
            if let pg = page {
                // panOverlay is applied as .overlay on the FRAMED container rather
                // than as a ZStack sibling of PageInstrumentPreview.  This guarantees
                // the overlay always receives the container's fixed 150 pt height as
                // its layout size, completely independent of whatever
                // PageInstrumentPreview draws (or redraws) inside.
                PageInstrumentPreview(page: pg, offset: previewOffset)
                    .allowsHitTesting(false)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
                    .overlay { panOverlay }
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.12))
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
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

// MARK: - Prefix Order Step

/// Matches the best instrument name in `filename` against `order`, returning the
/// order-list index (0-based) or nil.  Mirrors RenamerManager.detectInstrument but
/// works as a free function so it can be used by PrefixOrderStepView without a manager.
private func matchInstrumentOrder(in filename: String, order: [String]) -> Int? {
    let lower = filename.lowercased()
    let sorted = order.enumerated()
        .map { ($0.offset, $0.element) }
        .sorted { $0.1.count > $1.1.count }   // longest first → "bass clarinet" beats "clarinet"
    var matches: [(index: Int, position: Int)] = []
    for (idx, instrument) in sorted {
        if let range = lower.range(of: instrument.lowercased()) {
            let pos = lower.distance(from: lower.startIndex, to: range.lowerBound)
            matches.append((idx, pos))
        }
    }
    return matches.min(by: { $0.position < $1.position })?.index
}

/// A single item flowing through the Prefix Order step.
/// For the Splitter, `originalURL` is nil (file not on disk yet).
/// For Bulk Rename, `originalURL` is the current URL of the file to rename.
struct PrefixItem: Identifiable {
    let id: Int              // original zero-based index (stable across reordering)
    let proposedName: String // full filename incl. .pdf, e.g. "Beethoven - Flute.pdf"
    let page: PDFPage?
    var originalURL: URL? = nil
}

/// One row in PrefixOrderStepView — shows position, thumbnail, proposed name → final name.
private struct PrefixOrderRow: View {
    let item: PrefixItem
    let position: Int
    let finalName: String
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // Up / down arrows
            VStack(spacing: 2) {
                Button { onMoveUp?() } label: {
                    Image(systemName: "chevron.up").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(onMoveUp == nil)

                Button { onMoveDown?() } label: {
                    Image(systemName: "chevron.down").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(onMoveDown == nil)
            }
            .padding(.leading, 8)

            // Position badge
            Text(String(format: "%02d", position))
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(.accentColor)
                .frame(width: 30, alignment: .center)

            // Filenames
            VStack(alignment: .leading, spacing: 4) {
                Text(item.proposedName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(finalName)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Full-screen step that lets the user set and reorder prefix numbering.
/// Used as Step 3 (Splitter) or Step 2 (Bulk Rename).
struct PrefixOrderStepView: View {
    let stepLabel: String           // "Step 3" or "Step 2"
    let initialItems: [PrefixItem]
    @Binding var ensembleType: EnsembleType
    let onBack: () -> Void
    let onApply: ([PrefixItem]) -> Void  // reordered list; caller handles save

    @State private var items: [PrefixItem]
    @AppStorage("prefixSeparator") private var prefixSeparator: String = " - "

    init(stepLabel: String,
         initialItems: [PrefixItem],
         ensembleType: Binding<EnsembleType>,
         onBack: @escaping () -> Void,
         onApply: @escaping ([PrefixItem]) -> Void) {
        self.stepLabel = stepLabel
        self.initialItems = initialItems
        self._ensembleType = ensembleType
        self.onBack = onBack
        self.onApply = onApply
        let order = InstrumentOrders.getOrder(for: ensembleType.wrappedValue)
        self._items = State(initialValue: Self.autoSorted(initialItems, by: order))
    }

    // MARK: Auto-sort helpers

    static func autoSorted(_ items: [PrefixItem], by order: [String]) -> [PrefixItem] {
        var matched:   [(rank: Int, item: PrefixItem)] = []
        var unmatched: [PrefixItem] = []
        for item in items {
            if let rank = matchInstrumentOrder(in: item.proposedName, order: order) {
                matched.append((rank, item))
            } else {
                unmatched.append(item)
            }
        }
        return matched.sorted { $0.rank < $1.rank }.map(\.item) + unmatched
    }

    private func prefixedName(for item: PrefixItem, at position: Int) -> String {
        "\(String(format: "%02d", position))\(prefixSeparator)\(item.proposedName)"
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar ──────────────────────────────────────────────────
            HStack {
                Spacer()
                Text("\(stepLabel): Prefix Files")
                    .font(.title2).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // ── Ensemble type re-sort bar ─────────────────────────────────
            HStack(spacing: 12) {
                Text("Auto-sort by ensemble:")
                    .font(.headline)
                Picker("", selection: $ensembleType) {
                    Text("Wind Band").tag(EnsembleType.band)
                    Text("Jazz Band").tag(EnsembleType.jazz)
                    Text("Orchestra").tag(EnsembleType.orchestra)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .onChange(of: ensembleType) { newType in
                    let order = InstrumentOrders.getOrder(for: newType)
                    withAnimation { items = Self.autoSorted(items, by: order) }
                }
                Button("Re-sort") {
                    let order = InstrumentOrders.getOrder(for: ensembleType)
                    withAnimation { items = Self.autoSorted(items, by: order) }
                }
                .help("Re-apply instrument order to the current list")
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // ── File list ─────────────────────────────────────────────────
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                        PrefixOrderRow(
                            item: item,
                            position: position + 1,
                            finalName: prefixedName(for: item, at: position + 1),
                            onMoveUp:   position > 0              ? { items.swapAt(position, position - 1) } : nil,
                            onMoveDown: position < items.count - 1 ? { items.swapAt(position, position + 1) } : nil
                        )
                        if position < items.count - 1 { Divider() }
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            // ── Bottom bar ────────────────────────────────────────────────
            HStack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button { onApply(items) } label: {
                    Label("Apply & Save", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

// MARK: - Rename Summary

/// Final screen shown after files are written to disk.
struct RenameSummaryView: View {
    let finalNames: [String]
    /// Non-nil for the Splitter (lets us offer "Show in Finder"). Nil for Bulk Rename.
    let outputFolderURL: URL?
    let onStartOver: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // ── Success header ────────────────────────────────────────────
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(.green)
                Text("Done!")
                    .font(.title).fontWeight(.bold)
                Text("\(finalNames.count) file\(finalNames.count == 1 ? "" : "s") saved successfully.")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
            .padding(.bottom, 20)

            Divider()

            // ── File list ─────────────────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(finalNames.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.fill")
                                .foregroundColor(.accentColor)
                                .font(.caption)
                            Text(finalNames[i])
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                    }
                }
                .padding()
            }

            Divider()

            // ── Bottom bar ────────────────────────────────────────────────
            HStack {
                if let url = outputFolderURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(action: onStartOver) {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

// MARK: - Page Instrument Preview
struct PageInstrumentPreview: View {
    let page: PDFPage
    /// Pan offset in PDF points from the default top-left position.
    /// Positive y = up the page; negative y = down; positive x = right; negative x = left.
    var offset: CGPoint = .zero

    // Two-phase rendering for performance:
    //   1. Full page rendered ONCE async on appear (expensive PDF draw, background thread).
    //   2. Panning crops from the cached image instantly — no re-render needed.
    @State private var cachedPageImage: NSImage?
    @State private var displayImage: NSImage?

    var body: some View {
        Group {
            if let img = displayImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
                Color.gray.opacity(0.08)
            }
        }
        .task {
            // Render the full page once on a background thread, then extract initial crop.
            let full = await Self.renderFullPageAsync(page: page)
            cachedPageImage = full
            displayImage = Self.cropToStrip(from: full, page: page, offset: .zero)
        }
        .onChange(of: offset) { newOffset in
            // Fast path: crop from the cached image — no PDF re-render required.
            displayImage = Self.cropToStrip(from: cachedPageImage, page: page, offset: newOffset)
        }
    }

    // Render the full page at 2× resolution on a background thread.
    // Using thumbnail(of:for:) which correctly respects page rotation.
    private static func renderFullPageAsync(page: PDFPage) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let p = page
            DispatchQueue.global(qos: .userInitiated).async {
                let mediaBox = p.bounds(for: .mediaBox)
                let rotation = ((p.rotation % 360) + 360) % 360
                let scale: CGFloat = 2.0
                let size: NSSize = rotation == 90 || rotation == 270
                    ? NSSize(width: mediaBox.height * scale, height: mediaBox.width * scale)
                    : NSSize(width: mediaBox.width  * scale, height: mediaBox.height * scale)
                continuation.resume(returning: p.thumbnail(of: size, for: .mediaBox))
            }
        }
    }

    // Crop a strip from the cached full-page image.
    // CGImage origin is top-left; PDF origin is bottom-left — Y axis flipped in conversion.
    private static func cropToStrip(from pageImage: NSImage?, page: PDFPage, offset: CGPoint) -> NSImage? {
        guard let pageImage,
              let cg = pageImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let mediaBox = page.bounds(for: .mediaBox)
        let rotation  = ((page.rotation % 360) + 360) % 360
        let pageW = rotation == 90 || rotation == 270 ? mediaBox.height : mediaBox.width
        let pageH = rotation == 90 || rotation == 270 ? mediaBox.width  : mediaBox.height

        let cropH: CGFloat = 100
        let cropW = min(pageW * 0.4, 200)

        // Default anchor: top-left of the page (PDF y = pageH - cropH from the bottom edge).
        let defaultY = pageH - cropH
        let clampedX = min(max(offset.x, 0), pageW - cropW)
        let clampedY = min(max(defaultY + offset.y, 0), defaultY)

        // Convert PDF rect → CGImage pixel rect (flip Y: CGImage y=0 is top of page).
        let sX = CGFloat(cg.width)  / pageW
        let sY = CGFloat(cg.height) / pageH
        let pixRect = CGRect(
            x: (clampedX * sX).rounded(),
            y: ((pageH - clampedY - cropH) * sY).rounded(),
            width:  (cropW * sX).rounded(),
            height: (cropH * sY).rounded()
        )

        guard let cropped = cg.cropping(to: pixRect) else { return nil }
        return NSImage(cgImage: cropped, size: CGSize(width: cropW, height: cropH))
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
    let pageRotationOverrides: [Int: Int]
    let onRotateCurrentPageLeft:  () -> Void
    let onRotateCurrentPageRight: () -> Void

    var totalPages: Int { document.pageCount }

    var totalRotationForCurrentPage: Int {
        let pageNumber = currentPage + 1
        var rotation = baseRotation.degrees

        let shouldApplyAdditional: Bool
        switch additionalRotationMode {
        case .odd:  shouldApplyAdditional = pageNumber % 2 == 1
        case .even: shouldApplyAdditional = pageNumber % 2 == 0
        case .none: shouldApplyAdditional = false
        }
        if shouldApplyAdditional { rotation += additionalRotationAngle.degrees }

        rotation += pageRotationOverrides[currentPage, default: 0]

        return ((rotation % 360) + 360) % 360
    }

    var rotationDescription: String {
        if totalRotationForCurrentPage == 0 { return "No rotation" }
        let hasIndividual = pageRotationOverrides[currentPage, default: 0] != 0
        return hasIndividual
            ? "Rotated \(totalRotationForCurrentPage)° (this page)"
            : "Rotated \(totalRotationForCurrentPage)°"
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

                // Rotate-left button · page info · rotate-right button
                HStack(spacing: 10) {
                    Button(action: onRotateCurrentPageLeft) {
                        Image(systemName: "rotate.left")
                    }
                    .buttonStyle(.bordered)
                    .help("Rotate this page 90° counter-clockwise (,)")

                    VStack(spacing: 4) {
                        Text("Page \(currentPage + 1) of \(totalPages)")
                            .font(.headline)

                        Text(rotationDescription)
                            .font(.caption)
                            .foregroundColor(totalRotationForCurrentPage > 0 ? .orange : .secondary)
                            .fontWeight(totalRotationForCurrentPage > 0 ? .semibold : .regular)
                    }

                    Button(action: onRotateCurrentPageRight) {
                        Image(systemName: "rotate.right")
                    }
                    .buttonStyle(.bordered)
                    .help("Rotate this page 90° clockwise (.)")
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
    
    func saveRotatedPDF(to url: URL, baseRotation: RotationAngle, additionalRotationMode: RotationMode, additionalRotationAngle: RotationAngle, pageRotationOverrides: [Int: Int] = [:], completion: PDFAlertHandler) {
        guard let document = pdfDocument else { return }

        let newDocument = PDFDocument()

        for pageIndex in 0..<document.pageCount {
            guard let originalPage = document.page(at: pageIndex),
                  let page = originalPage.copy() as? PDFPage else { continue }

            let pageNumber = pageIndex + 1

            if baseRotation.degrees != 0 {
                page.rotation += baseRotation.degrees
            }

            // Per-page individual rotation (applied on top of the base rotation)
            let individualDegrees = pageRotationOverrides[pageIndex, default: 0]
            if individualDegrees != 0 {
                page.rotation += individualDegrees
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
    
    func saveSplitPDF(to folderURL: URL, splitMarkers: Set<Int>, baseFileName: String, customFileNames: [Int: String], pageToFileMapping: [Int: Int], separator: String = "_", completion: PDFAlertHandler) {
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
                fileName = "\(baseFileName)\(separator)\(customSuffix).pdf"
            } else {
                fileName = "\(baseFileName)\(separator)\(fileIndex + 1).pdf"
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
