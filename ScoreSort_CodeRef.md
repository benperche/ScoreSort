# ScoreSort — Code Reference
> Split by feature. Tabs: `Combine/CombineTab.swift`; `Rename/RenameViews.swift` + `Rename/RenamerManager.swift`; `Split/SplitView.swift` + `Split/SplitNaming.swift` + `Split/SplitPrefixStep.swift`; `Rotate/RotateTab.swift`.
> Tab 4 — Stamp: `Stamp/StampStore.swift` + `Stamp/StampTab.swift` (`StampView` designer/batch tool, plus `StampMenuButton` used by the Combine and Split toolbars).
> Pure logic in `ScoreSort/Logic/`: `InstrumentNames.swift` (preset matching + split instrument suggestions/detection), `SplitLogic.swift` (split maths, A3, bookmarks, booklet), `RenameLogic.swift` (folder-job helpers + score-order numbering), `FileUtilities.swift` (output dir, filename validation, permissions, page-range formatting), `StampLogic.swift` (stamp model, placement, drawing, flattening).
> Shared scaffolding (app entry, ContentView, AppState, menu commands, Sparkle, Preferences panes, DropZone, PDFManager) stays in `ScanReorienterApp_complete.swift` (~1 700 lines).
> One module/target — cross-file calls need no imports; filesystem-synchronized project auto-compiles files added under `ScoreSort/`. Tests: `ScoreSortTests` incl. `ViewSmokeTests` (host each tab) + `CombineManagerReorderTests`.
> Xcode project: "ScoreSort"

---

## App Structure

```
ScoreSortApp (@main)
  └── AppDelegate  — quits on window close
  └── WindowGroup  — ContentView            (.defaultSize 940×800)
        └── ContentView  — TabView (tags 0–4)
              ├── 0: CombineView
              ├── 1: RenamerView
              ├── 2: SplitView
              ├── 3: RotateView
              └── 4: StampView
        └── sheets: ShortcutsHelpView (⌘`), WelcomeTourView (⌘/),
                    StampDesignerView (⌥⌘S, via .sheet(item: appState.stampSheet))
  └── Settings  — AppPreferencesView (⌘,)
        ├── Tab "Combiner"  (tag "combiner") — CombinerPreferencesView
        └── Tab "Renamer"   (tag "renamer")  — PreferencesView (renamer instrument order)
```

Window min size: 900×700 (`.defaultSize(940, 800)` on the `WindowGroup`).

**There is no About window scene.** `CommandGroup(replacing: .appInfo)` calls `NSApp.orderFrontStandardAboutPanel(options: [.credits: aboutPanelCredits()])` — the standard macOS panel. A titled `Window` scene was removed because it added an unwanted entry to the Window menu. `aboutPanelCredits()` builds the credits string from the executable's modification date + authorship.

`AppPreferencesView` deep-links via `@AppStorage("preferredPrefsTab")` — write `"combiner"` or `"renamer"` before opening Preferences and `.onChange` selects that tab even if the window is already open.

**App-level shared state** (held as `@StateObject` on `ScoreSortApp`, injected via `.environmentObject()`):
- `AppState` — `selectedTab`, `showingKeyboardHelp`, `showingWelcomeTour`, `stampSheet`, plus two menu objects: `tabCommands` (`TabCommands`, the active tab's menu bridge) and `combineMenuState` (`CombineMenuState`)
- `RenamerManager` — used by both `RenamerView` and `AppPreferencesView`
- `EnsemblePresetStore` — used by `CombineView`, `PresetSidebarView`, `CombinerPreferencesView`
- `StampStore` — used by `StampView`, `StampMenuButton`, `CombineView`, `SplitView`

### Menu Bar Commands

The menu bar is **standard File / Edit / View plus one adaptive "Actions" menu** (redesigned in 1.8.0). There are no per-tab menus.

| Struct | Menu | Contents |
|--------|------|----------|
| `FileCommands` | File | `Open…` (⌘O, replaces `.newItem`) · `Save` (⌘S) · `Open in Preview` (⇧⌘P) · `Stamp…` (⌥⌘S) · `Clear` (⌘⌫) — all replacing `.saveItem`. Titles and enablement come from the active tab's slice; `Stamp…` is the one global item (it edits the shared stamp library, so it lives in File rather than Actions). |
| `ViewCommands` | View | Tab switching — Combine PDFs ⌘1 / Rename Files ⌘2 / Split PDF ⌘3 / Rotate Pages ⌘4 — plus `Show/Hide Presets` (⌥⌘P, disabled unless the active tab supplies `togglePresets`). |
| `TabActionsCommands` | Actions | `ForEach` over the active tab's `slice.tabActions`. The title is fixed at "Actions" — SwiftUI can't reliably retitle a `CommandMenu` — only the contents swap per tab. |
| `HelpCommands` | Help | Replaces `.help` (the default item errors): `Welcome Tour…` (⌘/) and `Keyboard Shortcuts…` (⌘\`). |

`CommandGroup(replacing: .appInfo)` → standard About panel (see above); `CommandGroup(after: .appInfo)` → `Check for Updates…` (Sparkle, disabled until `canCheckForUpdates`).

#### The `TabCommands` / `TabSlice` / `MenuAction` bridge

```swift
struct MenuAction: Identifiable {        // one row in the Actions menu
    let id = UUID()
    let title: String
    var key: KeyEquivalent? = nil        // a *modifier* shortcut only, never a bare key
    var modifiers: EventModifiers = .command
    var isEnabled: Bool = true
    let perform: () -> Void
}

struct TabSlice {
    var openTitle = "Open…";   var open: (() -> Void)?          // File ▸ ⌘O
    var primaryTitle = "Save"; var primarySave: (() -> Void)?   // File ▸ ⌘S
    var openInPreview: (() -> Void)?                            // File ▸ ⇧⌘P
    var clearTitle = "Clear";  var clear: (() -> Void)?         // File ▸ ⌘⌫
    var togglePresets: (() -> Void)?                            // View ▸ ⌥⌘P
    var tabActions: [MenuAction] = []                           // the Actions menu
}

final class TabCommands: ObservableObject { @Published var slice = TabSlice() }
```

`AppState.tabCommands` holds the single `TabCommands`; the command structs observe it and read `commands.slice`. A **nil closure disables** its menu item, so tabs express "not available yet" by leaving the closure nil rather than by flag plumbing.

**Only the active tab writes.** Each tab has a private `syncTabCommands()` that starts with `guard appState.selectedTab == <myTab> else { return }`, builds a fresh `TabSlice`, and assigns `appState.tabCommands.slice`. It's called from `.onAppear` and from `.onChange` of `appState.selectedTab` plus whatever state affects enablement — always wrapped in `DispatchQueue.main.async { … }` so publishing happens after the view body completes. Because hidden tabs stay mounted, the guard is what keeps the menus showing the on-screen tab.

Per-tab slices (see each tab's `syncTabCommands()`):

| Tab | ⌘O | ⌘S | ⌘⌫ | Actions menu |
|-----|----|----|----|--------------|
| 0 Combine (`CombineTab.swift:807`) | Add Files… | Create PDF… | Clear Files | Move Up ⌘↑ · Move Down ⌘↓ · Collate · Add Blank Page · Remove Selected · Select All · Select None · Show in Finder ⇧⌘F. Also supplies `openInPreview` and `togglePresets`. |
| 1 Rename (`RenameViews.swift:223`) | Choose Files or Folder… | Rename Files | Clear Files / **Start Over** on the done screen | Don't Rename Selected · Rescan Folder ⌘R · Skip Folder · Show in Finder ⇧⌘F |
| 2 Split (`SplitView.swift:799`) | Choose PDF… | per stage: Continue to Naming / Save Split Files | Clear File / **Start Over** on the summary | stage-dependent — Split: Split as A3… · Fix Booklet Order · Clear All Splits; Naming: Back to Split; Prefix: Back to Naming. Always ends with Show in Finder ⇧⌘F. |
| 3 Rotate (`RotateTab.swift:217`) | Choose PDF… | Save Rotated PDF | Clear File | Rotate Left · Rotate Right · Show in Finder ⇧⌘F |

Convention: actions are **listed even when unusable** (`isEnabled: false`) rather than omitted, so the menu advertises what a tab can do in its empty state. "Show in Finder" reveals the most relevant target — output folder on done/summary screens, else the source file/folder.

**Menus bind only non-editing modifier shortcuts** (⌘S/⌘O/⇧⌘P/⌘⌫/⌥⌘P/⇧⌘F/⌘R/⌘1–5, plus Combine's ⌘↑/⌘↓). Standard-editing keys (⌘A/⌘Z/⌫) and all bare keys stay in the tabs' own handlers — a `CommandMenu` shortcut intercepts globally *even when the item is `.disabled()`*, which broke ⌘A inside a save panel's text field. Hence `MenuAction.key` is documented as modifier-only.

**`CombineMenuState`** — no longer the menu bridge. It survives for Combine's in-view keyboard handling: `isPanelOpen` (set around the open/save panels; the `.onKeyPress` early-outs while a panel is up) and the `canRemove`/`canMoveUp`/`canMoveDown`/`canGroup`/`hasFiles`/`isActiveTab` flags plus action closures kept in sync by `syncMenuFlags()` / `syncMenuClosures()`. Nothing outside `CombineTab.swift` reads the flags or closures now that `CombinerCommands` is gone.

**Keyboard handlers are tab-scoped.** TabView keeps hidden tabs mounted, so handlers leak across tabs unless gated. Every one is gated the same way: Combine's `.onKeyPress` (`guard appState.selectedTab == 0`, then `guard !menuState.isPanelOpen`), Split's and Rotate's `.onKeyPress`, and the **app-global `NSEvent` local monitors** (renamer delete in `RenameViews.swift`, splitter delete + ⌘Z in `SplitView.swift`) which early-out with `guard appState.selectedTab == <tab> else { return … }`. (Combine 0, Rename 1, Split 2, Rotate 3.)

**`ShortcutsHelpView`** (⌘\`) — modal sheet, and **the complete shortcut reference**: a per-tab table with sections "Global (View & File menus)", "Combine PDFs", "Rename Files", "Split PDF", "Rotate Pages". Any new shortcut — menu-bound or in-view — should be added here.

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

`move(ids:before:undoManager:)` — backs **drag-to-reorder**. Pulls the moving files out (order preserved), then re-inserts the block immediately before `targetId` (or appends when nil). Registers a "Reorder Files" undo. `addToGroup(ids:groupId:undoManager:)` — backs **drag-onto-group**: reassigns the dragged files' `collateGroupId` to the target group, pulls them in after the group's current last member, then `cleanupSmallGroups()` dissolves any source group left with <2 members ("Add to Collate Group" undo).

The list is a `ScrollView`/`LazyVStack` (not a `List`), so drag/drop is SwiftUI `.draggable(file.id.uuidString)` (row UUID as a `String`, with a `dragPreview`) + `.dropDestination(for: String.self)` attached to **individual** sub-views (not the row wrapper), because the header and the member rows need different drop actions:
- **Header** (`CollateGroupHeaderRow`) → `handleReorderDrop` (insert *before* the group); shows the `insertionLine`.
- **Grouped member row** → `handleAddToGroup` (merge into the group); shows a whole-group merge highlight via `isMergeTarget` (driven by `mergeTargetGroupId`), not an insertion line.
- **Ungrouped row** → `handleReorderDrop` with an `insertionLine`.
- **Trailing `Color.clear` zone** → `handleReorderDropAtEnd` ("move to end").

`CombineView` drag helpers: `draggedSet(for:)` (whole selection if the dragged row is selected, else just that row, group-expanded), `groupSnappedTarget(_:)` (snaps a reorder target to its group's first member so a drop never splits a group), `setReorderTarget(_:_:)`, and `insertionLine(visible:)` (3pt accent line, `.overlay(alignment: .top)`). State: `dropTargetId`, `isDropAtEnd`, `mergeTargetGroupId`. Coexists with the view-level `.onDrop(of: [.fileURL])` (Finder import) because internal drags carry `String`, not `fileURL`.

**Collate-group visuals** (so a group's extent is obvious): a 3pt accent **spine** down the leading edge of the header and every member row, a faint accent fill on member rows (`rowBackground` in `CombineFileRow`), and a 2pt accent **closing border** under the last member (`isLastInGroup`, computed in `CombineView`). During a drag-merge, the whole group (header + members) tints to `accentColor.opacity(0.22)` via `isMergeTarget`.

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

**Keyboard shortcuts (in-view `.onKeyPress`):** ↑/↓ (navigate), ⇧↑/⇧↓ (extend), ⌘A (select all), `c` (group — only `.handled` if `canGroup`). The whole handler is skipped unless `selectedTab == 0` and no file panel is open (`menuState.isPanelOpen`). ⌘↑/⌘↓ (Move Up/Down) come from the Actions menu via `syncTabCommands()`.

**⌫ / ⌦ (remove selected)** is an `NSEvent` local monitor — `installKeyMonitor()`, installed in `.onAppear` and torn down in `.onDisappear` (`combineKeyMonitor`). Same gates as the `onKeyPress` (`selectedTab == 0`, `!isPanelOpen`) plus: passes the event through when the first responder is an `NSTextView`, when a sheet is key (`NSApp.keyWindow?.isSheet`), or when nothing is selected. Not a menu `.keyboardShortcut(.delete)` — the disabled-shortcut interception bug would steal backspace from every text field. (The 1.8.0 menu redesign dropped `CombinerCommands`, which had held this binding as a bare-key menu item, and left ⌫ unbound until this monitor was added.)

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

**Sync fix (mirror of the Preferences one):** `.onChange(of: presetStore.selectedPreset)` reloads `draftParts` when the selected preset's contents change externally (e.g. edits in the Preferences window) — so the sidebar updates live instead of only on ensemble switch. Guarded by `!isDirty` so unsaved local sidebar edits are never clobbered.

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
- Match = the first part for which `presetPartMatches(part:in:)` is true (qualifier-aware substring — see below, so a "Clarinet" part won't match a "Bass Clarinet" file).
- On match: `updateCopies(for:copies:)`.
- On no match: add to `newUnmatched`.

**Phase 2 — single-file consolidation**
For each base name whose **all** numbered siblings went unmatched (e.g. "Clarinet 1" and "Clarinet 2" both unmatched) and exactly **one** unmatched file matches the base name via `presetPartMatches` (e.g. one "Clarinet.pdf" — a "Bass Clarinet.pdf" is *not* counted, which is what lets the consolidation still fire when a bass clarinet is also present):
- Sum the siblings' copy counts (so 7 + 7 → **14** copies on the single "Clarinet.pdf").
- Apply to that file, remove from `newUnmatched`, mark siblings matched.
- More complex mismatches (e.g. 3 preset parts, 2 files) remain orange.

**Identity-aware matching — `presetPartMatches(part:in:)`**
Both args must be pre-lowercased + roman-normalised. The matcher reuses the splitter's instrument knowledge by *expanding each preset part into its equivalent filename phrases*, then testing each against the filename with a qualifier guard:
```swift
let instrumentQualifierWords: Set<String>  // bass, alto, contra(bass), soprano(ino), tenor, baritone, piccolo, english
func instrumentAliasPhrases(forBase base: String) -> [String]   // sax abbrev/reversed, French Horn=Horn, Vln=Violin, Bb Clarinet=Clarinet, clef-aware euph/bari; [] if unknown
func presetMatchPhrases(for part: String) -> [String]           // aliases + trailing number re-attached; falls back to the literal base for custom names
func phraseOccurs(_ phrase: String, in filename: String) -> Bool // substring, rejected if preceded by a qualifier word the phrase lacks
func presetPartMatches(part: String, in filename: String) -> Bool // true if ANY phrase occurs
```
- **Clef matters here, unlike the splitter.** `instrumentIdentityKey` (Step 2) *collapses* Euphonium/Baritone BC and TC into one identity; the Combine matcher keeps them **distinct** because it decides *which part to print*. So "Euphonium BC" matches a bass-clef file (incl. one the publisher spells "Baritone BC") but never the treble-clef one; a bare "Euphonium" preset entry matches either clef.
- The qualifier guard still prevents a generic root ("Clarinet") from matching a more specific instrument ("Bass Clarinet") — which also stops that specific file from blocking the numbered-sibling consolidation.
- The default **Wind Band template** ships "Euphonium BC" (not bare "Euphonium") so the common Australian-band case is clef-correct out of the box.
- Short 1–2 letter abbreviations (Cl, Fl, Tpt) are intentionally *not* aliased (collision-prone); word-level aliases + the sax family + clefs are. Tested in `PresetPartMatchesTests`.

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

### Accepted file types
The Score Order Sorter renames **PDFs and image scans** (JPG/JPEG/PNG/TIF/TIFF/HEIC/BMP/GIF) — detection is filename-based, and renaming only prepends a prefix to the existing filename so the original extension is preserved. The accepted set is the top-level `renamableFileExtensions` / `isRenamableFile(_:)` (just above `RenamerManager`), used by `scanFolder`, `loadFiles`, `addFiles`, the batch `folderHasDirectPDFs`, `additionalFolderFiles`, and the open panel (`[.pdf, .image, .folder]`). **Bulk Part Rename stays PDF-only** because it renders `PDFDocument` page previews; accidental pickups are handled by the existing "Don't Rename" exclude (`excludeSelected`/`setExcluded`).

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

### Batch folder renaming (Score Order Sorter)
Import **multiple folders at once** and process them one-by-one. All state is `@State` in `ScoreOrderSortView` (the queue is a UI-workflow concern; `RenamerManager` is unchanged and still single-folder):
- `batchFolders: [URL]` (ordered jobs; `count <= 1` ⇒ non-batch, no batch UI), `batchPosition: Int` (current folder index), `batchResults: [(folder, names)]` (accumulated for the final summary). `isBatchActive == batchFolders.count > 1`.
- **Import routing:** all entry points (`selectFolder` panel, empty-zone drop, and the done-screen restart drop) funnel through `startInput(_ urls:)` → folders go through `expandToJobFolders` then `beginBatch` (sorted, loads job 0); pure files ⇒ `loadFiles`. A single folder is just a batch of one.
- **Container-folder expansion** (`expandToJobFolders` → recursive `collectJobFolders`): walks each dropped folder's whole subtree and makes **every directory at any depth that directly contains PDFs** a job. So a single folder of PDFs = one job; a (nested) parent folder of piece folders batches them all. Jobs sorted by full `path` (groups siblings). The queue bar and summary display each folder via `qualifiedFolderName(for:among:)` — a path relative to the deepest shared ancestor (e.g. "Concert Band › Symphony 5") so same-named folders deep in a tree are distinguishable. Uses `folderHasDirectPDFs` / `isDirectory` helpers. (Bulk Part Rename is single-piece only: dropping a folder with no direct PDFs shows a "No PDFs in That Folder" alert pointing to the Score Order Sorter, rather than silently failing.)
- **Advance:** the Rename button calls `executeRename { … advanceOrFinish(recordResult:) }`. `advanceOrFinish` appends the result then loads the next folder (staying on the review screen, no per-folder Done screen) or, when the queue is exhausted, sets `renameResult` to show the combined Done screen. The button label flips to **"Rename & Next"** mid-batch.
- **Skip:** `skipCurrent()` = `advanceOrFinish(recordResult: nil)` (nothing appended). **Reorder:** `batchQueueBar` shows a `List` of the *upcoming* folders (`batchFolders[(batchPosition+1)...]`) with `.onMove(moveUpcoming)`, which reorders only the tail after the current folder.
- **Final summary:** `ScoreOrderRenameSummaryView` takes an optional `perFolder: [(folder, names)]?`; when >1 it renders a grouped multi-folder summary ("N folders · M files", Rescan/Show-in-Finder hidden). `batchResults.last` backs the single-folder fallback so a trailing Skip doesn't blank the summary.
- **Reset** (`resetBatch()`): Start Over, the toolbar button (labelled **"Cancel Batch"** mid-batch), and `beginBatch`.

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

**Move original to Trash** — a `.checkbox` Toggle bound to `@AppStorage("deleteSourceAfterSplit")` (persisted, defaults off). It lives in **Step 2** (`SplitNamingStageView`), right-justified on the same row as the "Prefix score order" toggle/picker (after the `Spacer()`), so it's the last decision before saving. The key is shared between `SplitView` and `SplitNamingStageView` via `@AppStorage`. After a *successful* save, both save paths (`saveSplitPDF`'s non-prefix branch and `applyPrefixToFolder`) call `trashSourceFileIfRequested()`, which `FileManager.trashItem`s `pdfManager.sourceURL` (recoverable, not a hard delete) and returns whether it acted. The result is stored in `@State sourceWasTrashed` and passed to `RenameSummaryView` as `sourceTrashedNote` so the summary confirms "Original moved to the Trash." Trash failure is surfaced via `showNSAlert` but is non-fatal (split files are already written).

**Clear buttons** — every tab's reset button is a standard bordered (square) `Button` with a full-rectangle hit target, **not** `.buttonStyle(.plain)` (the plain style only registered hits on the glyphs). Labels: **"Clear File"** (singular: Split Step 1, Split Step 2, Rotate) and **"Clear Files"** (plural: Combine, Rename Files, Bulk Part Rename).

**Done/summary screens are drop targets** — each finished-job screen has an (invisible, no `isTargeted` highlight) `.onDrop(of: [.fileURL], isTargeted: nil)` so dropping a new folder/PDF restarts the flow without clicking Start Over: Score Order Sorter (`handleRestartDrop` → `startInput`, which clears `renameResult` and starts a batch or `loadFiles` — see Batch folder renaming), Bulk Part Rename (`handleRestartDrop` → resets `baseFileName`/`bulkStage = .base`, `loadFromFolder`/`loadFiles`), Splitter (`handleSummaryPDFDrop` → `pdfManager.loadPDF`, letting the Group-level `onChange` reset all split state + re-run A3 detection). The same `handleRestartDrop` helpers also back each tool's empty drop zone. Rotate and Combine have no summary screen, so nothing to add there.

### SplitView methods (booklet / A3)

| Method | Purpose |
|--------|---------|
| `swapCurrentPageWithNext()` | Rebuilds the document with the current page and the next page exchanged. Sets both suppress flags. |
| `applyBookletOrder(pages: [Int], order: [Int])` | Rebuilds the document with the segment's pages in reading order. `order[readingPos]` = local index into `pages`. Also remaps `skippedPages` through the inverse permutation. Sets both suppress flags. |
| `requestBookletFix()` | Reads the current file segment and sets `bookletFixRequest` to present the sheet. |
| `canFixBookletOrder: Bool` | `true` when the current file has ≥ 4 pages and page count is divisible by 4. |
| `handleDeleteKey()` | Respects `skipMode`: `.page` → `toggleSkipPage(currentPage)`; `.file` → `toggleSkipFiles(selectedFileIndices or current file)`. |

**Step-1 undo/redo** (⌘Z / ⌘⇧Z): a manual `[SplitSnapshot]` `undoStack`/`redoStack` (view-local `@State`, since the split state isn't in a manager). Each mutating marker/skip/stride action (`clearAllMarkers`, `applyStride`, `restrideFromCurrentPage`, `toggleSplitAt`, `toggleSkipFiles`, `toggleSkipPage`) calls `pushUndo()` first; a `SplitSnapshot` captures `fileSizes` + `skippedPages` + `customFileNames` (not the document). ⌘Z is handled in the **NSEvent local monitor** (keyCode 6, gated on `!inTextField`) — not a menu command — so it works without an Edit-menu `UndoManager` and never bonks. Stacks are cleared on new-doc load, clear, **and** any in-place document rebuild (the `suppressDocumentReset` path), because a page reorder would make snapshot skip-indices stale. Document-rebuild actions (swap/booklet/A3) are intentionally **not** undoable here.

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

1. User drags in a PDF. `onChange` calls `isA3Landscape` → shows `A3SplitChoiceView` sheet. The sheet is passed `firstPage: pdfDocument.page(at: 0)` and renders its `thumbnail(of:for:)` (display orientation, so rotation is honoured) as the diagram background, with the "1 / Left half" and "2 / Right half" markers overlaid on a centre divider instead of abstract rectangles. Falls back to a plain rectangle if the page is nil.
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

- **`instrumentNames: [String]`** — the **selected ensemble's** score order (`InstrumentOrders.getOrder(for: prefixEnsembleType).map { $0.capitalized }`), used as the autocomplete + "next instrument" source across all rows. It's ensemble-specific (not the old `orchestra+band+jazz` union) so suggestions follow that ensemble — e.g. in a band Horn follows Trumpet, in an orchestra it precedes. Switches live when the ensemble changes (sticky `@AppStorage("prefixEnsembleType")`, auto-inferred). (The old `InstrumentOrders.allNames` union was removed.)
- Auto-scrolls to the focused row via `.onChange(of: focusedField)` + `ScrollViewReader.scrollTo(_:anchor:.center)`.

**Preview panning** (shared by the splitter and Bulk renamer — both use `SplitFileNamingRow`): besides the chevron arrow buttons, the preview is **draggable** — all rows share `previewOffset`. The main strip's `panOverlay` carries a `DragGesture` (grab-the-paper direction: drag right → see left, drag down → see up), converting screen→PDF points via the strip's captured `stripSize` and the `.fill` scale. The minimap `PageCropOverview` takes an `onPanBy` callback and is dragged by direct manipulation (move the indicator). Both feed `SplitFileNamingRow.applyPan(_:)`, which adds the delta to `previewOffset` and clamps to the page's valid range (`cropDims`).

**Step 3 ensemble choice (band/jazz/orchestra) is sticky.** The segmented picker writes to `@AppStorage("prefixEnsembleType")`, so it persists across splits and launches (shared by key with `SplitView` and `BulkRenameView`). **Auto-inference is high-confidence only** — `inferredSplitSuggestionEnsemble(_ orderedSuffixes: [String])` (names passed in file order) returns:
- `.orchestra` if a bowed string (violin/viola/cello) appears anywhere — never present in band/jazz. ("string bass"/"double bass" are excluded: jazz uses an upright string bass.)
- `.jazz` if the *first named part* is a saxophone — band/orchestra always lead with flute/piccolo, so sax-first means jazz. (A sax later in the list is **not** a signal — wind bands have saxes too.)
- `nil` otherwise, leaving the sticky choice untouched.

Because a plain wind-band list (flute first, no strings) triggers neither rule, no "manual lock" flag is needed — `@AppStorage` alone keeps the user's choice sticky. The `onChange(of: customFileNames)` handler fires the inference at most once per naming session (`hasInferredEnsemble`), so it won't fight manual edits, but it *can* override the displayed value when a real signal appears (e.g. strings showing up switches to orchestra). (Earlier versions inferred from only the first suffix and matched band before strings, so flute always won and orchestra was never detected.)

#### Prefix numbering — shared with the Score Order Sorter
`PrefixOrderStepView` (splitter Step 3 **and** Bulk Part Rename Step 2) numbers via the top-level pure function **`scoreOrderNumbers(forOrderedItems: [PrefixItem]) -> [Int: Int]`**, mirroring `scanFolder`: **score → 0**, manually-numbered items keep their number (reserved), everything else auto-numbers from **1** up skipping reserved numbers — so `00` is always reserved for the score, even when absent. `PrefixItem` carries `isScore` (set in `autoSorted`), `manualNumber` (forced number → others reflow; set via the double-click badge popover `PrefixEditSheet`, now numeric), and `isSkipped` (per-row skip control; excluded from output + numbering). **The same function drives both the Step 3 preview and the save** (`applyPrefixToFolder` adds skipped segments' pages to `skippedPages`; `applyPrefixAndRenameBulk` skips renaming) so display == saved names. (Previously the preview was 0-based and the save independently re-derived 1-based and ignored the old free-form `customPrefix` — display ≠ save, and no `00` reservation.) `scoreOrderNumbers` is unit-tested (`ScoreOrderNumberingTests`); `scanFolder` itself was left unchanged but matches the same rules.

#### `SplitFileNamingRow` autocomplete

**Identity, single source of truth:** `instrumentIdentityKey(_:)` answers "which instrument is this" — collapsing every alias incl. reversed sax forms (via `preferredInstrumentDisplayName`) and the alias table (`splitSuggestionGroupKey`, now a private detail used only here). Used by typical-part-count, the alias-skip, and the dropdown's used-set. **`nextDistinctInstrumentIndex(after:in:)`** is the one place that finds "the next instrument after this one" (skipping aliases of `prev`); both the dropdown (`nextSuggestionIndex`, which adds the bassoon-after-bass-clarinet straggler) and the cross-boundary (`splitSuggestionStartingNumberedName`) call it.

**`nextExpectedIndex: Int`** — scans rows above (nearest first) for the last recognised instrument, then `nextSuggestionIndex(after:in:usedKeys:)`. Rotates the suggestion list so the most likely next instrument appears first.

**`numberedSuggestion: String?`** — if the nearest previous suffix ends with a space + integer (e.g. "Flute 1"), returns the next part. Within a family it increments ("Flute 1" → "Flute 2"); once the number reaches the family's typical count (`splitSuggestionTypicalPartCount`, ensemble-specific) it crosses to the next instrument. Clef pairs take priority ("Baritone BC" → "Baritone TC" via `clefCompanion`, which is just `preferredInstrumentDisplayName` + a BC/TC swap).

**`splitSuggestionTypicalPartCount(_:)`** — hardcoded per-family part counts that drive the cross-boundary rollover (default 2 for unlisted families). Counts are **global** (not per-ensemble), so they compromise across educational concert band and jazz big band: trumpet 4, cornet 3, trombone 4, horn 4, clarinet 3, violin 3, alto sax 2, tenor sax 2, flute/oboe/bassoon 2, and single-part families (bass trombone, tuba, euphonium, baritone, piccolo, viola, cello, double bass, timpani, English horn, baritone/soprano sax…) at 1. **Cross-boundary into a single-part family is bare** — after "Trombone 4" the suggestion is "Bass Trombone", not "Bass Trombone 1" (the `> 1` guard in `splitSuggestionStartingNumberedName`). If counts ever need to differ by ensemble, this table would key on `EnsembleType`.

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

## Tab 4 — Stamp

A reusable **text stamp** ("Example School Band", "Property of XYZ") burned onto output pages. Its own tab (⌘5) designs the stamps and applies them to PDFs that already exist; **Combine and Split reuse the same saved stamps** via the `StampMenuButton` in their top toolbars.

### Model & logic — `Logic/StampLogic.swift`

| Symbol | Purpose |
|--------|---------|
| `Stamp` | `Codable` design: `name`, `text` (plain mirror), **`richTextData`** (RTF — the source of truth when present, so bold/italic/font/size/colour can vary run by run), `positionX`/`positionY`, `margin`, `fontFamily`/`isBold`/`isItalic`/`fontSize`/`colourHex` (**base** attributes: used when there's no rich text, and inherited by newly typed text), `hasBorder`. `isDrawable` is false for all-whitespace text. **Scope is deliberately not here** (see `StampJob`). `init(from:)` is hand-written: every key is `decodeIfPresent` + default, so fields can be added later without invalidating `stamps.json`, and a pre-drag `anchor` string is migrated to the equivalent position. |
| `StampJob` | `stamp` + `scope` — one stamping request. Keeps every export API to a single optional parameter (`nil` = don't stamp). `pageIndices(pageCount:partFirstPages:)` resolves the scope to a page set. |
| `StampAnchor` | The nine **presets** only — not stored on a stamp. `position` gives the fractions, `grid` is the row-major picker layout, `Stamp.move(to:)`/`matches(_:)` apply and detect one (so the grid shows nothing selected after a free drag). |
| `StampScope` | `.everyPage` or `.firstPageOfEachPart` — a **per-job** choice, stored per tool in `@AppStorage` (`combineStampScope`, `splitStampScope`, `stampTabScope`), never on the design. |
| `stampRect(for:textSize:in:)` | Places the box at `positionX`/`positionY` — fractions of the **travel** available inside the margins, so 1 means flush against the margin, not off-page. **PDF user space is y-up**, so `positionY == 1` is the top. Fractions are clamped. |
| `stampAttributedString(_:)` | What actually gets drawn: the decoded rich text, else the plain text in `stampBaseAttributes`. `Stamp.alignment` is applied over the whole range **without** clobbering per-run fonts/colours — deliberately not carried in the RTF, so the control stays authoritative. |
| `StampTextAlignment` | left / centre / right for the stamp's own lines. **Stored, not derived** — it used to be inferred from `positionX`, which meant dragging a multi-line stamp re-flowed its text. `derived(fromPositionX:)` survives only to migrate stamps saved before the control existed. |
| `stampRichText(_:)` / `stampRTFData(from:)` | RTF decode/encode. Empty rich text is treated as none, so a cleared editor falls back rather than drawing nothing. |
| `stampBoxSize(for:textSize:)` / `stampTravel(for:boxSize:in:)` | Box size (text + `stampPaddingH/V` when `hasBorder`) and the room it has to move. `stampTravel` is also the **denominator when converting a drag into a position** — a zero axis means the box fills that axis and simply sits at the margin. |
| `drawStamp(_:in:pageBox:)` | The single drawing routine — CoreText frame + optional rounded border. Used by **both** the flattener and the preview, so they can't diverge. |
| `stampedDocument(_:stamp:pageIndices:)` | The flattener (below). Returns nil for an empty doc or a blank stamp. |
| `applyingStamp(_:to:partFirstPages:)` | The call-site helper: applies a `StampJob?` inline, returning the document **unchanged** when there's nothing to stamp or the flatten fails. This is what every export path calls. |
| `stampPagePreviewImage(page:maxDimension:)` | Bitmap of page 1 (or a blank A4 sheet) **without** any stamp — the preview's cached background layer. |
| `visualPageBox(for page: PDFPage?)` | The origin-normalised, rotation-swapped crop box (A4 when nil) — shared by the preview and the drag maths so both agree with the flattener. |
| `nsColor(fromHex:)` / `hexString(from:)` | `#RRGGBB` round trip for storage and the `ColorPicker` binding. |

**How flattening works** — `doc.dataRepresentation()` → `CGPDFDocument` → redraw every page into one multi-page `CGPDFContext`, stamping the listed pages. Going via CGPDF (not `PDFPage.pageRef`) is deliberate: Combine's image pages (`PDFPage(image:)`) and blank pages (bare `PDFPage()`) have no `pageRef`. Each output page uses `visualPageBox` — the **crop box**, w/h swapped when `rotationAngle % 180 != 0` — and `getDrawingTransform`, which absorbs the page's `/Rotate`, so the stamp is placed in *visual* coordinates. Two consequences: **source annotations/links are dropped**, and **outlines don't survive** (so Combine stamps *before* building its `PDFOutline`; page indices are unchanged).

### Store & UI — `Stamp/`

- **`StampStore: ObservableObject`** → `stamps.json` in `~/Library/Application Support/ScoreSort/` — the **third** independent store (see `EnsemblePresetStore`, `InstrumentOrders`). Same shape as `EnsemblePresetStore`; seeds one starter stamp so the picker is never empty. `updateStamp` early-returns when nothing changed **and** routes through `scheduleSave()`, a 0.4 s debounce — encoding and atomically writing the whole store on every keystroke was part of why the text fields felt laggy. `save()` (immediate) is used for add/duplicate/delete, and `flushPendingSave()` runs when leaving the tab.
- **`StampView`** (tab 4) — left column is the designer (stamp picker, name, text, font/size/colour/border, the nine position presets, margin) driving a `draft: Stamp?` pushed back to the store `.onChange`; right column is the draggable preview plus the batch path. Publishes a `TabSlice` guarded on `selectedTab == 4`: Add Files ⌘O / Stamp Files ⌘S / Clear ⌘⌫, plus Actions rows **New Stamp ⌘N**, **Duplicate Stamp ⌘D**, Delete Stamp, Previous/Next Page (clickable only — the keys are bare ← →), and Show in Finder ⇧⌘F (reveals the *previewed* file). ⌘N/⌘D are free app-wide because `FileCommands` replaces File ▸ New with "Open…" on ⌘O, and the rows only exist while Stamp is active.
- **`FontFamilyPicker`** (private, in `StampTab.swift`) — the font popup holds ~300 rows, so it's extracted and `Equatable` on the family alone and used with `.equatable()`. Otherwise SwiftUI rebuilt all of them on every keystroke anywhere in the tab, which was the main source of typing lag.
- **`StampTextEditor` + `StampTextFormatter`** (`Stamp/StampTextEditor.swift`) — the stamp text is a real rich-text field: an `NSTextView` in `isRichText` mode (SwiftUI's `TextEditor` can't carry attributes on macOS 14), written back to the stamp as RTF on every change. `StampTextFormatter` lives on `AppState` so the **Format menu (⌘B / ⌘I)** can reach it, and it's inert (`isAvailable == false`) when no stamp editor exists. It **applies** to the selection, or the whole text when nothing is selected (`effectiveRange`). Its **state** is a different question and uses `hasTrait`: the whole selection when there is one (a mixed selection reads as off, so clicking bolds all of it), otherwise the caret's `typingAttributes` — so the buttons track the cursor as it moves between a bold run and a plain one. Toggling reads the same `hasTrait`, so the lit button always predicts what a click will do. Don't use `effectiveRange` for state: widening an empty selection to the whole string made the buttons describe the document rather than the cursor. The Style buttons use `.toggleStyle(.button)` and read their state from the formatter; the alignment segmented control sits beside them and binds straight to `Stamp.alignment` (it's a property of the stamp, not of the selection). Font/Size/Colour controls both update the stamp's base attributes *and* apply to the selection.
  - `refreshState()` guards every assignment (writing the same value to an `@Published` still fires `objectWillChange`), and `makeNSView`/`updateNSView` must call **`refreshStateSoon()`** — publishing from inside those is what produces SwiftUI's "Publishing changes from within view updates" warning.
  - The coordinator reloads the text view **only when a different stamp id is being edited** — rewriting it from the model on every update would fight the user's typing and drop the selection.
- **`StampPreviewCanvas`** (private, in `StampTab.swift`) — **three layers, for drag performance**: (1) the page as a cached `NSImage` from `stampPagePreviewImage`, re-rendered only when the page changes; (2) the stamp in a SwiftUI `Canvas` calling the shared `drawStamp`, so it stays faithful but costs ~nothing to redraw; (3) a transparent drag handle over the stamp (dashed highlight on hover). Dragging therefore redraws text only. The `Canvas` layer applies `translate(0, h)` + `scale(1, -1)` to turn Canvas's top-left/y-down space back into PDF's bottom-left/y-up before calling `drawStamp`, then scales page points → view points. The drag converts view points → page points → a fraction of `stampTravel`, from the position captured at gesture start, clamped to 0…1 (negating y).
  - **The first version was unusably laggy** because it re-loaded the PDF from disk *and* re-rendered the whole score page every frame. `StampView` also caches the preview page (`previewPage` + a retained `previewDocument` — a `PDFPage` can't draw once its document is released) instead of computing it per redraw. Don't reintroduce either per-frame cost.
- **Preview navigation** — `fileIndex` + `pageIndex` walk the **whole queue**: `previousPage`/`nextPage` cross file boundaries (stepping back lands on the previous file's *last* page), `firstPage`/`lastPage` go to the ends of the queue, `previousFile`/`nextFile` jump whole files. Keys match the Split and Rotate tabs — **← → pages, ⌘← ⌘→ ends, ↑ ↓ files** — in an `.onKeyPress` guarded on `selectedTab == 4` **and** on `NSApp.keyWindow?.firstResponder is NSTextView`, so arrows still belong to the rich text editor while typing. `clampPreviewPosition()` keeps the position valid after the queue changes. In `.firstPageOfEachPart` scope the stamp is still drawn on later pages (so it can be positioned from any of them) but the nav bar says in orange that the page won't be stamped.
- **Input** — a drop anywhere in the tab is accepted (`.onDrop` on the tab's outer container, not on the drop zone), routed through the shared `collectDroppedFileURLs` and `expandToFiles(_:extensions:)`, so **folders expand recursively** to their PDFs, name-sorted, exactly as the Combine tab and Renamer behave. The first file becomes the preview page. "Add Files…" allows folders too.
- **Batch output** — `items: [StampFileItem]` (url + editable `outputName`) and `StampOutputMode`: **`replaceOriginal` is the default** (writes over the file in place, behind one `confirmNSAlert`, names not editable — the file keeps its own), or `saveAsNew` (folder picker, per-file names validated by `pdfFilenameError` plus empty/duplicate checks via `nameProblem`, and a single confirm listing any destinations that already exist). One `write(_:job:)` does both. A standalone file is one "part", so first-page scope means its page 1.
- **`StampMenuButton`** — the pull-down in Combine's and Split Step 1's top toolbars: on/off toggle, which saved stamp, which pages, and "Edit Stamps…" (switches to tab 4 — tabs stay mounted, so no work is lost). Label reads "Stamp" or "Stamp: ⟨name⟩"; icon is `seal`/`seal.fill`.

### Where it applies

| Tool | Insertion point | "Each part" means |
|------|-----------------|-------------------|
| Combine | `CombineManager.buildDocument(addBlankPages:stampJob:)` — shared by `createCombinedPDF` and `openInPreview` | each source file per copy (the existing `bookmarks` page indices) |
| Split | `PDFManager.saveSplitPDF(… stampJob:)` — the one choke point for both save routes | page 0 of each output file |
| Stamp tab | `StampView.writeStampedFiles` | page 0 of each added file |

The Rotate tab is deliberately excluded — it works in rotation *metadata*, which flattening would bake in.

---

## Shared Infrastructure

**`PDFAlertHandler`** — `typealias PDFAlertHandler = (_ title: String, _ message: String, _ isError: Bool) -> Void`. All PDF save/export methods take this callback; they never show UI directly.

**`PDFManager: ObservableObject`** — used by both SplitView and RotateView (separate instances). Holds `pdfDocument`, `currentFileName`, and **`sourceURL`** (the file the user loaded, set in `loadPDF(from:)`; survives in-place `pdfDocument` rebuilds like A3 split / booklet reorder, so it outlives `PDFDocument.documentURL`).

**`expandToFiles(_ urls: [URL], extensions: Set<String>) -> [URL]`** — flattens a mixed file/folder drop into name-sorted files with the given (lowercase, dotless) extensions; folders are enumerated **recursively**. Shared by `CombineView.expandToSupportedFiles` (PDFs + images) and the Stamp tab (PDFs only), so folder drops behave identically. Pair it with `collectDroppedFileURLs(from:completion:)` and `urlIsDirectory(_:)` in `Logic/RenameLogic.swift` for a full drop handler.

**`outputDirectory(forSourceFile:) -> URL?`** — returns a source file's parent folder (nil-safe). Every output dialog sets `panel.directoryURL` from it so saves default to the **source file's folder** rather than the last-used location: combiner save (first non-blank input file), rotate save and both splitter output-folder pickers (`pdfManager.sourceURL`). The preset CSV export is intentionally excluded (no per-document source).

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
- **Instrument orders versioning** — `instrument-orders.json` carries a `"_version"` sentinel; `InstrumentOrders.setup()` regenerates the file on launch if it's older than `defaultsVersion`. **Bumping `defaultsVersion` overwrites the file with the defaults — it resets any user-customised order.** Bumped 3→4 (orchestra clarinet order: `eb clarinet` precedes `clarinet`) then 4→5 (band: removed the stray `"baritone"` from the **sax** section so baritone/euphonium brass no longer sorts with the saxes; reordered the low brass as baritone-group-before-euphonium with period clef forms `baritone b.c.`/`t.c.`).
- **Suggestion display names** — the Step 2 autocomplete source is the **selected ensemble's** order (`getOrder(for: prefixEnsembleType)`), which still contains every alias for *detection*, but the suggestion surfaces canonicalise the saxophone family to full names via `preferredInstrumentDisplayName(_:)` — applied in `splitSuggestionDisplayNames` (dropdown dedup) and `splitSuggestionStartingNumberedName` (cross-boundary, which also skips same-instrument aliases via `instrumentIdentityKey`). So suggestions read "Alto Saxophone", not "Alto Sax", while `detectInstrument` still matches "alto sax". (Replaced the old `saxStyleMatch`, which preserved the user's abbreviation.)
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
- **Stamping flattens, so it must run before outlines are built** — `stampedDocument` rebuilds page content via a `CGPDFContext`, which drops the document's `PDFOutline` and any source-page annotations. Page indices survive, so `CombineManager.buildDocument` stamps first and then builds the outline from the same bookmark indices. Anything else that adds document-level structure must do the same.
- **The stamp flattener reads the crop box, not the media box** — A3-split pages keep a full-sheet media box with a half-sheet crop box, so using the media box would resurrect the discarded half. `visualPageBox` also swaps w/h for 90°/270° pages, and `getDrawingTransform` bakes the rotation, so stamps land where the user *sees* them.
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
| `StampPlacementTests` | `stampRect` — all nine presets stay on the page, margins per edge, border padding, non-zero page origin (`StampLogicTests.swift`) |
| `StampFreePositionTests` | Free positioning/drag maths — fractions map onto `stampTravel`, out-of-range clamped, margin bounds travel, an oversized stamp has no travel, preset round trip, a dragged stamp matches no preset |
| `ExpandToFilesTests` | `expandToFiles` — recursive folder expansion, name sorting, case-insensitive extension filter, plain files, missing paths, mixed file+folder drops |
| `StampRichTextTests` | RTF round trip of per-run fonts/colours, rich text winning over base attributes, alignment not flattening runs, base-attribute fallback, empty rich text ignored, rich text surviving `Stamp` coding |
| `StampCodingTests` | `Stamp` encode/decode round trip, migration of a pre-drag `anchor` (and a stale `scope`), and defaults for missing fields |
| `StampScopeTests` | `StampJob.pageIndices` — every-page vs first-page-of-each-part, out-of-range part pages dropped, blank-job detection |
| `ApplyingStampTests` | `applyingStamp` — nil and blank jobs pass the document through by identity; a drawable job returns a new document with the same page count |
| `StampFlatteningTests` | `stampedDocument` — page count preserved, partial stamping, blank stamp/empty doc rejected, write-reload round trip, 90°-rotated page comes out landscape, A3 crop box wins over media box |
| `StampColourTests` | `nsColor(fromHex:)` / `hexString(from:)` round trip and black fallback |
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
| `SplitEnsembleInferenceTests` | `inferredSplitSuggestionEnsemble(_:)` — flute alone → nil, bowed string → orchestra, first part sax → jazz, sax-not-first → nil, strings beat sax, leading blanks skipped, case-insensitive, ambiguous band instruments → nil, upright/double bass → nil, empty → nil |
| `SplitNumberedSuggestionTests` | `splitSuggestionTypicalPartCount` is **ensemble-specific** (band: 3 trumpets, 1 tenor sax, 3 trombones; jazz: 4 trumpets, 2 tenor saxes, 4 trombones; default = band; single-part = 1, unknown → 2); `splitSuggestionStartingNumberedName` cross-boundary (single-part next is bare e.g. "Bass Trombone"/band tenor sax, multi-part keeps "1", below typical → nil, skips same-instrument aliases, ensemble-specific trumpet crossing) |
| `OutputDirectoryTests` | `outputDirectory(forSourceFile:)` — parent folder of source file, nil → nil |
| `RenamableFileTests` | `isRenamableFile(_:)` — accepts PDF + all image extensions, case-insensitive, rejects non-media / no extension |
| `QualifiedFolderNameTests` | `qualifiedFolderName(for:among:)` — single folder, distinct siblings, same-name-different-parent disambiguation, shared-parent collapse |
| `JobFolderExpansionTests` | `expandToRenameJobFolders(_:)` — folder of PDFs = 1 job, parent-of-folders batches children, nested at any depth, image scans count, no-renamable → empty, parent + PDF subfolder both jobs |
| `ScoreOrderNumberingTests` | `scoreOrderNumbers(forOrderedItems:)` — score→00 + instruments→01+, no-score still starts at 01, manual number reserved with reflow, auto skips reserved, skipped omitted (gap closed), all-manual, empty |
| `PreferredInstrumentNameTests` | `preferredInstrumentDisplayName(_:)` — sax family (any spelling/order) → full "X Saxophone"; baritone/euphonium clef variants → "X B.C."/"X T.C."; bari *sax* stays a saxophone (distinct identity from baritone brass); non-sax names unchanged |
| `NextSuggestionIndexTests` | `nextSuggestionIndex(after:in:usedKeys:)` — skips same-instrument aliases to next distinct; offers unused bassoon after bass clarinet; nil for unrecognised |

**Not covered:** collate group logic (no unit tests yet — `createCollateGroup`/`dissolveGroup`/`updateGroupCopies` and the collated PDF output loop); rescan mode stripping; `performRename()` filesystem operation; `applyBookletOrder` state mutations; UI/integration tests.

---

## Releasing & Sparkle Auto-Updates

ScoreSort ships via **direct distribution** (GitHub Releases) with **Sparkle 2** auto-updates. Not App Store / TestFlight.

### How it's wired
- **Sparkle package**: `XCRemoteSwiftPackageReference` to `sparkle-project/Sparkle` (up-to-next-major from 2.9.1). The product is linked to the **ScoreSort** target (`packageProductDependencies` + a `PBXBuildFile` in the app's Frameworks phase). If updates ever stop building with "no such module Sparkle", that link is what's missing.
- **Code**: `import Sparkle`; `UpdaterViewModel` (wraps `SPUStandardUpdaterController`); injected as `@StateObject` on `ScoreSortApp`; **Check for Updates…** menu item via `CommandGroup(after: .appInfo)`. To build an App Store/TestFlight variant, comment these back out (Sparkle must not ship in MAS builds).
- **Deferred first-launch start**: `UpdaterViewModel` inits the controller with `startingUpdater: false` and only calls `startUpdater()` once `appLaunchCount` (in `UserDefaults`, incremented each init) reaches **2**. This suppresses Sparkle's "check for updates automatically?" permission prompt on a brand-new user's *first* launch — it appears on the second launch instead. Manual **Check for Updates…** starts the updater on demand (`startUpdaterIfNeeded()`), so it still works on first launch.
- **Launch-quit guard**: `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns the static `mainWindowHasAppeared` flag (set true in `ContentView`'s `.onAppear`), **not** an unconditional `true`. Reason: at launch Sparkle's dialog can appear before the async `WindowGroup` window exists, and dismissing it would otherwise read as "last window closed" and quit the app before the main window shows. Don't revert this to `return true`.
- **Info.plist**: `SUFeedURL = https://benperche.github.io/ScoreSort/appcast.xml`, `SUPublicEDKey = 6Dj8WlfDC/fWZMetFfw7XObJTa9fOsyXGuHDpxjYFYY=`.
- **Appcast**: `docs/appcast.xml`, served by **GitHub Pages** from the repo's `docs/` folder. Downloads (DMGs) are **GitHub Release assets**.
- **Signing key**: the EdDSA **private key lives in the login Keychain** (paired with `SUPublicEDKey`). Verify with `generate_keys -p` (prints the public key — must equal `SUPublicEDKey`). Sparkle CLI tools (`sign_update`, `generate_keys`, `generate_appcast`) are in the resolved package artifacts: `~/Library/Developer/Xcode/DerivedData/ScoreSort-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`.

### How updates are detected
Sparkle compares each appcast item's `sparkle:version` (= **CFBundleVersion** / `CURRENT_PROJECT_VERSION`) against the running build. **`CURRENT_PROJECT_VERSION` must strictly increase every release** or no update is offered. `MARKETING_VERSION` is the user-visible `1.x` string (`sparkle:shortVersionString`).

### Release checklist (per version)
1. Bump **`MARKETING_VERSION`** and **`CURRENT_PROJECT_VERSION`** (build number — must increase) in both Debug/Release configs.
2. Xcode: Product ▸ Archive ▸ Distribute App ▸ **Direct Distribution** (notarizes + staples the `.app`).
3. Build a `ScoreSort.dmg` containing the notarized app; notarize + `xcrun stapler staple` the DMG.
4. Sign the DMG: `sign_update ScoreSort.dmg` → copy the `sparkle:edSignature` and `length`.
5. Add an `<item>` to `docs/appcast.xml` (template is in the file): `title`, `sparkle:version` (build no.), `sparkle:shortVersionString`, `pubDate`, `releaseNotesLink` (the GitHub release tag URL), and `enclosure` (`url` = release asset, `sparkle:edSignature`, `length`).
6. Create GitHub Release `vX.X`, attach `ScoreSort.dmg` (asset name must match the enclosure URL).
7. Commit + push `docs/appcast.xml` → Pages serves the new feed → existing users are offered the update.

**Stable download URL** (for the website's button): `https://github.com/benperche/ScoreSort/releases/latest/download/ScoreSort.dmg` always resolves to the newest release's asset.

**Gotchas:** keep the asset filename consistent (`ScoreSort.dmg`); an appcast item with a wrong `length`/`edSignature` makes Sparkle reject the update; un-notarized updates still install but re-trigger Gatekeeper's warning on each update.
