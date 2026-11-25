# Rename Files (tab 1, ⌘2) and "Sort into folders"

Files: `ScoreSort/Rename/RenameViews.swift` (`RenamerView`, `ScoreOrderSortView`, `ManualAssignmentView`, `BulkRenameView`), `Rename/RenamerManager.swift` (`RenamerManager`, `EnsembleType`, `InstrumentOrders`, `RenameOperation`), `Rename/PartFolderPicker.swift`, `Logic/RenameLogic.swift` (folder jobs, score-order numbering, the planner and the mover), `Logic/PartFolders.swift` ("Sort into folders"). The Renamer settings pane (`PreferencesView`) is in the main file. The prefix step that Bulk Rename shares with Split is `Split/SplitPrefixStep.swift` ([split.md](split.md#step-3--prefix-order-prefixorderstepview)).

The CLI's `rename` runs the same planner and mover: [cli-mcp.md](cli-mcp.md). Menu slice: [shared.md](shared.md).

Gotchas that concern this tab: [gotchas.md § Rename and instrument detection](gotchas.md#rename-and-instrument-detection), [§ SwiftUI and AppKit](gotchas.md#swiftui-and-appkit).

## Layout

`RenamerView` hosts two panels side by side:
- **Score Order Sorter** (`ScoreOrderSortView`, left) — numbers a folder of parts in score order (`00 - Score`, `01 - Flute`…). Backed by the app-level `RenamerManager`.
- **Bulk Part Rename** (`BulkRenameView`, right) — gives a set of PDFs a shared base name plus a part name each. All `@State`.

Whichever panel has files takes the whole tab: the sorter is hidden while `bulkHasFiles`, and `BulkRenameView` is hidden while `renamerManager.hasContent` — but `BulkRenameView` otherwise stays in the tree so its `@State` survives the layout switch.

## Score Order Sorter

### Accepted files

**PDFs and image scans** (`renamableFileExtensions`: pdf, jpg, jpeg, png, tif, tiff, heic, bmp, gif; `isRenamableFile(_:)`). Detection is by file name, and renaming only prepends a prefix, so the extension is kept. **Bulk Part Rename stays PDF-only** because it renders `PDFDocument` page previews.

### `RenamerManager`

| Property | Notes |
|----------|-------|
| `folderURL` / `directFiles` | a loaded folder, or files loaded one by one; `hasContent` is either |
| `operations: [RenameOperation]` | the current plan |
| `ensembleType` (`.band`/`.jazz`/`.orchestra`) | `didSet` loads that ensemble's order unless the user has customised it, then rescans |
| `customInstrumentOrder` | starts from the ensemble's order; a user edit sets the private `hasCustomOrder`, which stops ensemble changes overwriting it. `isLoadingPresetOrder` marks a preset load so it doesn't count as customising (without it the first ensemble switch locked the list) |
| `prefixSeparator` | persisted in `UserDefaults` (`prefixSeparator`) in `didSet` — **tests must never set it** |
| `partFolderMode`, `numberedFolders`, `folderOverrides` | "Sort into folders" — see below |
| `manualOverrides: [String: Int]` | file name → number given by hand |
| `excludedNames` | "Don't Rename" files; they stay listed, at the bottom |
| `isRescanMode`, `renumberedAutomatically` | "Renumber prefixed files" and whether ScoreSort turned it on itself |

Methods: `loadFolder(url:)`, `loadFiles(urls:)`, `addFiles(urls:)` (switches folder mode to direct-files mode and de-duplicates), `setExcluded(_:excluded:)`, `setFolder(_:for:)`, `setRescanMode(_:)`, `setManualOverride(for:number:)`, `getExistingNumbers()`, `clearFolder()`, `scanFolder()`, `executeRename(completion:)`, `detectInstrument(in:)` (a wrapper over `detectScoreOrderInstrument` with the current order).

`scanFolder()` only gathers the files — `directFiles`, or `renamerJobFiles(in:recursive:)` for a folder (recursive when Settings ▸ Renamer ▸ "Search subfolders recursively", `renamerSearchRecursively`, is on) — and hands them to the planner.

### The planner — `planScoreOrderRename(...)` (`Logic/RenameLogic.swift`)

Shared with the CLI. Touches nothing on disk. For each file:
1. Excluded → `.excluded`.
2. Already numbered (`^\d{2}[-_\s]`) and not in rescan mode → `.alreadyPrefixed` (or a move into its folder, see below).
3. In `manualOverrides` → manual list.
4. Otherwise `detectScoreOrderInstrument` on the name (old prefix stripped in rescan mode): `"score"` → score list; another instrument → detected list; none → `.undetected`.

Then: detected files sort by instrument rank, and parts of the same instrument by name **without the old prefix** using `localizedStandardCompare` (Trombone 2 before 3, Trumpet 10 after 9 — sorting by the prefixed name kept a wrong order "already correct"). Every score file gets `00`; detected parts number from `01`, skipping numbers reserved by manual overrides; manual files take their number as given. A rename whose target already exists becomes `.skip` with the status "Target exists"; in rescan mode a file whose prefix is already right is `.skip`, and a wrong one is `.correct`.

Final order: unrecognised first (so they're seen), then by new name, excluded last.

**`detectScoreOrderInstrument(in:order:)`** tries the order's names longest first (so "bass clarinet" beats "clarinet"), records each match's character position, and returns the **leftmost** ("Baritone BC Bassoon" is a baritone, not a bassoon).

### `RenameOperation` and its types

`id` is the standardised original path (stable across rescans, so selection survives). Fields: `originalURL`, `originalName`, `newName`, `newURL`, `type`, `statusOverride`, `oldPrefix`, `folder`, `fromFolder`; `newPathForDisplay` shows "Woodwind/01 - Flute.pdf" or "01 - Flute.pdf (out of Woodwind)".

| Type | Colour | Meaning |
|------|--------|---------|
| `.rename` | green | will be renamed (or moved into its folder) |
| `.correct` | orange | wrong prefix, will be corrected (rescan mode) |
| `.manual` | blue | number given by hand |
| `.skip` | secondary | already correct, or target exists |
| `.alreadyPrefixed` | secondary | has a two-digit prefix, outside rescan mode |
| `.undetected` | secondary | no instrument found (double-click to assign) |
| `.excluded` | red | "Don't Rename"; listed at the bottom with a Restore button |

### Renumbering

**Automatic.** `scoreOrderNeedsRenumbering(files:order:numberedByHand:)` is true when numbered files sit beside unnumbered recognised parts (numbering only the new ones would restart at 01 and repeat numbers), or when an already-numbered file was given a number by hand (outside rescan mode it is `.alreadyPrefixed` before overrides are looked at, so the number would be ignored). `RenamerManager.renumberIfMixed(reset:)` then turns `isRescanMode` on — at load, `addFiles` and `setManualOverride`, without clearing overrides — and sets `renumberedAutomatically` (the status text says so). The CLI's `rename` does the same and reports it.

**Sticky.** `rescanChosen` remembers the person's last "Renumber prefixed files" setting for the session; it survives loads and Clear. `renumberIfMixed` only ever adds the automatic tick on top. `setRescanMode(_:)` clears manual overrides when turned on.

**Manual numbers.** `setManualOverride(for:number:)`: if the number is taken, every other override at or above it shifts up by one; the file is un-excluded; then rescan. `getExistingNumbers()` counts "already correct" files in rescan mode too (they are renumbered around a manual number). `ManualAssignmentView` (presented with `.sheet(item:)`) keeps the number as **text** read live (`typedNumber`), starting at the file's current number: `TextField(value:format:)` only committed on Return or blur, so clicking Assign straight after typing assigned the stale value.

### Executing — `performRenames(_:)`

`RenamerManager.executeRename(completion:)` filters to `.rename`/`.correct`/`.manual` and calls `performRenames` (shared with the CLI), which pre-flights with `nonWritableParentDirectories` on the *source* folders (a new section folder doesn't exist yet), creates each destination folder, moves with `FileManager.moveItem`, and removes part folders left empty (`removeEmptiedPartFolders`: only folders holding nothing but `.DS_Store`). The manager then shows the read-only guidance or a "Partial Success" alert as needed, and either calls `completion(folderURL, renamedNames)` (so the view can show its summary) or rescans.

### Undo Rename — `Logic/RenameJournal.swift` (#19)

Every rename path records what it moved in **`last-rename.json`** (Application Support/ScoreSort): `performRenames` (the Score Order Sorter and the CLI's `rename --apply`) and both of Bulk Rename's own loops (`executeRename` with no prefix, `applyPrefixAndRenameBulk`; they keep their `NSFileCoordinator` moves and call `recordRenames` afterwards). Folders a rename makes go through `createFolderRecording`, so the journal knows which folders were new.
- **Only the last rename is kept.** A new one replaces the journal; one that moved nothing leaves it alone. In a batch of folders, `executeRename(appendToJournal:)` is true after the first folder, so one undo puts the whole batch back.
- **`undoLastRename(apply:journalAt:)`** works through the moves in reverse. A file goes back only if it's still where the rename left it and its old name is free (`isSameFile`, so a case-only rename undoes). Anything else is reported and stays in the journal for a later try. Folders the rename made are removed if left with nothing but `.DS_Store`. With `apply` false it only plans.
- **App:** an **Undo Rename** button on both done screens (`ScoreOrderRenameSummaryView`, and `RenameSummaryView` for Bulk Rename; Split passes no `onUndo`) and **Actions ▸ Undo Last Rename…**, all through `confirmAndUndoLastRename()`: it plans, asks, undoes and reports (`undoRenameSummary`). Not ⌘Z: menus bind no editing keys (see `CLAUDE.md`).
- **CLI/MCP:** `undo-rename` (plans unless `--apply`) and the `scoresort_undo_rename` tool. It's a separate command rather than `rename --undo`, because `rename` requires files and `--ensemble`.
- **Tests:** `RenameJournal.defaultURL` is **nil under tests** (`XCTestConfigurationFilePath`), so no test can write the real journal; tests pass `journalAt:` a temporary file (`RenameUndoTests`).

### Instrument orders — `InstrumentOrders`

Static accessors `band`, `jazz`, `orchestra`; `getOrder(for:)`. Lowercase name strings including every alias used for detection.

**External file:** `~/Library/Application Support/ScoreSort/instrument-orders.json` — pretty-printed `{ "_version": ["N"], "band": [...], "jazz": [...], "orchestra": [...], "_base_band": [...], … }`, where each `_base_…` is the built-in order that ensemble was last written from. `InstrumentOrders.setup()` (called from `AppDelegate.applicationDidFinishLaunching`) runs `prepareFile(at:)` — defaults written if the file is missing; if it's older than `defaultsVersion` (currently 9) it's **updated, not replaced** (`InstrumentOrders.updated`): an ensemble whose order still equals its `_base_…` takes the new built-in order as it is, and an edited one (or one from before version 9, which had no base) keeps the edits and gains each new instrument after its neighbour in the built-in order (`InstrumentOrders.merged`) — then loads it, ignoring the `_` keys. Hand edits take effect at the next launch. A file that can't be read (typically a broken hand edit) is **set aside under a dated name** before the defaults are written, and `launchNotice` tells the user through `SavedFileNoticeBanner`; if it can't be moved it's left alone and the built-in `bandDefault`/`jazzDefault`/`orchestraDefault` arrays are used. Bumping `defaultsVersion` no longer resets hand edits (it did up to version 8) — see [gotchas.md](gotchas.md#rename-and-instrument-detection) and [§ Saved files](gotchas.md#saved-files).

- **Band:** score → piccolo → flutes → oboe → cor anglais/english horn → bassoon → contrabassoon → Eb clarinet → clarinet → alto → bass → contrabass clarinet → soprano/alto/tenor/bari/bass sax → cornet → trumpet → horn → trombone → bass trombone → baritone (B.C. then T.C.) → euphonium → tuba → guitar/keyboard/piano/harp → violin → viola → cello → string bass/bass/double bass → timpani → mallets (bells, chimes, glockenspiel, xylophone, vibraphone, marimba) → drums → percussion.
- **Jazz:** score → vocals → solos → alto/tenor/bari sax → trumpet/cornet/flugelhorn → trombone → guitar → piano/keyboard → bass → drums → aux percussion → mallets/vibes → flute → clarinet → horn/euphonium/tuba.
- **Orchestra:** score → piccolo → flute → oboe → cor anglais → Eb clarinet → clarinet → bass clarinet → bassoon → contrabassoon → saxes → horn → trumpet → cornet → trombone → bass trombone → euphonium/baritone → tuba → timpani → mallets → percussion → drums → guitar/organ/keyboard/piano/celeste/harp → violin → viola → cello → double bass → string bass/bass.

### View — `ScoreOrderSortView`

- **Toolbar** (with files loaded): a "Renumber prefixed files" tick, Move to Folder (folders on), Don't Rename, Preferences (opens Settings on the Renamer tab), and Clear Files — labelled **Cancel Batch** mid-batch.
- **List:** unrecognised files, then the matched files, then excluded files. Rows are `ScoreOrderFileRow`; double-click opens `ManualAssignmentView`. Click, ⇧-click and ⌘-click select (`selectedIDs`, `lastClickedID`; ranges follow `allDisplayedOps`). ⌫ excludes the selection through an `NSEvent` monitor.
- **Bottom:** the ensemble picker (Wind Band / Jazz Band / Orchestra), the `PartFolderPicker`, status text, and **Rename Files** (disabled when `renameCount == 0`; **Rename & Next** mid-batch).
- **Done screen:** `ScoreOrderRenameSummaryView` (Start Over, Show in Finder, Rescan Folder). Dropping files or folders on it starts again.

### Batch folders

Several folders can be imported at once and worked through one at a time. The queue is view state in `ScoreOrderSortView`; `RenamerManager` stays single-folder.

- `batchFolders` (ordered jobs; one or none means no batch UI), `batchPosition`, `batchResults`; `isBatchActive == batchFolders.count > 1`.
- **Import:** every entry point (the open panel, the empty-zone drop, the done-screen drop) goes through `startInput(_:)`. Folders go through `expandToRenameJobFolders` then `beginBatch`; plain files go to `loadFiles`. A single folder is a batch of one.
- **`expandToRenameJobFolders`** walks each dropped folder's whole subtree: **every directory at any depth that directly contains renamable files** is a job, sorted by full path. A piece's own part folders (Woodwind, Brass…) belong to the piece's job rather than being jobs themselves.
- **`qualifiedFolderName(for:among:)`** shows each folder relative to the deepest shared ancestor ("Concert Band › Symphony 5"), so same-named folders are distinguishable.
- **Advance:** Rename calls `executeRename { … advanceOrFinish(recordResult:) }`, which records the result and loads the next folder (no per-folder done screen) or, when the queue is exhausted, shows the combined summary. `skipCurrent()` advances without recording.
- **Reorder:** `batchQueueBar` lists the *upcoming* folders with `.onMove(moveUpcoming)`; only the tail after the current folder moves.
- **Summary:** with more than one result, `ScoreOrderRenameSummaryView` groups by folder ("N folders · M files") and hides Rescan/Show in Finder. `batchResults.last` backs the single-folder case so a trailing Skip doesn't blank it.
- **Reset** (`resetBatch()`): Start Over, Cancel Batch, and `beginBatch`.

## Bulk Part Rename — `BulkRenameView`

Takes a folder or individual PDFs (`loadedFiles`), a shared `baseFileName` and a per-file suffix (`suffixes`, with the same instrument autocomplete as Split Step 2). Stages (`BulkStage`): `.base` → `.prefix` → `.summary`.

- With **"Prefix score order"** on (`@AppStorage("prefixEnabled")`), `executeRename()` builds `PrefixItem`s (nothing on disk yet) and shows the shared `PrefixOrderStepView`; its `onApply` runs `applyPrefixAndRenameBulk(orderedItems:)`.
- With it off, `executeRename()` renames straight to base + separator + suffix; duplicate output names block the button (`hasDuplicateNames`).
- Both paths pre-flight with `nonWritableParentDirectories` and report permission failures with `readOnlyLocationMessage`.
- Shared settings: `filenameSeparator` (the suffix separator, also used by Split), `prefixEnsembleType`, and the "Sort into folders" keys.
- Single piece only: a dropped folder with no direct PDFs shows a "No PDFs in That Folder" alert pointing at the Score Order Sorter.

## Settings ▸ Renamer — `PreferencesView`

Ensemble type; the instrument order editor (drag to reorder, add, Reset to Default; committed by Save); the suffix separator (`filenameSeparator`, Split and Bulk Rename); the prefix separator (Score Order Sorter); "Search subfolders recursively" (`renamerSearchRecursively`); "Sort parts into folders" and "Number section folders".

## Sort into folders

`Logic/PartFolders.swift` and `Rename/PartFolderPicker.swift`. Used by Split (Steps 2–3), both Rename panels and the CLI.

Puts each part in a **section** folder or an **instrument** folder (Flute, Clarinet, Alto Saxophone…) **beside** the files — inside the folder being saved to or renamed in — so each group of players can be given just their own parts. The score and unrecognised names stay at the top.

| Ensemble | Sections (`partFolderSections(for:)`) |
|----------|----------|
| Band | Woodwind, Brass, Percussion, Strings, Vocals. **No Rhythm folder:** piano/keyboards, guitar, bass guitar and string bass go in Brass. |
| Orchestra | Woodwind, Brass, Percussion, Rhythm (piano/keyboards, guitar, bass guitar), Strings (including string bass), Vocals |
| Jazz | Saxophones (all woodwind), Trumpets, Trombones (with horn and low brass), Rhythm (percussion, drum kit, keyboards, guitar, basses), Strings, Vocals |

Domain calls (Ben, 2026-11-10): drum kit stays in Percussion outside jazz; big band uses jazz sections; score at the top level. (Ben, 2026-11-16): a concert band has no Rhythm folder — its rhythm parts go in Brass; an orchestra keeps Rhythm.

**Mode and settings**
- `PartFolderMode` (`.off` / `.section` / `.instrument`). **One remembered setting** (`PartFolderMode.defaultsKey` = `partFolderDefault`), shown by Settings ▸ Renamer and by every on-screen `PartFolderPicker`. Split and Bulk Rename bind `@AppStorage` directly; `RenamerManager.partFolderMode` writes it in `didSet` (not under the test runner) and `ScoreOrderSortView` follows changes made elsewhere. Ben wanted it to stay as last set across launches, not reset to a default.
- **Numbered section folders** (`PartFolderMode.numberedDefaultsKey` = `partFolderNumbered`; `PartFolderMode.numbersSections` reads it and is always false under the test runner): "1 Woodwind", "2 Brass"… Each section's number is its fixed place in `partFolderSections(for:)`, so pieces split into one folder share folders. Threaded as `numbered:` through `partFolderName`, `partFolderDestination(for:partName:…)`, `partFolderSections`, `partFolderChoices`, `planScoreOrderRename(numberedFolders:)`, `RenamerManager.numberedFolders` and `PrefixFolderSorting.numbered`; the CLI follows the setting. `partFolderBaseName` strips the number, so `isPartFolderName("2 Brass")` and the no-nesting check treat "Brass" and "2 Brass" as one folder.
- Where the picker shows: the Score Order Sorter's bottom bar; Split and Bulk Rename **in the prefix step** (via `PrefixFolderSorting`), and on their naming step only when "Prefix score order" is off (that step then saves).

**Choosing the folder**
- `partFolderName(forFileName:mode:ensemble:numbered:)` uses its own whole-word phrase table (`partFolderEntries` — not the instrument-order lists): **leftmost** match, longest at a tie. Clef words are removed first; a bare "Baritone" is the bari sax in jazz unless a clef or "horn" says brass.
- **Split and Bulk Rename decide by the part name** (`partFolderName(partName:fileName:…)`), not the whole file name, since a piece title can name an instrument ("Trumpet Voluntary - Flute 1"); a part with no suffix falls back to the file name. The Score Order Sorter goes by the file name, matching its numbering.
- `partFolderDestination(for:folder:)` never nests a file already in a folder of that name. `partFolderPath(_:folder:)` gives "Brass/03 - Trumpet 1.pdf". `partFolderNameError(_:)` validates a typed folder name.

**Split.** Names carry the folder. `PDFManager.splitPlans(partFolders:)` takes file index → folder (Step 3's `PrefixItem.folder`, or `SplitView.splitPartFolders()` when saving from Step 2); `writeSplitFiles` and `saveSplitFiles`' temp-folder move create the folders.

**Prefix step** (Split Step 3, Bulk Rename Step 2). `PrefixFolderSorting(mode:defaultFolder:)` gives the binding and ScoreSort's guess per item id. Recognised rows group under `PartFolderGroupHeader`s with full paths; the arrows swap within a folder; rows drag between folders (payload `"scoresort-prefix-part:" + id`) and right-click offers `PartFolderMenuItems`. Hand choices are view state (`folderOverrides`, lost on Back like the order). `onApply` receives each `PrefixItem.folder`, and the save uses those (`applyPrefixToFolder`, `applyPrefixAndRenameBulk` → `partFolderDestination(for:folder:)`). Shared pieces in `PartFolderPicker.swift`: `partFolderChoices`, `PartFolderMenuItems`, `partFolderDragPreview`, `PartFolderDragDrop`, `askForPartFolderName`.

**Score Order Sorter**
- `planScoreOrderRename(folderMode:ensemble:…)` sends each `newURL` through `partFolderDestination` and sets `RenameOperation.folder`. Already-numbered or already-correct files that would move become `.rename` operations with `newName == originalName` (CLI status "move into folder").
- **Grouped list.** `folderGroups` groups matched rows by `operation.folder` ("" = top level) in order of first appearance, under `PartFolderGroupHeader` (teal `Color.partFolder`, left spine, styled like Combine's collate groups).
- **Move to Folder** (toolbar menu, and each row's context menu — the selection if the row is in it, else that row): `partFolderSections(for:)` plus folders in use, New Folder… (`askForPartFolderName`), Top Level, and ScoreSort's Choice. Choices live in `RenamerManager.folderOverrides` (original file name → folder, "" = top level; reset on load and clear) → `planScoreOrderRename(folderOverrides:)`, ignored with folders off. Unrecognised and excluded rows can't be moved (give them a number first).
- **Dragging** does the same: rows are `.draggable` (payload `"scoresort-renamer-part:" + originalName`, so stray text drops are ignored; the selection moves if the dragged row is in it); headers and rows are `.dropDestination(for: String.self)` targets for their folder (`handleFolderDrop` → `setFolder`, highlighted via `folderDropTarget`). `PartFolderDragDrop` attaches both only with folders on. Only folders already in the list are drop targets; an empty section is reached through the menu.
- **A sorted piece is one job.** `partSubfolders(of:)` (subfolders named like any section or instrument folder, holding parts) are absorbed by `expandToRenameJobFolders` and listed by `renamerJobFiles(in:recursive:)`. `planScoreOrderRename(root:)` places files relative to `partPieceFolder(of:root:)`, so By Section leaves sorted parts where they are (`folder` is set on staying files too, so they group under it), Off gathers them back (`RenameOperation.fromFolder` → "(out of Brass)"), and `performRenames` removes part folders left empty. The CLI passes `root` only when `--folders` is given, so an assistant's plain rename never un-sorts a piece. CLI: `rename --folder "FILE=FOLDER"` (MCP `folderChoices`).
- **The matched list is one flat `ForEach(matchedListItems)`** of `MatchedListItem` (`.folderHeader` / `.file`). See [gotchas.md](gotchas.md#swiftui-and-appkit) for why.

**Tests** that build a `RenamerManager()` set `partFolderMode = .off`, because it starts from the user's real setting.
