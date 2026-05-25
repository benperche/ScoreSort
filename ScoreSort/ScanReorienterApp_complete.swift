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
// import Sparkle  // Re-enable for DMG/direct distribution builds

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

// MARK: - Sparkle Updater (disabled for App Store / TestFlight builds)
// Re-enable the class below and uncomment `import Sparkle` when building for DMG distribution.
//
// final class UpdaterViewModel: ObservableObject {
//     private let updaterController: SPUStandardUpdaterController
//     @Published var canCheckForUpdates = false
//     init() {
//         updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
//         updaterController.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
//     }
//     func checkForUpdates() { updaterController.updater.checkForUpdates() }
// }

// MARK: - Main App
@main
struct ScoreSortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var renamerManager = RenamerManager()
    @StateObject private var presetStore = EnsemblePresetStore()
    // @StateObject private var updaterViewModel = UpdaterViewModel()  // Re-enable for DMG builds
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(renamerManager)
                .environmentObject(presetStore)
        }
        // ── Screenshot size ───────────────────────────────────────────────────
        // Uncomment the line below when taking App Store screenshots (1280×800).
        // Re-comment it before shipping so users can freely resize the window.
         .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About ScoreSort") {
                    openWindow(id: "about")
                }
            }
            // CommandGroup(after: .appInfo) {  // Re-enable for DMG builds (needs Sparkle)
            //     Button("Check for Updates\u{2026}") { updaterViewModel.checkForUpdates() }
            //     .disabled(!updaterViewModel.canCheckForUpdates)
            // }
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
            TabView(selection: Binding(
                get: { appState.selectedTab },
                set: { newValue in DispatchQueue.main.async { appState.selectedTab = newValue } }
            )) {
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
        .onAppear { DispatchQueue.main.async { syncMenuClosures() } }
        .onChange(of: selectedFiles)          { DispatchQueue.main.async { syncMenuFlags() } }
        .onChange(of: combineManager.files)   { DispatchQueue.main.async { syncMenuFlags() } }
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

                        Button(action: addBlankPage) {
                            Label("Add Blank Page", systemImage: "doc.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .help("Insert a blank A4 page after the selected file (or at the end)")

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
        panel.allowedContentTypes = [.pdf, .jpeg, .png, .tiff, .bmp, .gif, .heic]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.title = "Select PDF or Image Files"
        panel.message = "Select PDF or image files, or select a folder to add all supported files inside it"

        panel.beginSheetModal(for: window) { response in
            self.menuState.isPanelOpen = false
            if response == .OK {
                let expanded = Self.expandToSupportedFiles(panel.urls)
                self.combineManager.addFiles(urls: expanded, undoManager: self.undoManager)
            }
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
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
            let expanded = Self.expandToSupportedFiles(collected)
            if expanded.isEmpty {
                showNSAlert(title: "Unsupported File Type",
                            message: "ScoreSort can combine PDFs and images (JPEG, PNG, TIFF, HEIC, BMP, GIF). The dropped item(s) were not recognised.",
                            isError: true)
            } else {
                self.combineManager.addFiles(urls: expanded, undoManager: self.undoManager)
            }
        }
    }

    static let supportedExtensions: Set<String> = ["pdf", "jpg", "jpeg", "png", "tif", "tiff", "heic", "bmp", "gif"]

    /// Expands a mixed list of file and folder URLs into a flat, sorted list of supported file URLs.
    /// Folders are enumerated recursively; unsupported files are ignored.
    static func expandToSupportedFiles(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let enumerator = fm.enumerator(at: url,
                                                     includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                for case let fileURL as URL in enumerator
                where supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                    result.append(fileURL)
                }
            } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
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

    private func addBlankPage() {
        combineManager.addBlankPage(after: selectedFiles, undoManager: undoManager)
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
                .foregroundColor(file.isBlankPage ? .secondary : .primary)
                .italic(file.isBlankPage)
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
                : isUnmatched ? Color.orange.opacity(0.12)
                : file.isBlankPage ? Color.gray.opacity(0.08) : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture { onToggleSelect() }
        .onChange(of: copiesFieldFocused) { _, focused in
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
        .onChange(of: copiesFocused) { _, focused in
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
        .onChange(of: presetStore.selectedPresetId) { loadDraft() }
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
                
                shortcutSection("Renamer") {
                    shortcutRow("⌘,", "Open Preferences")
                }
                
                shortcutSection("Split PDF") {
                    shortcutRow("← / →", "Previous / next page")
                    shortcutRow("⌘← / ⌘→", "First / last page")
                    shortcutRow("Space", "Toggle split marker")
                    shortcutRow("↑ / ↓", "Jump between output files")
                    shortcutRow("⌫", "Toggle skip on selected output file(s)")
                }
                
                shortcutSection("Rotate Pages") {
                    shortcutRow("← / →", "Previous / next page")
                    shortcutRow(", / .", "Rotate current page left / right")
                }
                
                shortcutSection("Tabs") {
                    shortcutRow("⌘1", "Combine PDFs")
                    shortcutRow("⌘2", "Rename Files")
                    shortcutRow("⌘3", "Split PDF")
                    shortcutRow("⌘4", "Rotate Pages")
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
                "The app is designed to work closely with the macOS Finder. Usually the easiest way to get files into the app will be by dragging files or folders onto the relevant page of this app.",
                "You can return to this tour at any time via **Help → Welcome Tour**."
            ],
            tipText: "If your files live in Google Drive or Dropbox, install the desktop app so your folders appear in Finder.",
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
                "You can save your usual instrument allocations as **Ensemble Presets** in Preferences. These can be viewed in the Presets sidebar to help you remember the normal number of parts required. Use **Apply to Files** to attempt to automatically match your preset allocations to your filenames.",
                "When ready, click **Create PDF** to save the combined file, or **Open in Preview** to print directly without saving a new document.",
                "**Advanced: Collate Sets:** Select a group of parts and press **C** to interleave their pages in the output document. Ideal where you have a number of parts required for multiple players, for example in a percussion section — each player's copies will print together in a ready-to-distribute stack."
            ],
            tipText: "⌫ removes selected files · ⌘Z undoes any change · ⌘↑ / ⌘↓ reorders",
            imageName: "tour-combiner"
        ),

        // ── Page 3: Rename Files ──────────────────────────────────────────
        WelcomeTourPage(
            icon: "folder.badge.gearshape",
            iconColor: .orange,
            tabShortcut: "⌘2",
            title: "Rename Files",
            useCase: "You have a folder of parts with unhelpful filenames (e.g. `scan001.pdf`) and want to rename them consistently.",
            bodyParagraphs: [
                "Drag a folder onto the **right side** to replace the filenames of multiple files at once — for example for parts downloaded from IMSLP. A preview window shows the top of each file so you can identify each part.",
                "Enter a base name (e.g. `Beethoven Symphony 5`), then fill in each instrument name. The app intelligently suggests instrument names and numbers as you type — accept suggestions with the arrow keys and Return.",
                "Once all names are filled in, toggle **Prefix score order** to step through the score-order flow, or skip straight to saving files to a chosen folder."
            ],
            tipText: "Tab moves between instrument name fields · You can change the default score order in Preferences",
            imageName: "tour-renamer"
        ),

        // ── Page 4: Score Order Sorter ────────────────────────────────────
        WelcomeTourPage(
            icon: "list.number",
            iconColor: .orange,
            tabShortcut: "⌘2",
            title: "Score Order Sorter",
            useCase: "You have a folder of already-named parts and want to add score-order prefix numbers so they sort correctly in Finder.",
            bodyParagraphs: [
                "Drag a folder onto the **left side** of the Rename Files tab. The app detects instrument names and assigns sequential prefix numbers automatically (e.g. `01 - Beethoven - Flute.pdf`).",
                "Files whose instrument name isn't recognised appear at the top, highlighted in orange — double-click any of them to assign a number manually.",
                "Adjust the order as needed using the up/down arrows, then click **Rename Files** to apply."
            ],
            tipText: "Switch between Wind Band, Jazz Band, and Orchestra orderings to match your ensemble",
            imageName: "tour-score-order"
        ),

        // ── Page 5: Split PDF ─────────────────────────────────────────────
        WelcomeTourPage(
            icon: "scissors",
            iconColor: .green,
            tabShortcut: "⌘3",
            title: "Split PDF",
            useCase: "You have one large PDF — e.g. a complete scan of all parts bound together — and need to split it into separate instrument files.",
            bodyParagraphs: [
                "Drop the PDF and use **← →** to move through pages. Press **Space** to toggle a split marker, and **↑ ↓** to jump to the first page of each output file. Equally-spaced markers can be placed automatically using the **stride** control. Once you have entered your split markers, you can also choose to skip certain sections of the PDF in the output using your **Delete** key.",
                "In Step 2, name each output file — the same flow as Rename Files. Toggle **Prefix score order** to add score-order numbers automatically in Step 3."
            ],
            tipText: "⌘← / ⌘→ jumps to the first or last page · Space toggles a split marker · Delete skips the selected file",
            imageName: "tour-splitter"
        ),

        // ── Page 6: Rotate Pages ──────────────────────────────────────────
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
            imageName: "tour-rotator"
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
            }

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
        .frame(width: 700)
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

            // ── Screenshot — full image, no cropping ──────────────────────
            if let name = page.imageName, let nsImage = NSImage(named: name) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        Rectangle()
                            .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    )
            }

            // ── Text content ──────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 0) {

                // Header row
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: page.icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(page.iconColor)

                    Text(page.title)
                        .font(.headline)

                    Spacer()

                    if let shortcut = page.tabShortcut {
                        Text(shortcut)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(4)
                    }
                }
                .padding(.top, page.imageName != nil ? 14 : 28)

                if let useCase = page.useCase {
                    Text(useCase)
                        .font(.callout)
                        .italic()
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                }

                Divider()
                    .padding(.vertical, 10)

                // Body paragraphs
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(page.bodyParagraphs.indices, id: \.self) { i in
                        Text(markdownString: page.bodyParagraphs[i])
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(1.5)
                    }
                }

                // Tip callout
                if let tip = page.tipText {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.yellow)
                            .font(.footnote)
                            .padding(.top, 1)
                        Text(markdownString: tip)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(Color.yellow.opacity(0.25), lineWidth: 1)
                    )
                    .cornerRadius(7)
                    .padding(.top, 12)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
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

    func duplicatePreset(_ id: UUID) {
        guard let original = presets.first(where: { $0.id == id }) else { return }
        let copy = EnsemblePreset(
            id: UUID(),
            name: "Copy of \(original.name)",
            parts: original.parts.map { PresetPart(id: UUID(), name: $0.name, copies: $0.copies) }
        )
        if let idx = presets.firstIndex(where: { $0.id == id }) {
            presets.insert(copy, at: idx + 1)
        } else {
            presets.append(copy)
        }
        selectedPresetId = copy.id
        save()
    }

    func exportCSV() -> String {
        var lines = ["Preset Name,Part Name,Copies"]
        for preset in presets {
            for part in preset.parts {
                func escape(_ s: String) -> String {
                    s.contains(",") || s.contains("\"") ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
                }
                lines.append("\(escape(preset.name)),\(escape(part.name)),\(part.copies)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func importCSV(_ string: String) {
        var partsByPreset: [String: [PresetPart]] = [:]
        var order: [String] = []
        let lines = string.components(separatedBy: .newlines).dropFirst()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let fields = Self.parseCSVLine(trimmed)
            guard fields.count >= 2 else { continue }
            let presetName = fields[0]
            let partName   = fields[1]
            let copies     = fields.count >= 3 ? (Int(fields[2]) ?? 1) : 1
            if partsByPreset[presetName] == nil {
                partsByPreset[presetName] = []
                order.append(presetName)
            }
            partsByPreset[presetName]?.append(PresetPart(name: partName, copies: copies))
        }
        for name in order {
            if let parts = partsByPreset[name], !parts.isEmpty {
                addPreset(name: name, parts: parts)
            }
        }
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                let next = line.index(after: i)
                if inQuotes && next < line.endIndex && line[next] == "\"" {
                    current.append("\"")
                    i = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields
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
    /// True for synthetic blank-page entries (url is unused).
    var isBlankPage: Bool = false
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
    func addBlankPage(after selectedIDs: Set<UUID>, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        let dummy = URL(fileURLWithPath: "/dev/null")
        let entry = CombineFile(url: dummy, name: "Blank Page", pageCount: 1, copies: 1, isBlankPage: true)
        if let lastIdx = files.indices.last(where: { selectedIDs.contains(files[$0].id) }) {
            files.insert(entry, at: lastIdx + 1)
        } else {
            files.append(entry)
        }
        registerUndo(undoManager: undoManager, actionName: "Add Blank Page",
                     restoringFiles: bf, restoringGroups: bg)
    }

    func addFiles(urls: [URL], undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                guard let document = PDFDocument(url: url) else { continue }
                files.append(CombineFile(url: url, name: url.lastPathComponent, pageCount: document.pageCount, copies: 1))
            } else {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
                let frameCount = CGImageSourceGetCount(src)
                guard frameCount > 0 else { continue }
                files.append(CombineFile(url: url, name: url.lastPathComponent, pageCount: frameCount, copies: 1))
            }
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
        var bookmarks: [(label: String, pageIndex: Int)] = []

        func addPages(from file: CombineFile, copyIndex: Int, totalCopies: Int) {
            if file.isBlankPage {
                if let blank = createBlankPage() { doc.insert(blank, at: idx); idx += 1 }
                return
            }
            let ext = file.url.pathExtension.lowercased()
            let baseName = file.name.hasSuffix(".pdf") ? String(file.name.dropLast(4)) : file.name
            let label = totalCopies > 1 ? "\(baseName) \(copyIndex + 1)/\(totalCopies)" : baseName
            bookmarks.append((label: label, pageIndex: idx))
            if ext != "pdf" {
                for page in pdfPages(fromImageAt: file.url) { doc.insert(page, at: idx); idx += 1 }
            } else {
                guard let src = PDFDocument(url: file.url) else { return }
                for p in 0..<src.pageCount {
                    if let page = src.page(at: p) { doc.insert(page, at: idx); idx += 1 }
                }
                if addBlankPages && src.pageCount % 2 == 1 {
                    if let blank = createBlankPage() { doc.insert(blank, at: idx); idx += 1 }
                }
            }
        }

        var i = 0
        while i < files.count {
            if let gid = files[i].collateGroupId, let group = collateGroups[gid] {
                var groupFiles: [CombineFile] = []
                while i < files.count && files[i].collateGroupId == gid { groupFiles.append(files[i]); i += 1 }
                for ci in 0..<group.copies { for f in groupFiles { addPages(from: f, copyIndex: ci, totalCopies: group.copies) } }
            } else {
                let file = files[i]; i += 1
                for ci in 0..<file.copies { addPages(from: file, copyIndex: ci, totalCopies: file.copies) }
            }
        }

        let root = PDFOutline()
        for (label, pageIndex) in bookmarks {
            if let page = doc.page(at: pageIndex) {
                let item = PDFOutline()
                item.label = label
                item.destination = PDFDestination(page: page, at: .zero)
                root.insertChild(item, at: root.numberOfChildren)
            }
        }
        doc.outlineRoot = root

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
        var bookmarks: [(label: String, pageIndex: Int)] = []

        func addPages(from file: CombineFile, copyIndex: Int, totalCopies: Int) {
            if file.isBlankPage {
                if let blank = createBlankPage() { doc.insert(blank, at: idx); idx += 1 }
                return
            }
            let ext = file.url.pathExtension.lowercased()
            let baseName = file.name.hasSuffix(".pdf") ? String(file.name.dropLast(4)) : file.name
            let label = totalCopies > 1 ? "\(baseName) \(copyIndex + 1)/\(totalCopies)" : baseName
            bookmarks.append((label: label, pageIndex: idx))
            if ext != "pdf" {
                for page in pdfPages(fromImageAt: file.url) { doc.insert(page, at: idx); idx += 1 }
            } else {
                guard let src = PDFDocument(url: file.url) else { return }
                for p in 0..<src.pageCount {
                    if let page = src.page(at: p) { doc.insert(page, at: idx); idx += 1 }
                }
                if addBlankPages && src.pageCount % 2 == 1 {
                    if let blank = createBlankPage() { doc.insert(blank, at: idx); idx += 1 }
                }
            }
        }

        var i = 0
        while i < files.count {
            if let gid = files[i].collateGroupId, let group = collateGroups[gid] {
                var groupFiles: [CombineFile] = []
                while i < files.count && files[i].collateGroupId == gid { groupFiles.append(files[i]); i += 1 }
                for ci in 0..<group.copies { for f in groupFiles { addPages(from: f, copyIndex: ci, totalCopies: group.copies) } }
            } else {
                let file = files[i]; i += 1
                for ci in 0..<file.copies { addPages(from: file, copyIndex: ci, totalCopies: file.copies) }
            }
        }

        let root = PDFOutline()
        for (label, pageIndex) in bookmarks {
            if let page = doc.page(at: pageIndex) {
                let item = PDFOutline()
                item.label = label
                item.destination = PDFDestination(page: page, at: .zero)
                root.insertChild(item, at: root.numberOfChildren)
            }
        }
        doc.outlineRoot = root

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("CombinedForPrint.pdf")
        guard doc.write(to: tempURL) else { onError("Error", "Failed to create temporary PDF", true); return }
        NSWorkspace.shared.open(tempURL)
    }

    private func createBlankPage() -> PDFPage? {
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842) // A4
        let blankPage = PDFPage()
        blankPage.setBounds(pageRect, for: .mediaBox)
        return blankPage
    }

    /// Renders one frame of an image file as an A4 PDF page, scaled to fit with white background.
    private func makeA4Page(from cgImage: CGImage) -> PDFPage? {
        let a4 = CGSize(width: 595, height: 842)
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        let scale = min(a4.width / imgW, a4.height / imgH)
        let drawW = imgW * scale
        let drawH = imgH * scale
        let drawRect = CGRect(x: (a4.width - drawW) / 2,
                              y: (a4.height - drawH) / 2,
                              width: drawW, height: drawH)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: Int(a4.width), height: Int(a4.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: a4))
        ctx.draw(cgImage, in: drawRect)

        guard let rendered = ctx.makeImage() else { return nil }
        let nsImage = NSImage(cgImage: rendered, size: a4)
        guard let page = PDFPage(image: nsImage) else { return nil }
        page.setBounds(CGRect(origin: .zero, size: a4), for: .mediaBox)
        return page
    }

    /// Returns all frames of an image file as A4 PDF pages.
    private func pdfPages(fromImageAt url: URL) -> [PDFPage] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        var pages: [PDFPage] = []
        for i in 0..<CGImageSourceGetCount(src) {
            guard let cgImage = CGImageSourceCreateImageAtIndex(src, i, nil),
                  let page = makeA4Page(from: cgImage) else { continue }
            pages.append(page)
        }
        return pages
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
    @State private var renameResult: (folderURL: URL?, names: [String])? = nil

    var body: some View {
        if let result = renameResult {
            // ── Done screen ───────────────────────────────────────────────
            ScoreOrderRenameSummaryView(
                renamedNames: result.names,
                folderURL: result.folderURL,
                onStartOver: {
                    renameResult = nil
                    renamerManager.clearFolder()
                },
                onRescan: {
                    renameResult = nil
                    renamerManager.scanFolder()
                }
            )
        } else {
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
        let undetected = renamerManager.operations.filter { $0.type == .undetected }
        let detected   = renamerManager.operations.filter { $0.type != .undetected }
        return ScrollView {
            LazyVStack(spacing: 0) {
                // Undetected section
                if !undetected.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("Unmatched — instrument not recognised")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.10))

                    ForEach(undetected) { operation in
                        ScoreOrderFileRow(operation: operation, isUnmatched: true) {
                            selectedFileForAssignment = operation
                        }
                        Divider()
                    }
                }

                // Detected section
                if !detected.isEmpty {
                    if !undetected.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            Text("Matched")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color(NSColor.controlBackgroundColor))
                    }

                    ForEach(detected) { operation in
                        ScoreOrderFileRow(operation: operation) {
                            selectedFileForAssignment = operation
                        }
                        Divider()
                    }
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
                Button {
                    renamerManager.executeRename { folderURL, names in
                        renameResult = (folderURL: folderURL, names: names)
                    }
                } label: {
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

// MARK: - Score Order Rename Summary

/// Full-screen done screen shown after the Score Order Sorter renames files.
private struct ScoreOrderRenameSummaryView: View {
    let renamedNames: [String]
    let folderURL: URL?
    let onStartOver: () -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // ── Success header ────────────────────────────────────────────
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(.green)
                Text("Done!")
                    .font(.title).fontWeight(.bold)
                Text("\(renamedNames.count) file\(renamedNames.count == 1 ? "" : "s") renamed successfully.")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
            .padding(.bottom, 20)

            Divider()

            // ── File list ─────────────────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(renamedNames.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.fill")
                                .foregroundColor(.accentColor)
                                .font(.caption)
                            Text(renamedNames[i])
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.vertical, 12)
            }

            Divider()

            // ── Bottom bar ─────────────────────────────────────────────────
            HStack(spacing: 12) {
                Button(action: onStartOver) {
                    Label("Start Over", systemImage: "arrow.uturn.left")
                }
                .buttonStyle(.bordered)

                if let url = folderURL {
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(action: onRescan) {
                    Label("Rescan Folder", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .help("Rescan the folder to review or continue renaming")
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

// MARK: - Score Order File Row
/// One row in the Score Order Sorter list — matches the visual style of PrefixOrderRow.
private struct ScoreOrderFileRow: View {
    let operation: RenameOperation
    var isUnmatched: Bool = false
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
        .background(
            isHovered ? Color.accentColor.opacity(0.05)
            : isUnmatched ? Color.orange.opacity(0.06)
            : Color.clear
        )
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
                    let pdfs = collected.filter { $0.pathExtension.lowercased() == "pdf" }
                    if pdfs.isEmpty {
                        showNSAlert(title: "Unsupported File Type",
                                    message: "The naming stage only accepts PDF files.",
                                    isError: true)
                    } else {
                        loadFiles(pdfs)
                    }
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
                .onChange(of: focusedField) { _, newValue in
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
        VStack(spacing: 0) {
            // ── Scrollable content ────────────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    Text("Instrument Order Preferences")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .center)

                    // ── Ensemble type selector ────────────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ensemble Type:")
                            .font(.headline)
                        Picker("Ensemble Type", selection: $ensembleType) {
                            Text("Wind Band").tag(EnsembleType.band)
                            Text("Jazz Band").tag(EnsembleType.jazz)
                            Text("Orchestra").tag(EnsembleType.orchestra)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: ensembleType) { _, newType in
                            editableOrder = InstrumentOrders.getOrder(for: newType)
                        }
                    }

                    Divider()

                    // ── Instrument list ───────────────────────────────────────
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
                                    VStack(spacing: 2) {
                                        Button(action: {
                                            if index > 0 { editableOrder.swapAt(index, index - 1) }
                                        }) {
                                            Image(systemName: "chevron.up").font(.caption)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(index == 0)

                                        Button(action: {
                                            if index < editableOrder.count - 1 {
                                                editableOrder.swapAt(index, index + 1)
                                            }
                                        }) {
                                            Image(systemName: "chevron.down").font(.caption)
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

                                    Button(action: { editableOrder.remove(at: index) }) {
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
                                .onSubmit { addInstrument() }
                            Button(action: addInstrument) {
                                Image(systemName: "plus.circle.fill")
                            }
                            .disabled(newInstrument.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    Divider()

                    // ── Suffix separator (Splitter & Bulk Rename) ─────────────
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

                    // ── Prefix separator (Score Order Sorter) ─────────────────
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

                    // ── Folder search depth ───────────────────────────────────
                    VStack(alignment: .leading, spacing: 6) {
                        @AppStorage("renamerSearchRecursively") var searchRecursively: Bool = false
                        Toggle("Search subfolders recursively", isOn: $searchRecursively)
                            .toggleStyle(.checkbox)
                        Text("When off (default), only PDFs directly inside the dropped folder are shown. When on, PDFs inside any nested subfolders are included too.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(28)
            }

            // ── Sticky footer ─────────────────────────────────────────────────
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    instrumentOrder = editableOrder
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
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
            CombinerPreferencesView()
                .tabItem { Label("Combiner", systemImage: "doc.on.doc") }

            PreferencesView(
                ensembleType: $renamerManager.ensembleType,
                instrumentOrder: $renamerManager.customInstrumentOrder,
                prefixSeparator: $renamerManager.prefixSeparator
            )
            .tabItem { Label("Renamer", systemImage: "folder.badge.gearshape") }
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
    @State private var showingDeleteConfirm = false

    var body: some View {
        HSplitView {
            // Left panel: preset list
            VStack(spacing: 0) {
                List(selection: $selectedId) {
                    ForEach(presetStore.presets) { preset in
                        Text(preset.name)
                            .tag(preset.id)
                            .contextMenu {
                                Button("Duplicate") {
                                    presetStore.duplicatePreset(preset.id)
                                    selectedId = presetStore.selectedPresetId
                                    editingPreset = presetStore.selectedPreset
                                }
                                Divider()
                                Button("Delete…", role: .destructive) {
                                    selectedId = preset.id
                                    showingDeleteConfirm = true
                                }
                            }
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
                        // Fall back to first preset if selection was lost
                        if selectedId == nil { selectedId = presetStore.presets.first?.id }
                        if selectedId != nil { showingDeleteConfirm = true }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.plain)
                    .disabled(presetStore.presets.isEmpty)

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

                    Divider()
                        .frame(height: 16)
                        .padding(.horizontal, 2)

                    Menu {
                        Button("Export All Presets…") {
                            let csv = presetStore.exportCSV()
                            let panel = NSSavePanel()
                            panel.nameFieldStringValue = "ScoreSort Presets.csv"
                            panel.allowedContentTypes = [.commaSeparatedText]
                            if panel.runModal() == .OK, let url = panel.url {
                                try? csv.write(to: url, atomically: true, encoding: .utf8)
                            }
                        }
                        Button("Import Presets from CSV…") {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.commaSeparatedText]
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url,
                               let csv = try? String(contentsOf: url, encoding: .utf8) {
                                presetStore.importCSV(csv)
                                selectedId = presetStore.presets.last?.id
                                editingPreset = presetStore.presets.last
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 24)
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

                    Text("Parts:")
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                    List {
                        ForEach(editingPreset?.parts ?? [], id: \.id) { part in
                            let idx = editingPreset?.parts.firstIndex(where: { $0.id == part.id }) ?? 0
                            let count = editingPreset?.parts.count ?? 0
                            PresetPartRow(
                                part: Binding(
                                    get: {
                                        editingPreset?.parts.first { $0.id == part.id } ?? part
                                    },
                                    set: { newVal in
                                        if let i = editingPreset?.parts.firstIndex(where: { $0.id == part.id }) {
                                            editingPreset?.parts[i] = newVal
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
                                },
                                onMoveUp: idx > 0 ? {
                                    editingPreset?.parts.move(fromOffsets: IndexSet(integer: idx), toOffset: idx - 1)
                                    saveEditing()
                                } : nil,
                                onMoveDown: idx < count - 1 ? {
                                    editingPreset?.parts.move(fromOffsets: IndexSet(integer: idx), toOffset: idx + 2)
                                    saveEditing()
                                } : nil
                            )
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
            if selectedId == nil || !presetStore.presets.contains(where: { $0.id == selectedId }) {
                selectedId = presetStore.presets.first?.id
            }
            editingPreset = presetStore.presets.first { $0.id == selectedId }
        }
        .onChange(of: selectedId) { _, newId in
            editingPreset = presetStore.presets.first { $0.id == newId }
        }
        .onChange(of: presetStore.presets) { _, updated in
            // If selection was lost (e.g. after rapid import), restore it
            if selectedId == nil || !updated.contains(where: { $0.id == selectedId }) {
                selectedId = updated.first?.id
            }
        }
        // Keep the right panel in sync when the store is changed externally
        // (e.g. "Save to Preset" from the sidebar while preferences is open).
        // Since saveEditing() always writes before this fires, reloading is safe.
        .onChange(of: presetStore.presets) { _, updated in
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
        .alert("Delete Preset?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let id = selectedId {
                    presetStore.deletePreset(id)
                    selectedId = presetStore.presets.first?.id
                    editingPreset = presetStore.presets.first
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let name = presetStore.presets.first(where: { $0.id == selectedId })?.name {
                Text("\"\(name)\" will be permanently deleted.")
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

    func scanFolder() {
        operations = []

        // Build the list of PDF files to process: either directly-supplied URLs
        // or everything enumerated from the chosen folder.
        var pdfFiles: [URL]
        if !directFiles.isEmpty {
            pdfFiles = directFiles
        } else if let folderURL = folderURL {
            let fileManager = FileManager.default
            let searchRecursively = UserDefaults.standard.bool(forKey: "renamerSearchRecursively")
            if searchRecursively {
                // Deep search: pick up PDFs anywhere inside the folder tree.
                guard let enumerator = fileManager.enumerator(at: folderURL,
                                                              includingPropertiesForKeys: [.isRegularFileKey]) else {
                    return
                }
                pdfFiles = []
                for case let fileURL as URL in enumerator
                where fileURL.pathExtension.lowercased() == "pdf" {
                    pdfFiles.append(fileURL)
                }
            } else {
                // Shallow search (default): only immediate children of the folder.
                let contents = (try? fileManager.contentsOfDirectory(
                    at: folderURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                pdfFiles = contents.filter { $0.pathExtension.lowercased() == "pdf" }
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
        
        // Sort: undetected files first (so they are immediately visible), then by new filename
        operations.sort { op1, op2 in
            let u1 = op1.type == .undetected
            let u2 = op2.type == .undetected
            if u1 && !u2 { return true }
            if !u1 && u2 { return false }
            if op1.newName.isEmpty && op2.newName.isEmpty { return op1.originalName < op2.originalName }
            if op1.newName.isEmpty { return false }
            if op2.newName.isEmpty { return true }
            return op1.newName < op2.newName
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
    
    func executeRename(
        completion: ((_ folderURL: URL?, _ renamedNames: [String]) -> Void)? = nil
    ) {
        let toRename = operations.filter { $0.type == .rename || $0.type == .correct || $0.type == .manual }

        guard !toRename.isEmpty else { return }

        var successCount = 0
        var renamedNames: [String] = []
        var errors: [String] = []

        for operation in toRename {
            guard let newURL = operation.newURL else { continue }
            do {
                try FileManager.default.moveItem(at: operation.originalURL, to: newURL)
                successCount += 1
                renamedNames.append(newURL.lastPathComponent)
            } catch {
                errors.append("\(operation.originalName): \(error.localizedDescription)")
            }
        }

        if !errors.isEmpty {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Partial Success"
            let errorList = errors.prefix(5).joined(separator: "\n")
            var message = "Renamed \(successCount) file(s), but \(errors.count) failed:\n\n\(errorList)"
            if errors.count > 5 { message += "\n... and \(errors.count - 5) more" }
            errorAlert.informativeText = message
            errorAlert.alertStyle = .warning
            errorAlert.runModal()
        }

        // If a completion handler is provided, let the caller show the summary
        // screen before rescanning (so we don't immediately wipe the result).
        if let completion {
            completion(folderURL, renamedNames)
        } else {
            scanFolder()
        }
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
        "program notes",
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
        "special alto saxophone",
        "special alto sax",
        "alto saxophone",
        "saxophone alto",
        "alto sax",
        "sax alto",
        "alto",
        "tenor sax",
        "tenor saxophone",
        "saxophone tenor",
        "sax tenor",
        "tenor",
        "bari sax",
        "baritone sax",
        "baritone saxophone",
        "bari saxophone",
        "sax bari",
        "saxophone bari",
        "sax baritone",
        "bari",
        "baritone",
        "bass sax",
        "bass saxophone",
        "cornet",
        "trumpet",
        "horn",
        "trombone",
        "bass trombone",
        "trombone bass",
        "euphonium treble clef",
        "euphonium tc",
        "euphonium bass clef",
        "euphonium bc",
        "euphonium",
        "eupho",
        "baritone treble clef",
        "baritone tc",
        "baritone bass clef",
        "baritone bc",
        "baritone",
        "tuba",
        "guitar",
        "electric guitar",
        "keyboard",
        "piano",
        "harp",
        "violin",
        "viola",
        "cello",
        "string bass",
        "bass",
        "basses",
        "double bass",
        "timpani",
        "mallet",
        "mallets",
        "mallet percussion",
        "bells",
        "chimes",
        "glockenspiel",
        "glock",
        "xylophone",
        "xylo,",
        "vibraphone",
        "marimba",
        "drums",
        "drum set",
        "percussion",
        "snare drum",
        "bass drum",
        "cymbals",
        "crash cymbals",
        "suspended cymbal",
        "tambourine",
        "auxiliary",
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
        "organ",
        "keyboard",
        "piano",
        "celeste",
        "celesta",
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
                            
                            HStack(spacing: 0) {
                                // Left half — mode selector
                                Picker("Then also rotate:", selection: $additionalRotationMode) {
                                    Text("No additional rotation").tag(RotationMode.none)
                                    Text("Odd pages (1, 3, 5...)").tag(RotationMode.odd)
                                    Text("Even pages (2, 4, 6...)").tag(RotationMode.even)
                                }
                                .pickerStyle(.radioGroup)
                                .frame(maxWidth: .infinity, alignment: .leading)

                                // Right half — angle selector, left-aligned at window midpoint
                                if additionalRotationMode != .none {
                                    HStack(spacing: 8) {
                                        Text("By:")
                                            .foregroundColor(.secondary)
                                        Picker("Additional rotation angle", selection: $additionalRotationAngle) {
                                            Text("90°").tag(RotationAngle.rotate90)
                                            Text("180°").tag(RotationAngle.rotate180)
                                            Text("270°").tag(RotationAngle.rotate270)
                                        }
                                        .pickerStyle(.segmented)
                                        .labelsHidden()
                                        .frame(width: 200)
                                        Spacer()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Spacer()
                                        .frame(maxWidth: .infinity)
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
        .onChange(of: pdfManager.pdfDocument) { _, newValue in
            if newValue != nil {
                isViewFocused = true
            } else {
                // PDF cleared — reset all rotation state for the next document.
                baseRotation = .none
                additionalRotationMode = .none
                additionalRotationAngle = .rotate180
                pageRotationOverrides = [:]
                currentPage = 0
            }
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
        .onChange(of: pdfManager.pdfDocument) { _, newValue in
            if newValue == nil { pageRotationOverrides = [:] }
        }
        .onChange(of: isShowingSavePanel) { _, newValue in
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

/// Reads the top-level PDF outline and returns fileSizes (page counts per section)
/// and the corresponding bookmark labels, both ordered by page position.
/// Returns nil if the document has fewer than two usable top-level bookmarks.
func splitSizesFromBookmarks(_ document: PDFDocument) -> (sizes: [Int], labels: [String])? {
    let totalPages = document.pageCount
    guard totalPages > 0,
          let root = document.outlineRoot,
          root.numberOfChildren > 0 else { return nil }

    var entries: [(pageIndex: Int, label: String)] = []
    for i in 0..<root.numberOfChildren {
        guard let item = root.child(at: i),
              let page = item.destination?.page else { continue }
        let idx = document.index(for: page)
        guard idx < totalPages else { continue }
        entries.append((pageIndex: idx, label: item.label ?? ""))
    }
    entries.sort { $0.pageIndex < $1.pageIndex }

    let markers = entries.compactMap { $0.pageIndex > 0 ? $0.pageIndex : nil }
    guard !markers.isEmpty else { return nil }

    var sizes: [Int] = []
    var prev = 0
    for marker in markers {
        sizes.append(marker - prev)
        prev = marker
    }
    sizes.append(totalPages - prev)
    return (sizes: sizes, labels: entries.map { $0.label })
}

/// Parses bookmark labels of the form "NN - Piecename - Partname" and extracts
/// a shared base name and per-file suffixes. Returns nil if any label doesn't
/// match the pattern or piece names are inconsistent across labels.
func extractSplitNames(from labels: [String]) -> (baseName: String, suffixes: [String])? {
    guard !labels.isEmpty else { return nil }
    var pieceName: String? = nil
    var suffixes: [String] = []
    for label in labels {
        let parts = label.components(separatedBy: " - ")
        guard parts.count >= 3,
              parts[0].allSatisfy({ $0.isNumber }) else { return nil }
        let piece = parts[1]
        let part = parts[2...].joined(separator: " - ")
        if let existing = pieceName {
            guard piece == existing else { return nil }
        } else {
            pieceName = piece
        }
        suffixes.append(part)
    }
    guard let baseName = pieceName, !baseName.isEmpty else { return nil }
    return (baseName: baseName, suffixes: suffixes)
}

/// Returns true if every checked page in `doc` looks like A3 landscape
/// (~1190 × 842 pt — twice the width of A4 portrait).
/// Checks up to the first three pages for consistency.
/// A4 landscape has the same √2 aspect ratio, so width > 1000 pt is used to
/// distinguish the two formats.
func isA3Landscape(_ doc: PDFDocument) -> Bool {
    guard doc.pageCount > 0 else { return false }
    let pagesToCheck = min(doc.pageCount, 3)
    for i in 0..<pagesToCheck {
        guard let page = doc.page(at: i) else { return false }
        let bounds = page.bounds(for: .mediaBox)
        var w = bounds.width, h = bounds.height
        // Many scanners store landscape pages as portrait + a 90°/270° rotation flag
        // rather than actually embedding landscape dimensions.  Swap w/h in that case
        // so we test the visually-correct orientation.
        if page.rotation % 180 != 0 { swap(&w, &h) }
        // A3 landscape in PDF points: ~1190 × 842.
        // Width > 1000 distinguishes A3 from A4 landscape (which is only ~842 pt wide).
        // Upper bound 1500 gives headroom for scanners that embed slightly larger sizes.
        guard w > h, w > 1000, w < 1500 else { return false }
    }
    return true
}

/// Broader check used for the hint banner: returns `true` when pages look landscape
/// and have an aspect ratio close to A3 (√2 ≈ 1.414), but don't meet the strict
/// width thresholds of `isA3Landscape` (e.g. different scanner DPI or page size).
/// The ratio window 1.3–1.6 covers A3 at various resolutions while excluding
/// standard-width landscape scores.
func looksLikeA3Landscape(_ doc: PDFDocument) -> Bool {
    guard doc.pageCount > 0 else { return false }
    let pagesToCheck = min(doc.pageCount, 3)
    for i in 0..<pagesToCheck {
        guard let page = doc.page(at: i) else { return false }
        let bounds = page.bounds(for: .mediaBox)
        var w = bounds.width, h = bounds.height
        if page.rotation % 180 != 0 { swap(&w, &h) }
        guard w > h else { return false }          // must be landscape
        let ratio = w / h
        guard ratio >= 1.3, ratio <= 1.6 else { return false }  // ~A3/A4 proportions
    }
    return true
}

/// Splits every page in `doc` into left and right halves, returning a new
/// PDFDocument with twice as many pages.  The crop/media box of each copy is
/// set to cover only its half so viewers render the correct region.
/// `leftFirst == true` → left half precedes right half (normal reading order).
func splitA3Pages(_ doc: PDFDocument, leftFirst: Bool) -> PDFDocument {
    let result = PDFDocument()
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i) else { continue }
        let media = page.bounds(for: .mediaBox)
        let rot = ((page.rotation % 360) + 360) % 360

        // When a page carries a rotation flag, the mediaBox is in *native* coordinates
        // (the unrotated space). We must split along the native axis that corresponds
        // to the visual horizontal divide.
        //
        //   0°  → landscape stored as landscape: split on native X axis
        //  90°  → portrait native, rotated 90° CCW to look landscape:
        //          visual left = native TOP half  (high Y)
        // 180°  → landscape stored upside-down:  visual left = native RIGHT half
        // 270°  → portrait native, rotated 270° CW to look landscape:
        //          visual left = native BOTTOM half (low Y)

        let nativeFirstBox: CGRect
        let nativeSecondBox: CGRect

        switch rot {
        case 90:
            // PDF rotation is clockwise. 90° CW: native top → visual right,
            // so visual left = native BOTTOM half (low y).
            let halfH = media.height / 2.0
            let nativeTop    = CGRect(x: media.minX, y: media.minY + halfH, width: media.width, height: halfH)
            let nativeBottom = CGRect(x: media.minX, y: media.minY,         width: media.width, height: halfH)
            nativeFirstBox  = leftFirst ? nativeBottom : nativeTop
            nativeSecondBox = leftFirst ? nativeTop    : nativeBottom
        case 270:
            // 270° CW (= 90° CCW): native top → visual left,
            // so visual left = native TOP half (high y).
            let halfH = media.height / 2.0
            let nativeTop    = CGRect(x: media.minX, y: media.minY + halfH, width: media.width, height: halfH)
            let nativeBottom = CGRect(x: media.minX, y: media.minY,         width: media.width, height: halfH)
            nativeFirstBox  = leftFirst ? nativeTop    : nativeBottom
            nativeSecondBox = leftFirst ? nativeBottom : nativeTop
        case 180:
            let halfW = media.width / 2.0
            let nativeLeft  = CGRect(x: media.minX,         y: media.minY, width: halfW, height: media.height)
            let nativeRight = CGRect(x: media.minX + halfW, y: media.minY, width: halfW, height: media.height)
            // 180°: visual left → native right half
            nativeFirstBox  = leftFirst ? nativeRight : nativeLeft
            nativeSecondBox = leftFirst ? nativeLeft  : nativeRight
        default: // 0° — standard landscape
            let halfW = media.width / 2.0
            let nativeLeft  = CGRect(x: media.minX,         y: media.minY, width: halfW, height: media.height)
            let nativeRight = CGRect(x: media.minX + halfW, y: media.minY, width: halfW, height: media.height)
            nativeFirstBox  = leftFirst ? nativeLeft  : nativeRight
            nativeSecondBox = leftFirst ? nativeRight : nativeLeft
        }

        guard let firstPage  = page.copy() as? PDFPage,
              let secondPage = page.copy() as? PDFPage else { continue }
        firstPage.setBounds(nativeFirstBox,   for: .mediaBox)
        firstPage.setBounds(nativeFirstBox,   for: .cropBox)
        secondPage.setBounds(nativeSecondBox, for: .mediaBox)
        secondPage.setBounds(nativeSecondBox, for: .cropBox)
        result.insert(firstPage,  at: result.pageCount)
        result.insert(secondPage, at: result.pageCount)
    }
    return result
}

// MARK: - Split View
private enum SplitStage { case split, naming, prefix, summary }

/// Controls whether the Delete key (and the Skip button) targets a single page or
/// the whole output file that contains the current page.
enum SkipMode { case page, file }

// MARK: - Booklet Reorder Helpers

/// Saddle-stitch booklet deimposition: outer cover scanned first, front face of each
/// sheet before its back face.  Returns an `order` array where `order[readingPos]` is
/// the 0-based index *within the file segment* whose page should appear at that
/// reading position.
///
/// Verified:  N=4 → [1,2,3,0]   N=8 → [1,2,5,6,7,4,3,0]
func coverFirstFrontBackOrder(n: Int) -> [Int] {
    guard n >= 4, n % 4 == 0 else { return [] }
    var result = [Int](repeating: 0, count: n)
    for k in 1...(n / 4) {
        let scanBase = (k - 1) * 4
        // Each sheet occupies 4 scan positions: [front-left, front-right, back-left, back-right]
        // where front-left is the outer spine side.
        result[2 * k - 2]     = scanBase + 1   // reading front page 1 → right side of front scan
        result[2 * k - 1]     = scanBase + 2   // reading front page 2 → left side of back scan
        result[n - 2 * k]     = scanBase + 3   // reading back page 1  → right side of back scan
        result[n - 2 * k + 1] = scanBase + 0   // reading back page 2  → left side of front scan
    }
    return result
}

/// Alternative: inner sheets scanned before the outer cover (less common).
func innerFirstFrontBackOrder(n: Int) -> [Int] {
    guard n >= 8, n % 4 == 0 else { return [] }
    // Rotate the scan indices by n/2 (swap first half and second half of scans).
    return coverFirstFrontBackOrder(n: n).map { ($0 + n / 2) % n }
}

/// Returns candidate reorderings for an n-page booklet segment (n must be ≥ 4 and
/// a multiple of 4).  Each tuple carries a display label, a short description, and
/// the order array (`order[readingPos] = localScanIndex`).
func bookletCandidates(n: Int) -> [(label: String, description: String, order: [Int])] {
    guard n >= 4, n % 4 == 0 else { return [] }
    var result: [(String, String, [Int])] = []

    let standard = coverFirstFrontBackOrder(n: n)
    result.append((
        "Standard (cover first)",
        "Outer cover scanned first; each sheet: front face then back face.",
        standard
    ))

    if n >= 8 {
        let inner = innerFirstFrontBackOrder(n: n)
        result.append((
            "Inner-first",
            "Inner sheets scanned first, outer cover last.",
            inner
        ))
    }

    return result
}

/// A pending request to reorder the pages of one output-file segment.
struct BookletFixRequest: Identifiable {
    let id = UUID()
    let fileIndex: Int
    /// Absolute page indices (in the full document) that form this file segment, sorted.
    let pages: [Int]
    /// A snapshot of the document at the time the request was created.
    let document: PDFDocument
}

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
    /// Pages to omit from output. A file whose every page is in this set is treated as "fully skipped".
    @State private var skippedPages: Set<Int> = []
    /// File indices currently highlighted in the output-files list (for multi-select + Delete).
    @State private var selectedFileIndices: Set<Int> = []
    /// Retained reference to the local NSEvent monitor that handles the delete key.
    @State private var splitViewKeyMonitor: Any?
    @State private var bookmarkNoticeVisible = false
    /// Controls the sheet that asks "which half is page 1?" when an A3 doc is detected.
    @State private var showingA3Detection = false
    /// Set before programmatically loading an A3-split document so onChange skips re-detection.
    @State private var suppressNextA3Detection = false
    /// Set before swapping pages so onChange skips the full state-reset (preserving split markers).
    @State private var suppressDocumentReset = false
    /// True while background A3 splitting is in progress; shows a loading overlay.
    @State private var isProcessingA3 = false
    /// Shows a gentle hint banner when a PDF looks like an A3 scan but didn't trigger auto-detection.
    @State private var a3HintVisible = false
    /// Shows a brief tip banner after an A3 split loads into Step 1.
    @State private var a3SplitNoticeVisible = false
    /// Shows a brief tip banner after the first booklet fix, pointing to the per-card redo icon.
    @State private var bookletRedoNoticeVisible = false
    /// Whether Delete / the Skip button targets the current page or the whole file.
    /// Defaults to `.file`; set to `.page` automatically after an A3 split.
    @State private var skipMode: SkipMode = .file
    /// Non-nil when the "Fix Booklet Order" sheet should be presented.
    @State private var bookletFixRequest: BookletFixRequest? = nil
    /// The most recently applied booklet order, stored so the user can repeat it.
    /// Tuple carries the file's page count (for eligibility check) and the order array.
    @State private var lastBookletOrder: (n: Int, order: [Int])? = nil
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

    /// Returns all page indices for a given output file index (sorted).
    func pagesForFile(_ fileIndex: Int) -> [Int] {
        pageToFileMapping.filter { $0.value == fileIndex }.keys.sorted()
    }

    /// True if every page in the output file is in skippedPages.
    func isFileFullySkipped(_ fileIndex: Int) -> Bool {
        let pages = pagesForFile(fileIndex)
        return !pages.isEmpty && pages.allSatisfy { skippedPages.contains($0) }
    }

    /// True if some (but not all) pages in the output file are in skippedPages.
    func isFilePartiallySkipped(_ fileIndex: Int) -> Bool {
        let pages = pagesForFile(fileIndex)
        let n = pages.filter { skippedPages.contains($0) }.count
        return n > 0 && n < pages.count
    }

    /// Number of output files that have at least one non-skipped page.
    var activeFileCount: Int {
        (0..<numberOfFiles).filter { !isFileFullySkipped($0) }.count
    }

    /// Indices of output files whose every page is skipped.
    var skippedFileIndices: Set<Int> {
        Set((0..<numberOfFiles).filter { isFileFullySkipped($0) })
    }

    var body: some View {
        // The onChange lives at the Group level — outside all stage views — so it
        // fires regardless of which stage (split / naming / prefix / summary) is
        // currently active.  Previously it was buried inside splitStageBody and
        // therefore silent when a new PDF arrived during naming or later stages,
        // causing stale customFileNames from an earlier file to bleed through.
        Group {
            switch splitStage {
            case .summary:
                RenameSummaryView(
                    finalNames: summaryNames,
                    outputFolderURL: pendingFolderURL,
                    onStartOver: {
                        pdfManager.clearPDF() // onChange handles full state reset
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
                        skippedPages: skippedPages,
                        skippedFileIndices: skippedFileIndices,
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
        .onChange(of: pdfManager.pdfDocument) { _, newValue in
            if let doc = newValue {
                // Page-swap replaces the document in-place: preserve all split state.
                if suppressDocumentReset {
                    suppressDocumentReset = false
                    return
                }

                // New PDF loaded — reset the entire split flow so no state from
                // a previous file can survive into the naming or prefix stages.
                isViewFocused = true
                customFileNames.removeAll()
                previewOffset = .zero
                skippedPages = []
                selectedFileIndices = []
                skipMode = .file

                // Detect A3 landscape — pause and ask the user which half is page 1,
                // unless this load was triggered by our own A3 processing pipeline.
                if !suppressNextA3Detection && isA3Landscape(doc) {
                    showingA3Detection = true
                    return
                }
                // If the page proportions look A3-like but the strict check didn't fire
                // (e.g. unusual scanner DPI), show a gentle hint banner instead.
                if !suppressNextA3Detection && looksLikeA3Landscape(doc) {
                    withAnimation { a3HintVisible = true }
                }
                suppressNextA3Detection = false
                setupSplitState()
            } else {
                // PDF cleared — reset all split flow state so nothing bleeds
                // into the next session regardless of which stage we were on.
                fileSizes = []
                currentPage = 0
                customFileNames.removeAll()
                previewOffset = .zero
                splitStage = .split
                baseFileName = ""
                prefixItems = []
                summaryNames = []
                pendingFolderURL = nil
                skippedPages = []
                selectedFileIndices = []
                skipMode = .file
                lastBookletOrder = nil
                bookletRedoNoticeVisible = false
                a3HintVisible = false
            }
        }
        .sheet(isPresented: $showingA3Detection) {
            A3SplitChoiceView(
                onChoose: { leftFirst in
                    guard let original = pdfManager.pdfDocument else { return }
                    showingA3Detection = false
                    isProcessingA3 = true
                    // Run the crop-box splitting on a background thread so the
                    // UI stays responsive on large documents.
                    DispatchQueue.global(qos: .userInitiated).async {
                        let splitDoc = splitA3Pages(original, leftFirst: leftFirst)
                        DispatchQueue.main.async {
                            isProcessingA3 = false
                            // Switch to page-skip mode so Delete skips individual pages,
                            // which is more useful after an A3 split where blank pages
                            // often need to be removed one at a time.
                            skipMode = .page
                            suppressNextA3Detection = true
                            pdfManager.pdfDocument = splitDoc
                            // onChange fires, skips A3 re-detection, calls setupSplitState().
                            // Show a brief tip so the user knows about Swap.
                            withAnimation(.easeInOut(duration: 0.2)) { a3SplitNoticeVisible = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                                withAnimation(.easeInOut(duration: 0.2)) { a3SplitNoticeVisible = false }
                            }
                        }
                    }
                },
                onKeepAsIs: {
                    showingA3Detection = false
                    setupSplitState()
                }
            )
        }
        .sheet(item: $bookletFixRequest) { req in
            let n = req.pages.count
            let matchCount = fileSizes.filter { $0 == n }.count
            BookletOrderSheet(
                request: req,
                matchingFileCount: matchCount,
                onApply: { order in
                    bookletFixRequest = nil
                    applyBookletOrder(pages: req.pages, order: order)
                },
                onApplyToAll: matchCount > 1 ? { order in
                    bookletFixRequest = nil
                    applyBookletOrderToAllMatchingFiles(order: order, n: n)
                } : nil,
                onCancel: { bookletFixRequest = nil }
            )
        }
        .overlay {
            if isProcessingA3 {
                ZStack {
                    Color(NSColor.windowBackgroundColor).opacity(0.7)
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(1.3)
                        Text("Splitting A3 pages…")
                            .font(.headline)
                        Text("Cutting each page down the middle.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(32)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .shadow(radius: 20)
                    )
                }
                .ignoresSafeArea()
            }
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
                    Button { showingA3Detection = true } label: {
                        Label("Split as A3…", systemImage: "rectangle.split.2x1")
                    }
                    .help("Manually trigger A3 splitting — use this if auto-detection didn't fire (e.g. scanner saved landscape pages with a rotation flag)")

                    Button(action: requestBookletFix) {
                        Label("Fix Booklet Order", systemImage: "rectangle.stack")
                    }
                    .disabled(!canFixBookletOrder)
                    .help("Reorder pages in the current file segment to correct booklet scanning order. Set split markers first to define file boundaries.")

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

            if bookmarkNoticeVisible {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill")
                        .foregroundColor(.accentColor)
                    Text("Split points loaded from bookmarks")
                        .font(.callout)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { bookmarkNoticeVisible = false } }
                        label: { Image(systemName: "xmark").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if a3HintVisible {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.split.2x1")
                        .foregroundColor(.secondary)
                    Text("This looks like it might be an A3 scan — each page may contain two A4 halves.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button("Split as A3…") {
                        withAnimation { a3HintVisible = false }
                        showingA3Detection = true
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { a3HintVisible = false } }
                        label: { Image(systemName: "xmark").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(NSColor.windowBackgroundColor))
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.secondary.opacity(0.2)), alignment: .bottom)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if a3SplitNoticeVisible {
                HStack(spacing: 8) {
                    Image(systemName: "scissors")
                        .foregroundColor(.orange)
                    Text("A3 pages split in half — use **Swap with Next** (S) to fix page order if needed")
                        .font(.callout)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { a3SplitNoticeVisible = false } }
                        label: { Image(systemName: "xmark").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if bookletRedoNoticeVisible {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.play")
                        .foregroundColor(.accentColor)
                    Text("Booklet order saved — tap **⬚▶** on any matching file card to apply the same order instantly")
                        .font(.callout)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { bookletRedoNoticeVisible = false } }
                        label: { Image(systemName: "xmark").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

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
                                skippedPages: skippedPages,
                                skipMode: $skipMode,
                                onToggleMarker: { toggleSplitAt(page: currentPage) },
                                onSkipCurrentFile: {
                                    if let fi = pageToFileMapping[currentPage] {
                                        toggleSkipFiles([fi])
                                    }
                                },
                                onSkipCurrentPage: { toggleSkipPage(currentPage) },
                                onSwapWithNext: swapCurrentPageWithNext
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
                            let skippedCount = numberOfFiles - activeFileCount
                            Group {
                                if skippedCount > 0 {
                                    Text("Output Files (\(activeFileCount) active · \(skippedCount) skipped)")
                                        .font(.headline)
                                } else {
                                    Text("Output Files (\(numberOfFiles))")
                                        .font(.headline)
                                }
                            }

                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(0..<numberOfFiles, id: \.self) { fileIndex in
                                        let filePageCount = fileIndex < fileSizes.count ? fileSizes[fileIndex] : 0
                                        let canFix  = filePageCount >= 4 && filePageCount % 4 == 0
                                        let canRedo = lastBookletOrder?.n == filePageCount && canFix
                                        let bookletFixAction: (() -> Void)? = canFix ? {
                                            let pages = pagesForFile(fileIndex)
                                            guard let doc = pdfManager.pdfDocument else { return }
                                            bookletFixRequest = BookletFixRequest(
                                                fileIndex: fileIndex,
                                                pages: pages,
                                                document: doc
                                            )
                                        } : nil
                                        let bookletRedoAction: (() -> Void)? = canRedo ? {
                                            guard let last = lastBookletOrder else { return }
                                            let pages = pagesForFile(fileIndex)
                                            applyBookletOrder(pages: pages, order: last.order)
                                        } : nil
                                        FilePreviewCard(
                                            fileIndex: fileIndex,
                                            pageToFileMapping: pageToFileMapping,
                                            totalPages: totalPages,
                                            baseFileName: baseFileName,
                                            customFileNames: customFileNames,
                                            currentPage: currentPage,
                                            isFullySkipped: isFileFullySkipped(fileIndex),
                                            isPartiallySkipped: isFilePartiallySkipped(fileIndex),
                                            skippedPages: skippedPages,
                                            isSelected: selectedFileIndices.contains(fileIndex),
                                            onNavigate: { pageIndex in currentPage = pageIndex },
                                            onSelect: { isCmd, isShift in
                                                handleFileSelection(fileIndex, isCmd: isCmd, isShift: isShift)
                                            },
                                            onFixBookletOrder: bookletFixAction,
                                            onRedoBookletOrder: bookletRedoAction
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
                                .disabled(activeFileCount < 1 || (activeFileCount < 2 && skippedPages.isEmpty))
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
                            // Keep selection in sync with whichever file the page lands in
                            if let fi = pageToFileMapping[currentPage] { selectedFileIndices = [fi] }
                            return .handled
                        case .rightArrow:
                            if press.modifiers.contains(.command) {
                                currentPage = totalPages - 1
                            } else if currentPage < totalPages - 1 {
                                currentPage += 1
                            }
                            if let fi = pageToFileMapping[currentPage] { selectedFileIndices = [fi] }
                            return .handled
                        case .downArrow:
                            let fileStartsDown = ([0] + splitMarkers.sorted())
                            if let next = fileStartsDown.first(where: { $0 > currentPage }),
                               let fi = pageToFileMapping[next] {
                                currentPage = next
                                if press.modifiers.contains(.shift) {
                                    // Extend the range from the anchor (lowest selected index)
                                    let anchor = selectedFileIndices.min() ?? fi
                                    selectedFileIndices = Set(anchor...max(anchor, fi))
                                } else {
                                    selectedFileIndices = [fi]
                                }
                            }
                            return .handled
                        case .upArrow:
                            let fileStartsUp = ([0] + splitMarkers.sorted())
                            if let prev = fileStartsUp.last(where: { $0 < currentPage }),
                               let fi = pageToFileMapping[prev] {
                                currentPage = prev
                                if press.modifiers.contains(.shift) {
                                    let anchor = selectedFileIndices.max() ?? fi
                                    selectedFileIndices = Set(min(anchor, fi)...anchor)
                                } else {
                                    selectedFileIndices = [fi]
                                }
                            }
                            return .handled
                        case .space:
                            if currentPage > 0 {
                                toggleSplitAt(page: currentPage)
                            }
                            return .handled
                        default:
                            // S — swap current page with the next one
                            if press.characters == "s" || press.characters == "S" {
                                swapCurrentPageWithNext()
                                return .handled
                            }
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
            // SwiftUI's onKeyPress doesn't reliably fire for the delete/backspace key
            // on macOS — the system routes it through a different responder path first.
            // A local NSEvent monitor catches it at the app level before that happens.
            splitViewKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 51 || event.keyCode == 117 else { return event }
                // Don't steal delete from text fields (stride stepper etc.)
                if NSApp.keyWindow?.firstResponder is NSTextView { return event }
                DispatchQueue.main.async { self.handleDeleteKey() }
                return nil  // consume — prevents the system bonk
            }
        }
        .onDisappear {
            if let m = splitViewKeyMonitor { NSEvent.removeMonitor(m) }
            splitViewKeyMonitor = nil
        }
    } // end splitStageBody
    
    private func clearAllMarkers() {
        fileSizes = totalPages > 0 ? [totalPages] : []
        customFileNames.removeAll()
        skippedPages = []
        selectedFileIndices = []
    }

    private func applyStride() {
        fileSizes = splitSizes(totalPages: totalPages, stride: stride)
        customFileNames.removeAll()
        skippedPages = []
        selectedFileIndices = []
    }

    private func toggleSplitAt(page: Int) {
        fileSizes = toggleSplit(in: fileSizes, at: page)
    }

    /// Toggle skip on all pages of the given file indices.
    /// If every file in the set is already fully skipped, they are un-skipped; otherwise all are skipped.
    private func toggleSkipFiles(_ fileIndices: Set<Int>) {
        let allFullySkipped = fileIndices.allSatisfy { isFileFullySkipped($0) }
        for idx in fileIndices {
            let pages = pagesForFile(idx)
            if allFullySkipped {
                skippedPages.subtract(pages)
            } else {
                skippedPages.formUnion(pages)
            }
        }
        selectedFileIndices = []
    }

    /// Called by the NSEvent monitor when Delete or Forward-Delete is pressed.
    /// Behaviour depends on `skipMode`:
    ///   • `.page` — toggles skip on the current page only.
    ///   • `.file` — toggles skip on all selected file cards (or the file at the current page).
    private func handleDeleteKey() {
        switch skipMode {
        case .page:
            toggleSkipPage(currentPage)
        case .file:
            let targets = selectedFileIndices.isEmpty
                ? Set([pageToFileMapping[currentPage]].compactMap { $0 })
                : selectedFileIndices
            if !targets.isEmpty { toggleSkipFiles(targets) }
        }
    }

    /// Toggle skip on a single page.
    private func toggleSkipPage(_ page: Int) {
        if skippedPages.contains(page) {
            skippedPages.remove(page)
        } else {
            skippedPages.insert(page)
        }
    }

    /// Handle a tap on a file card in the output-files list.
    private func handleFileSelection(_ fileIndex: Int, isCmd: Bool, isShift: Bool) {
        if isShift, let anchor = selectedFileIndices.min() {
            let lo = min(anchor, fileIndex)
            let hi = max(anchor, fileIndex)
            selectedFileIndices = Set(lo...hi)
        } else if isCmd {
            if selectedFileIndices.contains(fileIndex) {
                selectedFileIndices.remove(fileIndex)
            } else {
                selectedFileIndices.insert(fileIndex)
            }
        } else {
            selectedFileIndices = [fileIndex]
            // Also navigate the preview to the first page of this file.
            if let firstPage = pagesForFile(fileIndex).first {
                currentPage = firstPage
            }
        }
        // Clicking a card in the right panel takes focus away from the key-press
        // handler. Restore it so Delete/Space/arrows work without an extra click.
        isViewFocused = true
    }

    func saveSplitPDF() {
        guard let document = pdfManager.pdfDocument,
              activeFileCount >= 1,
              activeFileCount >= 2 || !skippedPages.isEmpty else { return }

        if prefixEnabled {
            // Go straight to Step 3 — folder picker comes after the user confirms order.
            // Only include files that have at least one non-skipped page.
            var items: [PrefixItem] = []
            var pagePos = 0
            for fileIndex in 0..<fileSizes.count {
                let fileSize = fileSizes[fileIndex]
                if !isFileFullySkipped(fileIndex) {
                    let suffix = customFileNames[fileIndex] ?? ""
                    let proposed: String
                    if suffix.isEmpty {
                        proposed = "\(baseFileName)\(filenameSeparator)\(fileIndex + 1).pdf"
                    } else {
                        proposed = "\(baseFileName)\(filenameSeparator)\(suffix).pdf"
                    }
                    let firstPage = document.page(at: pagePos)
                    items.append(PrefixItem(id: fileIndex, proposedName: proposed, page: firstPage))
                }
                pagePos += fileSize
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
                    skippedPages: skippedPages,
                    separator: filenameSeparator
                ) { title, message, isError in
                    if isError {
                        showNSAlert(title: title, message: message, isError: true)
                    } else {
                        var names: [String] = []
                        for i in 0..<fileSizes.count {
                            guard !isFileFullySkipped(i) else { continue }
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

    /// Reads bookmarks from the currently loaded document (if any) and initialises
    /// `fileSizes`, `baseFileName`, and `customFileNames`.  Also shows the bookmark
    /// notice banner.  Call this whenever a new (non-A3) document finishes loading.
    private func setupSplitState() {
        let bookmarkData = pdfManager.pdfDocument.flatMap { splitSizesFromBookmarks($0) }
        if let data = bookmarkData {
            fileSizes = data.sizes
            if let names = extractSplitNames(from: data.labels) {
                baseFileName = names.baseName
                for (i, suffix) in names.suffixes.enumerated() {
                    customFileNames[i] = suffix
                }
            } else {
                baseFileName = pdfManager.currentFileName ?? ""
            }
            withAnimation(.easeInOut(duration: 0.2)) { bookmarkNoticeVisible = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation(.easeInOut(duration: 0.2)) { bookmarkNoticeVisible = false }
            }
        } else {
            fileSizes = totalPages > 0 ? [totalPages] : []
            baseFileName = pdfManager.currentFileName ?? ""
        }
        if splitStage != .split { splitStage = .split }
    }

    /// True when the current file segment has ≥ 4 pages and a count divisible by 4,
    /// meaning a booklet reorder is meaningful.
    var canFixBookletOrder: Bool {
        guard let fi = pageToFileMapping[currentPage] else { return false }
        guard fi < fileSizes.count else { return false }
        let n = fileSizes[fi]
        return n >= 4 && n % 4 == 0
    }

    /// Builds a `BookletFixRequest` for the current file segment and presents the sheet.
    private func requestBookletFix() {
        guard let doc = pdfManager.pdfDocument,
              let fi = pageToFileMapping[currentPage] else { return }
        let pages = pagesForFile(fi)
        bookletFixRequest = BookletFixRequest(fileIndex: fi, pages: pages, document: doc)
    }

    /// `true` when the last booklet order can be re-applied to the current file —
    /// i.e. a previous order was saved AND the current file has the same page count.
    var canRedoBookletOrder: Bool {
        guard let last = lastBookletOrder,
              let fi = pageToFileMapping[currentPage],
              fi < fileSizes.count else { return false }
        return fileSizes[fi] == last.n
    }

    /// Re-applies the last booklet order to the current file segment.
    private func redoBookletOrder() {
        guard let last = lastBookletOrder,
              let fi = pageToFileMapping[currentPage] else { return }
        let pages = pagesForFile(fi)
        guard pages.count == last.n else { return }
        applyBookletOrder(pages: pages, order: last.order)
    }

    /// Reorders the pages of a file segment in the loaded document without resetting
    /// split markers or skipped-page state.
    ///
    /// - Parameters:
    ///   - pages: Absolute page indices (in the full document) for the segment.
    ///   - order: Permutation where `order[readingPos]` is the *local* index within
    ///            `pages` that should appear at that reading position.
    private func applyBookletOrder(pages: [Int], order: [Int]) {
        guard let doc = pdfManager.pdfDocument else { return }
        let newDoc = PDFDocument()

        // Build the new absolute-page sequence, swapping only the segment's positions.
        for absIdx in 0..<doc.pageCount {
            let srcAbsIdx: Int
            if let localIdx = pages.firstIndex(of: absIdx) {
                // This slot belongs to the segment — use the permuted source.
                srcAbsIdx = pages[order[localIdx]]
            } else {
                srcAbsIdx = absIdx
            }
            if let page = doc.page(at: srcAbsIdx) {
                newDoc.insert(page, at: newDoc.pageCount)
            }
        }

        // Update skippedPages: re-map skipped pages within the segment to their new positions.
        var newSkipped = skippedPages
        for absIdx in pages { newSkipped.remove(absIdx) }
        for (newLocal, oldLocal) in order.enumerated() {
            if skippedPages.contains(pages[oldLocal]) {
                newSkipped.insert(pages[newLocal])
            }
        }
        skippedPages = newSkipped

        // On the very first fix, show a brief tip pointing to the per-card redo icon.
        if lastBookletOrder == nil {
            withAnimation(.easeInOut(duration: 0.2)) { bookletRedoNoticeVisible = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                withAnimation(.easeInOut(duration: 0.2)) { bookletRedoNoticeVisible = false }
            }
        }

        // Save the order so the user can repeat it with Redo.
        lastBookletOrder = (n: pages.count, order: order)

        // Replace the document while preserving all other split state.
        suppressNextA3Detection = true
        suppressDocumentReset   = true
        pdfManager.pdfDocument  = newDoc
    }

    /// Applies a booklet order to **every** file segment in the document whose page
    /// count equals `n`, in a single document rebuild pass.  This avoids the
    /// multiple-replacement problem (each `onChange` would clear `suppressDocumentReset`
    /// before the next call could use it).
    private func applyBookletOrderToAllMatchingFiles(order: [Int], n: Int) {
        guard let doc = pdfManager.pdfDocument else { return }
        let newDoc = PDFDocument()
        var newSkipped = skippedPages
        var processedFiles = Set<Int>()

        for absIdx in 0..<doc.pageCount {
            guard let fi = pageToFileMapping[absIdx] else {
                // Shouldn't normally happen, but copy the page as-is.
                if let page = doc.page(at: absIdx) { newDoc.insert(page, at: newDoc.pageCount) }
                continue
            }

            let filePages = pagesForFile(fi)

            if filePages.count == n && !processedFiles.contains(fi) {
                // First encounter of a matching file — insert all pages in reading order.
                processedFiles.insert(fi)
                for oldLocal in order {
                    if let page = doc.page(at: filePages[oldLocal]) {
                        newDoc.insert(page, at: newDoc.pageCount)
                    }
                }
                // Remap skipped pages within this file.
                for absPage in filePages { newSkipped.remove(absPage) }
                for (newLocal, oldLocal) in order.enumerated() {
                    if skippedPages.contains(filePages[oldLocal]) {
                        newSkipped.insert(filePages[newLocal])
                    }
                }
            } else if filePages.count == n {
                // Already inserted by the block above — skip.
                continue
            } else {
                // Non-matching file — copy page as-is.
                if let page = doc.page(at: absIdx) { newDoc.insert(page, at: newDoc.pageCount) }
            }
        }

        skippedPages = newSkipped
        lastBookletOrder = (n: n, order: order)
        suppressNextA3Detection = true
        suppressDocumentReset   = true
        pdfManager.pdfDocument  = newDoc
    }

    /// Swaps the current page with the next one in the loaded document, preserving
    /// all split markers, skipped pages, and custom file names.
    /// Uses `suppressDocumentReset` so `onChange` skips the normal full-reset path.
    private func swapCurrentPageWithNext() {
        guard let document = pdfManager.pdfDocument,
              currentPage < document.pageCount - 1 else { return }

        let newDoc = PDFDocument()
        for i in 0..<document.pageCount {
            let srcIdx: Int
            if i == currentPage         { srcIdx = currentPage + 1 }
            else if i == currentPage + 1 { srcIdx = currentPage }
            else                          { srcIdx = i }
            if let page = document.page(at: srcIdx) {
                newDoc.insert(page, at: newDoc.pageCount)
            }
        }
        suppressNextA3Detection = true
        suppressDocumentReset   = true
        pdfManager.pdfDocument  = newDoc
        // currentPage stays the same so the preview immediately shows
        // what was just moved down one slot.
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
            skippedPages: skippedPages,
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

// MARK: - A3 Split Choice View

/// Sheet shown when an A3-landscape PDF is detected.  The user picks which half
/// is page 1 (left-first or right-first), or dismisses without splitting.
struct A3SplitChoiceView: View {
    /// Called with `true` for left-first, `false` for right-first.
    let onChoose: (Bool) -> Void
    let onKeepAsIs: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("A3 Landscape Detected")
                .font(.title2)
                .fontWeight(.semibold)

            Text("This document looks like an A3 sheet with two A4 pages side by side.\nWhich half should become the first page?")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 380)

            // Visual diagram — two A4-portrait rectangles side by side
            HStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                    VStack(spacing: 6) {
                        Image(systemName: "1.circle.fill")
                            .font(.title)
                            .foregroundColor(.accentColor)
                        Text("Left half")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 90, height: 126)

                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    VStack(spacing: 6) {
                        Image(systemName: "2.circle")
                            .font(.title)
                            .foregroundColor(.secondary)
                        Text("Right half")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 90, height: 126)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    .padding(-10)
            )
            .padding(14)

            // Choice buttons
            HStack(spacing: 16) {
                Button {
                    onChoose(true)
                } label: {
                    HStack {
                        Image(systemName: "arrow.left.to.line")
                        Text("Left half first")
                    }
                    .frame(width: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    onChoose(false)
                } label: {
                    HStack {
                        Image(systemName: "arrow.right.to.line")
                        Text("Right half first")
                    }
                    .frame(width: 150)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Text("For saddle-stitch booklets, pages come out in sheet order — use the reorder step to fix the sequence.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Button("Keep as-is — don't split pages") {
                onKeepAsIs()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(36)
        .frame(minWidth: 480)
    }
}


// MARK: - Booklet Order Sheet

/// Sheet shown by "Fix Booklet Order".  Displays candidate reorderings as thumbnail
/// strips with radio buttons, plus a drag-to-reorder custom option as a fallback.
struct BookletOrderSheet: View {
    let request: BookletFixRequest
    /// Total number of files in the document with the same page count (including this one).
    let matchingFileCount: Int
    let onApply: ([Int]) -> Void
    /// Non-nil when there is more than one matching file; applies the order to all of them.
    let onApplyToAll: (([Int]) -> Void)?
    let onCancel: () -> Void

    // -1 means "custom order" is selected; 0…n-1 indexes into `candidates`.
    @State private var selectedOption: Int = 0
    @State private var customOrder: [Int] = []   // local indices within request.pages

    private let candidates: [(label: String, description: String, order: [Int])]

    init(request: BookletFixRequest,
         matchingFileCount: Int,
         onApply: @escaping ([Int]) -> Void,
         onApplyToAll: (([Int]) -> Void)? = nil,
         onCancel: @escaping () -> Void) {
        self.request           = request
        self.matchingFileCount = matchingFileCount
        self.onApply           = onApply
        self.onApplyToAll      = onApplyToAll
        self.onCancel          = onCancel
        self.candidates = bookletCandidates(n: request.pages.count)
        // Custom order starts as the identity permutation.
        _customOrder = State(initialValue: Array(0..<request.pages.count))
    }

    private var n: Int { request.pages.count }

    /// Returns the page at a given local index in the current option's order.
    private func pageForLocalIdx(_ localIdx: Int, option: Int) -> PDFPage? {
        let order: [Int]
        if option == -1 {
            order = customOrder
        } else {
            guard option < candidates.count else { return nil }
            order = candidates[option].order
        }
        guard localIdx < order.count else { return nil }
        let absIdx = request.pages[order[localIdx]]
        return request.document.page(at: absIdx)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────────
            VStack(spacing: 4) {
                Text("Fix Booklet Order")
                    .font(.title2).fontWeight(.semibold)
                Text("File \(request.fileIndex + 1) · \(n) pages")
                    .font(.subheadline).foregroundColor(.secondary)
                Text("Choose a reordering that matches how the booklet was scanned, then press Apply.")
                    .font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .padding(.top, 2)
            }
            .padding(.top, 28)
            .padding(.bottom, 16)
            .padding(.horizontal, 28)

            Divider()

            // ── Options list ─────────────────────────────────────────────
            // ScrollViewReader lets us programmatically scroll to the custom-order
            // row when the user selects it, avoiding the confusing nested-scroll situation
            // where the inner List absorbs scroll events and hides part of the outer sheet.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        // Automatic candidate options
                        ForEach(candidates.indices, id: \.self) { optIdx in
                            BookletOptionRow(
                                label: candidates[optIdx].label,
                                description: candidates[optIdx].description,
                                isSelected: selectedOption == optIdx,
                                onSelect: { selectedOption = optIdx }
                            ) {
                                // Thumbnail strip for this candidate
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(0..<n, id: \.self) { localIdx in
                                            BookletThumbnailCell(
                                                page: pageForLocalIdx(localIdx, option: optIdx),
                                                label: "\(localIdx + 1)"
                                            )
                                        }
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 4)
                                }
                            }
                        }

                        // Custom drag-to-reorder option
                        BookletOptionRow(
                            label: "Custom order",
                            description: "Drag rows to set the reading order yourself.",
                            isSelected: selectedOption == -1,
                            onSelect: { selectedOption = -1 }
                        ) {
                            if selectedOption == -1 {
                                // Non-scrolling List: scrollDisabled lets the outer ScrollView
                                // handle all scrolling so the inner list never steals events.
                                // Height is exact — no inner scroll bar, no nested scroll confusion.
                                List {
                                    ForEach(customOrder.indices, id: \.self) { pos in
                                        let localIdx = customOrder[pos]
                                        HStack(spacing: 16) {
                                            Text("\(pos + 1).")
                                                .frame(width: 28, alignment: .trailing)
                                                .foregroundColor(.secondary)
                                                .font(.headline)
                                            BookletThumbnailCell(
                                                page: request.document.page(at: request.pages[localIdx]),
                                                label: "Scan \(localIdx + 1)",
                                                thumbWidth: 180, thumbHeight: 254
                                            )
                                            Text("Page in scan position \(localIdx + 1)")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                            Spacer()
                                        }
                                        .padding(.vertical, 8)
                                    }
                                    .onMove { from, to in
                                        customOrder.move(fromOffsets: from, toOffset: to)
                                    }
                                }
                                .listStyle(.plain)
                                .scrollDisabled(true)
                                // Each row: 254pt thumb + 20pt label + 16pt vertical padding = ~290pt
                                .frame(height: CGFloat(n) * 290)
                            } else {
                                // Collapsed preview strip when not selected
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(customOrder.indices, id: \.self) { pos in
                                            BookletThumbnailCell(
                                                page: request.document.page(at: request.pages[customOrder[pos]]),
                                                label: "\(pos + 1)"
                                            )
                                        }
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        .id("customRow")
                    }
                    .padding(24)
                }
                .onChange(of: selectedOption) { _, newVal in
                    if newVal == -1 {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("customRow", anchor: .top)
                        }
                    }
                }
            }

            Divider()

            // ── Footer buttons ───────────────────────────────────────────
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let applyAll = onApplyToAll {
                    Button("Apply to All (\(matchingFileCount) files)") {
                        let order = selectedOption == -1 ? customOrder : candidates[selectedOption].order
                        applyAll(order)
                    }
                    .disabled(selectedOption >= candidates.count && selectedOption != -1)
                    .help("Apply this reordering to all \(matchingFileCount) files with \(request.pages.count) pages")
                }
                Button("Apply") {
                    let order = selectedOption == -1 ? customOrder : candidates[selectedOption].order
                    onApply(order)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedOption >= candidates.count && selectedOption != -1)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 580, minHeight: 500)
    }
}

/// A single radio-button row inside `BookletOrderSheet`.
private struct BookletOptionRow<Content: View>: View {
    let label: String
    let description: String
    let isSelected: Bool
    let onSelect: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                        .font(.system(size: 16))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).fontWeight(.medium)
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            content()
                .padding(.leading, 26)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.07)
                      : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15),
                        lineWidth: isSelected ? 1.5 : 1)
        )
    }
}

/// A single thumbnail cell used in the booklet-order sheet.
/// Default size ~90×127 pt for horizontal strips; pass larger values for the
/// drag-to-reorder list where each row shows one page at full readability.
private struct BookletThumbnailCell: View {
    let page: PDFPage?
    let label: String
    var thumbWidth: CGFloat  = 90
    var thumbHeight: CGFloat = 127

    var body: some View {
        VStack(spacing: 4) {
            PDFPageView(page: page, rotation: 0)
                .frame(width: thumbWidth, height: thumbHeight)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Split Controls Section
struct SplitControlsSection: View {
    @Binding var currentPage: Int
    let splitMarkers: Set<Int>
    let fileSizes: [Int]
    let totalPages: Int
    let skippedPages: Set<Int>
    @Binding var skipMode: SkipMode
    let onToggleMarker: () -> Void
    let onSkipCurrentFile: () -> Void
    let onSkipCurrentPage: () -> Void
    let onSwapWithNext: () -> Void

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

    /// True if the current page is in skippedPages.
    private var currentPageIsSkipped: Bool { skippedPages.contains(currentPage) }

    /// True if every page in the current file is skipped.
    private var currentFileIsFullySkipped: Bool {
        guard let info = currentFileInfo else { return false }
        let pages = info.fileStart..<(info.fileStart + info.fileSize)
        return pages.allSatisfy { skippedPages.contains($0) }
    }

    /// Label for the skip/unskip button, derived from skip mode and current state.
    private var skipButtonLabel: String {
        switch skipMode {
        case .page:
            return currentPageIsSkipped ? "Un-skip Page" : "Skip Page"
        case .file:
            return currentFileIsFullySkipped ? "Un-skip File" : "Skip File"
        }
    }

    private var skipButtonIcon: String {
        switch skipMode {
        case .page:
            return currentPageIsSkipped ? "arrow.uturn.backward" : "trash"
        case .file:
            return currentFileIsFullySkipped ? "arrow.uturn.backward" : "trash"
        }
    }

    private var skipButtonIsActive: Bool {
        skipMode == .page ? currentPageIsSkipped : currentFileIsFullySkipped
    }

    var body: some View {
        VStack(spacing: 10) {
            // ── Row 1: Navigation ──────────────────────────────────────────
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
                    HStack(spacing: 6) {
                        Text("Page \(currentPage + 1) of \(totalPages)")
                            .font(.headline)
                        if currentPageIsSkipped {
                            Text("SKIPPED")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.15))
                                .foregroundColor(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    // Show which output file this page belongs to
                    if let info = currentFileInfo {
                        let isAtStart = currentPage == info.fileStart
                        let endPage = info.fileStart + info.fileSize - 1
                        let rangeText = info.fileStart == endPage
                            ? "p.\(info.fileStart + 1)"
                            : "pp.\(info.fileStart + 1)–\(endPage + 1)"
                        let skipSuffix = currentFileIsFullySkipped ? " — skipped" : ""
                        Text("File \(info.fileIndex + 1) (\(rangeText), \(info.fileSize) \(info.fileSize == 1 ? "page" : "pages"))\(isAtStart && currentPage > 0 ? " — split marker" : "")\(skipSuffix)")
                            .font(.caption)
                            .foregroundColor(currentFileIsFullySkipped ? .red
                                            : (isAtStart && currentPage > 0) ? .orange
                                            : .secondary)
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

            Divider()
                .padding(.horizontal)

            // ── Row 2: Split marker + Swap with Next ───────────────────────
            HStack(spacing: 12) {
                Button(action: onToggleMarker) {
                    if splitMarkers.contains(currentPage) {
                        Label("Remove Split", systemImage: "xmark.circle")
                    } else {
                        Label("Add Split Here (Space)", systemImage: "scissors")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(currentPage == 0)

                Spacer()

                Button(action: onSwapWithNext) {
                    Label("Swap with Next (S)", systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(currentPage >= totalPages - 1)
                .help("Swap the current page with the one after it")
            }
            .padding(.horizontal)

            // ── Row 3: Skip mode toggle + Skip/Unskip button ──────────────
            HStack(spacing: 12) {
                Picker("", selection: $skipMode) {
                    Text("Skip Page").tag(SkipMode.page)
                    Text("Skip File").tag(SkipMode.file)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Controls whether Delete / the Skip button skips only the current page or the entire output file")

                Spacer()

                Button(action: {
                    switch skipMode {
                    case .page: onSkipCurrentPage()
                    case .file: onSkipCurrentFile()
                    }
                }) {
                    Label(skipButtonLabel, systemImage: skipButtonIcon)
                        .foregroundColor(skipButtonIsActive ? .orange : .red)
                }
                .buttonStyle(.bordered)
                .help(skipMode == .page
                      ? (currentPageIsSkipped ? "Un-skip this page (Delete)" : "Skip this page (Delete)")
                      : (currentFileIsFullySkipped ? "Un-skip this output file (Delete)" : "Skip this output file (Delete)"))
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
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
    let isFullySkipped: Bool
    let isPartiallySkipped: Bool
    let skippedPages: Set<Int>
    let isSelected: Bool
    let onNavigate: (Int) -> Void
    /// Called when the user clicks the card; provides Cmd and Shift modifier state.
    let onSelect: (_ isCmd: Bool, _ isShift: Bool) -> Void
    /// Non-nil when this file's page count qualifies for booklet reordering (≥ 4, divisible by 4).
    var onFixBookletOrder: (() -> Void)? = nil
    /// Non-nil when a previous booklet order exists and matches this file's page count.
    var onRedoBookletOrder: (() -> Void)? = nil

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

    /// Background fill colour reflecting skip / selection / active state.
    private var cardFill: Color {
        if isFullySkipped    { return Color.red.opacity(0.12) }
        if isPartiallySkipped { return Color.orange.opacity(0.12) }
        if isSelected        { return Color.accentColor.opacity(0.15) }
        if isActive          { return Color.accentColor.opacity(0.08) }
        return Color(NSColor.controlBackgroundColor)
    }

    private var cardBorder: Color {
        if isFullySkipped    { return Color.red.opacity(0.4) }
        if isPartiallySkipped { return Color.orange.opacity(0.4) }
        if isSelected        { return Color.accentColor.opacity(0.7) }
        if isActive          { return Color.accentColor.opacity(0.5) }
        return .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: isFullySkipped ? "doc.fill" : "doc.fill")
                    .foregroundColor(isFullySkipped ? .red
                                     : isPartiallySkipped ? .orange
                                     : isActive ? .accentColor : .blue)

                Text(fileName)
                    .font(.headline)
                    .foregroundColor(isFullySkipped ? .secondary : .primary)
                    .strikethrough(isFullySkipped)

                if isFullySkipped {
                    Text("SKIPPED")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if isPartiallySkipped {
                    Text("PARTIAL")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundColor(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Spacer()

                if let fixBooklet = onFixBookletOrder {
                    Button(action: fixBooklet) {
                        Image(systemName: "rectangle.stack")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Fix booklet page order for this file")
                }

                if let redoBooklet = onRedoBookletOrder {
                    Button(action: redoBooklet) {
                        Image(systemName: "rectangle.stack.badge.play")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Repeat the last booklet reordering on this file")
                }

                let activeCount = pagesInFile.filter { !skippedPages.contains($0) }.count
                if isPartiallySkipped {
                    Text("\(activeCount) of \(pagesInFile.count) pages")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(pagesInFile.count) page\(pagesInFile.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 4) {
                ForEach(pagesInFile.prefix(10), id: \.self) { pageIndex in
                    let pageSkipped = skippedPages.contains(pageIndex)
                    Button(action: {
                        onNavigate(pageIndex)
                    }) {
                        Text("\(pageIndex + 1)")
                            .font(.caption2)
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(pageSkipped
                                          ? Color.red.opacity(0.25)
                                          : Color.accentColor.opacity(0.2))
                            )
                            .foregroundColor(pageSkipped ? .red : .primary)
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
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(cardBorder, lineWidth: 1.5)
                )
        )
        // Tap selects the card (with modifier support); the selection handler
        // in SplitView also navigates when it's a plain single-click.
        .contentShape(Rectangle())
        .onTapGesture {
            let mods = NSEvent.modifierFlags
            onSelect(mods.contains(.command), mods.contains(.shift))
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

/// Formats a set of 0-based page indices into a compact human-readable range string.
/// E.g. {0,1,2,6,7,8,9} → "pp.1–3, 7–10"
func formatSkippedPageRanges(_ pages: Set<Int>) -> String {
    guard !pages.isEmpty else { return "" }
    let sorted = pages.sorted()
    var ranges: [(Int, Int)] = []
    var start = sorted[0], end = sorted[0]
    for p in sorted.dropFirst() {
        if p == end + 1 { end = p }
        else { ranges.append((start, end)); start = p; end = p }
    }
    ranges.append((start, end))
    return ranges.map { s, e in s == e ? "p.\(s+1)" : "pp.\(s+1)–\(e+1)" }.joined(separator: ", ")
}

// MARK: - Split Naming Stage (Step 2)
/// Full-window Step 2: lets users set the base filename and per-file name suffixes,
/// with a large first-page thumbnail for each output file.
struct SplitNamingStageView: View {
    let pdfDocument: PDFDocument
    let fileSizes: [Int]
    /// Pages omitted from output (passed from SplitView).
    let skippedPages: Set<Int>
    /// File indices whose every page is skipped — hidden from this step.
    let skippedFileIndices: Set<Int>
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

    /// Set to true once we've auto-inferred the ensemble type from the first suffix.
    /// Prevents re-inference on subsequent edits.
    @State private var hasInferredEnsemble = false

    /// All file indices, excluding fully-skipped ones.
    var visibleFileIndices: [Int] {
        (0..<fileSizes.count).filter { !skippedFileIndices.contains($0) }
    }

    var numberOfFiles: Int { fileSizes.count }

    /// Page index of the first page in a given file.
    private func firstPageIndex(for fileIndex: Int) -> Int {
        fileSizes.prefix(fileIndex).reduce(0, +)
    }

    /// Row subtitle: page range + active page count, noting any partially-skipped pages.
    private func subtitle(for fileIndex: Int) -> String {
        let start = firstPageIndex(for: fileIndex)
        let size  = fileSizes[fileIndex]
        let end   = start + size - 1
        let range = (start == end) ? "Page \(start + 1)" : "Pages \(start + 1)–\(end + 1)"
        let activeCount = (start..<(start + size)).filter { !skippedPages.contains($0) }.count
        if activeCount < size {
            return "\(range) · \(activeCount) active of \(size) pages"
        }
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
        let count = visibleFileIndices.count
        return (count >= 2 || (count >= 1 && !skippedPages.isEmpty))
            && baseNameError == nil && !anySuffixError
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

            // ── Skipped-pages banner ──────────────────────────────────────
            if !skippedPages.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .foregroundColor(.orange)
                    let rangeStr = formatSkippedPageRanges(skippedPages)
                    let hiddenCount = skippedFileIndices.count
                    if hiddenCount > 0 {
                        Text("Skipping \(rangeStr) from input · \(hiddenCount) file\(hiddenCount == 1 ? "" : "s") hidden above")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Skipping \(rangeStr) from input")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.07))

                Divider()
            }

            // ── File list ─────────────────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(visibleFileIndices, id: \.self) { fileIndex in
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
                                previewOffset: $previewOffset,
                                isLastField: fileIndex == visibleFileIndices.last,
                                onLastTab: { if canSave { onSave() } }
                            )
                            .id(fileIndex)
                            if fileIndex != visibleFileIndices.last { Divider() }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onAppear {
                    proxy.scrollTo(0, anchor: .top)
                    hasInferredEnsemble = false
                }
                .onChange(of: focusedField) { _, newValue in
                    if let field = newValue {
                        withAnimation { proxy.scrollTo(field, anchor: .center) }
                    }
                }
                .onChange(of: customFileNames) { _, newNames in
                    // Auto-infer ensemble type from the first suffix typed.
                    // Only runs once per naming session.
                    guard !hasInferredEnsemble,
                          let first = newNames.values.first(where: { !$0.isEmpty }),
                          let inferred = inferredSplitSuggestionEnsemble(first)
                    else { return }
                    prefixEnsembleType = inferred
                    hasInferredEnsemble = true
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

// MARK: - Split Suggestion Helpers

/// Returns the base name of an instrument by stripping a trailing integer.
/// "Flute 1" → "Flute", "Horn in F 3" → "Horn in F", "Score" → "Score"
private func splitSuggestionBaseName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    let parts = trimmed.components(separatedBy: " ")
    if parts.count >= 2, let last = parts.last, Int(last) != nil {
        return parts.dropLast().joined(separator: " ")
    }
    return trimmed
}

/// Normalises an instrument name to a canonical group key for alias matching.
/// "Alto Sax", "Alto Saxophone", "Alto" → "alto saxophone"
private func splitSuggestionGroupKey(_ name: String) -> String {
    let base = splitSuggestionBaseName(name).lowercased()
    let aliases: [(Set<String>, String)] = [
        (["alto sax", "alto saxophone", "alto"], "alto saxophone"),
        (["tenor sax", "tenor saxophone", "tenor"], "tenor saxophone"),
        (["soprano sax", "soprano saxophone"], "soprano saxophone"),
        (["baritone sax", "bari sax", "baritone saxophone", "bari"], "baritone saxophone"),
        (["bb clarinet", "b-flat clarinet", "clarinet in bb"], "clarinet"),
        (["bass clar", "bass clarinet"], "bass clarinet"),
        (["contra clarinet", "contrabass clarinet", "contra bass clarinet"], "contrabass clarinet"),
        (["bb trumpet", "trumpet in bb", "b-flat trumpet"], "trumpet"),
        (["french horn", "horn in f", "f horn"], "horn"),
        (["trombone", "tenor trombone"], "trombone"),
        (["bass tbn", "bass trombone"], "bass trombone"),
        (["string bass", "double bass", "contrabass"], "double bass"),
        (["vln", "violin"], "violin"),
        (["vla", "viola"], "viola"),
        (["vlc", "cello", "violoncello"], "cello"),
        // Euphonium / baritone clef variants — all collapse to "euphonium" / "baritone"
        // so nextExpectedIndex can find the instrument after the last euphonium/baritone entry.
        (["euphonium treble clef", "euphonium t.c.", "euphonium tc",
          "euphonium bass clef",   "euphonium b.c.", "euphonium bc",
          "euphonium", "eupho"],   "euphonium"),
        (["baritone treble clef",  "baritone t.c.",  "baritone tc",
          "baritone bass clef",    "baritone b.c.",  "baritone bc",
          "baritone"], "baritone"),
    ]
    for (variants, canonical) in aliases {
        if variants.contains(base) { return canonical }
    }
    return base
}

/// Returns the natural companion for a clef-paired instrument name, preserving
/// the exact notation style of the input.
///
///   "Euphonium B.C." → "Euphonium T.C."
///   "Euphonium TC"   → "Euphonium BC"
///   "Baritone Treble Clef" → "Baritone Bass Clef"
///
/// Returns `nil` if the name is not a recognised clef-paired variant.
private func clefCompanion(for name: String) -> String? {
    // Each tuple: (bc variant, tc variant) — both directions are handled below.
    let pairs: [(bc: String, tc: String)] = [
        ("Euphonium B.C.",    "Euphonium T.C."),
        ("Euphonium BC",      "Euphonium TC"),
        ("Euphonium Bass Clef",   "Euphonium Treble Clef"),
        ("Baritone B.C.",     "Baritone T.C."),
        ("Baritone BC",       "Baritone TC"),
        ("Baritone Bass Clef",    "Baritone Treble Clef"),
    ]
    let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
    for pair in pairs {
        if lower == pair.bc.lowercased() { return pair.tc }
        if lower == pair.tc.lowercased() { return pair.bc }
    }
    return nil
}

/// Rewrites `name` so that its "sax"/"saxophone" word matches the style used in
/// `reference`. E.g. if the user typed "Alto Saxophone", the cross-boundary
/// suggestion "Tenor Sax" becomes "Tenor Saxophone".
private func saxStyleMatch(_ name: String, toStyleOf reference: String) -> String {
    let refLower = reference.lowercased()
    // Detect which style the reference uses — must be a standalone word "sax"
    // (not the start of "saxophone"), hence the word-boundary regex.
    let usesFull  = refLower.range(of: "saxophone", options: .regularExpression) != nil
    let usesAbbr  = !usesFull && (refLower.range(of: "\\bsax\\b", options: .regularExpression) != nil)
    if usesFull {
        // Expand standalone "Sax" → "Saxophone" in the result
        return name.replacingOccurrences(of: "\\bSax\\b", with: "Saxophone",
                                         options: [.regularExpression, .caseInsensitive])
    } else if usesAbbr {
        // Shorten "Saxophone" → "Sax"
        return name.replacingOccurrences(of: "Saxophone", with: "Sax",
                                         options: .caseInsensitive)
    }
    return name
}

/// Typical number of parts for common instrument families (used to detect when
/// to cross to the next instrument in cross-boundary suggestions).
private func splitSuggestionTypicalPartCount(_ baseName: String) -> Int {
    let key = splitSuggestionGroupKey(baseName)
    let counts: [String: Int] = [
        "flute": 2, "piccolo": 1, "oboe": 2, "english horn": 1, "bassoon": 2,
        "clarinet": 3, "bass clarinet": 1, "contrabass clarinet": 1,
        "alto saxophone": 2, "tenor saxophone": 1, "baritone saxophone": 1, "soprano saxophone": 1,
        "cornet": 2, "trumpet": 4, "horn": 4, "trombone": 3, "bass trombone": 1,
        "euphonium": 1, "baritone": 1, "tuba": 1,
        "violin": 2, "viola": 1, "cello": 1, "double bass": 1,
        "percussion": 4, "timpani": 1,
    ]
    return counts[key] ?? 2
}

/// If the previous suffix's number equals the typical part count for that family,
/// returns "NextInstrument 1" as a cross-boundary numbered suggestion.
/// E.g. after "Flute 2" (typical=2) → "Oboe 1" if Oboe follows Flute in the list.
private func splitSuggestionStartingNumberedName(
    prevSuffix: String,
    instrumentNames: [String]
) -> String? {
    let prev = prevSuffix.trimmingCharacters(in: .whitespaces)
    guard !prev.isEmpty else { return nil }
    let parts = prev.components(separatedBy: " ")
    guard parts.count >= 2,
          let last = parts.last, let n = Int(last), n > 0
    else { return nil }
    let basePart = parts.dropLast().joined(separator: " ")
    let typical = splitSuggestionTypicalPartCount(basePart)
    guard n >= typical else { return nil }
    // Find the instrument's position in the list via group key
    let key = splitSuggestionGroupKey(basePart)
    // Search for any name in the list whose base matches our key
    if let idx = instrumentNames.firstIndex(where: {
        splitSuggestionGroupKey(splitSuggestionBaseName($0)) == key ||
        splitSuggestionGroupKey($0) == key
    }) {
        let nextIdx = (idx + 1) % instrumentNames.count
        let rawNextName = splitSuggestionBaseName(instrumentNames[nextIdx])
        // Preserve the user's preferred sax style: "Alto Saxophone" → "Tenor Saxophone" not "Tenor Sax"
        let nextName = saxStyleMatch(rawNextName, toStyleOf: basePart)
        return "\(nextName) 1"
    }
    return nil
}

/// Deduplicates a list by collapsing numbered variants to their base name.
/// ["Flute 1", "Flute 2", "Oboe", "Oboe 1"] → ["Flute", "Oboe"]
private func splitSuggestionDisplayNames(_ names: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for name in names {
        let base = splitSuggestionBaseName(name)
        let key = base.lowercased()
        if seen.insert(key).inserted {
            result.append(base)
        }
    }
    return result
}

/// Infers the most likely ensemble type from the first suffix the user types.
/// Returns nil if no confident match is found.
private func inferredSplitSuggestionEnsemble(_ suffix: String) -> EnsembleType? {
    let lower = suffix.lowercased()
    let jazzKeywords = ["alto sax", "tenor sax", "baritone sax", "soprano sax",
                        "lead trumpet", "lead trombone", "rhythm guitar", "guitar",
                        "drum set", "drum kit", "bass guitar", "electric bass"]
    for kw in jazzKeywords where lower.contains(kw) { return .jazz }
    let orchKeywords = ["violin", "viola", "cello", "double bass", "string bass",
                        "oboe", "bassoon", "french horn", "horn in f"]
    for kw in orchKeywords where lower.contains(kw) { return .orchestra }
    let bandKeywords = ["piccolo", "flute", "clarinet", "trumpet", "trombone",
                        "euphonium", "tuba", "cornet", "percussion", "timpani",
                        "saxophone", "baritone", "bb "]
    for kw in bandKeywords where lower.contains(kw) { return .band }
    return nil
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
    /// True for the last visible row — Tab/Return will call onLastTab instead of advancing focus.
    var isLastField: Bool = false
    /// Called when Tab or Return is pressed on the last field. Defaults to a no-op so
    /// BulkRenameView (which doesn't pass this) keeps its existing behaviour.
    var onLastTab: () -> Void = {}

    /// Separator inserted between base name and suffix in output filenames.
    /// Mirrors the setting in Preferences → Renamer.
    @AppStorage("filenameSeparator") private var filenameSeparator: String = " - "

    /// Step sizes in PDF points.
    /// cropH = 100 pt; stepV = 25 pt → 75 % overlap between consecutive positions.
    /// cropW ≈ 200 pt; stepH = 100 pt → 50 % overlap horizontally.
    private let stepV: CGFloat = 25
    private let stepH: CGFloat = 100

    private var isFieldFocused: Bool { fieldFocus.wrappedValue == fileIndex }

    // Arrow-key selection index into the suggestions list (nil = in the text field)
    @State private var selectedSuggestionIndex: Int? = nil
    /// What the user actually typed before arrowing into a suggestion.
    /// Restored when the user presses Escape or arrows back above the first item.
    @State private var committedTypedText: String = ""

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
    /// Uses alias normalisation so "Alto Sax" and "Alto Saxophone" are treated
    /// as the same instrument family.
    private var nextExpectedIndex: Int {
        for i in Swift.stride(from: fileIndex - 1, through: 0, by: -1) {
            let prev = (allSuffixes[i] ?? "").trimmingCharacters(in: .whitespaces)
            if !prev.isEmpty {
                let prevKey = splitSuggestionGroupKey(prev)
                if let idx = instrumentNames.firstIndex(where: {
                    splitSuggestionGroupKey($0) == prevKey
                }) {
                    return min(idx + 1, instrumentNames.count - 1)
                }
            }
        }
        return 0
    }

    /// Top-priority numbered suggestion based on the nearest previous suffix:
    /// - If "Flute 1" and typical count for Flute is 2 → suggests "Flute 2"
    /// - If "Flute 2" and typical count for Flute is 2 → cross-boundary: suggests "Oboe 1"
    private var numberedSuggestion: String? {
        for i in Swift.stride(from: fileIndex - 1, through: 0, by: -1) {
            let prev = (allSuffixes[i] ?? "").trimmingCharacters(in: .whitespaces)
            guard !prev.isEmpty else { continue }

            // Clef companion takes priority: "Euphonium B.C." → "Euphonium T.C."
            if let companion = clefCompanion(for: prev) { return companion }

            let parts = prev.components(separatedBy: " ")
            // Must have at least two tokens and last token must be a positive integer
            if parts.count >= 2, let last = parts.last, let n = Int(last), n > 0 {
                let basePart = parts.dropLast().joined(separator: " ")
                let typical = splitSuggestionTypicalPartCount(basePart)
                if n >= typical {
                    // Cross-boundary: suggest the next instrument family at part 1
                    return splitSuggestionStartingNumberedName(
                        prevSuffix: prev,
                        instrumentNames: instrumentNames
                    )
                } else {
                    // Same family, next part — preserve the user's sax style
                    let rawNext = "\(basePart) \(n + 1)"
                    return rawNext  // basePart already uses the user's own style
                }
            }
            break  // only consider the closest non-empty row
        }
        return nil
    }

    /// The text to use when filtering suggestions.
    /// While the user is arrowing through the list, the field shows the highlighted
    /// suggestion but suggestions must stay anchored to what was actually typed —
    /// otherwise arrowing to "Flute" collapses the list to a single match.
    private var queryText: String {
        selectedSuggestionIndex != nil ? committedTypedText : suffix
    }

    private var suggestions: [String] {
        // Rotate the base instrument list so "next expected" comes first
        let start = nextExpectedIndex
        let rotated = Array(instrumentNames.suffix(from: start))
                    + Array(instrumentNames.prefix(start))

        // Collapse "Flute 1", "Flute 2" → "Flute" so the list stays compact.
        // When user types a number we show numbered variants (via numberedSuggestion).
        let deduplicated = splitSuggestionDisplayNames(rotated)

        var result: [String]
        if queryText.isEmpty {
            result = Array(deduplicated.prefix(8))
        } else {
            let q = queryText.lowercased()
            let prefixMatches   = deduplicated.filter { $0.lowercased().hasPrefix(q) }
            let containsMatches = deduplicated.filter {
                $0.lowercased().contains(q) && !$0.lowercased().hasPrefix(q)
            }
            result = Array((prefixMatches + containsMatches).prefix(8))
        }

        // Prepend numbered suggestion ("Flute 2" or cross-boundary "Oboe 1") when relevant
        if let numbered = numberedSuggestion {
            let show = queryText.isEmpty || numbered.lowercased().hasPrefix(queryText.lowercased())
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

            // ── Instrument name crop with pan overlay + minimap ──────────
            if let pg = page {
                HStack(alignment: .top, spacing: 8) {
                    // Main crop strip (panning)
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

                    // Minimap: full-page thumbnail with crop indicator
                    PageCropOverview(page: pg, offset: previewOffset)
                        .frame(width: 52, height: 70)
                        .padding(.top, (150 - 70) / 2)  // vertically centre against the 150pt strip
                }
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
                        // Arrow-key navigation: immediately apply the highlighted suggestion
                        // to the field so Tab/Return can advance without an extra keypress.
                        .onKeyPress(.downArrow) {
                            guard !suggestions.isEmpty else { return .ignored }
                            if selectedSuggestionIndex == nil {
                                committedTypedText = suffix   // remember what was typed
                            }
                            let newIdx = min((selectedSuggestionIndex ?? -1) + 1,
                                            suggestions.count - 1)
                            selectedSuggestionIndex = newIdx
                            suffix = suggestions[newIdx]
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            if let idx = selectedSuggestionIndex, idx > 0 {
                                selectedSuggestionIndex = idx - 1
                                suffix = suggestions[idx - 1]
                            } else {
                                // Arrowed back above the list — restore what the user typed
                                selectedSuggestionIndex = nil
                                suffix = committedTypedText
                            }
                            return .handled
                        }
                        .onKeyPress(.return) {
                            // Suggestion is already in the field; just clear the dropdown.
                            if selectedSuggestionIndex != nil { selectedSuggestionIndex = nil }
                            if isLastField { onLastTab() }
                            else { fieldFocus.wrappedValue = fileIndex + 1 }
                            return .handled
                        }
                        .onKeyPress(.tab) {
                            // For non-last fields: return .ignored so AppKit's natural Tab
                            // traversal moves focus — that's more reliable than a manual
                            // FocusState update in the same event.
                            if selectedSuggestionIndex != nil { selectedSuggestionIndex = nil }
                            guard isLastField else { return .ignored }
                            onLastTab()
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            // Cancel: restore what the user had typed before arrowing
                            selectedSuggestionIndex = nil
                            suffix = committedTypedText
                            return .handled
                        }
                        .onChange(of: suffix) { _, newValue in
                            // If this change was caused by arrow-key selection, don't reset
                            // the selection or the committed text — we set suffix intentionally.
                            if let idx = selectedSuggestionIndex,
                               idx < suggestions.count,
                               suggestions[idx] == newValue { return }
                            // The user typed — reset arrow navigation
                            selectedSuggestionIndex = nil
                            committedTypedText = newValue
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
    /// When non-nil, overrides the auto-computed position number with this free-form string.
    var customPrefix: String? = nil
}

/// One row in PrefixOrderStepView — shows position, thumbnail, proposed name → final name.
private struct PrefixOrderRow: View {
    let item: PrefixItem
    let position: Int        // auto-computed 0-based position
    let autoPrefix: String   // what auto-numbering would produce (e.g. "00")
    let finalName: String
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    var isUnmatched: Bool = false
    var onEditPrefix: (() -> Void)? = nil  // called on double-click of the badge

    private var displayPrefix: String {
        item.customPrefix ?? autoPrefix
    }
    private var isCustom: Bool { item.customPrefix != nil }

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

            // Position badge — double-click to set a custom prefix
            Text(displayPrefix)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(isCustom ? .orange : .accentColor)
                .frame(minWidth: 30, alignment: .center)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isCustom ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1)
                )
                .help("Double-click to set a custom prefix")
                .gesture(TapGesture(count: 2).onEnded { onEditPrefix?() })

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
                        .foregroundColor(isCustom ? .orange : .accentColor)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isUnmatched ? Color.orange.opacity(0.06) : Color.clear)
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
    /// IDs of items whose proposed name couldn't be matched to the current instrument order.
    @State private var unmatchedIds: Set<Int>
    /// The item whose prefix badge was double-clicked (drives the edit popover).
    @State private var prefixEditTarget: PrefixItem? = nil
    /// The draft prefix text being edited in the popover.
    @State private var prefixEditDraft: String = ""
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
        let sorted = Self.autoSorted(initialItems, by: order)
        self._items = State(initialValue: sorted)
        self._unmatchedIds = State(initialValue: Self.computeUnmatchedIds(initialItems, by: order))
    }

    // MARK: Auto-sort helpers

    /// Returns items sorted by instrument order.
    /// Score (rank 0) is pinned first → gets prefix "00".
    /// Other matched items follow in instrument order.
    /// Unmatched items go last (highlighted orange) so they don't displace the score.
    static func autoSorted(_ items: [PrefixItem], by order: [String]) -> [PrefixItem] {
        var score:     [PrefixItem] = []
        var matched:   [(rank: Int, item: PrefixItem)] = []
        var unmatched: [PrefixItem] = []
        for item in items {
            if let rank = matchInstrumentOrder(in: item.proposedName, order: order) {
                if rank == 0 { score.append(item) }
                else { matched.append((rank, item)) }
            } else {
                unmatched.append(item)
            }
        }
        return score + matched.sorted { $0.rank < $1.rank }.map(\.item) + unmatched
    }

    /// Returns the set of item IDs whose proposed names don't match any instrument in `order`.
    static func computeUnmatchedIds(_ items: [PrefixItem], by order: [String]) -> Set<Int> {
        Set(items.filter { matchInstrumentOrder(in: $0.proposedName, order: order) == nil }.map(\.id))
    }

    /// The prefix string for an item — custom if set, otherwise zero-based position ("00", "01"…).
    private func autoPrefix(at position: Int) -> String { String(format: "%02d", position) }

    private func prefixedName(for item: PrefixItem, at position: Int) -> String {
        let prefix = item.customPrefix ?? autoPrefix(at: position)
        return "\(prefix)\(prefixSeparator)\(item.proposedName)"
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
                .onChange(of: ensembleType) { _, newType in
                    let order = InstrumentOrders.getOrder(for: newType)
                    withAnimation { items = Self.autoSorted(items, by: order) }
                    unmatchedIds = Self.computeUnmatchedIds(items, by: order)
                }
                Button("Re-sort") {
                    let order = InstrumentOrders.getOrder(for: ensembleType)
                    withAnimation { items = Self.autoSorted(items, by: order) }
                    unmatchedIds = Self.computeUnmatchedIds(items, by: order)
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
                    let matchedItems   = items.filter { !unmatchedIds.contains($0.id) }
                    let unmatchedItems = items.filter {  unmatchedIds.contains($0.id) }

                    // ── Matched section (score + auto-detected instruments) ──
                    ForEach(matchedItems, id: \.id) { item in
                        let position   = items.firstIndex(where: { $0.id == item.id })!
                        let sectionIdx = matchedItems.firstIndex(where: { $0.id == item.id })!
                        PrefixOrderRow(
                            item: item,
                            position: position,
                            autoPrefix: autoPrefix(at: position),
                            finalName: prefixedName(for: item, at: position),
                            onMoveUp:   sectionIdx > 0                      ? { items.swapAt(position, position - 1) } : nil,
                            onMoveDown: sectionIdx < matchedItems.count - 1 ? { items.swapAt(position, position + 1) } : nil,
                            onEditPrefix: { prefixEditTarget = item; prefixEditDraft = item.customPrefix ?? autoPrefix(at: position) }
                        )
                        if item.id != matchedItems.last?.id { Divider() }
                    }

                    // ── Unmatched section (instrument not recognised) ──────
                    if !unmatchedItems.isEmpty {
                        if !matchedItems.isEmpty { Divider() }
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("Unmatched — instrument not recognised · double-click the prefix badge to set a custom prefix")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.10))

                        ForEach(unmatchedItems, id: \.id) { item in
                            let position   = items.firstIndex(where: { $0.id == item.id })!
                            let sectionIdx = unmatchedItems.firstIndex(where: { $0.id == item.id })!
                            PrefixOrderRow(
                                item: item,
                                position: position,
                                autoPrefix: autoPrefix(at: position),
                                finalName: prefixedName(for: item, at: position),
                                onMoveUp:   sectionIdx > 0                        ? { items.swapAt(position, position - 1) } : nil,
                                onMoveDown: sectionIdx < unmatchedItems.count - 1 ? { items.swapAt(position, position + 1) } : nil,
                                isUnmatched: true,
                                onEditPrefix: { prefixEditTarget = item; prefixEditDraft = item.customPrefix ?? autoPrefix(at: position) }
                            )
                            if item.id != unmatchedItems.last?.id { Divider() }
                        }
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
        // ── Custom prefix editor ──────────────────────────────────────────
        .sheet(item: $prefixEditTarget) { target in
            PrefixEditSheet(
                fileName: target.proposedName,
                draft: $prefixEditDraft,
                onApply: { value in
                    if let idx = items.firstIndex(where: { $0.id == target.id }) {
                        items[idx].customPrefix = value.trimmingCharacters(in: .whitespaces).isEmpty ? nil : value.trimmingCharacters(in: .whitespaces)
                    }
                    prefixEditTarget = nil
                },
                onClear: {
                    if let idx = items.firstIndex(where: { $0.id == target.id }) {
                        items[idx].customPrefix = nil
                    }
                    prefixEditTarget = nil
                },
                onCancel: { prefixEditTarget = nil }
            )
        }
    }
}

/// Small sheet for typing a free-form prefix override.
private struct PrefixEditSheet: View {
    let fileName: String
    @Binding var draft: String
    let onApply: (String) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set Custom Prefix")
                .font(.title2).fontWeight(.semibold)

            Text(fileName)
                .font(.callout)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            VStack(alignment: .leading, spacing: 6) {
                Text("Prefix (any text — leave blank to restore auto-numbering)")
                    .font(.caption).foregroundColor(.secondary)
                TextField("e.g. 00, 05a, Extra", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { onApply(draft) }
            }

            HStack {
                Button("Clear (use auto)", role: .destructive, action: onClear)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(draft) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { fieldFocused = true }
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
        .onChange(of: offset) { _, newOffset in
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

// MARK: - Page Crop Overview (minimap)
/// Small thumbnail of the full page with a highlighted rectangle showing where
/// the current crop window sits. Displayed beside the main instrument preview
/// so users can orientate themselves within the page.
struct PageCropOverview: View {
    let page: PDFPage
    var offset: CGPoint = .zero

    /// Fixed display size for the minimap thumbnail.
    private let thumbWidth: CGFloat  = 52
    private let thumbHeight: CGFloat = 70

    @State private var thumbnailImage: NSImage?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Full-page thumbnail
            Group {
                if let img = thumbnailImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: thumbWidth, height: thumbHeight)
                        .clipped()
                } else {
                    Color.gray.opacity(0.1)
                        .frame(width: thumbWidth, height: thumbHeight)
                }
            }
            .background(Color.white)

            // Crop indicator rectangle overlay
            cropIndicator
        }
        .frame(width: thumbWidth, height: thumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        .task {
            thumbnailImage = await Self.renderThumbnailAsync(
                page: page,
                width: thumbWidth, height: thumbHeight
            )
        }
    }

    /// Computes the position and size of the highlighted rectangle in the minimap's
    /// coordinate space, mirroring the crop logic in PageInstrumentPreview.
    private var cropIndicator: some View {
        let mediaBox = page.bounds(for: .mediaBox)
        let rotation  = ((page.rotation % 360) + 360) % 360
        let pageW = rotation == 90 || rotation == 270 ? mediaBox.height : mediaBox.width
        let pageH = rotation == 90 || rotation == 270 ? mediaBox.width  : mediaBox.height

        let cropH: CGFloat = 100
        let cropW = min(pageW * 0.4, 200)

        let defaultY = pageH - cropH
        let clampedX = min(max(offset.x, 0), pageW - cropW)
        let clampedY = min(max(defaultY + offset.y, 0), defaultY)

        // Scale from PDF points to thumbnail pixels
        let scaleX = thumbWidth  / pageW
        let scaleY = thumbHeight / pageH

        // PDF y=0 is at page bottom; SwiftUI y=0 is at top — flip
        let rectX = clampedX * scaleX
        let rectY = (pageH - clampedY - cropH) * scaleY
        let rectW = cropW  * scaleX
        let rectH = cropH  * scaleY

        return Rectangle()
            .stroke(Color.accentColor, lineWidth: 1.5)
            .background(Color.accentColor.opacity(0.15))
            .frame(width: max(rectW, 4), height: max(rectH, 4))
            .offset(x: rectX, y: rectY)
    }

    private static func renderThumbnailAsync(
        page: PDFPage, width: CGFloat, height: CGFloat
    ) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let size = NSSize(width: width * 2, height: height * 2)  // 2× for retina
                continuation.resume(returning: page.thumbnail(of: size, for: .mediaBox))
            }
        }
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
                guard let url = url else { return }
                DispatchQueue.main.async {
                    if url.pathExtension.lowercased() == "pdf" {
                        pdfManager.loadPDF(from: url)
                    } else {
                        showNSAlert(title: "Unsupported File Type",
                                    message: "This tab only accepts PDF files.",
                                    isError: true)
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
    
    func saveSplitPDF(to folderURL: URL, splitMarkers: Set<Int>, baseFileName: String, customFileNames: [Int: String], pageToFileMapping: [Int: Int], skippedPages: Set<Int> = [], separator: String = "_", completion: PDFAlertHandler) {
        guard let document = pdfDocument else { return }

        let numberOfFiles = (pageToFileMapping.values.max() ?? 0) + 1
        var fileDocuments: [Int: PDFDocument] = [:]

        // Initialize PDF documents for each file
        for fileIndex in 0..<numberOfFiles {
            fileDocuments[fileIndex] = PDFDocument()
        }

        // Distribute pages to files, skipping any pages in skippedPages
        for pageIndex in 0..<document.pageCount {
            guard !skippedPages.contains(pageIndex),
                  let page = document.page(at: pageIndex),
                  let fileIndex = pageToFileMapping[pageIndex],
                  let targetDoc = fileDocuments[fileIndex] else {
                continue
            }

            targetDoc.insert(page, at: targetDoc.pageCount)
        }

        // Save each file (skip files that ended up with zero pages after skipping)
        var savedFiles: [String] = []
        var errors: [String] = []

        for fileIndex in 0..<numberOfFiles {
            guard let doc = fileDocuments[fileIndex],
                  doc.pageCount > 0 else { continue }

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
