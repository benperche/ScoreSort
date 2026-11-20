# Combine PDFs (tab 0, ⌘1)

Files, all in `ScoreSort/Combine/` (split out of one 3,000-line file for #14): `CombineTab.swift` (`CombineView` only: the list, keyboard handling, menu bridge, applying a preset), `CombineManager.swift` (`CombineFile`, `CollateGroup`, `CombineLayout`, `CombineOutputOptions`, `CombineManager`), `EnsemblePresetStore.swift` (the preset model, store and templates), `PresetViews.swift` (`PresetPartRow`, `NewPresetSheet`, `PresetSidebarView`), `CombineRows.swift` (`CombineFileRow`, `CollateGroupHeaderRow`, the fixed list colours), `BookletSetupViews.swift` (`CombineSheet`, `BookletIntroView`, `BookletDuplexSetupView`, `CombineOutputMenuButton`, `BookletScaleField`), `Combine/CombineQuickLook.swift` (Space to preview), `Combine/BookletLayoutSheet.swift` (booklet page-turn review), `Logic/PresetMatching.swift` (`matchPreset`), `Logic/InstrumentNames.swift` (name matching), `Logic/ImagePages.swift` (images → pages), `Logic/FileUtilities.swift` (bookmarks that follow moved files), `Logic/PDFSaving.swift`, `Logic/OutlineLogic.swift`. The Combiner settings pane (`CombinerPreferencesView`) is in the main file.

Booklet output and printing have their own file: [printing-booklets.md](printing-booklets.md). Stamping: [stamp.md](stamp.md). The command line's `combine`, `presets` and `allocate`: [cli-mcp.md](cli-mcp.md). Menu slice and keyboard gating: [shared.md](shared.md).

Gotchas that concern this tab: [gotchas.md § Combine](gotchas.md#combine), [§ PDFKit and PDF geometry](gotchas.md#pdfkit-and-pdf-geometry) (outlines, stamping order), [§ Menus and keyboard](gotchas.md#menus-and-keyboard), [§ Printing and booklets](gotchas.md#printing-and-booklets).

- **View:** `CombineView` · **View model:** `CombineManager: ObservableObject` · **Models:** `CombineFile`, `CollateGroup` · **Rows:** `CombineFileRow`, `CollateGroupHeaderRow` · **Sidebar:** `PresetSidebarView` (Presets toolbar button, ⌥⌘P)

## Data models

`CombineFile: Identifiable, Equatable, FollowsMovedFile`
- `id` (auto UUID), `url` (where the file was last found), `name` (`url.lastPathComponent`, with extension; follows renames), `pageCount`
- `copies` — ignored when `collateGroupId` is set
- `collateGroupId: UUID?` — non-nil when the file belongs to a collate group
- `isBlankPage` — a synthetic blank entry (a page of `CombineOutputOptions.paper`); `url` is unused
- `bookletLayout: BookletPartLayout?` — booklet output only; nil means "whatever suits this length". `effectiveBookletLayout` resolves it through `bookletDefaultLayout(pageCount:)`
- `bookmark: Data?` — made in `addFiles`; finds the file again after a move or rename in Finder

`CollateGroup` (`id`, `copies`) — a set of files whose pages are interleaved: 4 copies of [Perc 1, Perc 2, Timpani] → P1,P2,T, P1,P2,T, …

`CombineLayout` (`.singlePages` / `.booklet`) and `CombineOutputOptions` (`layout`, `sheetSize`, `bookletPageScale`, `addBlankPages`, `singleSided`, `duplexFlip`) describe the *shape* of the output. `CombineView.outputOptions` assembles them from `@AppStorage` (`combineLayout`, `combineBookletSheetSize`, `combineBookletScalePercent`, `combineSingleSided`) plus the per-printer `duplexFlip`.

## CombineManager

`@Published var files: [CombineFile]` and `@Published var collateGroups: [UUID: CollateGroup]`.

**Undo:** `registerUndo(undoManager:actionName:restoringFiles:restoringGroups:)` snapshots **both** together so undo/redo always restores a consistent pair. Every mutating method captures `files` and `collateGroups` before mutating.

| Method | Notes |
|--------|-------|
| `addFiles(urls:undoManager:)` | PDFs and images (JPEG, PNG, TIFF, HEIC, BMP, GIF). PDFs use `PDFDocument.pageCount`; images use `CGImageSourceGetCount`. Appends with `copies = 1`, no group, and a `fileBookmark(for:)`. |
| `refreshFileLocations()` | Calls `followMove()` on each real file; if it moved or was renamed, updates `url` **and** `name` (so the list and the table of contents match the file). Called at the top of all three outputs and by `CombineView.createPDF()` before the save panel, so the panel opens in the file's *current* folder. A file it can't find keeps its old path and is then reported by name. Not undoable: it's a sync, not an edit. |
| `addBlankPage(after:undoManager:)` | Inserts a blank entry after the last selected file, or at the end. |
| `removeFiles(ids:undoManager:)` | Removes files and dissolves any group left with fewer than 2 members. |
| `updateCopies(for:copies:undoManager:)` | Clamps to a minimum of 1. |
| `clearAll(undoManager:)` | Clears files and groups. |
| `setBookletLayout(_:for:undoManager:)` / `applyBookletLayoutToUndecided(_:including:undoManager:)` | Per-part booklet layout; the second leaves parts someone has already decided on, and returns `(applied, kept)`. |
| `moveUp/moveDown(ids:undoManager:)` | `swapAt` block moves. `CombineView` expands the set through `expandForGroups()` first, so a collate group moves as one unit. |
| `move(ids:before:undoManager:)` | Drag-to-reorder: pulls the moving files out (order kept) and re-inserts the block before `targetId` (or appends when nil). |
| `addToGroup(ids:groupId:undoManager:)` | Drag-onto-group: reassigns the files to the target group, inserts them after its last member, then `cleanupSmallGroups()` dissolves any source group left with fewer than 2. |
| `createCollateGroup(fileIds:undoManager:)` | Pulls the selected files together at the position of the first one and gives them a shared group id (`copies: 1`). |
| `dissolveGroup(id:undoManager:)` / `updateGroupCopies(id:copies:undoManager:)` | Ungroup; set the group's copy count (min 1). |

**Totals.** `totalFiles` and `totalPages` walk `files` once, detecting group runs: a standalone file contributes `copies` / `pageCount × copies`; a group contributes `memberCount × group.copies` / `sumOfMemberPages × group.copies`. `totalBookletSheets` mirrors `buildDocument`'s segmentation to count *sheets of paper*: every copy of every real file starts a new booklet, blank-page entries join the booklet before them, and each booklet is `bookletPaddedCount(pages) / 4` sheets.

### Output

All three outputs — `createCombinedPDF(to:options:stampJob:completion:)`, `openInPreview(options:stampJob:onError:)` and `printCombined(options:stampJob:in:onError:)` — call `refreshFileLocations()` and then the private `buildDocument(options:stampJob:rotateBackFaces:)`, which returns `(doc, pageCount, bookmarks, unreadable)`. They can't drift apart. `rotateBackFaces` is the duplex compensation and is passed **only by `printCombined`** (see [printing-booklets.md](printing-booklets.md)).

**Inputs are reopened at build time, not when added.** This was the bug behind a long-running bare "Failed to create PDF": files dragged in and then moved in Finder were silently skipped until the document was empty. Now moves and renames are followed by bookmark, and `unreadable` lists whatever still can't be opened (deleted, binned, replaced, damaged, or refused by macOS), each once, in list order. All three outputs stop on a non-empty list with `unreadableFilesMessage`, which re-reads each file to give macOS's own reason. Nothing is saved, because a set of parts with one silently missing is worse than no file. Saving goes through `savePDFDocument(_:to:)`, which returns the real error text instead of `write(to:)`'s bare Bool.

`buildDocument` runs one `while i < files.count` loop with a nested `addPages(from:copyIndex:totalCopies:)`:
- **Standalone file:** all its copies together.
- **Group:** the consecutive files with the same `collateGroupId`, repeated `group.copies` times as a set.
- **Blank entry:** one `PDFPage` of `options.paper` from `createBlankPage(_:)`; no bookmark. The pad after an odd-length part is the same page.
- **Image:** `pdfPages(fromImageAt:paper:)` renders each frame onto a page of `options.paper` (`makePage(from:paper:)`: scaled to fit, white background, the image placed into a real PDF page at its own resolution, capped at `maximumImagePageResolution` (600 ppi) — #36; it used to be redrawn at about 72 dpi). `options.paper` is A4 unless set; the tab and the CLI pass `PaperSize.current` ([shared.md § Paper size](shared.md#paper-size)).
- **PDF:** `PDFDocument(url:)`, pages copied across. With `addBlankPages`, an odd-length file gets a trailing blank **unless the layout is `.booklet`** (padding to a multiple of 4 supersedes padding to 2).

Each real file adds a `bookmarks` entry `(label, pageIndex)` — the filename without `.pdf`, or `"Filename N/Total"` for multiple copies — and a parallel `partLayouts` entry.

**The order is stamp → impose → outline, and it matters:**
1. `applyingStamp(...)` first, so stamps land on *reading* pages. Bookmark page indices double as "first page of each part". If it throws, `stampProblem` is set and all three outputs stop with "Couldn’t Stamp the Parts" (after the `unreadable` check) rather than producing unstamped output.
2. For `.booklet`, `bookletSegments(pageCount:partFirstPages:)` carves the document at the bookmark indices and `imposedBookletDocument(...)` rebuilds it as sheets. Because there is **one bookmark per part per copy**, seven copies of a part become seven separately foldable booklets. Each segment's layout, and each bookmark's new `pageIndex` (`imposed.sheetStarts`), is found by looking up which segment *contains* the reading page, not by position: `bookletSegments` can prepend a segment at page 0, and a file that fails to load contributes a label but no pages.
3. `outlineReadyDocument(from:)` moves the pages into a fresh `PDFDocument()`, then the `PDFOutline` is built and assigned. Without that step macOS 27 saves stamped and booklet output with no table of contents. Each destination aims at the **top-left of the crop box** (`.zero` is the foot of the page in PDF coordinates, which lands a viewer on the next part).

## CombineView

| State | Purpose |
|-------|---------|
| `selectedFiles: Set<UUID>` | selected rows |
| `focusedFileId` / `anchorFileId` | keyboard cursor row / shift-range anchor |
| `listFocused` (`@FocusState`) | whether the list has key focus |
| `showPresetSidebar` | sidebar slide-in |
| `unmatchedFileIds` | files the last preset apply didn't match (orange) |
| `splitCopyFileIds` | files that shared one preset entry's copies (blue, `Color.presetSplit`) — the split is the app's guess |
| `dropTargetId`, `isDropAtEnd`, `mergeTargetGroupId` | drag-and-drop feedback |
| `activeSheet: CombineSheet?`, `showBookletLayout`, `quickLookIndex` | booklet intro / two-sided wizard sheets, and the two overlays |
| `stampEnabled`, `stampScope` (`@AppStorage`) | the toolbar `StampMenuButton`; `activeStampJob` builds the `StampJob` |

**Focus and selection are separate, and only selection is drawn.** The list carries `.focusEffectDisabled()` on purpose. The ring used to sit around the middle of the layout (Combine is the only tab that attaches `.focusable()` to an inner view rather than the whole tab) and marked the one state nobody wonders about. Consequences that look like bugs but aren't — **don't "fix" them**:
- **Tab into the list does nothing visible.** Tab moves focus, not selection; a list that selected a row because you tabbed to it would fight ⌘A and Select None. The first ↓ then selects the first file (`navigateSelection` treats a nil cursor as starting just off the end).
- **`focusedFileId` never sits on an unselected row.** `selectFile`, `navigateSelection` and `selectAll` all point it at a selected row; `selectNone` and ⌘-click-to-deselect clear it. It only shows *within* a multi-row selection (accent 0.18 against 0.10). A background for "cursor but not selected" is dead code; it was tried.
- Combine **never self-focuses the list on appear** (unlike Rotate/Split/Stamp); it takes focus after a click, and `returnFocusToList()` hands it back when an overlay closes.

**Collate helpers.** `expandForGroups(_:)` adds every group-mate of the given ids (used by move up/down and their `can…` flags). `canGroup` is true for 2+ selected files none of which is already grouped. `groupSelected()` calls `createCollateGroup` and clears the selection.

**List rendering.** The list is a `ScrollView`/`LazyVStack`, not a `List`. `ForEach(combineManager.files)` emits a `CollateGroupHeaderRow` before the first member of each group (first = `files.first(where: { $0.collateGroupId == gid })?.id == file.id`), then a `CombineFileRow`. Group headers are virtual: `navigateSelection(direction:extending:)` walks the flat `files` array.

**Drag and drop.** Rows are `.draggable(file.id.uuidString)` with a `dragPreview`; `.dropDestination(for: String.self)` is attached to individual sub-views because they need different actions:
- group header → `handleReorderDrop` (insert *before* the group), with an `insertionLine`
- grouped member row → `handleAddToGroup` (merge into the group), with a whole-group highlight (`isMergeTarget`)
- ungrouped row → `handleReorderDrop` with an `insertionLine`
- trailing `Color.clear` zone → `handleReorderDropAtEnd`

Helpers: `draggedSet(for:)` (the whole selection if the dragged row is selected, else that row; group-expanded), `groupSnappedTarget(_:)` (snaps a target to its group's first member so a drop never splits a group), `setReorderTarget`, `insertionLine(visible:)`. This coexists with the view-level `.onDrop(of: [.fileURL])` (Finder import) because internal drags carry a `String`.

**Collate-group visuals** use `Color.collateGroup` (fixed indigo, never the accent colour, so a group can't read as "selected"): a spine down the leading edge of the header and members, a faint fill on member rows, a closing border under the last member (`isLastInGroup`), and a stronger tint over the whole group during a drag-merge.

**Keyboard.**
- In-view `.onKeyPress` (skipped unless `selectedTab == 0` and `!menuState.isPanelOpen`): ↑/↓ navigate, ⇧↑/⇧↓ extend, ⌘A select all, `c` collate (handled only if `canGroup`), Space opens Quick Look.
- ⌘↑/⌘↓ (Move Up/Down) and ⌘T (Booklet Page Turns…) come from the Actions menu.
- **⌫ / ⌦** is an `NSEvent` local monitor (`installKeyMonitor()`), with the same gates plus: it passes the event through when the first responder is an `NSTextView`, when a sheet is key, or when nothing is selected. It is not a menu shortcut because a disabled `CommandMenu` shortcut would steal backspace from every text field.

**Quick Look** (`CombineQuickLook.swift`). Space shows the cursor row (or first selected, or first part) in `CombineQuickLookView`, an overlay wrapping `QLPreviewView` (`QuickLookPreview`). It uses the view rather than the system `QLPreviewPanel` because the panel wants responder-chain control that is brittle from SwiftUI, and because it renders images as well as PDFs. Its own key monitor handles ←/↑, →/↓, Space and Escape; the preview must be first responder for scrolling to work. `quickLookIndex != nil` sets `menuState.isPanelOpen`.

**Output controls.** `CombineOutputMenuButton` is the one pull-down for the shape of the output (single pages / booklet, sheet size, two-sided setup, add blank pages, single-sided, review page turns); `BookletScaleField` edits the booklet scale. The bottom bar's buttons are then only about where the output goes: Create PDF (`createPDF()`), Open in Preview, Print. `outputSummary` shows files and pages, plus sheets of paper in booklet mode.

**Panels.** `selectFiles()` and `createPDF()` use `beginSheetModal(for:)` and set `menuState.isPanelOpen` around the panel.

**Removal notice.** `showRemovalNotice(count:undoManager:)` shows for 5 s with an Undo button.

### Rows

`CombineFileRow` takes the file plus `isSelected`, `isFocused`, `isUnmatched`, `hasSplitCopies`, `isGrouped` (indents, hides the copies stepper), `isLastInGroup`, `isMergeTarget`, `showsBookletLayout` (+ `onBookletLayoutChanged`), and the callbacks `onToggleSelect` (tick box), `onRowTap` (plain click selects just this row; ⌘ toggles; ⇧ extends), `onCopiesChanged`, `onRemove`. Minus at `copies == 1` calls `onRemove`. `rowBackground` picks, in order: merge target, selected, unmatched (orange), split copies (blue), grouped, blank page.

`CollateGroupHeaderRow` mirrors the columns: stack icon + "Collate Group (N files)" + ungroup button; pages = the members' sum (one complete set); a copies stepper with double-click-to-type editing. `onUngroup` calls `dissolveGroup`.

## Ensemble presets

`PresetPart` (`id`, `name`, `copies`) and `EnsemblePreset` (`id`, `name`, `parts`, optional `stampId`), both `Codable`.

**`EnsemblePresetStore`** (app-level `@EnvironmentObject`): `@Published presets` and `selectedPresetId`; `selectedPreset`. Persisted as JSON at `~/Library/Application Support/ScoreSort/ensemble-presets.json`, loaded on init and saved by every mutating method: `addPreset(name:parts:)`, `updatePreset(_:)`, `deletePreset(_:)`, `movePresets(from:to:)`, `duplicatePreset(_:)` ("Copy of …"), `exportCSV()` / `importCSV(_:)` (`Preset Name,Part Name,Copies`).

- **Reading and writing go through `SavedListFile<EnsemblePreset>`** (`Logic/SavedListFile.swift`, shared with `StampStore`): an unreadable file is set aside under a dated name before anything can save over it, entries decode one by one, and a failed save is reported. Problems are published as `notices` and shown by `SavedFileNoticeBanner` above the tabs, never as an alert. `init(fileURL:)` is injectable (`defaultFileURL`; `nil` = memory only) — **tests never use the default**. The CLI reads the file itself (`savedPresets(at:)`, `readSavedList`), read-only, and says why if it can't. See [gotchas.md § Saved files](gotchas.md#saved-files).

- **No auto-seed.** The store starts empty; both editors show an empty-state prompt.
- **Templates** are static arrays, not stored presets: `windBandTemplate`, `jazzTemplate`, `orchestraTemplate`. The wind band template ships "Euphonium BC" (not bare "Euphonium") so the common Australian-band case is clef-correct out of the box.
- **Independent of the Renamer's instrument orders** (`instrument-orders.json`). The two systems don't interact.

**Preset → stamp link.** `EnsemblePreset.stampId` optionally names a saved stamp (a school's or organisation's mark). `CombineView.applyPresetStamp` selects it and switches stamping **on** when the preset is applied, but only as a default: the toolbar's Stamp button shows what's armed and turns it off in one click. A preset with no stamp leaves the current choice alone. `PresetStampPicker` (in `Stamp/StampTab.swift`) sets it in both preset editors.

**`PresetSidebarView`** — 260 pt panel on the right of `CombineView`. State: `draftParts` (working copy of the selected preset's parts), `isDirty`, `applyResult`, `showingNewPreset`. "Apply to Files" calls `CombineView.applyPreset(parts:stampId:)` through `onApply` and shows matched (green) and unmatched (orange) counts; unmatched parts are tinted in `PresetPartRow`. Revert/Save appear when dirty. `.onChange(of: presetStore.selectedPreset)` reloads the draft when the preset changes elsewhere (the Settings window), guarded by `!isDirty` so unsaved sidebar edits are never clobbered.

**`CombinerPreferencesView`** (Settings ▸ Combiner) — `HSplitView`: a preset list (`.onMove`, up/down chevrons, add/remove, duplicate, CSV import/export) and a parts editor using `PresetPartRow`, a `PresetStampPicker`, and a "Reset to Template…" menu. `.onChange(of: presetStore.presets)` reloads `editingPreset` when the store changes (saves made in the sidebar), guarded against a loop from its own edits.

**`NewPresetSheet`** — template cards (Wind Band / Jazz Band / Orchestra) and a name field; calls `addPreset(name:parts:)`.

**`PresetPartRow`** — shared by both editors: double-click the name or the copies count to edit inline; optional up/down chevrons; minus at `copies == 1` calls `onDelete` (which runs `renumberAfterDeletion`); `isUnmatched` tints it orange.

### Applying a preset — `matchPreset(parts:files:)`

`CombineView.applyPreset(parts:stampId:)` arms the stamp and calls **`CombineManager.applyPreset(parts:undoManager:)`**, which runs `matchPreset` (`Logic/PresetMatching.swift`, shared with the CLI's `combine`/`allocate`), applies `result.copies` through `updateCopies`, and stores `unmatchedFileIds` and `splitFileIds`. `PresetMatchResult` also carries `matchedCount`, `unmatchedPartNames` and `assignments` (which part fed which file).

1. **Direct match.** Parts are tried longest name first (so "Bass Clarinet" beats "Clarinet"). File and part names are lowercased and passed through `normalizeRomanNumerals`; a file takes the first part for which `presetPartMatches(part:in:)` is true. Matches are gathered per *part* before copies are set: one entry matching several files (say "Trumpet: 7" over Trumpet 1 and Trumpet 2) has its copies spread by `splitPresetCopies(_:across:)` — remainder to the earlier files — rather than given to each in full, and those files are marked as split.
2. **Consolidation.** When *every* numbered part of a base name ("Clarinet 1", "Clarinet 2") went unmatched and exactly **one** unmatched file matches the base name (one "Clarinet.pdf"; a "Bass Clarinet.pdf" doesn't count), that file gets the sum (7 + 7 → 14).

Anything more complicated stays unmatched and orange on purpose ([rationale](gotchas.md#combine)).

**Identity-aware matching** (`Logic/InstrumentNames.swift`; both arguments pre-lowercased and roman-normalised):
- `instrumentQualifierWords` — bass, alto, contra(bass), soprano/sopranino, tenor, baritone, piccolo, english.
- `instrumentAliasPhrases(forBase:)` — sax abbreviations and reversed forms, French Horn = Horn, Vln = Violin, Bb Clarinet = Clarinet, clef-aware euphonium/baritone; `[]` if unknown.
- `presetMatchPhrases(for:)` — aliases with the trailing number re-attached; falls back to the literal base for custom names.
- `phraseOccurs(_:in:)` — substring, rejected if preceded by a qualifier word the phrase lacks.
- `presetPartMatches(part:in:)` — true if any phrase occurs.

Notes:
- **Clef matters here, unlike in the splitter.** `instrumentIdentityKey` (Split Step 2) collapses Euphonium/Baritone BC and TC into one identity; this matcher keeps them **distinct** because it decides *which part to print*. "Euphonium BC" matches a bass-clef file (including one spelled "Baritone BC") but never the treble-clef one; a bare "Euphonium" entry matches either.
- The qualifier guard stops a generic root ("Clarinet") matching a more specific instrument ("Bass Clarinet"), which also stops that file blocking the consolidation.
- 1–2 letter abbreviations (Cl, Fl, Tpt) are deliberately *not* aliased (collision-prone). Tested in `PresetPartMatchesTests`.

Supporting functions: `normalizeRomanNumerals(_:)` (trailing " i"/" ii"/" iii"/" iv" → digits; needs the leading space; longest first), `numberedBase(of:)` ("Violin I" → "violin", "Oboe" → nil), `renumberAfterDeletion(_:)` (a sole numbered survivor loses its number: "Horn 1" → "Horn").
