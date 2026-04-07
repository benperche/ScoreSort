# Music PDF Manager — Code Reference
> Single file: `ScanReorienterApp_complete.swift` (~3926 lines)
> Xcode project: "Music PDF Wrangler"

---

## App Structure

```
MusicPDFManagerApp (@main)
  └── AppDelegate  — quits on window close
  └── ContentView  — TabView (tags 0–3)
        ├── 0: CombineView
        ├── 1: RenamerView
        ├── 2: SplitView
        └── 3: RotateView
  └── Window("about")  — AboutView (custom About panel, version 0.2)
```

Window min size: 900×700.

### Menu Bar Commands

| Struct | Menu | Purpose |
|--------|------|---------|
| `NavigateCommands` | Navigate | Tab switching (⌘1–⌘4) |
| `CombinerCommands` | Combiner | File list shortcuts (arrow keys, ⌘↑/↓, ⌫, ⌘A) |
| `HelpCommands` | Help | Opens `ShortcutsHelpView` sheet |

`CommandGroup(replacing: .appInfo)` replaces the system About panel with a button that calls `openWindow(id: "about")`, opening `AboutView` as a separate `Window` scene.

**`CombineCommands`** (plain struct, not `Commands`) — passed via `FocusedValues` (key: `CombineCommandsKey`) using `.focusedSceneValue(\.combineCommands, …)` on `CombineView`. `CombinerCommands` reads it with `@FocusedSceneValue`. All `can*` flags are gated on `appState.selectedTab == 0` so shortcuts are inert on other tabs.

**`AppState`** gains `showingKeyboardHelp: Bool` — toggled by `HelpCommands` and the ⌨ toolbar button in `CombineView`. `ContentView` presents `ShortcutsHelpView` as `.sheet(isPresented:)` off this flag.

**`ShortcutsHelpView`** — modal sheet listing all shortcuts grouped into Navigation, File Management, Tabs, and Renamer sections.

---

## Tab 0 — Combine PDFs

**View:** `CombineView`
**ViewModel:** `CombineManager: ObservableObject`
**Model:** `CombineFile: Identifiable` (id, url, name, pageCount, copies: Int)
**Row:** `CombineFileRow` (gains `isFocused: Bool` for stronger highlight on keyboard cursor row)

### CombineManager key methods
| Method | Purpose |
|--------|---------|
| `addFiles(urls:undoManager:)` | Reads PDFs via PDFKit, appends CombineFile |
| `removeFiles(ids:undoManager:)` | Removes by UUID set |
| `updateCopies(for:copies:undoManager:)` | Clamps to min 1 |
| `moveUp/Down(ids:undoManager:)` | Multi-select block move via `swapAt` |
| `clearAll(undoManager:)` | Removes all files |
| `createCombinedPDF(to:addBlankPages:completion:)` | Writes to URL, calls `completion` with result |
| `openInPreview(addBlankPages:onError:)` | Writes temp file → NSWorkspace.open; calls `onError` on failure only |

All mutating methods take an `undoManager: UndoManager?` and use snapshot-based undo (captures pre-action state; registers undo handler that also registers redo).

`createCombinedPDF` and `openInPreview` take a `PDFAlertHandler` callback — they never show UI directly. The caller (the view) is responsible for presenting any alert. See `PDFAlertHandler` in Shared Infrastructure.

**Computed:** `totalFiles` = sum of copies; `totalPages` = sum of pageCount×copies.

**Blank page logic:** If `addBlankPages` and file has odd pageCount, insert a blank PDFPage after its last copy's pages.

### CombineView keyboard navigation state
| Property | Type | Purpose |
|----------|------|---------|
| `selectedFiles` | `Set<UUID>` | Currently selected (checked) files |
| `focusedFileId` | `UUID?` | Keyboard cursor (highlighted row) |
| `anchorFileId` | `UUID?` | Shift-range selection anchor |
| `listFocused` | `Bool` (@FocusState) | Whether ScrollView has key focus |
| `removalNoticeVisible` | `Bool` | Undo banner visibility |
| `removalNoticeCount` | `Int` | File count for banner text (singular/plural) |

**`navigateSelection(direction:extending:)`** — moves `focusedFileId` by ±1; if `extending` is true, expands `selectedFiles` between `anchorFileId` and new cursor; otherwise replaces selection with just the new item and resets anchor.

**Keyboard shortcuts (in-view):** The `ScrollView` carries `.focusable()` + `.focused($listFocused)` + `.onKeyPress` for ↑/↓ (plain and ⇧). Cmd+↑/↓ and ⌫ are handled exclusively via `CombinerCommands` menu shortcuts (which take priority over `onKeyPress`). `listFocused` is set to `true` on any row tap so navigation is immediately available after a click.

**Removal notice:** shown by `showRemovalNotice(count:undoManager:)` — called from both the per-row minus button (count=1) and `removeSelected()` (count = selection size). Auto-dismisses after 5 s; Undo button dismisses immediately and invokes `undoManager.undo()`.

---

## Tab 1 — Sheet Music Renamer

**View:** `RenamerView`  
**ViewModel:** `RenamerManager: ObservableObject`  
**Model:** `RenameOperation: Identifiable`  
**Sheets:** `ManualAssignmentView` (uses `.sheet(item:)`), `PreferencesView` (⌘,)  
**Row:** `FileRowView` — double-click triggers manual override sheet

### RenamerManager state
```swift
folderURL: URL?
operations: [RenameOperation]
ensembleType: EnsembleType   // .band | .jazz | .orchestra
customInstrumentOrder: [String]
manualOverrides: [String: Int]   // filename → assigned number
isRescanMode: Bool
hasCustomOrder: Bool
```

### Key flow: `scanFolder()`
1. Enumerate flat PDFs in folder, sort alphabetically.
2. For each file:
   - In rescan mode: strip `^\d{2}[-_\s]` prefix before detection.
   - In normal mode: if already prefixed → `.alreadyPrefixed`, skip.
   - If in `manualOverrides` → add to `manuallyAssigned` list.
   - Run `detectInstrument()` → if "score" → `scoreFiles`; else → `detectedFiles`; else → `undetectedFiles`.
3. `detectedFiles.sort { $0.order < $1.order }` (instrument order index).
4. Assign prefixes: score = `00`, instruments = `01`, `02`, …
5. For each group, create `RenameOperation` with type `.rename`, `.correct`, `.skip`, `.manual`, or `.undetected`.
6. Sort `operations` by `newName` (empty names last).

### `detectInstrument(in filename:) -> (Int, String)?`
- Sorts `customInstrumentOrder` by **length descending** (so "bass clarinet" beats "clarinet").
- Finds all matches and their **character position** in filename.
- Returns the **leftmost** match (handles "Baritone BC Bassoon" → baritone, not bassoon).

### `setManualOverride(for:number:)`
- If number conflicts with existing override, shifts all overrides ≥ number up by 1.
- Then assigns number, triggers `scanFolder()`.

### `executeRename()`
- Filters operations where type ∈ {`.rename`, `.correct`, `.manual`}.
- `FileManager.moveItem(at:to:)` for each.
- Shows partial-success alert if any fail.
- Re-runs `scanFolder()` after.

### RenameOperationType & colours
| Type | Colour | Meaning |
|------|--------|---------|
| `.rename` | green | Will be renamed |
| `.correct` | orange | Wrong prefix, will be corrected (rescan mode) |
| `.manual` | blue | Manual override |
| `.skip` | secondary | Already correct / target exists |
| `.alreadyPrefixed` | secondary | Has `\d{2}` prefix in normal mode |
| `.undetected` | secondary | No instrument found |

### Instrument orders (`InstrumentOrders`)
Three computed vars: `band`, `jazz`, `orchestra`. Loaded via `getOrder(for: EnsembleType)`.
`customInstrumentOrder` starts from the active preset; `hasCustomOrder` flag prevents preset changes from overwriting user edits.

**External file:** `~/Library/Application Support/Music PDF Manager/instrument-orders.json`
Written from built-in defaults on first launch (via `InstrumentOrders.setup()` called in `AppDelegate.applicationDidFinishLaunching`). App loads from the file at startup; changes take effect on next launch. If the file is missing or unreadable the private `bandDefault`/`jazzDefault`/`orchestraDefault` arrays are used as fallback. File is pretty-printed JSON: `{ "band": [...], "jazz": [...], "orchestra": [...] }`.

**Band order highlights:** score → piccolo → flute → oboe → cor anglais/english horn → bassoon → contrabassoon → Eb clarinet → clarinet → alto clarinet → bass clarinet → contrabass clarinet → sopranos sax → alto sax → tenor sax → bari sax → bass sax → cornet → trumpet → horn → trombone → bass trombone → euphonium/baritone → tuba → guitar/keyboard/piano/harp → string bass/bass → timpani → mallets → bells/chimes/glockenspiel/xylophone/vibraphone/marimba → drums → percussion → violin → viola → cello → double bass

**Jazz order highlights:** score → vocals → solos → alto/tenor/bari sax → trumpet/cornet/flugelhorn → trombone → guitar → piano/keyboard → bass → drums → aux percussion → mallets/vibes → flute → clarinet → horn/eupho/tuba

**Orchestra:** score → piccolo → flute → oboe → cor anglais → clarinet → Eb clarinet → alto clarinet → bass clarinet → contrabass clarinet → bassoon → contrabassoon → saxes → horn → trumpet → cornet → trombone → bass trombone → eupho/baritone → tuba → timpani → mallets → percussion → drums → guitar/keyboard/piano/harp → violin → viola → cello → double bass → string bass/bass

### RenamerView UI
- Sort columns: `.originalName`, `.newName`, `.status` (toggles asc/desc).
- `sortedOperations` computed from `renamerManager.operations`.
- Toolbar: Choose Folder | Change Folder | Preferences (⌘,) | Rescan for Errors.
- Bottom: status text + "Rename Files" button (disabled if `renameCount == 0`).

---

## Tab 2 — Split PDF

**Views:** `SplitView` (Step 1) → `SplitNamingStageView` (Step 2) → `SplitFileNamingRow` (one row per output file)
**Supporting:** `SuggestionButton`, `PageInstrumentPreview`, `SplitControlsSection`
**ViewModel:** `PDFManager` (shared type, separate `@StateObject` per tab)

### Data model — `fileSizes: [Int]`

The split state is stored as an **ordered array of page counts**, one entry per output file. For example `[2, 2, 1, 3]` means four files containing 2, 2, 1, and 3 pages respectively.

This replaces the old `splitMarkers: Set<Int>` approach. Benefits:
- Adding a split at position P inside file i partitions that entry: `fileSizes[i]` splits into two entries.
- Removing a split (clicking the first page of file i) merges `fileSizes[i-1]` and `fileSizes[i]`.
- All subsequent file indices adjust automatically — no stale markers possible.

`splitMarkers: Set<Int>` is now a **derived computed property** (for rendering the page strip) — the set of page indices that start a new file (excluding page 0).

`pageToFileMapping: [Int: Int]` maps each page index to its output file index.

### SplitView key state

```swift
@State private var fileSizes: [Int] = []        // primary split model
@State private var stride: Int = 2               // for auto-split
@State private var showingNamingStage: Bool = false
@State private var baseFileName: String = ""
@State private var customFileNames: [Int: String] = [:]  // fileIndex → suffix
```

`body` switches between `splitStageBody` (Step 1) and `SplitNamingStageView` (Step 2) based on `showingNamingStage`.

### Pure split functions (top-level, above `SplitView`)

| Function | Purpose |
|----------|---------|
| `toggleSplit(in sizes: [Int], at page: Int) -> [Int]` | Returns new sizes array with split toggled at `page`. Splits mid-file or merges at a boundary. |
| `splitSizes(totalPages: Int, stride: Int) -> [Int]` | Returns sizes array dividing `totalPages` into `stride`-sized chunks (last chunk takes remainder). |

These are pure functions with no side effects — extracted from `SplitView` for testability. The private view methods `toggleSplitAt(page:)` and `applyStride()` are now one-line wrappers that call these and assign the result to `fileSizes`.

### Step 1 UI

Two-column layout:
- **Left:** page strip + large current-page preview
- **Right:** stride/auto-split controls, output file cards, base filename field, "Name Files →" button

Keyboard shortcuts (focus must be on preview area):
- `Space` — toggle split on current page
- `←` / `→` — previous / next page
- `⌘←` / `⌘→` — jump to first / last page

### Step 2 — `SplitNamingStageView`

Full-window scrollable list of `SplitFileNamingRow` views, one per output file.

Key properties:
```swift
let pdfDocument: PDFDocument
let fileSizes: [Int]
@Binding var baseFileName: String
@Binding var customFileNames: [Int: String]
let onBack: () -> Void
let onSave: () -> Void
@FocusState private var focusedField: Int?   // drives auto-scroll
```

- **`instrumentNames: [String]`** — ordered, deduplicated union of orchestra + band + jazz lists from `InstrumentOrders`, each entry `.capitalized`. Used as autocomplete source across all rows.
- **`filenameError(for:)`** — returns an error string if text contains `/`, `:`, or `\`.
- **`canSave`** — requires `numberOfFiles >= 2`, no base name error, no suffix error.
- Auto-scrolls to the focused row via `.onChange(of: focusedField)` + `ScrollViewReader.scrollTo(_:anchor:.center)`.

Bottom bar: "← Back" button + "Split and Save" button (disabled when `!canSave`).

### `SplitFileNamingRow`

One row per output file. Key properties:

```swift
let fileIndex: Int
let fileSizes: [Int]
let firstPageIndex: Int
let pdfDocument: PDFDocument
let baseFileName: String
@Binding var suffix: String
var fieldFocus: FocusState<Int?>.Binding   // passed from parent — no local copy
let instrumentNames: [String]
let allSuffixes: [Int: String]             // snapshot of all rows' current suffixes
@State private var selectedSuggestionIndex: Int? = nil
```

**Important:** `fieldFocus` is a `FocusState<Int?>.Binding` passed directly from the parent, not a local `@FocusState`. This ensures Tab navigation and click both update the parent's scroll logic. A local `@FocusState` copy caused a macOS bug where the initial click on the TextField was silently swallowed.

**`PageInstrumentPreview`** — renders a cropped 2× Retina image of the top-left corner of the page (100 pt tall, left 40% up to 200 pt wide) where instrument names typically appear. Uses `.allowsHitTesting(false)` to prevent the fill-mode image's hit-test area from blocking the TextField below.

#### Autocomplete

**`nextExpectedIndex: Int`** — scans rows above (nearest first) to find the last recognised instrument name, then returns `index + 1` in `instrumentNames`. This rotates the suggestion list so the most likely next instrument appears first.

**`numberedSuggestion: String?`** — checks if the nearest previous non-empty suffix ends with a space and a positive integer (e.g. "Flute 1"). If so, returns the incremented version ("Flute 2") to inject as the top suggestion.

**`suggestions: [String]`** — builds a rotated list from `nextExpectedIndex`, filters to prefix-matches then contains-matches when text is non-empty, then prepends `numberedSuggestion` if applicable. Always ≤ 8 entries.

#### Keyboard interaction on TextField

| Key | Behaviour |
|-----|-----------|
| `↓` | Move `selectedSuggestionIndex` down (starts at 0 if nil) |
| `↑` | Move up; set nil when above index 0 |
| `Return` | If index set: accept suggestion, clear index. Else: advance `fieldFocus` to next row |
| `Escape` | Clear `selectedSuggestionIndex` |
| Any typing | Reset `selectedSuggestionIndex` to nil |

#### `SuggestionButton`

```swift
private struct SuggestionButton: View {
    let label: String
    var isSelected: Bool = false   // arrow-key highlight
    let action: () -> Void
    @State private var isHovered = false
    // background: selected → opacity 0.20, hover → 0.10, default → clear
}
```

### `PageInstrumentPreview`

Renders via `renderInstrumentNameArea(from:)`:
- Crop rect: top of page (`y = origin.y + height - cropHeight`), left 40% (max 200 pt), 100 pt tall
- Rendered at 2× scale into an `NSImage` via `NSGraphicsContext` / `PDFPage.draw(with:to:)`
- Handles 90°/270° rotated pages by swapping width/height before cropping

---

## Tab 3 — Rotate Pages

**View:** `RotateView`
**ViewModel:** `PDFManager`

Controls: `baseRotation: RotationAngle` (all pages) + `additionalRotationMode: RotationMode` (odd/even/none) + `additionalRotationAngle`.

Preview: `PDFPageView: NSViewRepresentable` wrapping `PDFView`. Renders page to `NSImage` first (via `renderFullImage`) to avoid mutating shared page state, then sets `clonedPage.rotation`.

Save: `PDFManager.saveRotatedPDF(to:baseRotation:additionalRotationMode:additionalRotationAngle:)` — iterates pages, mutates `page.rotation` on copy, writes new document.

Keyboard navigation: `←` / `→` (previous/next page); `⌘←` / `⌘→` (first/last page). Shared with the Split tab's Step 1 preview.

### Supporting enums
```swift
enum RotationAngle: Int { case none=0, rotate90=90, rotate180=180, rotate270=270 }
enum RotationMode { case odd, even, none }
```

---

## Shared Infrastructure

**`PDFAlertHandler`** — `typealias PDFAlertHandler = (_ title: String, _ message: String, _ isError: Bool) -> Void`. Passed to all PDF save/export methods so managers never show UI directly. `showNSAlert(title:message:isError:)` is a private free function used at view call sites to avoid repeating the NSAlert boilerplate.

**`PDFManager: ObservableObject`** — used by both SplitView and RotateView (separate instances).
- `loadPDF(from:)`, `clearPDF()`
- `saveRotatedPDF(to:baseRotation:additionalRotationMode:additionalRotationAngle:completion:)` — copies each page before rotating (source document is never mutated); calls `completion` on finish
- `saveSplitPDF(to:splitMarkers:baseFileName:customFileNames:pageToFileMapping:completion:)` — calls `completion` with success or partial-success result

**`pdfFilenameError(for:) -> String?`** — top-level free function; returns an error string if the input contains `/`, `:`, `\`, or a null character. Used by both `SplitNamingStageView` and `SplitFileNamingRow`.

**`PDFPageView: NSViewRepresentable`** — safe preview clone via `renderFullImage(from:) -> NSImage?` using `NSGraphicsContext` / `CGContext`.

---

## Known Patterns & Gotchas

- **`.sheet(item:)` not `.sheet(isPresented:)`** — used for ManualAssignmentView to avoid blank sheet bug.
- **Instrument detection is leftmost-match**, not longest-match or order-match, to handle compound names.
- **`bass clarinet` before `clarinet`** in lists — length-sort in detectInstrument handles this, but the order in the static arrays also matters as a tie-break (same position → lower original index wins).
- **`canCreateDirectories = true`** set on NSOpenPanel for folder selection.
- **Print automation not possible** — NSPrintOperation / AppleScript all fail reliably; "Open in Preview" + ⌘P is the documented workflow.
- **App quits on window close** via `NSApplicationDelegateAdaptor(AppDelegate.self)` returning `true` from `applicationShouldTerminateAfterLastWindowClosed`.
- **`.clipped()` does not restrict hit testing** — in SwiftUI, `.clipped()` clips rendering but the view's hit-test area remains its full layout frame. Use `.allowsHitTesting(false)` when an image with `.fill` content mode would otherwise absorb clicks meant for views below it. (Affected `PageInstrumentPreview` inside `SplitFileNamingRow`.)
- **`FocusState` must not be duplicated across parent/child boundaries** — passing `FocusState<T>.Binding` from parent to child and using `.focused(binding, equals:)` in the child is the correct pattern. Adding a local `@FocusState` in the child creates a second responder that intercepts the first click on a TextField on macOS (the click is consumed to transfer focus to the local state rather than starting editing).
- **`fileSizes` array vs `splitMarkers` set** — the array model is the source of truth; `splitMarkers` is only derived for rendering. This prevents the stale-marker problem that arose when pages were removed or re-ordered.
- **Instrument orders versioning** — `instrument-orders.json` in Application Support contains a `"version"` sentinel. On launch, `InstrumentOrders.setup()` compares the file's version to the built-in default; if the file is older it is regenerated, so new aliases/entries in the code automatically propagate to existing installs.

---

## Test Suite

**Target:** `MusicPDFManagerTests` (Swift Testing framework — `@Suite` / `@Test` / `#expect`)
**File:** `Music PDF ManagerTests/Music_PDF_ManagerTests.swift`
**Import:** `@testable import Music_PDF_Manager`

**Shared helper:** `writePDF(pages: Int, to: URL)` — creates a real blank-page PDF using PDFKit; used wherever a test needs `PDFDocument(url:)` to succeed with a non-zero page count.

| Suite | What it covers |
|-------|----------------|
| `FilenameValidationTests` | `pdfFilenameError(for:)` — valid names, illegal chars (`/` `:` `\` null) |
| `InstrumentDetectionTests` | `detectInstrument(in:)` — case insensitivity, leftmost match, length-sort, nil on no match, order index |
| `ManualOverrideTests` | `setManualOverride(for:number:)` — assign, replace, conflict shift, chain shift |
| `ScanFolderTests` | `loadFolder(url:)` pipeline — score prefix, sequential prefixes, undetected, manual override, already-prefixed skip |
| `ToggleSplitTests` | `toggleSplit(in:at:)` — mid-file split, boundary merge, edge cases (page 0, first page, empty array) |
| `SplitSizesTests` | `splitSizes(totalPages:stride:)` — even division, remainder, stride > total, zero pages |
| `CombineManagerTests` | Computed properties, `addFiles`, `removeFiles`, `clearAll`, `updateCopies`, `moveUp/Down` block behaviour, `createCombinedPDF` (page count, blank insertion, copies) |
| `PDFManagerTests` | `saveRotatedPDF` (rotation values, source-not-mutated regression guard, odd/even additional rotation); `saveSplitPDF` (file count, page counts, custom filenames, auto-numbering) |

**Not covered:** rescan mode stripping (planned but deferred); `performRename()` filesystem operation; UI/integration tests.
