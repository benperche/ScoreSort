# ScoreSort — Code Reference
> Single file: `ScanReorienterApp_complete.swift` (~8 500 lines)
> Xcode project: "ScoreSort"

---

## App Structure

```
ScoreSortApp (@main)
  └── AppDelegate  — quits on window close
  └── WindowGroup  — ContentView
        └── ContentView  — TabView (tags 0–3)
              ├── 0: CombineView
              ├── 1: RenamerView
              ├── 2: SplitView
              └── 3: RotateView
  └── Settings  — AppPreferencesView (⌘,)
        ├── Tab "Combine Presets"  — CombinerPreferencesView
        └── Tab "Renamer"          — RenamerPreferencesView (placeholder)
  └── Window("about")  — AboutView (custom About panel)
```

Window min size: 900×700.

**App-level shared state** (held as `@StateObject` on `ScoreSortApp`, injected via `.environmentObject()`):
- `AppState` — `selectedTab`, `showingKeyboardHelp`, `combineMenuState`
- `RenamerManager` — used by both `RenamerView` and `AppPreferencesView`
- `EnsemblePresetStore` — used by `CombineView`, `PresetSidebarView`, `CombinerPreferencesView`

### Menu Bar Commands

| Struct | Menu | Purpose |
|--------|------|---------|
| `NavigateCommands` | Navigate | Tab switching (⌘1–⌘4) |
| `CombinerCommands` | Combiner | File list shortcuts (arrow keys, ⌘↑/↓, ⌫, ⌘A, C) |
| `HelpCommands` | Help | Opens `ShortcutsHelpView` sheet |

`CommandGroup(replacing: .appInfo)` replaces the system About panel with a button that calls `openWindow(id: "about")`, opening `AboutView` as a separate `Window` scene.

**`CombineMenuState`** — `ObservableObject` shared between `CombineView` (writes) and `CombinerCommands` (reads). Carries `canRemove`, `canMoveUp`, `canMoveDown`, `canGroup`, `hasFiles`, `isPanelOpen` flags plus action closures (`removeSelected`, `moveUp`, `moveDown`, `group`, `selectAll`, navigation closures). `CombineView.syncMenuFlags()` + `syncMenuClosures()` keep it in sync via `.onAppear` and `.onChange`.

**`ShortcutsHelpView`** — modal sheet listing all shortcuts grouped by Combine navigation, Combine file management, Combine collate groups, Combine presets, Tabs, Split/Rotate, and Renamer.

---

## Tab 0 — Combine PDFs

**View:** `CombineView`  
**ViewModel:** `CombineManager: ObservableObject`  
**Models:** `CombineFile`, `CollateGroup`  
**Rows:** `CombineFileRow`, `CollateGroupHeaderRow`  
**Sidebar:** `PresetSidebarView` (toggled by the Presets toolbar button)

### Data models

```swift
struct CombineFile: Identifiable, Equatable {
    let id: UUID          // auto-generated
    let url: URL
    let name: String      // url.lastPathComponent (includes extension)
    let pageCount: Int
    var copies: Int       // ignored when collateGroupId is set
    var collateGroupId: UUID?   // non-nil → file belongs to a collate group
    var isBlankPage: Bool = false  // synthetic blank A4 entry; url is unused
}

/// A named set of files whose pages are interleaved when combining.
/// e.g. 4 copies of [Perc 1, Perc 2, Timpani] →
///      P1,P2,T, P1,P2,T, P1,P2,T, P1,P2,T
struct CollateGroup: Identifiable, Equatable {
    let id: UUID
    var copies: Int
}
```

### CombineManager

```swift
@Published var files: [CombineFile] = []
@Published var collateGroups: [UUID: CollateGroup] = [:]
```

**Undo:** `registerUndo(undoManager:actionName:restoringFiles:restoringGroups:)` snapshots **both** arrays together so undo/redo always restores a consistent state. All mutating methods capture `let bf = files; let bg = collateGroups` before mutation.

#### File management methods
| Method | Notes |
|--------|-------|
| `addFiles(urls:undoManager:)` | Accepts PDFs and images (JPEG, PNG, TIFF, HEIC, BMP, GIF). PDFs use `PDFDocument.pageCount`; images use `CGImageSourceGetCount` for frame count. Appends `CombineFile` with `copies=1`, no group. |
| `addBlankPage(after:undoManager:)` | Inserts a synthetic blank A4 `CombineFile` (`isBlankPage=true`) after the last selected file, or at the end if nothing is selected. |
| `removeFiles(ids:undoManager:)` | Removes files; auto-dissolves any group that drops below 2 members |
| `updateCopies(for:copies:undoManager:)` | Clamps to min 1; applies to standalone file only |
| `clearAll(undoManager:)` | Clears both `files` and `collateGroups` |

#### Reordering
`moveUp/Down(ids:undoManager:)` — same `swapAt` block-move logic as before, but `CombineView` always expands the passed set via `expandForGroups()` first so collate groups move as an indivisible unit.

#### Collate group methods
| Method | Notes |
|--------|-------|
| `createCollateGroup(fileIds:undoManager:)` | Pulls selected files together contiguously at the position of the first selected file, assigns them a shared `UUID`, stores a new `CollateGroup(copies:1)` |
| `dissolveGroup(id:undoManager:)` | Clears `collateGroupId` on all member files; removes group from dictionary |
| `updateGroupCopies(id:copies:undoManager:)` | Clamps to min 1; applies to the group's copy count |

#### Computed properties
`totalFiles` and `totalPages` iterate `files` in a single pass, detecting group boundaries by watching for `collateGroupId` changes:
- **Standalone file:** contributes `file.copies` / `file.pageCount × file.copies`
- **Group:** contributes `memberCount × group.copies` / `sumOfMemberPages × group.copies`

#### PDF output
`createCombinedPDF(to:addBlankPages:completion:)` and `openInPreview(addBlankPages:onError:)` both use a nested `addPages(from:copyIndex:totalCopies:)` helper and a single `while i < files.count` loop that detects groups:
- **Standalone:** `for ci in 0..<file.copies { addPages(from: file, copyIndex: ci, totalCopies: file.copies) }`
- **Group:** collect all consecutive files with the same `collateGroupId`, then `for ci in 0..<group.copies { for f in groupFiles { addPages(from: f, copyIndex: ci, totalCopies: group.copies) } }`

Inside `addPages(from:copyIndex:totalCopies:)`:
- **Blank page entries** (`isBlankPage == true`): insert one A4 `PDFPage` via `createBlankPage()` and return.
- **Image files** (extension ≠ `"pdf"`): call `pdfPages(fromImageAt:)` which uses `CGImageSource` to iterate frames, renders each onto an A4 canvas via `makeA4Page(from:)` (scaled to fit, white background, aspect ratio preserved), and returns the array of `PDFPage`s.
- **PDF files**: load `PDFDocument(url:)`, copy pages. If `addBlankPages` and page count is odd, append a blank page.

A `bookmarks` array of `(label: String, pageIndex: Int)` is accumulated during the loop. The label is the filename (without extension) for single-copy files, or `"Filename N/Total"` for multi-copy. Blank pages are not bookmarked. After all pages are inserted, a `PDFOutline` tree is built from the bookmarks array and assigned to `doc.outlineRoot`, producing a table of contents visible in Preview's sidebar.

### CombineView

#### Key state
| Property | Type | Purpose |
|----------|------|---------|
| `selectedFiles` | `Set<UUID>` | Currently selected file IDs |
| `focusedFileId` | `UUID?` | Keyboard cursor row |
| `anchorFileId` | `UUID?` | Shift-range selection anchor |
| `listFocused` | `Bool` (@FocusState) | Whether ScrollView has key focus |
| `showPresetSidebar` | `Bool` | Controls sidebar slide-in |
| `unmatchedFileIds` | `Set<UUID>` | Files not matched by last preset apply (orange tint) |

#### Collate group helpers
**`expandForGroups(_ ids: Set<UUID>) -> Set<UUID>`** — for each ID that belongs to a group, adds all group-mates to the set. Used by `moveUp()`, `moveDown()`, `canMoveUp`, `canMoveDown` so groups always move as a block.

**`canGroup: Bool`** — `selectedFiles.count >= 2` and no selected file already has a `collateGroupId`.

**`groupSelected()`** — calls `combineManager.createCollateGroup(fileIds:selectedFiles)`, then clears selection/focus.

#### List rendering
The `ForEach(combineManager.files)` body uses a `@ViewBuilder` to optionally emit a `CollateGroupHeaderRow` + `Divider` before each file that is the **first** member of its group, then a `CombineFileRow` (with `isGrouped: file.collateGroupId != nil`).

"First member" is detected by: `combineManager.files.first(where: { $0.collateGroupId == gid })?.id == file.id`.

#### Navigation
**`navigateSelection(direction:extending:)`** — navigates the flat `combineManager.files` array (group headers are virtual and not part of navigation). Selecting a grouped file and pressing ⌘↑/↓ triggers `moveUp/Down` via `expandForGroups`, moving the whole group.

**Keyboard shortcuts (in-view `.onKeyPress`):** ↑/↓ (navigate), ⇧↑/⇧↓ (extend), ⌘A (select all), `c` (group — only `.handled` if `canGroup`). ⌘↑/↓ and ⌫ come from `CombinerCommands`.

#### Removal notice
`showRemovalNotice(count:undoManager:)` — auto-dismisses after 5 s; Undo button invokes `undoManager.undo()`.

### CombineFileRow

```swift
struct CombineFileRow: View {
    let file: CombineFile
    let isSelected: Bool
    let isFocused: Bool
    let isUnmatched: Bool       // orange tint when preset apply left this unmatched
    var isGrouped: Bool = false // hides copies stepper, adds 14pt leading indent
    let onToggleSelect: () -> Void
    let onCopiesChanged: (Int) -> Void
    let onRemove: () -> Void
}
```

When `isGrouped`: copies area is replaced with `Spacer().frame(width: 100)`. Minus at `copies==1` still calls `onRemove` (which will dissolve the group if it drops below 2 members).

### CollateGroupHeaderRow

Shown before the first file of each collate group. Columns mirror `CombineFileRow`:
- **Name area:** stack icon + "Collate Group (N files)" label + ↗ ungroup button
- **Pages (80pt):** sum of member file page counts (= pages for one complete set)
- **Copies (100pt):** `CollateGroup.copies` stepper with double-click-to-type inline editing

`onUngroup` calls `combineManager.dissolveGroup(id:undoManager:)`.

---

## Tab 0 — Ensemble Presets subsystem

### Data model

```swift
struct PresetPart: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var copies: Int
}

struct EnsemblePreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var parts: [PresetPart]
}
```

### EnsemblePresetStore

`ObservableObject` held at app level, injected as `@EnvironmentObject`.

```swift
@Published var presets: [EnsemblePreset] = []
```

**Persistence:** JSON at `~/Library/Application Support/ScoreSort/ensemble-presets.json`. Loaded on `init`; saved by `save()` (called from all mutating methods).

**Key methods:**
| Method | Notes |
|--------|-------|
| `addPreset(name:parts:)` | Appends a new preset with an explicit parts array |
| `updatePreset(_:)` | Replaces by ID |
| `deletePreset(id:)` | Removes by ID |
| `movePresets(from:to:)` | `IndexSet`-based reorder for drag support in `List` |

**No auto-seed.** On first launch the store is empty; `CombinerPreferencesView` and `PresetSidebarView` both show an empty-state prompt directing the user to create a preset.

**Built-in templates** (static computed vars, not stored):
- `EnsemblePresetStore.windBandTemplate` — score + wind/brass/perc/strings
- `EnsemblePresetStore.jazzTemplate` — score + saxes + brass + rhythm
- `EnsemblePresetStore.orchestraTemplate` — score + woodwinds + brass + perc + strings

### PresetSidebarView

Slide-in panel (width 260 pt) on the right of `CombineView`, toggled by the Presets toolbar button with a `.move(edge:.trailing).combined(with:.opacity)` transition.

State:
- `selectedPresetId: UUID?` — drives dropdown picker
- `editingParts: [PresetPart]` — local working copy of selected preset's parts
- `isDirty: Bool` — `editingParts != selectedPreset.parts`
- `applyResult: (matched, unmatched, unmatchedPartNames)?` — shown as colour-coded summary after apply

**Empty state:** when no presets exist, shows a "Create your first preset" button that presents `NewPresetSheet`.

**Apply button** calls `CombineView.applyPreset(parts:)` via the `onApply` closure. Result summary shows green (matched) and orange (unmatched) counts. Parts that were unmatched are highlighted with `Color.orange.opacity(0.12)` in `PresetPartRow`.

**Revert/Save:** visible when `isDirty`. Revert discards `editingParts`; Save calls `presetStore.updatePreset(_:)`.

### CombinerPreferencesView

Native `Settings` window tab (via SwiftUI `Settings` scene) — `HSplitView` with a left preset list and a right parts editor.

- **Left panel:** `List` with `ForEach` + `.onMove` for drag reorder; Up/Down chevron buttons for keyboard reorder; + and − buttons.
- **Right panel:** parts list using `PresetPartRow` with explicit `Binding(get:set:)` closures (since `editingPreset` is `@State EnsemblePreset?`). "Reset to Template…" is a `Menu` offering all three templates. "New Preset" uses `NewPresetSheet`.
- **Sync fix:** `.onChange(of: presetStore.presets)` reloads `editingPreset` when `fresh != editingPreset` to catch saves made in the sidebar — guarded to avoid a loop from self-edits.

### NewPresetSheet

Modal sheet presenting three `TemplateCard` buttons (Wind Band / Jazz Band / Orchestra) and a name text field. Calls `presetStore.addPreset(name:parts:)` with the chosen template's parts array (or empty if the user just typed a name without selecting a template).

### Preset apply logic — `CombineView.applyPreset(parts:)`

```swift
@discardableResult
private func applyPreset(parts: [PresetPart])
    -> (matched: Int, unmatched: Int, unmatchedPartNames: Set<String>)
```

Two-phase algorithm:

**Phase 1 — direct match with roman-numeral normalisation**
Parts sorted longest-name-first (so "Bass Clarinet" wins over "Clarinet"). For each `CombineFile`:
- Normalise both `file.name.lowercased()` and each `part.name.lowercased()` through `normalizeRomanNumerals(_:)`.
- Match = the first part whose normalised name is a substring of the normalised filename.
- On match: `updateCopies(for:copies:)`.
- On no match: add to `newUnmatched`.

**Phase 2 — single-file consolidation**
For each base name whose **all** numbered siblings went unmatched (e.g. "Flute 1" and "Flute 2" both unmatched) and exactly **one** unmatched file contains the base name (e.g. one "Flute.pdf"):
- Sum the siblings' copy counts.
- Apply to that file, remove from `newUnmatched`, mark siblings matched.
- More complex mismatches (e.g. 3 preset parts, 2 files) remain orange.

**Supporting free functions:**

```swift
func normalizeRomanNumerals(_ s: String) -> String
// Converts trailing " i"→" 1", " ii"→" 2", " iii"→" 3", " iv"→" 4"
// Checked longest-first to prevent "iv" being partially replaced by "i".
// Requires a space before the roman numeral (word-boundary guard).

func numberedBase(of name: String) -> String?
// Returns the base name if the last word (after roman-numeral normalisation) is an integer.
// e.g. "Violin I" → "violin", "Flute 2" → "flute", "Oboe" → nil

func renumberAfterDeletion(_ parts: [PresetPart]) -> [PresetPart]
// After deleting a numbered part, if a base name has only one survivor,
// strips the trailing number from that survivor's name
// ("Horn 1" sole survivor → "Horn").
```

### PresetPartRow

Used in both `PresetSidebarView` and `CombinerPreferencesView`. Features:
- Double-click **name** → inline `TextField` rename (`@FocusState nameFocused`)
- Double-click **copies count** → inline `TextField` edit (`@FocusState copiesFocused`)
- Minus at `copies == 1` → calls `onDelete` (which invokes `renumberAfterDeletion` after removal)
- `isUnmatched: Bool` → `Color.orange.opacity(0.12)` background when last apply left this part without a file match

---

## Tab 1 — Sheet Music Renamer

**View:** `RenamerView`  
**ViewModel:** `RenamerManager: ObservableObject`  
**Model:** `RenameOperation: Identifiable`  
**Sheets:** `ManualAssignmentView` (uses `.sheet(item:)`), `AppPreferencesView` (⌘,)  
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

**External file:** `~/Library/Application Support/ScoreSort/instrument-orders.json`
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
**Supporting:** `SuggestionButton`, `PageInstrumentPreview`, `SplitControlsSection`, `A3SplitChoiceView`, `BookletOrderSheet`
**ViewModel:** `PDFManager` (shared type, separate `@StateObject` per tab)

### Data model — `fileSizes: [Int]`

The split state is stored as an **ordered array of page counts**, one entry per output file. For example `[2, 2, 1, 3]` means four files containing 2, 2, 1, and 3 pages respectively.

`splitMarkers: Set<Int>` is now a **derived computed property** (for rendering the page strip) — the set of page indices that start a new file (excluding page 0).

`pageToFileMapping: [Int: Int]` maps each page index to its output file index.

### SplitView key state

```swift
@State private var fileSizes: [Int] = []
@State private var stride: Int = 2
@State private var currentPage: Int = 0
@State private var baseFileName: String = ""
@State private var customFileNames: [Int: String] = [:]   // fileIndex → suffix
@State private var skippedPages: Set<Int> = []
@State private var selectedFileIndices: Set<Int> = []
@State private var skipMode: SkipMode = .file             // page or file skip mode
@State private var bookletFixRequest: BookletFixRequest? = nil
// A3 detection flags
@State private var showingA3Detection = false
@State private var suppressNextA3Detection = false
@State private var suppressDocumentReset = false           // preserves split state during in-place doc replace
@State private var isProcessingA3 = false
@State private var a3SplitNoticeVisible = false
```

When a new PDF loads, `fileSizes` is pre-populated via `splitSizesFromBookmarks` if the document has a top-level outline. If the bookmark labels match the `"NN - Piecename - Partname"` pattern (as produced by ScoreSort's own combiner output), `baseFileName` and `customFileNames` are also pre-filled via `extractSplitNames`.

**`suppressDocumentReset`** — set to `true` before replacing `pdfManager.pdfDocument` in-place (page swap, booklet reorder). `onChange` returns early without resetting any split state.

**`suppressNextA3Detection`** — set to `true` before loading an already-processed A3 document so `onChange` skips re-triggering the detection sheet.

**`skipMode`** — defaults to `.file`; automatically set to `.page` after an A3 split (where blank pages need to be removed individually). Reset to `.file` on any fresh PDF load or clear.

### SplitView methods (booklet / A3)

| Method | Purpose |
|--------|---------|
| `swapCurrentPageWithNext()` | Rebuilds the document with the current page and the next page exchanged. Sets both suppress flags. |
| `applyBookletOrder(pages: [Int], order: [Int])` | Rebuilds the document with the segment's pages in reading order. `order[readingPos]` = local index into `pages`. Also remaps `skippedPages` through the inverse permutation. Sets both suppress flags. |
| `requestBookletFix()` | Reads the current file segment and sets `bookletFixRequest` to present the sheet. |
| `canFixBookletOrder: Bool` | `true` when the current file has ≥ 4 pages and page count is divisible by 4. |
| `handleDeleteKey()` | Respects `skipMode`: `.page` → `toggleSkipPage(currentPage)`; `.file` → `toggleSkipFiles(selectedFileIndices or current file)`. |

### Pure split / A3 / booklet functions (top-level, above `SplitView`)

| Function | Purpose |
|----------|---------|
| `toggleSplit(in sizes: [Int], at page: Int) -> [Int]` | Returns new sizes array with split toggled at `page`. Splits mid-file or merges at a boundary. |
| `splitSizes(totalPages: Int, stride: Int) -> [Int]` | Returns sizes array dividing `totalPages` into `stride`-sized chunks (last chunk takes remainder). |
| `splitSizesFromBookmarks(_ document: PDFDocument) -> (sizes: [Int], labels: [String])?` | Reads the document's top-level `PDFOutline`, sorts entries by page index, and returns a `fileSizes` array and a parallel array of bookmark label strings. Returns `nil` if the document has fewer than two usable bookmarks. The first bookmark may point to page 0 (its label is included but page 0 is never a split marker). |
| `extractSplitNames(from labels: [String]) -> (baseName: String, suffixes: [String])?` | Parses bookmark labels of the form `"NN - Piecename - Partname"` (numeric prefix, space-hyphen-space separator). Returns a shared `baseName` and per-file `suffixes` if all labels parse successfully and share the same piece name. Returns `nil` on any mismatch. |
| `isA3Landscape(_ doc: PDFDocument) -> Bool` | Returns `true` if the first ≤ 3 pages are all landscape, width > 1000 pt and < 1500 pt. Accounts for `page.rotation` metadata: if `rotation % 180 != 0`, width and height are swapped before measuring (so pages stored as portrait + 90°/270° rotation flag are detected correctly). |
| `splitA3Pages(_ doc: PDFDocument, leftFirst: Bool) -> PDFDocument` | For each page, creates two copies and sets their `mediaBox`/`cropBox` to the correct native half. Uses `page.rotation` (clockwise degrees) to determine which native axis is the visual horizontal divide: 0° → split on X; 90° CW → visual left = native bottom half (split on Y); 180° → visual left = native right half; 270° CW → visual left = native top half. Vector-quality; no re-rendering. |
| `coverFirstFrontBackOrder(n: Int) -> [Int]` | Saddle-stitch deimposition: outer cover scanned first, each sheet's front face before back. Returns a permutation where `result[readingPos] = scanPos` (0-indexed). Verified: N=4→`[1,2,3,0]`, N=8→`[1,2,5,6,7,4,3,0]`. Returns `[]` if N < 4 or N % 4 ≠ 0. |
| `innerFirstFrontBackOrder(n: Int) -> [Int]` | Inner sheets scanned first (alternative scanning convention). Implemented as a half-rotation of `coverFirstFrontBackOrder`. Returns `[]` if N < 8 or N % 4 ≠ 0. |
| `bookletCandidates(n: Int) -> [(label: String, description: String, order: [Int])]` | Returns candidate reorderings for an n-page segment: "Standard (cover first)" always; "Inner-first" if n ≥ 8. Each candidate's `order` is a valid permutation. |

### `SplitControlsSection` layout (3 rows)

| Row | Contents |
|-----|----------|
| 1 | Navigation: `|◀` `◀` … Page N of M / File info … `▶` `▶|` |
| 2 | `[Add/Remove Split (Space)]` ← disabled at page 0 … `[Swap with Next (S)]` ← disabled at last page |
| 3 | Segmented `[Skip Page ∣ Skip File]` … `[Skip/Unskip button]` — label adapts to mode and current state |

`SplitControlsSection` binds `skipMode: Binding<SkipMode>` directly; the segmented control updates the parent's state in place.

### A3 split workflow

1. User drags in a PDF. `onChange` calls `isA3Landscape` → shows `A3SplitChoiceView` sheet.
2. User picks "Left half first" / "Right half first". Background thread calls `splitA3Pages`. On completion, sets `skipMode = .page`, then assigns result to `pdfManager.pdfDocument` (suppress flags prevent re-detection and state reset).
3. `a3SplitNoticeVisible` banner appears for 6 s pointing to "Swap with Next (S)".
4. Toolbar "Fix Booklet Order" button becomes available once split markers define file segments of size divisible by 4.

### Booklet reorder workflow

1. User sets split markers to define each booklet as its own file segment.
2. User navigates to a file with ≥ 4 pages (divisible by 4); toolbar "Fix Booklet Order" becomes enabled.
3. Tapping the button creates a `BookletFixRequest` and presents `BookletOrderSheet`.
4. Sheet shows thumbnail strips (90 × 127 pt) for each candidate reordering with radio buttons, plus a drag-to-reorder custom option.
5. On Apply, `applyBookletOrder` replaces the document in-place (split markers and skipped-page mapping preserved).

### `BookletOrderSheet`

```swift
struct BookletOrderSheet: View {
    let request: BookletFixRequest   // fileIndex, pages: [Int], document: PDFDocument
    let onApply: ([Int]) -> Void     // called with the chosen order permutation
    let onCancel: () -> Void
}
```

- Candidates generated by `bookletCandidates(n:)`.
- Thumbnails rendered via `PDFPageView` at 90 × 127 pt.
- Custom drag-to-reorder via `List` + `ForEach.onMove` (no `editMode` needed on macOS).
- Apply button disabled when no valid option is selected.

### Step 2 — `SplitNamingStageView`

Full-window scrollable list of `SplitFileNamingRow` views, one per output file.

- **`instrumentNames: [String]`** — ordered, deduplicated union of orchestra + band + jazz lists from `InstrumentOrders`, each entry `.capitalized`. Used as autocomplete source across all rows.
- Auto-scrolls to the focused row via `.onChange(of: focusedField)` + `ScrollViewReader.scrollTo(_:anchor:.center)`.

#### `SplitFileNamingRow` autocomplete

**`nextExpectedIndex: Int`** — scans rows above (nearest first) to find the last recognised instrument name, then returns `index + 1` in `instrumentNames`. Rotates suggestion list so the most likely next instrument appears first.

**`numberedSuggestion: String?`** — if the nearest previous suffix ends with a space + integer (e.g. "Flute 1"), returns the incremented version ("Flute 2").

**`suggestions: [String]`** — rotated list filtered to prefix-matches then contains-matches; prepends `numberedSuggestion` if applicable. Always ≤ 8 entries.

| Key | Behaviour |
|-----|-----------|
| `↓` | Move `selectedSuggestionIndex` down (starts at 0 if nil) |
| `↑` | Move up; set nil when above index 0 |
| `Return` | If index set: accept suggestion. Else: advance focus to next row |
| `Escape` | Clear `selectedSuggestionIndex` |
| Any typing | Reset `selectedSuggestionIndex` to nil |

---

## Tab 3 — Rotate Pages

**View:** `RotateView`  
**ViewModel:** `PDFManager`

Controls: `baseRotation: RotationAngle` (all pages) + `additionalRotationMode: RotationMode` (odd/even/none) + `additionalRotationAngle`.

Preview: `PDFPageView: NSViewRepresentable` wrapping `PDFView`. Renders page to `NSImage` first (via `renderFullImage`) to avoid mutating shared page state, then sets `clonedPage.rotation`.

Keyboard navigation: `←` / `→` (previous/next); `⌘←` / `⌘→` (first/last). Shared with Split tab Step 1.

```swift
enum RotationAngle: Int { case none=0, rotate90=90, rotate180=180, rotate270=270 }
enum RotationMode { case odd, even, none }
```

---

## Shared Infrastructure

**`PDFAlertHandler`** — `typealias PDFAlertHandler = (_ title: String, _ message: String, _ isError: Bool) -> Void`. All PDF save/export methods take this callback; they never show UI directly.

**`PDFManager: ObservableObject`** — used by both SplitView and RotateView (separate instances).

**`pdfFilenameError(for:) -> String?`** — returns an error string if input contains `/`, `:`, `\`, or null.

**Read-only-location guards (rename permission failures)** — three free functions near `pdfFilenameError`, used by all rename/move paths to handle cloud-sync (Dropbox/Google Drive/iCloud), locked, and read-only-volume folders that are *readable but not writable*:
- `nonWritableParentDirectories(of urls: [URL]) -> [URL]` — distinct parent dirs that fail `FileManager.isWritableFile`. Empty = all writable. Used as a pre-flight gate before attempting any move.
- `isFilePermissionError(_ error: Error) -> Bool` — true for `NSFileWriteNoPermissionError`/`NSFileReadNoPermissionError`, POSIX `EACCES`/`EPERM`/`EROFS`, including a POSIX error nested under `NSUnderlyingErrorKey`. Used to decide whether to show friendly guidance after a move fails.
- `readOnlyLocationMessage(folderName: String?) -> String` — the standard actionable message ("copy to Documents/Desktop, or fix Get Info → Locked / Sharing & Permissions"). Falls back to "this location" when name is nil.

Wired into `RenamerManager.executeRename` (Score Order Sorter), `BulkRenameView.executeRename`, and `applyPrefixAndRenameBulk` (Bulk Renamer): each pre-flights with `nonWritableParentDirectories` and aborts with the friendly message; if moves still fail and *all* failures were permission errors, it shows the friendly message instead of the raw "Partial Success" dump.

**`PDFPageView: NSViewRepresentable`** — safe preview clone via `renderFullImage(from:)`.

---

## Known Patterns & Gotchas

- **`.sheet(item:)` not `.sheet(isPresented:)`** — used for ManualAssignmentView to avoid blank sheet bug.
- **Instrument detection is leftmost-match**, not longest-match or order-match, to handle compound names.
- **`bass clarinet` before `clarinet`** in lists — length-sort in detectInstrument handles this, but the order in the static arrays also matters as a tie-break.
- **`canCreateDirectories = true`** set on NSOpenPanel for folder selection.
- **Print automation not possible** — NSPrintOperation / AppleScript all fail reliably; "Open in Preview" + ⌘P is the documented workflow.
- **App quits on window close** via `NSApplicationDelegateAdaptor(AppDelegate.self)`.
- **`.clipped()` does not restrict hit testing** — use `.allowsHitTesting(false)` when an image with `.fill` content mode would absorb clicks meant for views below it. (Affected `PageInstrumentPreview` inside `SplitFileNamingRow`.)
- **`FocusState` must not be duplicated across parent/child** — pass `FocusState<T>.Binding` from parent to child; a local copy intercepts the first click on a TextField.
- **`fileSizes` array vs `splitMarkers` set** — array is the source of truth; `splitMarkers` is derived for rendering only.
- **Instrument orders versioning** — `instrument-orders.json` carries a `"version"` sentinel; `InstrumentOrders.setup()` regenerates the file on launch if it's older than the built-in default.
- **`EnsemblePresetStore` is separate from the Renamer's `InstrumentOrders`** — presets (name + per-part copy counts) live in `ensemble-presets.json`; instrument orders (name strings only) live in `instrument-orders.json`. They are independent systems.
- **Preset apply does not interact with collate groups** — `applyPreset` sets `copies` on individual `CombineFile` entries; it ignores `collateGroupId` entirely. A grouped file can have its copies set by a preset apply, but the value is unused by the PDF output loop (which uses `group.copies` instead). Consider whether this is the desired behaviour if mixing groups and presets.
- **Roman-numeral normalisation requires a space prefix** — `normalizeRomanNumerals` only converts ` i`/` ii`/` iii`/` iv` (word-boundary guard). This prevents false matches like "celli" → "cell1". IV is checked before I to prevent "violin iv" → "violin 1v".
- **Collate group contiguity is maintained by `createCollateGroup`** — files are pulled together at the position of the first selected file. Nothing in the code subsequently enforces contiguity, but nothing currently breaks it either (move operations use `expandForGroups` which moves all group files together).
- **`suppressDocumentReset` is the "in-place replace" flag** — any operation that replaces `pdfManager.pdfDocument` without wanting a full state reset (page swap, booklet reorder) must set this flag immediately before the assignment. `onChange` clears it and returns early, preserving `fileSizes`, `skippedPages`, `customFileNames`, etc.
- **`suppressNextA3Detection` prevents A3 re-detection loops** — set before loading an already-processed document. Cleared by `onChange` after it is checked, so it is single-use.
- **Booklet math: `order[readingPos] = scanPos`** — the permutation arrays produced by `coverFirstFrontBackOrder` and friends index *into* the file segment's pages array: `pages[order[readingPos]]` gives the absolute page index to place at `readingPos`. The formula is derived from saddle-stitch sheet geometry; verified for N=4 and N=8.
- **`SkipMode.page` after A3 split** — because A3 scanning produces interleaved left/right halves, blank pages tend to appear one at a time rather than whole-file. Page-skip mode is therefore the more useful default after splitting.
- **`editMode` is unavailable on macOS** — SwiftUI's `\.editMode` environment key is iOS-only. On macOS, `ForEach.onMove` inside a `List` enables drag-to-reorder natively with no extra configuration.
- **PDF `page.rotation` is clockwise** — the PDF spec defines `Rotate` as clockwise degrees. So `rotation = 90` means 90° CW: the native top edge swings to the visual right. When splitting A3 pages with a 90° rotation flag, the visual left half corresponds to the native *bottom* half (low Y). This is counterintuitive but matches Preview.app behaviour. The inverse holds for 270°.
- **ScoreSort's Rotate tab uses `page.rotation` metadata** — it does not geometrically transform page content. This is the standard PDF approach and is correctly handled by Preview. The consequence is that rotated pages have a portrait native mediaBox with a rotation flag, so `isA3Landscape` must swap w/h before measuring, and `splitA3Pages` must split along the Y axis rather than X.

---

## Test Suite

**Target:** `ScoreSortTests` (Swift Testing framework — `@Suite` / `@Test` / `#expect`)  
**File:** `ScoreSortTests/Music_PDF_ManagerTests.swift`  
**Import:** `@testable import ScoreSort`

**Shared helper:** `writePDF(pages: Int, to: URL)` — creates a real blank-page PDF using PDFKit.

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
| `RomanNumeralTests` | `normalizeRomanNumerals` — no-op on plain text, I/II/III/IV conversion, IV matched before I |
| `NumberedBaseTests` | `numberedBase(of:)` — arabic suffix, roman suffix, unnumbered returns nil |
| `RenumberAfterDeletionTests` | `renumberAfterDeletion` — arabic survivor, roman survivor, pair untouched, capitalisation preserved |
| `CoverFirstFrontBackOrderTests` | `coverFirstFrontBackOrder(n:)` — N=4 and N=8 known values, valid permutation for N=12/16, structural properties (first reading page always scan 1, last always scan 0), guard conditions (n<4, n%4≠0) |
| `InnerFirstFrontBackOrderTests` | `innerFirstFrontBackOrder(n:)` — valid permutation N=8/16, differs from cover-first, empty for N=4/N%4≠0 |
| `BookletCandidatesTests` | `bookletCandidates(n:)` — correct count (1 for N=4, 2 for N=8), valid permutations for all N, correct N=4 order, non-empty labels/descriptions |
| `A3LandscapeDetectionTests` | `isA3Landscape(_:)` — empty doc, portrait, square, too narrow (≤1000 pt), too wide (≥1400 pt), A3 landscape, multi-page, mixed-size doc |
| `A3PageSplittingTests` | `splitA3Pages(_:leftFirst:)` — output count doubled, half width, unchanged height, left/right crop origins, mediaBox=cropBox, empty input |
| `ReadOnlyLocationTests` | `nonWritableParentDirectories` (writable allowed, read-only `chmod 0555` flagged + deduped), `isFilePermissionError` (Cocoa write-no-permission, POSIX EACCES/EROFS, nested underlying POSIX, false for name-collision), `readOnlyLocationMessage` (names folder + mentions Dropbox/Documents, nil fallback) |

**Not covered:** collate group logic (no unit tests yet — `createCollateGroup`/`dissolveGroup`/`updateGroupCopies` and the collated PDF output loop); rescan mode stripping; `performRename()` filesystem operation; `applyBookletOrder` state mutations; UI/integration tests.
