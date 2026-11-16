# Shared scaffolding: app, menus, shared infrastructure

Everything here lives in `ScoreSort/ScanReorienterApp_complete.swift` (the legacy-named main file, about 1,900 lines) unless another file is named. Gotchas that concern this area: [gotchas.md § Menus and keyboard](gotchas.md#menus-and-keyboard) and [§ SwiftUI and AppKit](gotchas.md#swiftui-and-appkit).

## App structure

```
ScoreSortEntry (@main, CLI/Entry.swift)   — a command-line verb runs headless; otherwise ScoreSortApp.main()
ScoreSortApp
  └── AppDelegate  — InstrumentOrders.setup() on launch; quits on last window close (once the window has appeared)
  └── WindowGroup  — ContentView            (.defaultSize 940×800; TabView min 1020×700)
        └── ContentView  — ZStack { TabView (tags 0–4), overlays }
              ├── 0: CombineView     ⌘1
              ├── 1: RenamerView     ⌘2
              ├── 2: SplitView       ⌘3
              ├── 3: RotateView      ⌘4
              └── 4: StampView       ⌘5
              overlays (not sheets): WelcomeTourView (⌘/), ShortcutsHelpView (⌘`)
  └── Settings  — AppPreferencesView (⌘,)
        ├── "Combiner"       (tag "combiner") — CombinerPreferencesView   → combine.md
        ├── "Renamer"        (tag "renamer")  — PreferencesView           → rename.md
        └── "AI Assistants"  (tag "ai")       — AIAssistantsPreferencesView (CLI/AIAssistantsPreferences.swift) → cli-mcp.md
```

- The minimum width was raised from 900 to 1020 for the Stamp tab (its fixed-width designer column plus preview don't fit narrower).
- **There is no About window scene.** `CommandGroup(replacing: .appInfo)` calls `NSApp.orderFrontStandardAboutPanel(options: [.credits: aboutPanelCredits()])`. A titled `Window` scene was removed because it added an unwanted entry to the Window menu. `aboutPanelCredits()` builds the credits from the executable's modification date plus authorship.
- **Settings deep-links** through `@AppStorage("preferredPrefsTab")`: write `"combiner"`, `"renamer"` or `"ai"` before opening Settings, and `AppPreferencesView`'s `.onChange` selects that tab even if the window is already open.
- **Welcome tour and shortcuts panel are overlays** drawn in `ContentView`'s `ZStack` over a dimmed backdrop (tap the backdrop or press Escape to close), not `.sheet`s. The tour shows on first launch (`@AppStorage("hasSeenWelcomeTour")`) after a 0.5 s delay. Its pages are the static `WelcomeTourPage.all`; `WelcomeTourView`, `TourPageContentView` and `TourImageView` (PNG or animated GIF from the asset catalog) render them. `WelcomeTourContent.md` at the repo root is the editable draft of the tour copy, not something the app reads.

### App-level shared state

Held as `@StateObject` on `ScoreSortApp` and injected with `.environmentObject()`:

| Object | Used by |
|--------|---------|
| `AppState` — `selectedTab`, `showingKeyboardHelp`, `showingWelcomeTour`, plus `tabCommands` (`TabCommands`), `combineMenuState` (`CombineMenuState`) and `stampFormatter` (`StampTextFormatter`, for the Format menu) | every tab |
| `RenamerManager` | `RenamerView`, `AppPreferencesView` (the Renamer pane binds its ensemble, order and separator) |
| `EnsemblePresetStore` | `CombineView`, `PresetSidebarView`, `CombinerPreferencesView` |
| `StampStore` | `StampView`, `StampMenuButton`, `CombineView`, `SplitView`, Settings |
| `UpdaterViewModel` (Sparkle; not injected) | the "Check for Updates…" menu item — see [releasing.md](releasing.md) |

`PDFManager` is *not* app-level: Split and Rotate each own a separate `@StateObject`. `CombineManager` belongs to `CombineView`.

## Menu bar

Standard **File / Edit / View** plus one adaptive **Actions** menu and a **Format** menu (redesigned in 1.8.0). There are no per-tab menus.

| Struct | Menu | Contents |
|--------|------|----------|
| `FileCommands` | File | `Open…` (⌘O, replaces `.newItem`) · `Save` (⌘S) · `Open in Preview` (⇧⌘P) · `Clear` (⌘⌫), all replacing `.saveItem` · `Close` (⌘W, added by hand: SwiftUI gave this `WindowGroup` no Close item) · `Print…` (⌘P, replaces `.printItem`). Titles and enablement come from the active tab's slice. |
| `ViewCommands` | View | Tab switching: Combine PDFs ⌘1 / Rename Files ⌘2 / Split PDF ⌘3 / Rotate Pages ⌘4 / Stamp ⌘5, plus `Show/Hide Presets` (⌥⌘P, disabled unless the active tab supplies `togglePresets`). Debug builds add "Set Window to 1280 × 800 (screenshots)". |
| `TabActionsCommands` | Actions | `ForEach` over the active tab's `slice.tabActions`. The title is fixed: SwiftUI can't reliably retitle a `CommandMenu`, so only the contents swap per tab. |
| `FormatCommands` | Format | `Bold` (⌘B) and `Italic` (⌘I), driven by `AppState.stampFormatter`; disabled unless a stamp text editor is on screen (`formatter.isAvailable`). |
| `HelpCommands` | Help | Replaces `.help` (the default item errors): `Welcome Tour…` (⌘/), `Keyboard Shortcuts…` (⌘\`), and `OpenAIAssistantsSettingsButton` (opens Settings on the AI Assistants tab). |

`CommandGroup(replacing: .appInfo)` → the standard About panel; `CommandGroup(after: .appInfo)` → `Check for Updates…` (Sparkle, disabled until `canCheckForUpdates`).

### The `TabCommands` / `TabSlice` / `MenuAction` bridge

- `MenuAction` — one Actions-menu row: `title`, optional `key` (**a modifier shortcut only, never a bare or standard-editing key**), `modifiers` (default `.command`), `isEnabled`, `perform`.
- `TabSlice` — the active tab's contextual verbs: `openTitle`/`open` (⌘O), `primaryTitle`/`primarySave` (⌘S), `openInPreview` (⇧⌘P), `print` (⌘P), `clearTitle`/`clear` (⌘⌫), `togglePresets` (⌥⌘P), `tabActions`.
- `TabCommands` — `ObservableObject` with one `@Published var slice`. `AppState.tabCommands` holds the single instance; the command structs observe it.

A **nil closure disables** its menu item, so a tab says "not available yet" by leaving the closure nil.

**Only the active tab writes.** Each tab has a private `syncTabCommands()` that begins `guard appState.selectedTab == <myTab> else { return }`, builds a fresh `TabSlice` and assigns `appState.tabCommands.slice`. It is called from `.onAppear` and from `.onChange` of `appState.selectedTab` and whatever state affects enablement, wrapped in `DispatchQueue.main.async` so publishing happens after the view body completes. Hidden tabs stay mounted, so the guard is what keeps the menus showing the on-screen tab.

| Tab | ⌘O | ⌘S | ⌘⌫ | Actions menu |
|-----|----|----|----|--------------|
| 0 Combine | Add Files… | Create PDF… | Clear Files | Move Up ⌘↑ · Move Down ⌘↓ · Collate · Add Blank Page · Remove Selected · Select All · Select None · Booklet Page Turns… ⌘T (enabled only in booklet output) · Show in Finder ⇧⌘F. Also supplies `openInPreview`, `print` and `togglePresets`. |
| 1 Rename | Choose Files or Folder… | Rename Files | Clear Files / **Start Over** on the done screen | Don't Rename Selected · Rescan Folder ⌘R · Skip Folder · Show in Finder ⇧⌘F (done screen: Rescan Folder · Show in Finder) |
| 2 Split | Choose PDF… | per stage: Continue to Naming / Save Split Files (none on Step 3 or the summary) | Clear File / **Start Over** on the summary | Split: Split Double Pages… · Fix Booklet Order · Use Bookmarks… · Clear All Splits; Naming: Back to Split; Prefix: Back to Naming. Always ends with Show in Finder ⇧⌘F. |
| 3 Rotate | Choose PDF… | Save Rotated PDF | Clear File | Rotate Left · Rotate Right · Show in Finder ⇧⌘F |
| 4 Stamp | Add Files… | Stamp Files… | Clear Files | New Stamp ⌘N · Duplicate Stamp ⌘D · Delete Stamp · Previous Page · Next Page · Show in Finder ⇧⌘F |

Conventions:
- Actions are **listed even when unusable** (`isEnabled: false`) rather than omitted, so the menu advertises what a tab can do in its empty state.
- "Show in Finder" calls `revealInFinder(_:)` (selects a file, opens a folder, no-op on nil) on the most relevant target: the output folder on done/summary screens, else the source file or folder.
- **Menus bind only non-editing modifier shortcuts**: ⌘O/⌘S/⇧⌘P/⌘P/⌘W/⌘⌫/⌥⌘P/⇧⌘F/⌘R/⌘1–5, Combine's ⌘↑/⌘↓/⌘T, Stamp's ⌘N/⌘D and Format's ⌘B/⌘I. Standard-editing keys (⌘A/⌘Z/⌫) and all bare keys stay in the tabs' own handlers. The reason is in [gotchas.md](gotchas.md#menus-and-keyboard).

### `CombineMenuState`

No longer the menu bridge. It survives for Combine's in-view keyboard handling: `isPanelOpen` (set around the open/save panels; Combine's key handlers early-out while a panel is up) and the `canRemove`/`canMoveUp`/`canMoveDown`/`canGroup`/`hasFiles`/`isActiveTab` flags plus action closures kept in sync by `CombineView.syncMenuFlags()` / `syncMenuClosures()`. Nothing outside `CombineTab.swift` reads the flags or closures (the old `CombinerCommands` menu is gone; a comment in the source still names it).

### Keyboard handlers are tab-scoped

`TabView` keeps hidden tabs mounted, so handlers leak across tabs unless gated. Each tab's `.onKeyPress` starts with `guard appState.selectedTab == <tab>` (Combine 0, Split 2, Rotate 3, Stamp 4), and the **app-global `NSEvent` local monitors** do the same: Combine's delete monitor (`installKeyMonitor`, also gated on `isPanelOpen`, text fields and sheets), the Renamer's delete monitor in `RenameViews.swift`, and Split's delete + ⌘Z monitor in `SplitView.swift`. `CombineQuickLook.swift` installs its own monitor only while its preview panel is up.

### `ShortcutsHelpView` (⌘\`)

**The complete shortcut reference**: sections "Global (View & File menus)", "Combine PDFs", "Rename Files", "Split PDF", "Rotate Pages", "Stamp". Any new shortcut, menu-bound or in-view, should be added here.

## Shared infrastructure

**`PDFAlertHandler`** — `typealias PDFAlertHandler = (_ title: String, _ message: String, _ isError: Bool) -> Void`. PDF save/export methods take this callback and never show UI themselves. `showNSAlert(title:message:isError:)` and `confirmNSAlert(title:message:confirmTitle:)` (destructive confirm button, Escape cancels) are the view-side helpers.

**`PDFManager: ObservableObject`** — one instance each for Split and Rotate. Holds `pdfDocument`, `currentFileName` and **`sourceURL`** (the file the user loaded, set in `loadPDF(from:)`; it survives in-place `pdfDocument` rebuilds such as an A3 split or booklet reorder, so it outlives `PDFDocument.documentURL`). `saveRotatedPDF(...)` writes the Rotate tab's output; `saveSplitPDF(...)` builds `splitFilePlans` and calls `writeSplitFiles` (`Logic/SplitLogic.swift`), the same writer the CLI uses.

**`DropZoneView`** — the "Drop a PDF here / Choose PDF" empty state for Split and Rotate; takes the tab's `PDFManager` and an optional `subtitle`. Rejects non-PDF drops with an alert.

**`PDFPageView`** — a page as a fitted image on white (Split Step 1, Rotate before/after, booklet thumbnails), with an optional extra clockwise `rotation` and an optional `stamp` drawn in. Re-renders only when its page, rotation or stamp changes (`.task(id:)`), keeping the previous image up meanwhile. Deliberately not a `PDFView`: see [gotchas.md § PDFKit](gotchas.md#pdfkit-and-pdf-geometry).

**`Unchecked<T>`** — an `@unchecked Sendable` box for capturing PDFKit objects in `@Sendable` closures. Its explicit empty `deinit` works around a Release-mode compiler crash; leave it.

**`Binding.deferredCommit()`** — the same binding, committing on the next runloop turn. Use it on a segmented `Picker` bound to an `@Published` property, which otherwise logs "Publishing changes from within view updates".

**`RotationMode`** (`.odd`/`.even`/`.none`) and **`RotationAngle`** (0/90/180/270, `.degrees`) — the Rotate tab's enums.

### File helpers — `Logic/FileUtilities.swift`

- **`outputDirectory(forSourceFile:) -> URL?`** — a source file's parent folder (nil-safe). Every output dialog sets `panel.directoryURL` from it so saves default to the **source file's folder** rather than the last-used location: Combine's save (first non-blank input), Rotate's save and both Split output-folder pickers (`pdfManager.sourceURL`). The preset CSV export is intentionally excluded (no per-document source).
- **`expandToFiles(_ urls:extensions:) -> [URL]`** — flattens a mixed file/folder drop into name-sorted files with the given (lowercase, dotless) extensions; folders are enumerated **recursively**. Shared by `CombineView.expandToSupportedFiles` and the Stamp tab (both PDFs + images, via `pageableFileExtensions`), so folder drops behave identically. Pair it with `collectDroppedFileURLs(from:completion:)` and `urlIsDirectory(_:)` in `Logic/RenameLogic.swift` for a full drop handler.
- **`pdfFilenameError(for:) -> String?`** — an error string if the input contains `/`, `:`, `\` or a null.
- **Read-only-location guards**, for cloud-sync (Dropbox/Google Drive/iCloud), locked and read-only-volume folders that are *readable but not writable*:
  - `nonWritableParentDirectories(of:) -> [URL]` — distinct parent folders failing `FileManager.isWritableFile`. A pre-flight gate before any move.
  - `isFilePermissionError(_:) -> Bool` — true for `NSFileWriteNoPermissionError`/`NSFileReadNoPermissionError` and POSIX `EACCES`/`EPERM`/`EROFS`, including a POSIX error nested under `NSUnderlyingErrorKey`.
  - `readOnlyLocationMessage(folderName:) -> String` — the standard actionable message ("copy to Documents/Desktop, or fix Get Info → Locked / Sharing & Permissions"); "this location" when the name is nil.

  Callers: `performRenames` (`Logic/RenameLogic.swift`, which backs `RenamerManager.executeRename` and the CLI's `rename`), `BulkRenameView.executeRename` and `applyPrefixAndRenameBulk` (`Rename/RenameViews.swift`), and `savePDFDocument` (`Logic/PDFSaving.swift`). Each pre-flights and aborts with the friendly message; if moves still fail and *all* failures were permission errors, it shows the friendly message instead of the raw "Partial Success" list.

### Other shared logic files

| File | What it gives every tab |
|------|-------------------------|
| `Logic/PDFSaving.swift` | `savePDFDocument(_:to:)` (a save that reports the real reason on failure) and `unreadableFilesMessage` |
| `Logic/OutlineLogic.swift` | `outlineReadyDocument(from:)` — attach outlines to its result so they survive saving ([gotcha](gotchas.md#pdfkit-and-pdf-geometry)) |
| `Logic/ImagePages.swift` | images → A4 PDF pages, and the supported-extension sets (Combine and Stamp) |
| `Logic/InstrumentNames.swift` | instrument-name matching used by Combine presets, Rename and Split — see [rename.md](rename.md) and [split.md](split.md) |
| `Logic/PartFolders.swift` | "Sort into folders" — see [rename.md](rename.md) |
| `Logic/StampLogic.swift` | stamping, used by Combine, Split and Stamp — see [stamp.md](stamp.md) |
