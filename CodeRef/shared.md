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
        ├── "Combiner"       (tag "combiner") — CombinerPreferencesView   → combine.md (+ PaperSizeSettingRow, see Paper size)
        ├── "Renamer"        (tag "renamer")  — PreferencesView           → rename.md
        └── "AI Assistants"  (tag "ai")       — AIAssistantsPreferencesView (CLI/AIAssistantsPreferences.swift) → cli-mcp.md
```

- The minimum width was raised from 900 to 1020 for the Stamp tab (its fixed-width designer column plus preview don't fit narrower).
- **There is no About window scene.** `CommandGroup(replacing: .appInfo)` calls `NSApp.orderFrontStandardAboutPanel(options: [.credits: aboutPanelCredits()])`. A titled `Window` scene was removed because it added an unwanted entry to the Window menu. `aboutPanelCredits()` builds the credits from the executable's modification date plus authorship, the GPL-3.0 line with the source URL, and then the full text of `ScoreSort/Acknowledgements.txt` (a bundle resource: Sparkle's MIT licence and its bundled BSD/zlib notices, which must ship with the binary — Sparkle's framework doesn't carry them). Update that file if a dependency is added. The repo's `LICENSE` is GPL-3.0; `SECURITY.md` covers private reporting.
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

## Files opened from outside: Open With and the Dock icon (#21)

`Info.plist` declares PDFs (`com.adobe.pdf`), images (`public.image`) and folders (`public.folder`) as documents, all **`LSHandlerRank` Alternate**, so ScoreSort is offered under Open With but never becomes anyone's default PDF app.

- **Arrival.** `AppDelegate.application(_:open:)` puts the URLs in `ExternalOpenQueue.shared`, because the window may not exist yet: opening a file is often what launches the app. `ContentView` takes them in `.onReceive(ExternalOpenQueue.shared.$pending)` and calls `AppState.handleOpenedFiles`.
- **One window.** `ContentView` has `.handlesExternalEvents(preferring: ["*"], allowing: ["*"])`, so SwiftUI hands the event to the existing window instead of opening a new one each time. **Don't use `.handlesExternalEvents(matching: [])` on the `WindowGroup`**: it stops the extra windows, but then a cold launch from a file opens *no* window. Tested in the built app: cold (with `-ApplePersistenceIgnoreState YES`, so window restoration can't hide the result) and warm, single files, several files and a folder, one window each time.
- **Which tab: `routeOpenedFiles`** (`Logic/OpenRouting.swift`, pure; `OpenRoutingTests`). The tab on screen takes the files if it can without losing work: Combine and Stamp add to their lists; Split and Rotate only when empty; Rename only when idle (`currentTabHasContent` is `tabCommands.slice.clear != nil`, since the active tab's Clear is enabled exactly when it has something loaded). Otherwise several files or a folder go to Combine, and a single PDF or image gets an **Open in…** chooser (`OpenChoiceView`, `AppState.openChoice`). Anything else is left out; nothing usable gives an alert.
- **Hand-over.** `AppState.deliver(_:to:)` switches tab and sets `pendingOpen`; each tab's `takePendingOpen()` (on appear, and on `pendingOpen` changing) takes the files once (`AppState.takePendingOpen(for:)`) and loads them through its own loader: Combine `addFiles`, Rename `startInput`, Split and Rotate `pdfManager.loadPDF`, Stamp `addInput`.

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

**`PDFPageView`** — a page as a fitted image on white (Split Step 1, Rotate before/after, booklet thumbnails), with an optional extra clockwise `rotation` and an optional `stamp` drawn in. Re-renders only when its page, rotation or stamp changes (`.task(id:)`), keeping the previous image up meanwhile. **It draws off the main thread** (#34): `renderPagePreview` (Core Graphics via `renderScan`, so the crop box is shown; stamp via `drawStamp`; extra turn via `rotatedImage`) runs in a detached task, and a result that arrives after the page has changed again is dropped, so arrow-key paging through a big scan never waits on a page. A page built in memory (no `pageRef`) still draws through PDFKit's `thumbnail` on the main actor. Deliberately not a `PDFView`: see [gotchas.md § PDFKit](gotchas.md#pdfkit-and-pdf-geometry).

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
| `Logic/ImagePages.swift` | images → PDF pages of the default paper (`makePage(from:paper:)`, `pdfPages(fromImageAt:paper:)`, `pdfDocument(forFileAt:paper:)`; `makeA4Page` is the A4 case), and the supported-extension sets (Combine and Stamp) |
| `Logic/PaperSize.swift` | the default paper — see [Paper size](#paper-size) below |
| `Logic/InstrumentNames.swift` | instrument-name matching used by Combine presets, Rename and Split — see [rename.md](rename.md) and [split.md](split.md) |
| `Logic/PartFolders.swift` | "Sort into folders" — see [rename.md](rename.md) |
| `Logic/StampLogic.swift` | stamping, used by Combine, Split and Stamp — see [stamp.md](stamp.md) |

## Paper size

`Logic/PaperSize.swift` (#18). ScoreSort assumed A4 and A3; North America uses Letter, with booklets on Tabloid (11 × 17 in = 1224 × 792 pt, two Letter pages side by side).

**What is really A4-specific, and what was only labelled so.** Output made from PDFs always keeps the source's page size: a booklet's double-size sheet is two of its first page side by side, a split half is half its sheet, stamping and rotating keep every page. Those needed only their *labels* changing. The default paper is used **only where there is no page to follow**: images turned into pages, Combine's blank pages (the Blank Page entry and the pad after an odd-length part), `.fitA4Landscape` booklets (fitted onto the paper turned landscape), the two-sided test sheet, and the Stamp designer's blank page with no file loaded.

| Symbol | Behaviour |
|--------|-----------|
| `PaperSize` | `.a4` (595 × 842) / `.letter` (612 × 792). `pageSize`, `pageBox`, `landscapeBox`, `name` ("A4"/"Letter"), `doubleSheetName` ("A3"/"Tabloid"), `halfName` ("A5"/"half-letter"). `nonisolated`, so the `nonisolated` stamp helpers can take it. |
| `PaperSize.matching(_:)` | A4 or Letter either way up, within 4 pt; nil otherwise. |
| `PaperSize.forRegion(_:)` / `automatic(printerPaper:region:)` | Pure: the printer's paper if it is A4 or Letter, else Letter in `letterRegions` (US, CA, MX, …), else A4. |
| `PaperSize.system` | `automatic` with `NSPrintInfo.shared.paperSize` (the default printer's paper, or macOS's default paper size) and `Locale.current.region`, cached once per launch. |
| `PaperSize.current` | The Settings choice (`PaperSizeChoice`, UserDefaults `paperSize`: automatic / a4 / letter), Automatic resolved through `system`. Read by the CLI too (same bundle). |
| `PaperSizeSettingRow` | Settings ▸ Combiner, a bar under the preset editor (`safeAreaInset`): "Automatic (A4)" / A4 / US Letter. Main file. |

**The logic takes `paper:` and defaults to `.a4`; callers pass `PaperSize.current`.** This keeps the logic pure and the tests identical on any Mac — CI runs in the US, where Automatic could be Letter, and a test must never depend on Ben's own setting. `CombineOutputOptions.paper` (default `.a4`) carries it through `buildDocument`; `CombineView.outputOptions`, the CLI's `combine` and `stamp`, and the views (`CombineOutputMenuButton`, the Stamp designer, Booklet Page Turns) pass the current paper. Views that show labels observe `@AppStorage(PaperSizeChoice.defaultsKey)` so they update when Settings changes. **Nothing changes for A4 users**: on A4 every default, label and drawing position is what it was (the test sheet's text is laid out for A4 and centred, so on A4 it lands exactly where it did).

Double-page scan detection already covered Tabloid: 1224 × 792 is inside `isA3Landscape`'s 1000–1500 pt window and `looksLikeA3Landscape`'s 1.3–1.6 ratio, while Letter landscape (792 pt wide, ratio 1.29) is in neither (`TabloidScanDetectionTests`).
