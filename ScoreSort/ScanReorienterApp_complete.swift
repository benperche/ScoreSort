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
@preconcurrency import PDFKit
import UniformTypeIdentifiers
import Combine
import Sparkle

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
    @Published var isActiveTab = false  // disables the Combiner menu's bare-key shortcuts
                                        // (↑ ↓ ⌫ c p) when another tab is on screen

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
                .disabled(!state.isActiveTab || state.isPanelOpen || !state.hasFiles)

            Button("Extend Selection Up") { state.selectPreviousExtending() }
                .keyboardShortcut(.upArrow, modifiers: .shift)
                .disabled(!state.isActiveTab || state.isPanelOpen || !state.hasFiles)

            Button("Select Next") { state.selectNext() }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(!state.isActiveTab || state.isPanelOpen || !state.hasFiles)

            Button("Extend Selection Down") { state.selectNextExtending() }
                .keyboardShortcut(.downArrow, modifiers: .shift)
                .disabled(!state.isActiveTab || state.isPanelOpen || !state.hasFiles)

            Divider()

            Button("Move Up") { state.moveUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!state.isActiveTab || state.isPanelOpen || !state.canMoveUp)

            Button("Move Down") { state.moveDown() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!state.isActiveTab || state.isPanelOpen || !state.canMoveDown)

            Divider()

            Button("Remove Selected Files") { state.removeSelected() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!state.isActiveTab || state.isPanelOpen || !state.canRemove)

            Divider()

            Button("Group Selected Files") { state.group() }
                .keyboardShortcut("c", modifiers: [])
                .disabled(!state.isActiveTab || state.isPanelOpen || !state.canGroup)

            Divider()

            Button("Select All Files") { state.selectAll() }
                .disabled(!state.isActiveTab || state.isPanelOpen || !state.hasFiles)

            Divider()

            Button("Toggle Presets Panel") { state.togglePresetSidebar() }
                .keyboardShortcut("p", modifiers: [])
                .disabled(!state.isActiveTab)
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

// MARK: - Sparkle Updater (direct distribution via website / GitHub releases)
// Drives auto-update checks against the appcast at Info.plist's SUFeedURL.
// Not used for App Store / TestFlight builds (the Mac App Store handles updates).
final class UpdaterViewModel: ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    private var updaterStarted = false
    @Published var canCheckForUpdates = false
    init() {
        // Don't show Sparkle's "check for updates automatically?" permission prompt on
        // the very first launch — it greets brand-new users before they've used the app.
        // We defer *starting* the updater (which is what triggers the scheduled check and
        // the prompt) until the second launch. Manual "Check for Updates…" still works on
        // first launch via checkForUpdates(), which starts the updater on demand.
        let defaults = UserDefaults.standard
        let launchCount = defaults.integer(forKey: "appLaunchCount") + 1
        defaults.set(launchCount, forKey: "appLaunchCount")
        let startNow = launchCount >= 2

        // Pass startingUpdater: false so we control exactly when it starts.
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        updaterController.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        if startNow { startUpdaterIfNeeded() }
    }

    private func startUpdaterIfNeeded() {
        guard !updaterStarted else { return }
        updaterStarted = true
        updaterController.startUpdater()
    }

    func checkForUpdates() {
        // A user-initiated check is never the unwanted first-launch prompt, so it's fine
        // to start the updater here if it hasn't been started yet.
        startUpdaterIfNeeded()
        updaterController.updater.checkForUpdates()
    }
}

// MARK: - Main App
@main
struct ScoreSortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var renamerManager = RenamerManager()
    @StateObject private var presetStore = EnsemblePresetStore()
    @StateObject private var updaterViewModel = UpdaterViewModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(renamerManager)
                .environmentObject(presetStore)
        }
        // Default window size on first launch. Users can resize freely and the size is
        // then remembered. (Temporarily set to 1280×800 when taking App Store screenshots.)
        .defaultSize(width: 940, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About ScoreSort") {
                    openWindow(id: "about")
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates\u{2026}") { updaterViewModel.checkForUpdates() }
                    .disabled(!updaterViewModel.canCheckForUpdates)
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
    // Set true once the main window has appeared. Until then we must NOT quit on
    // last-window-close: at launch Sparkle's update dialog can appear before the
    // SwiftUI WindowGroup window is on screen (the window is created async), and
    // dismissing Sparkle's dialog would otherwise look like "last window closed"
    // and terminate the app before the main window ever shows.
    static var mainWindowHasAppeared = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        InstrumentOrders.setup()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return AppDelegate.mainWindowHasAppeared
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
                // Now that the main window is on screen, allow quit-on-last-window-close.
                AppDelegate.mainWindowHasAppeared = true
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
    @EnvironmentObject private var appState: AppState
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
    /// Drag-to-reorder: the (group-snapped) row id an insertion line is shown above,
    /// or `.endOfList` when hovering the trailing drop zone. Nil when not dragging.
    @State private var dropTargetId: UUID?
    @State private var isDropAtEnd = false
    /// Drag-to-reorder: the collate group whose body is hovered (drop = add to group).
    @State private var mergeTargetGroupId: UUID?
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
        .onAppear { DispatchQueue.main.async { syncMenuClosures(); syncMenuFlags() } }
        .onChange(of: selectedFiles)          { DispatchQueue.main.async { syncMenuFlags() } }
        .onChange(of: combineManager.files)   { DispatchQueue.main.async { syncMenuFlags() } }
        // Disable the Combiner menu's bare-key shortcuts the instant another tab is shown.
        .onChange(of: appState.selectedTab)   { DispatchQueue.main.async { syncMenuFlags() } }
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
                        Label("Clear Files", systemImage: "xmark.circle.fill")
                    }
                    .help("Remove all files and start over")
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
                                let isGroupFirst = file.collateGroupId.map { gid in
                                    combineManager.files.first(where: { $0.collateGroupId == gid })?.id == file.id
                                } ?? false
                                VStack(spacing: 0) {
                                    // If this file is the first member of a collate group,
                                    // emit a group header row before it. The header is a
                                    // *reorder* drop target (lands above the group), while
                                    // the member rows below merge dropped files into it.
                                    if isGroupFirst, let gid = file.collateGroupId,
                                       let group = combineManager.collateGroups[gid] {
                                        let groupFiles = combineManager.files.filter { $0.collateGroupId == gid }
                                        CollateGroupHeaderRow(
                                            group: group,
                                            fileCount: groupFiles.count,
                                            totalPages: groupFiles.reduce(0) { $0 + $1.pageCount },
                                            isMergeTarget: mergeTargetGroupId == gid,
                                            onCopiesChanged: { newValue in
                                                combineManager.updateGroupCopies(id: gid, copies: newValue, undoManager: undoManager)
                                            },
                                            onUngroup: {
                                                combineManager.dissolveGroup(id: gid, undoManager: undoManager)
                                            }
                                        )
                                        .draggable(file.id.uuidString) { dragPreview(for: file) }
                                        .overlay(alignment: .top) { insertionLine(visible: dropTargetId == file.id) }
                                        .dropDestination(for: String.self) { items, _ in
                                            handleReorderDrop(items, onto: file.id)
                                        } isTargeted: { setReorderTarget(file.id, $0) }
                                        Divider()
                                    }
                                    CombineFileRow(
                                        file: file,
                                        isSelected: selectedFiles.contains(file.id),
                                        isFocused: focusedFileId == file.id,
                                        isUnmatched: unmatchedFileIds.contains(file.id),
                                        isGrouped: file.collateGroupId != nil,
                                        isLastInGroup: isLastInGroup(file),
                                        isMergeTarget: file.collateGroupId != nil && mergeTargetGroupId == file.collateGroupId,
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
                                    .draggable(file.id.uuidString) { dragPreview(for: file) }
                                    .overlay(alignment: .top) {
                                        // Ungrouped rows show a reorder insertion line; grouped
                                        // member rows use the whole-group merge highlight instead.
                                        insertionLine(visible: file.collateGroupId == nil && dropTargetId == file.id)
                                    }
                                    .dropDestination(for: String.self) { items, _ in
                                        if let gid = file.collateGroupId {
                                            return handleAddToGroup(items, groupId: gid)
                                        }
                                        return handleReorderDrop(items, onto: file.id)
                                    } isTargeted: { targeted in
                                        if let gid = file.collateGroupId {
                                            if targeted { mergeTargetGroupId = gid; dropTargetId = nil }
                                            else if mergeTargetGroupId == gid { mergeTargetGroupId = nil }
                                        } else {
                                            setReorderTarget(file.id, targeted)
                                        }
                                    }
                                    Divider()
                                }
                            }

                            // Trailing zone: drop here to move the block to the very end.
                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .contentShape(Rectangle())
                                .overlay(alignment: .top) { insertionLine(visible: isDropAtEnd) }
                                .dropDestination(for: String.self) { items, _ in
                                    handleReorderDropAtEnd(items)
                                } isTargeted: { isDropAtEnd = $0 }
                        }
                    }
                    .focusable()
                    .focused($listFocused)
                    .onKeyPress { press in
                        guard appState.selectedTab == 0 else { return .ignored }   // Combine tab only
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

            Text("Merge multiple PDFs or images into a single document ready to print in one go")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.top, 4)
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

    // True when `file` is the last member of its collate group (used to draw the
    // closing border so a group's extent is obvious).
    private func isLastInGroup(_ file: CombineFile) -> Bool {
        guard let gid = file.collateGroupId,
              let idx = combineManager.files.firstIndex(where: { $0.id == file.id })
        else { return false }
        let next = idx + 1
        return next >= combineManager.files.count || combineManager.files[next].collateGroupId != gid
    }

    // Snap a drop target to its collate group's first member, so an insert never
    // lands inside a group (which would split it). Ungrouped ids are returned as-is.
    private func groupSnappedTarget(_ targetId: UUID) -> UUID {
        guard let gid = combineManager.files.first(where: { $0.id == targetId })?.collateGroupId
        else { return targetId }
        return combineManager.files.first(where: { $0.collateGroupId == gid })?.id ?? targetId
    }

    // The set of files a drag should move: the whole selection if the dragged row is
    // part of it, otherwise just the dragged row — then group-expanded either way.
    private func draggedSet(for draggedId: UUID) -> Set<UUID> {
        let base: Set<UUID> = selectedFiles.contains(draggedId) ? selectedFiles : [draggedId]
        return expandForGroups(base)
    }

    /// Handle a reorder drop onto `rowId`. Returns true if the order changed.
    private func handleReorderDrop(_ items: [String], onto rowId: UUID) -> Bool {
        dropTargetId = nil
        mergeTargetGroupId = nil
        guard let first = items.first, let draggedId = UUID(uuidString: first) else { return false }
        let moving = draggedSet(for: draggedId)
        let target = groupSnappedTarget(rowId)
        guard !moving.contains(target) else { return false }   // dropped onto its own block
        combineManager.move(ids: moving, before: target, undoManager: undoManager)
        return true
    }

    /// Handle a drop onto a collate group's body — merge the dragged file(s) into it.
    private func handleAddToGroup(_ items: [String], groupId: UUID) -> Bool {
        dropTargetId = nil
        mergeTargetGroupId = nil
        guard let first = items.first, let draggedId = UUID(uuidString: first) else { return false }
        combineManager.addToGroup(ids: draggedSet(for: draggedId), groupId: groupId, undoManager: undoManager)
        return true
    }

    // Track which row's insertion line is shown while reordering.
    private func setReorderTarget(_ id: UUID, _ targeted: Bool) {
        if targeted { dropTargetId = id; mergeTargetGroupId = nil }
        else if dropTargetId == id { dropTargetId = nil }
    }

    /// Handle a drop onto the trailing zone — move the dragged block to the end.
    private func handleReorderDropAtEnd(_ items: [String]) -> Bool {
        isDropAtEnd = false
        guard let first = items.first, let draggedId = UUID(uuidString: first) else { return false }
        combineManager.move(ids: draggedSet(for: draggedId), before: nil, undoManager: undoManager)
        return true
    }

    /// Drag preview, reflecting what's actually being moved: "Collate Group" when the
    /// drag is exactly one collate group, "N items" for a multi-file selection, else
    /// the single file's name.
    @ViewBuilder private func dragPreview(for file: CombineFile) -> some View {
        let moving = draggedSet(for: file.id)
        if let gid = file.collateGroupId,
           moving == Set(combineManager.files.filter { $0.collateGroupId == gid }.map(\.id)) {
            dragPreviewLabel("Collate Group", systemImage: "rectangle.stack.fill")
        } else if moving.count > 1 {
            dragPreviewLabel("\(moving.count) items", systemImage: "doc.on.doc")
        } else {
            dragPreviewLabel(file.name, systemImage: "doc.on.doc")
        }
    }

    private func dragPreviewLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .lineLimit(1)
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    /// A thin accent insertion line shown where a dragged block will land.
    @ViewBuilder private func insertionLine(visible: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 8)
            .opacity(visible ? 1 : 0)
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
        // Default to the folder of the first real input file.
        if let firstSource = combineManager.files.first(where: { !$0.isBlankPage })?.url {
            panel.directoryURL = outputDirectory(forSourceFile: firstSource)
        }

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
        menuState.isActiveTab = appState.selectedTab == 0
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
                presetPartMatches(part: normalizeRomanNumerals($0.name.lowercased()), in: filename)
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
                return presetPartMatches(part: base, in: normalizeRomanNumerals(file.name.lowercased()))
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
    /// True when this is the last member of its collate group (draws the closing border).
    var isLastInGroup: Bool = false
    /// True while a drag is hovering this file's collate group (highlight as merge target).
    var isMergeTarget: Bool = false
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
        .background(rowBackground)
        // Continuous accent spine down the left edge of a collate group, plus a
        // closing border under the last member so the group's extent is obvious.
        .overlay(alignment: .leading) {
            if isGrouped {
                Rectangle().fill(Color.accentColor.opacity(0.55)).frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) {
            if isLastInGroup {
                Rectangle().fill(Color.accentColor.opacity(0.55)).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggleSelect() }
        .onChange(of: copiesFieldFocused) { _, focused in
            if !focused && isEditingCopies { commitCopiesEdit() }
        }
    }

    private var rowBackground: Color {
        if isMergeTarget { return Color.accentColor.opacity(0.22) }   // drag merge highlight
        if isSelected { return Color.accentColor.opacity(isFocused ? 0.18 : 0.1) }
        if isUnmatched { return Color.orange.opacity(0.12) }
        if isGrouped { return Color.accentColor.opacity(0.05) }   // faint group fill
        if file.isBlankPage { return Color.gray.opacity(0.08) }
        return Color.clear
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
    /// True while a drag is hovering this group (highlight as merge target).
    var isMergeTarget: Bool = false
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
        .background(Color.accentColor.opacity(isMergeTarget ? 0.22 : 0.07))
        // Top of the accent spine that runs down the whole collate group.
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.accentColor.opacity(0.55)).frame(width: 3)
        }
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
                    shortcutRow("R", "Re-stride: apply stride from current page to end")
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
                "Drag your files (or a whole folder) into the app, then reorder with **⌘↑ / ⌘↓** or by dragging. You can also drag in **images** (JPEG, PNG, TIFF…) — each becomes an A4 page — and insert a blank sheet anywhere with **Add Blank Page**. Set how many copies of each part you need with the stepper beside it.",
                "You can save your usual instrument allocations as **Ensemble Presets** in Preferences. These can be viewed in the Presets sidebar to help you remember the normal number of parts required. Use **Apply to Files** to attempt to automatically match your preset allocations to your filenames.",
                "When ready, click **Create PDF** to save the combined file, or **Open in Preview** to print directly without saving. The combined PDF includes a clickable **table of contents** (one bookmark per file), shown in Preview's sidebar.",
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
                "In Step 2, name each output file — the same flow as Rename Files. Toggle **Prefix score order** to add score-order numbers automatically in Step 3.",
                "**A3 & booklet scans:** Drop an A3 scan (two A4 pages side-by-side) and ScoreSort offers to split every sheet down the middle into separate pages. If a booklet was scanned out of reading order, put each booklet in its own split, then use **Fix Booklet Order** to restore the page order automatically — or **Swap with Next (S)** to nudge individual pages."
            ],
            tipText: "Space toggles a split marker · S swaps a page with the next · Delete skips a page or file · ⌘← / ⌘→ jumps to first / last page",
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

/// Reports the natural height of the current tour page so the card can hug its content.
private struct TourContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct WelcomeTourView: View {
    var onDismiss: () -> Void

    @State private var currentPage = 0
    @State private var goingForward = true
    @State private var contentHeight: CGFloat = 0

    private let pages = WelcomeTourPage.all
    /// The card hugs each page's content up to this height, then scrolls — so a short
    /// page (like the welcome page) isn't stretched to the full window height.
    private let maxContentHeight: CGFloat = 600

    var body: some View {
        VStack(spacing: 0) {

            // ── Content: card hugs the page's height, scrolling past the cap ──
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    TourPageContentView(page: pages[currentPage])
                        .id(currentPage)
                        .transition(.asymmetric(
                            insertion: .move(edge: goingForward ? .trailing : .leading)
                                        .combined(with: .opacity),
                            removal:   .move(edge: goingForward ? .leading : .trailing)
                                        .combined(with: .opacity)
                        ))
                        .background(GeometryReader { geo in
                            Color.clear.preference(key: TourContentHeightKey.self,
                                                   value: geo.size.height)
                        })
                }
                .frame(height: min(max(contentHeight, 1), maxContentHeight))
                .onPreferenceChange(TourContentHeightKey.self) { contentHeight = $0 }
                .onChange(of: currentPage) { _, newValue in
                    proxy.scrollTo(newValue, anchor: .top)   // reset to top on each page change
                }
                .animation(.easeInOut(duration: 0.25), value: contentHeight)
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
        "Euphonium BC", "Tuba",
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

    /// Moves the given files (a group-expanded block; order preserved) so they land
    /// immediately before `targetId`, or to the end when `targetId` is nil. Callers
    /// snap `targetId` to a collate-group boundary, so groups stay contiguous.
    func move(ids: Set<UUID>, before targetId: UUID?, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        let moving = files.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        var remaining = files.filter { !ids.contains($0.id) }
        let insertIndex: Int
        if let targetId, let idx = remaining.firstIndex(where: { $0.id == targetId }) {
            insertIndex = idx
        } else {
            insertIndex = remaining.count   // target nil or itself moved → append
        }
        remaining.insert(contentsOf: moving, at: insertIndex)
        files = remaining
        if files.map(\.id) != bf.map(\.id) {
            registerUndo(undoManager: undoManager, actionName: "Reorder Files",
                         restoringFiles: bf, restoringGroups: bg)
        }
    }

    /// Adds the given files into an existing collate group (drag-onto-group). The files
    /// are reassigned to `groupId` and pulled in contiguously after the group's current
    /// last member. Files already in the group are ignored; any source group left with
    /// fewer than 2 members is dissolved.
    func addToGroup(ids: Set<UUID>, groupId: UUID, undoManager: UndoManager?) {
        guard collateGroups[groupId] != nil else { return }
        let bf = files; let bg = collateGroups
        let addingIds = ids.filter { id in
            files.first(where: { $0.id == id })?.collateGroupId != groupId
        }
        guard !addingIds.isEmpty else { return }

        var moving = files.filter { addingIds.contains($0.id) }
        for i in moving.indices { moving[i].collateGroupId = groupId }
        var remaining = files.filter { !addingIds.contains($0.id) }
        if let lastIdx = remaining.lastIndex(where: { $0.collateGroupId == groupId }) {
            remaining.insert(contentsOf: moving, at: lastIdx + 1)
        } else {
            remaining.append(contentsOf: moving)
        }
        files = remaining
        cleanupSmallGroups()
        registerUndo(undoManager: undoManager, actionName: "Add to Collate Group",
                     restoringFiles: bf, restoringGroups: bg)
    }

    /// Dissolves any collate group left with fewer than 2 members.
    private func cleanupSmallGroups() {
        for gid in collateGroups.keys where files.filter({ $0.collateGroupId == gid }).count < 2 {
            for i in files.indices where files[i].collateGroupId == gid { files[i].collateGroupId = nil }
            collateGroups.removeValue(forKey: gid)
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
    /// Persisted so callers can request a specific tab before opening the window.
    @AppStorage("preferredPrefsTab") private var preferredPrefsTab: String = "combiner"
    @State private var selectedTab: String = "combiner"

    var body: some View {
        TabView(selection: $selectedTab) {
            CombinerPreferencesView()
                .tabItem { Label("Combiner", systemImage: "doc.on.doc") }
                .tag("combiner")

            PreferencesView(
                ensembleType: $renamerManager.ensembleType,
                instrumentOrder: $renamerManager.customInstrumentOrder,
                prefixSeparator: $renamerManager.prefixSeparator
            )
            .tabItem { Label("Renamer", systemImage: "folder.badge.gearshape") }
            .tag("renamer")
        }
        .frame(width: 680, height: 720)
        .onAppear { selectedTab = preferredPrefsTab }
        // Fires even when the window is already open, so deep-linking works
        // whether the window is freshly opened or already visible.
        .onChange(of: preferredPrefsTab) { _, newTab in selectedTab = newTab }
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

// MARK: - Rotate View
struct RotateView: View {
    @EnvironmentObject private var appState: AppState
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
                        Label("Clear File", systemImage: "xmark.circle.fill")
                    }
                    .help("Remove the current file and start over")
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
                DropZoneView(pdfManager: pdfManager,
                             subtitle: "Correct pages that came out sideways or upside-down after scanning")
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
            guard appState.selectedTab == 3 else { return .ignored }   // Rotate tab only
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
        savePanel.directoryURL = outputDirectory(forSourceFile: pdfManager.sourceURL)

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

// MARK: - Sendable utilities

/// Wraps a non-Sendable value so it can be safely captured in a @Sendable closure.
/// Use only where you can guarantee the underlying object is actually thread-safe
/// (e.g. PDFKit types, which Apple uses from background threads despite not being
/// formally marked Sendable).
final class Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
    // Explicit deinit prevents a Swift compiler crash in Release mode where
    // EarlyPerfInliner hits an internal assertion on the synthesised deinit
    // of a generic @unchecked Sendable class.
    deinit {}
}

// MARK: - Drop Zone View (Shared)
struct DropZoneView: View {
    @ObservedObject var pdfManager: PDFManager
    var subtitle: String? = nil
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

            if let subtitle {
                Text(subtitle)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
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
    /// The file the user loaded. Retained so output dialogs can default to its folder
    /// (it survives in-place document rebuilds like A3 split / booklet reorder, which
    /// replace `pdfDocument` and would otherwise drop `PDFDocument.documentURL`).
    @Published var sourceURL: URL?

    func loadPDF(from url: URL) {
        guard let document = PDFDocument(url: url) else {
            print("Failed to load PDF")
            return
        }

        self.pdfDocument = document
        self.currentFileName = url.deletingPathExtension().lastPathComponent
        self.sourceURL = url
    }

    func clearPDF() {
        pdfDocument = nil
        currentFileName = nil
        sourceURL = nil
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
func showNSAlert(title: String, message: String, isError: Bool) {
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
