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
    /// Bridges the *active* tab's actions to the File/Edit/View/⟨tab⟩ menus.
    let tabCommands = TabCommands()
}

// MARK: - Tab Commands (menu bridge for the active tab)
// The active tab publishes a TabSlice describing the contextual verbs and its own
// action list; the menu command structs read it. Only the active tab writes (each
// tab guards its publish on `selectedTab == myTab`), so the slice always reflects
// whatever tab is on screen. Standard-editing keys (⌘A/⌘Z/⌫) and bare keys are NOT
// bound here — they stay in each tab's onKeyPress/NSEvent handlers; the menu rows
// for them are clickable only. See CLAUDE.md on CommandMenu shortcut interception.

/// One row in the adaptive ⟨active-tab⟩ menu.
struct MenuAction: Identifiable {
    let id = UUID()
    let title: String
    /// A *modifier* shortcut only (nil for none). Never a bare key / standard-editing key.
    var key: KeyEquivalent? = nil
    var modifiers: EventModifiers = .command
    var isEnabled: Bool = true
    let perform: () -> Void
}

/// The active tab's contextual menu commands. Closures are nil when unavailable
/// (the corresponding menu item is then disabled). Editing-ish verbs (Select All,
/// Undo, Delete/Skip) live in `tabActions` rather than the Edit menu, so the system
/// Edit menu (text Undo/Cut/Copy/Paste/Select All) is left untouched.
struct TabSlice {
    var openTitle: String = "Open\u{2026}"        // File ▸ ⌘O
    var open: (() -> Void)? = nil
    var primaryTitle: String = "Save"             // File ▸ ⌘S (context: Create PDF / Save Split / …)
    var primarySave: (() -> Void)? = nil
    var openInPreview: (() -> Void)? = nil        // File ▸ ⇧⌘P (Combine)
    var clearTitle: String = "Clear"              // File ▸ ⌘⌫ label (e.g. "Start Over" on done screens)
    var clear: (() -> Void)? = nil                // File ▸ ⌘⌫
    var togglePresets: (() -> Void)? = nil        // View ▸ ⌥⌘P (Combine)
    var tabActions: [MenuAction] = []             // the adaptive "Actions" menu
}

final class TabCommands: ObservableObject {
    @Published var slice = TabSlice()
}

/// Reveals a file (selected in its parent folder) or opens a folder in Finder. No-op on nil.
func revealInFinder(_ url: URL?) {
    guard let url = url else { return }
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
        NSWorkspace.shared.open(url)
    } else {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
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

// MARK: - File Commands (contextual Open / Save / Preview / Clear for the active tab)
struct FileCommands: Commands {
    @ObservedObject var commands: TabCommands

    var body: some Commands {
        // Open… replaces File ▸ New.
        CommandGroup(replacing: .newItem) {
            Button(commands.slice.openTitle) { commands.slice.open?() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(commands.slice.open == nil)
        }
        // Save / export, preview, clear replace the Save slot.
        CommandGroup(replacing: .saveItem) {
            Button(commands.slice.primaryTitle) { commands.slice.primarySave?() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(commands.slice.primarySave == nil)

            Button("Open in Preview") { commands.slice.openInPreview?() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(commands.slice.openInPreview == nil)

            Divider()

            Button(commands.slice.clearTitle) { commands.slice.clear?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(commands.slice.clear == nil)
        }
    }
}

// MARK: - View Commands (tab switching + panel toggles)
struct ViewCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandMenu("View") {
            Button("Combine PDFs") { appState.selectedTab = 0 }
                .keyboardShortcut("1", modifiers: .command)
            Button("Rename Files") { appState.selectedTab = 1 }
                .keyboardShortcut("2", modifiers: .command)
            Button("Split PDF") { appState.selectedTab = 2 }
                .keyboardShortcut("3", modifiers: .command)
            Button("Rotate Pages") { appState.selectedTab = 3 }
                .keyboardShortcut("4", modifiers: .command)

            Divider()

            Button("Show/Hide Presets") { appState.tabCommands.slice.togglePresets?() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(appState.tabCommands.slice.togglePresets == nil)
        }
    }
}

// MARK: - Tab Actions Commands (the adaptive "Actions" menu for the current tab)
// A single stable-titled menu whose *contents* are the active tab's actions
// (SwiftUI can't reliably retitle a CommandMenu, so the title stays "Actions").
struct TabActionsCommands: Commands {
    @ObservedObject var commands: TabCommands

    var body: some Commands {
        CommandMenu("Actions") {
            ForEach(commands.slice.tabActions) { action in
                let button = Button(action.title) { action.perform() }
                    .disabled(!action.isEnabled)
                if let key = action.key {
                    button.keyboardShortcut(key, modifiers: action.modifiers)
                } else {
                    button
                }
            }
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
            FileCommands(commands: appState.tabCommands)
            ViewCommands(appState: appState)
            TabActionsCommands(commands: appState.tabCommands)
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

// MARK: - Keyboard Shortcuts Help
struct ShortcutsHelpView: View {
    var onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Keyboard Shortcuts")
                    .font(.title2)
                    .fontWeight(.semibold)

                shortcutSection("Global (View & File menus)") {
                    shortcutRow("⌘1 – ⌘4", "Switch tab (Combine / Rename / Split / Rotate)")
                    shortcutRow("⌘O", "Open — add files / choose a PDF or folder")
                    shortcutRow("⌘S", "Primary action — Create PDF / Save / Rename (per tab)")
                    shortcutRow("⇧⌘F", "Show in Finder (the folder we’re working from)")
                    shortcutRow("⌘⌫", "Clear / Start Over")
                    shortcutRow("⌘,", "Preferences")
                    shortcutRow("⌘/", "Welcome tour")
                    shortcutRow("⌘`", "This shortcuts panel")
                }

                shortcutSection("Combine PDFs") {
                    shortcutRow("↑ / ↓", "Select previous / next file")
                    shortcutRow("⇧↑ / ⇧↓", "Extend selection up / down")
                    shortcutRow("⌘A", "Select all files")
                    shortcutRow("⌫", "Remove selected files")
                    shortcutRow("⌘↑ / ⌘↓", "Move selected files up / down")
                    shortcutRow("C", "Collate selected files into a group")
                    shortcutRow("⌘Z / ⇧⌘Z", "Undo / Redo")
                    shortcutRow("⌥⌘P", "Show / hide the presets panel (also P)")
                    shortcutRow("⇧⌘P", "Open the combined PDF in Preview")
                }

                shortcutSection("Rename Files") {
                    shortcutRow("⌫", "Move selected files to “Don’t Rename”")
                    shortcutRow("⌘R", "Rescan the current folder")
                }

                shortcutSection("Split PDF") {
                    shortcutRow("← / →", "Previous / next page")
                    shortcutRow("⌘← / ⌘→", "First / last page")
                    shortcutRow("↑ / ↓", "Jump between output files")
                    shortcutRow("⇧↑ / ⇧↓", "Extend the output-file selection")
                    shortcutRow("Space", "Add / remove a split at the current page")
                    shortcutRow("S", "Swap the current page with the next")
                    shortcutRow("R", "Re-stride: apply stride from here to the end")
                    shortcutRow("⌫", "Skip the current page / output file")
                    shortcutRow("⌘Z / ⇧⌘Z", "Undo / Redo split edits")
                    shortcutRow("↩", "Next step (Name Files)")
                    shortcutRow("⎋", "Back to the previous step")
                }

                shortcutSection("Rotate Pages") {
                    shortcutRow("← / →", "Previous / next page")
                    shortcutRow("⌘← / ⌘→", "First / last page")
                    shortcutRow(", / .", "Rotate current page left / right")
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
        .frame(width: 500)
        .frame(maxHeight: 620)
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
                .frame(width: 96, alignment: .leading)
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
