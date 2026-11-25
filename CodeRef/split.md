# Split PDF (tab 2, ⌘3)

Files: `ScoreSort/Split/SplitModel.swift` (`SplitModel`: the document and Step 1's state, with the operations that change them), `Split/SplitView.swift` (Step 1's screen, the stages, sheets and saving; `BookletOrderSheet`, `SplitControlsSection`), `Split/ScanSplitSheet.swift` (Split Double Pages), `Split/SplitBookmarks.swift` (the bookmark prompt), `Split/SplitNaming.swift` (Step 2: `SplitNamingStageView`, `SplitFileNamingRow`, plus Step 1's `FilePreviewCard`), `Split/SplitPrefixStep.swift` (Step 3 `PrefixOrderStepView`, shared with Bulk Rename; `RenameSummaryView`; `PageInstrumentPreview`, `PageCropOverview`), `Logic/SplitLogic.swift` (split maths, A3, bookmarks, booklet *de*imposition, the file writer), `Logic/ScanSplitLogic.swift` (double-page scans), `Logic/InstrumentNames.swift` (Step 2 suggestions), `Logic/RenameLogic.swift` (`PrefixItem` and score-order numbering). `SplitView` holds a `SplitModel` as its `@StateObject`; the model holds the tab's own `PDFManager` ([shared.md](shared.md#shared-infrastructure)), which loads the file and remembers `sourceURL`.

Booklet *imposition* (Combine's direction) and printing: [printing-booklets.md](printing-booklets.md). Stamping split output: [stamp.md](stamp.md). The CLI's `split` and `split-scans`: [cli-mcp.md](cli-mcp.md). "Sort into folders": [rename.md](rename.md#sort-into-folders). Menu slice: [shared.md](shared.md#the-tabcommands--tabslice--menuaction-bridge).

Gotchas that concern this tab: [gotchas.md § Split](gotchas.md#split), [§ PDFKit and PDF geometry](gotchas.md#pdfkit-and-pdf-geometry) (rotation, crop boxes), [§ SwiftUI and AppKit](gotchas.md#swiftui-and-appkit), [§ Menus and keyboard](gotchas.md#menus-and-keyboard).

## Stages

`SplitView` switches on a private `SplitStage`: `.split` (Step 1, `splitStageBody`) → `.naming` (Step 2, `SplitNamingStageView`) → `.prefix` (Step 3, `PrefixOrderStepView`, only with "Prefix score order" on) → `.summary` (`RenameSummaryView`).

## The model — `Split/SplitModel.swift`

`SplitModel` owns the document and Step 1's state, and **every change of document is one of its operations**, so nothing has to work out afterwards what kind of change it was. The view used to reset in an `onChange` of the document. It told in-place rebuilds apart by `suppressDocumentReset`, `suppressNextA3Detection` and `pendingScanSplitSkips`, flags set just before each assignment; they're gone now. Only the model writes `pdfManager.pdfDocument`. It forwards the manager's `objectWillChange`, so the view redraws through the model. `fileSizes`, `skippedPages`, `selectedFileIndices`, `documentRebuilt`, `documentBookmarks` and `lastBookletOrder` are `private(set)`. `currentPage`, `stride`, `skipMode`, `baseFileName` and `customFileNames` are bound by controls and Step 2.

| Operation | What it does |
|-----------|--------------|
| `load(from:) -> SplitLoadSuggestion?` | Opens the PDF and starts afresh (`startAfresh`): one file named after the PDF, page 1, no names, skips or selection, `skipMode = .file`, `documentRebuilt` off, bookmarks read, undo cleared. `stride` and `lastBookletOrder` carry over. Answers `.splitDoublePages` (`isA3Landscape` or `looksLikeDoublePageScan`), `.doublePageHint` (`looksLikeA3Landscape`) or `.ordinaryPages`. Nil if the file wouldn't open, and then nothing changes. **This is the only place the double-page check runs.** So nothing ScoreSort builds is offered Split Double Pages, and no rebuild can stop the next PDF being offered it (#29). |
| `clear()` | Closes the document and resets everything, `lastBookletOrder` included. |
| `applyScanSplit(_:to:) -> PDFDocument?` | Split Double Pages (below): the new document, `startAfresh`, then the sheet's skips, `skipMode = .page`, `documentRebuilt`. |
| `swapCurrentPageWithNext()`, `applyBookletOrder(pages:order:)`, `applyBookletOrderToAllMatchingFiles(order:n:)` | In-place rebuilds (below), through the private `replaceInPlace`. |
| `toggleSplitAt(page:)`, `applyStride()`, `restrideFromCurrentPage()`, `clearAllSplits()`, `toggleSkipPage(_:)`, `toggleSkipFiles(_:)`, `toggleSkipForDeleteKey()` | Undoable edits. |
| `applyBookmarks(_:nameStyle:)` | Bookmarks (below); a new undo history. |
| `undo()`, `redo()` | Step 1 undo (below). |
| `goToPreviousPage(toFirst:)`, `goToNextPage(toLast:)`, `goToPreviousFile(extendingSelection:)`, `goToNextFile(extendingSelection:)`, `selectFile(_:command:shift:)` | Navigation and the card selection, for the keys and clicks the view handles. |

**The view** (`SplitView`) keeps:
- the stages, sheets, panels and banners;
- focus and the Step 2 preview pan;
- the `NSEvent` monitor and `onKeyPress` handlers, with their tab guards;
- the background save and `syncTabCommands`.

Every way a PDF arrives goes through `openFile`: the drop zone (`DropZoneView`'s `onOpen`), Choose PDF…, Finder or the Dock (`takePendingOpen`), and a drop on the summary. `openFile` calls `load(from:)` and brings the flow back to Step 1 whichever stage was showing (`showNewDocument`: focus, pan reset, `.split`). Then it opens Split Double Pages, or shows the hint and offers bookmarks.

Clear File, Start Over and the menu's Clear go through `clearFile`. It also resets the view's own state: the stage, the Step 3 items, the summary and the banners.

## Step 1 — split points

### The model: `fileSizes: [Int]`

The split is an **ordered array of page counts**, one per output file: `[2, 2, 1, 3]` is four files. Everything else is derived: `splitMarkers` (pages that start a file, page 0 excluded — for drawing only), `pageToFileMapping` (page → file; build it once per redraw — the file-card list does — not once per card), `pagesForFile` (`splitFilePages`, a range straight from `fileSizes`), `activeFileCount`, `skippedFileIndices`. Never store split points anywhere else ([gotcha](gotchas.md#split)).

Other model state: `stride` (1–20), `currentPage`, `baseFileName`, `customFileNames: [Int: String]` (file index → suffix), `skippedPages: Set<Int>`, `selectedFileIndices`, `skipMode` (`.file`/`.page`), `documentBookmarks`, `lastBookletOrder` (`SplitBookletOrder`), `documentRebuilt`. The view's: `bookmarkOffer`, `scanSplitRequest`, `bookletFixRequest`, and banner flags (`a3HintVisible`, `a3SplitNoticeVisible`, `bookletRedoNoticeVisible`).

Pure functions (`Logic/SplitLogic.swift`):

| Function | Behaviour |
|----------|-----------|
| `toggleSplit(in:at:)` | Splits a file at a mid-file page, or merges a file into the one before when `page` is its first page. No-op at page 0. |
| `splitSizes(totalPages:stride:)` | Even chunks; the last takes the remainder. |
| `remapFileNames(_:from:to:)` | Re-keys `customFileNames` across a change of `fileSizes` by start page, so a name stays with the file that still starts on the same page. `toggleSplitAt` uses it (before, adding one split slid every later name onto the wrong file). |
| `splitOutputFileName(base:separator:suffix:fileIndex:onlyFile:)` | **The one place a split file's name is composed.** Empty suffix → the 1-based file number; empty base → the suffix alone, no separator; `onlyFile` with a blank suffix → `"<base>.pdf"`, so a part only cut or reordered keeps its own name. Step 1's cards, Step 2's rows, Step 3, the summary, `PDFManager.saveSplitPDF` and the CLI all call it. |
| `splitActiveFileCount(pageToFile:skippedPages:)` | Files with at least one page not skipped; drives `onlyFile`. |
| `firstKeptPage(fileStart:fileSize:skippedPages:)` | The page shown for a file in Steps 2–3: its first page that will be saved, so a skipped black or blank first page doesn't stand in for the part. |
| `splitOutputIsWorthSaving(activeFiles:skippedPages:pagesRebuilt:)` | ≥ 1 active file and (≥ 2 files, or some pages skipped, or pages rebuilt). |
| `splitOutputReplacesSource(names:folder:source:)` | Whether a name lands exactly on the source file: `isSameFile`, so any case on a case-insensitive disk, a symlinked folder or a hard link counts. False when the output doesn't exist yet. |

**Continuing.** `canContinueToNaming` (the Next button, Return, the menu's primary action and `saveSplitPDF`'s guard) and Step 2's `canSave` both use `splitOutputIsWorthSaving`. `documentRebuilt` is set by Split Double Pages, Swap with Next and Fix Booklet Order and cleared on a new or cleared document (all in the model): without it a part scanned on A3 and cut to A4 — still one file, nothing skipped — couldn't be saved.

### Layout

Left half: `SplitControlsSection` over a `PDFPageView` of the current page (with the stamp drawn in when the page will be stamped — `previewStamp`). Right half: the Split Pattern box (Stride stepper, **Apply** (`applyStride`), **Clear All** (`clearAllMarkers`)), the Output Files list of `FilePreviewCard`s, and **Next: Name Files**. The toolbar has the `StampMenuButton`, a **Fix Scan** pull-down (Split Double Pages…, Fix Booklet Order) and **Clear File**.

`SplitControlsSection` binds `currentPage` and `skipMode`:

| Row | Contents |
|-----|----------|
| 1 | `|◀` `◀` · "Page N of M" (SKIPPED badge) over the current file's range · `▶` `▶|` |
| 2 | Add Split Here / Remove Split (Space), disabled on page 0 · Re-stride from Here (R), disabled on the first and last page |
| 3 | Swap with Next (S), disabled on the last page · a Page/File **switch** (a mini `Toggle`) and the Skip/Un-skip button, whose label and colour follow the mode and state |

`FilePreviewCard` shows a file's name, range and up to 10 page thumbnails; its fill shows fully skipped (red), partly skipped (orange), selected, or containing the current page. For a file of 4n pages it has a Fix Booklet Order icon, and a "repeat last order" icon when `lastBookletOrder` has the same page count. Click selects (⌘ toggles, ⇧ extends) and jumps to the file; clicking takes focus back to the page navigator so ← → keep working.

### Keys

`.onKeyPress` on Step 1 (gated on `selectedTab == 2`): ← → page (⌘ to first/last), ↑ ↓ jump between file starts (⇧ extends the file selection), Space toggles a split (not on page 0), Return continues when allowed, **S** swap with next, **R** re-stride from here. The keys stay in the view; what they do is a model operation (`goToNextPage`, `goToNextFile`, …).

An `NSEvent` local monitor (installed in `onAppear`, removed in `onDisappear`, gated on the tab and skipped when an `NSTextView` is first responder) handles:
- **⌫ / ⌦** → `model.toggleSkipForDeleteKey()`: `.page` skips or un-skips the current page; `.file` the selected files, or the current one.
- **⌘Z / ⇧⌘Z** (keyCode 6) → undo/redo, without an Edit-menu `UndoManager`, so it never bonks.

### Undo

The model's private `[SplitSnapshot]` `undoStack`/`redoStack` (capped at 50; `canUndo`/`canRedo`). `SplitSnapshot` holds `fileSizes`, `skippedPages` and `customFileNames` — not the document. `pushUndo()` runs before `clearAllSplits`, `applyStride`, `restrideFromCurrentPage`, `toggleSplitAt`, `toggleSkipFiles` and `toggleSkipPage`; undo and redo also clear the selection. The stacks are cleared on a new or cleared document, by `applyBookmarks`, **and on every in-place rebuild**, because a page reorder makes snapshot skip indices point at the wrong pages. Rebuilds (swap, booklet order, double-page split) are deliberately not undoable.

`restrideFromCurrentPage()` keeps every file ending at or before the current page (trimming the one it falls inside) and applies the stride from there; names of the re-strided files are dropped. It's for a short part in an otherwise regular set (a 3-page piccolo among 4-page parts).

### Skipping

`skippedPages` leaves pages out; a file whose every page is skipped is "fully skipped" and hidden from Step 2. `skipMode` defaults to `.file` and is reset to it on every load; after a double-page split it becomes `.page`, because blanks come one page at a time.

### In-place rebuilds

`swapCurrentPageWithNext()`, `applyBookletOrder(pages:order:)` and `applyBookletOrderToAllMatchingFiles(order:n:)` are model operations. Each builds a new `PDFDocument` with pages moved and hands it to the private `replaceInPlace`, which sets `documentRebuilt`, clears the undo history and assigns it.
- Split points, names and skips survive. Names are keyed by file index and the file sizes don't change, so they stay with their parts.
- The booklet functions remap `skippedPages` through the permutation and set `lastBookletOrder`.
- **A swap leaves skips where they were**: on the positions, not on the pages that moved.

The view's `applyBookletOrder` wrapper shows the repeat-icon banner the first time. "Apply to All" reorders every file of that length in one rebuild.

## Bookmarks — `Split/SplitBookmarks.swift`

**Bookmarks are offered, not applied.** A new PDF starts as one file named after the PDF; `setupSplitState()` stores `bookmarkSections(in:)` in `documentBookmarks` and, if there are any, sets `bookmarkOffer`, presenting `BookmarkSplitChoiceView` (`.sheet(item:)`).

The sheet shows one example file name (base dimmed, part bold), then each section's pages beside just its *part* name, with a sticky segmented choice (`@AppStorage("splitBookmarkNameStyle")`, `BookmarkNameStyle`): **Piece + Bookmark Title** or **Bookmark Title Only**. Repeating a long shared piece name on every row buried the instrument, as did middle truncation, so long lines are cut at whichever end the titles share. Buttons:
- **Split & Name Files** → `applyBookmarks(_:nameStyle:)`: `fileSizes`, `baseFileName` and `customFileNames` from `bookmarkSplitNames`.
- **Split Only** → the same with `nameStyle: nil` (split points, no names).
- **Ignore Bookmarks** → nothing.

`applyBookmarks` replaces the split state like a fresh load (clears skips, selection and undo). **Actions ▸ Use Bookmarks…** reopens the sheet from `documentBookmarks`, so Ignore isn't final. This replaced silently applying bookmarks under a 4-second banner. When Split Double Pages was offered on load and answered "Don't Split", the bookmark offer follows after 0.4 s so two sheets never present at once.

| Function | Behaviour |
|----------|-----------|
| `bookmarkSections(in:) -> [BookmarkSection]?` | The top-level outline as files (`startPage`, `pageCount`, `title`), in page order. Two bookmarks on one page count once (first title wins — otherwise a zero-page file); a first bookmark not on page 1 leaves an **untitled leading section** so titles stay aligned with their pages; a destination inside a `PDFActionGoTo` is read too. `nil` unless ≥ 2 sections. |
| `bookmarkSplitNames(titles:fallbackBaseName:style:)` | Titles → `(baseName, suffixes)`, index-aligned. Titles first go through `readableBookmarkTitle` (a title with no spaces has `_` turned into spaces — titles made from file names). `.titleOnly`: each title whole, base `""`. `.pieceAndTitle`: titles split on `" - "`; a leading all-digit segment on *every* title is dropped (Step 3 renumbers); the longest run of leading segments every title shares ("Composer - Piece") becomes the base, always leaving each title one segment; with nothing shared the base is `fallbackBaseName` (the PDF's name). A single numbered title counts as ScoreSort's own pattern. Only `" - "` separates, so "Clarinet 1/2/3" doesn't become base "Clarinet". Everything goes through `fileNameSafe`; an empty title gives an empty (auto-numbered) suffix. |
| `fileNameSafe(_:)` | `": "` → `" - "`, `/ : \` → `-`, line breaks and repeated spaces collapsed, a trailing `.pdf` dropped. Combine's "Flute 2/3" copy labels would otherwise block Step 2. |
| `splitSizesFromBookmarks(_:)`, `extractSplitNames(from:)` | The older interface (sizes + labels; strict `"NN - Piece - Part"` parsing). **No app code calls them now**; they survive for tests, which check `bookmarkSplitNames` agrees with `extractSplitNames` on ScoreSort's own labels. |

**An empty `baseFileName` is a real state** (Bookmark Title Only): `splitOutputFileName` then drops the separator everywhere at once.

## Split Double Pages — `Split/ScanSplitSheet.swift`, `Logic/ScanSplitLogic.swift`

Built for overhead/book scanners: a mix of spreads and single pages, each cropped to its own size, the gutter rarely in the middle, black scanner bed often filling one side. A flatbed A3 scan is the easy case (it replaced `A3SplitChoiceView`, which cut every page down the middle).

1. **Offer.** On a new PDF when `isA3Landscape(doc) || looksLikeDoublePageScan(doc)` (`ScanSplitRequest(fromLoad: true)`), or from Fix Scan / Actions ▸ Split Double Pages… (`fromLoad: false`). `looksLikeDoublePageScan` is bounds-only (crop box, rotation-aware): ≥ 2 pages, ≥ ¼ of them at aspect ≥ 1.2, and not all one size. `isA3Landscape` checks the first ≤ 3 pages' **media box** (w/h swapped for 90°/270°): landscape, 1000 < width < 1500 pt. `looksLikeA3Landscape` (aspect 1.3–1.6 on the first ≤ 3 pages) only drives the hint banner.
2. **Analyse.** `ScanSplitModel.start()` takes each page's `scanRenderSource` (`CGPDFPage` + PDFKit's crop box + rotation) on the main actor, then runs `analyseScanSource` for all of them under `DispatchQueue.concurrentPerform` on a background queue, publishing each result to the main actor as it lands; `cancel()` stops it. **Rendering goes through Core Graphics (`renderScan`), never PDFKit** — PDFKit's `draw` is about 3× slower on 600 dpi CCITT scans and not safe to call concurrently (43 scans went from 15 s to about 2 s). Pages built in memory (no `pageRef`) fall back to `thumbnail(of:for:)` on the main actor. Images are `scanAnalysisWidth` wide (440 px, 300 for tall scans) and double as the analysis image (`GrayImage`). The analysis functions are `nonisolated` because the module defaults to `MainActor`. `analyseScanSource` is shared with the CLI's `split-scans`.
3. **Detection** (`analyseScan(profile:aspect:)` over `columnProfile`, which ignores the top and bottom 8%):
   - a band of **scanner bed** ≥ 12% wide in from one edge (columns ≥ 97% dark; dark cover art stays below ~95%) → cut at its edge, *whatever the scan's shape* (`.scannerBed`);
   - otherwise aspect < 1 → one page;
   - otherwise the **gutter**: runs of near ink-free columns (≤ 1.2%, after a 5-column median so a fold shadow doesn't break the run) in the middle 28–72% of the paper; best = widest minus an off-centre penalty; cut as near the paper's middle as the gap allows, staying up to 2% clear of the music (`.gutter`);
   - no gap (music runs into the fold) → the least-inked column near the middle (`.leastInk`).
   Tuned on 363 real scans (Bernstein *Prelude, Fugue and Riffs*, Copley *Shea Butter Suite*, Stravinsky *Ebony Concerto*): every cut and blank matched inspection.
4. **Blanks.** `blankPieces` → `blankKind` per piece, ignoring its outer 6%: `.black` (mean < 0.35 and ≥ 90% dark) or `.white` (< 0.15% ink, so empty staff paper counts as empty; a sliver is `.white`). Suggested as skips.
5. **Review.** A lazy grid of `ScanSplitCard`s. Drag near the cut (±10 pt, resize cursor) to move it; click a piece to toggle its skip; a One/Two Pages switch; page-number badges in output order (`scanPieceOutputIndices`); First page Left/Right (`leftFirst`). Dragging and clicking share one `DragGesture(minimumDistance: 0)` — two gestures fought over the same clicks. A finished drag re-suggests skips unless the user has clicked one on that scan (`skipEdited`). The One/Two switch is **two plain buttons drawn as a segmented control**, not a segmented `Picker` ([why](gotchas.md#swiftui-and-appkit)).
6. **Same cut on every page** (`sameCutForAll`, header checkbox). On by default when `isUniformSheetScan(doc)` — every page the same landscape size (±2 pt, aspect ≥ 1.2), i.e. a flatbed A3 or Tabloid scan — so those split consistently down the middle with no per-scan checking: open, wait for the blank check, press Return. Every scan is `.split(at: sharedCut)`; dragging any cut moves all of them; One/Two is disabled; analysis only supplies blanks. Turning it off restores each scan's `suggested` layout and re-suggests skips.
7. **Apply.** `applyScanSplit` → `splitScans(_:layouts:leftFirst:)`, which only sets crop and media boxes (about 7 ms for 43 scans; images are never re-encoded). If nothing was cut and nothing skipped it does nothing. Otherwise `SplitModel.applyScanSplit` assigns the document and starts afresh, because every page index changed; the source file and its name are kept. **Then** it applies the skips (dropping any past the end), sets `skipMode = .page` and sets `documentRebuilt`. It never runs the double-page check, so the result isn't offered the split again. The view then returns to Step 1 and offers any bookmarks. A banner says how many pages were skipped and points at Delete and Swap with Next.

`splitPage(_:at:leftFirst:)` cuts along whichever native axis is horizontal on screen ([rotation gotcha](gotchas.md#pdfkit-and-pdf-geometry)): 0° native X, visual left = native left; 90° native Y, visual left = native bottom; 180° native X, visual left = native right; 270° native Y, visual left = native top. `splitA3Pages` is now just `splitScans` with every cut at 0.5 (used by tests).

## Fix Booklet Order (deimposition)

For a part scanned as a folded booklet: the scan order isn't the reading order.

1. Set split points so the booklet is one file. Fix Booklet Order is enabled when the current file has 4n pages (`canFixBookletOrder`); each eligible card also has the icon.
2. `requestBookletFix()` makes a `BookletFixRequest` (`fileIndex`, absolute `pages`, `document`) and presents `BookletOrderSheet` (`.sheet(item:)`).
3. The sheet lists `bookletCandidates(n:)` as radio rows with 90 × 127 pt thumbnail strips (`BookletThumbnailCell`, a `PDFPageView`), plus **Custom order**: a `List` + `ForEach.onMove` of large thumbnails (no `editMode` on macOS), `scrollDisabled` and sized exactly so the outer `ScrollView` does all scrolling. With more than one file of the same length it adds **Apply to All (N files)**.
4. Apply → `applyBookletOrder`, an in-place rebuild. The order is kept in `lastBookletOrder`; the first time, a banner points at the per-card repeat icon, which reapplies it to any other file of the same length.

| Function | Behaviour |
|----------|-----------|
| `coverFirstFrontBackOrder(n:)` | Saddle-stitch deimposition, outer cover scanned first, each sheet's front before its back. `result[readingPos] = scanPos` (0-based within the file). N=4 → `[1,2,3,0]`, N=8 → `[1,2,5,6,7,4,3,0]`. `[]` unless n ≥ 4 and n % 4 == 0. |
| `innerFirstFrontBackOrder(n:)` | Inner sheets scanned first: the cover-first order with scan indices rotated by n/2. `[]` unless n ≥ 8. |
| `bookletCandidates(n:)` | "Standard (cover first)" always; "Inner-first" when n ≥ 8. |

`pages[order[readingPos]]` is the absolute page placed at `readingPos`. Combine's **imposition** (`bookletImpositionOrder`) is the inverse of `coverFirstFrontBackOrder`, so the geometry has one source of truth — see [printing-booklets.md](printing-booklets.md#imposition--logicbookletlogicswift).

## Step 2 — naming (`SplitNamingStageView`)

A scrolling list of `SplitFileNamingRow`s, one per visible (not fully skipped) file, under a **Base Filename** field (with a live example) and an orange "Skipping pages …" banner when anything is skipped.

- **Bottom bar:** "Prefix score order" (`@AppStorage("prefixEnabled")`), the ensemble picker (`prefixEnsembleType`, always enabled because it drives suggestions), and, right-aligned, **Move original to Trash** (see below). Then Back to Split, the `PartFolderPicker` (only when the prefix step is off — otherwise folders are chosen in Step 3) and **Next: Prefix Order** / **Save Split Files**.
- **`canSave`** = `splitOutputIsWorthSaving(..., pagesRebuilt:)` and no name errors (`pdfFilenameError`) and, when saving directly with no prefix, no duplicate suffixes (case-insensitive). With the prefix on, duplicates only warn: the number keeps them apart.
- **Escape** goes back a step (`onExitCommand`; a focused text field takes Escape first). The first field is focused on appear (after a 0.05 s delay) and the list scrolls to keep the focused row centred.
- **Ensemble inference, high-confidence only.** `onChange(of: customFileNames)` calls `inferredSplitSuggestionEnsemble` with the names in file order, at most once per naming session (`hasInferredEnsemble`): a bowed string anywhere (violin, viola, cello; not string/double bass, which jazz uses) → orchestra; the *first* named part a saxophone → jazz (band and orchestra lead with flute/piccolo; a sax later proves nothing); otherwise nil. With no signal no lock is needed — `@AppStorage` alone keeps the choice sticky across splits and launches (shared by key with `SplitView`, `BulkRenameView` and Step 3). Earlier versions read only the first suffix and tested band before strings, so orchestra was never detected.

### `SplitFileNamingRow` (shared with Bulk Rename)

Shows the file's first kept page in `PageInstrumentPreview` (a 150 pt strip) and `PageCropOverview` (a minimap), then the suffix field, a live final name, and warnings.

**Preview panning.** All rows share `previewOffset`. The strip's `panOverlay` drags grab-the-paper style; the minimap is dragged by direct manipulation (`onPanBy`). Both feed `applyPan(_:)`, which clamps to `cropDims`. **What the strip shows is `instrumentPreviewCrop(pageSize:stripSize:)`**: up to 200 × 100 pt from the top-left (and at most 40% of the page width), cut to the strip's own shape, so a wide strip shows the full width and only a band of height. The preview, the minimap rectangle and the pan limits all use it (with `instrumentPreviewOrigin` for the clamped top-left), so the minimap marks exactly what's on screen; they used to take the whole 200 × 100 window, so the rectangle was about 3× too tall and panning stopped short. The preview image is `.allowsHitTesting(false)` ([why](gotchas.md#swiftui-and-appkit)).

**Suggestions.** `instrumentNames` is `splitSuggestionOrder(for: prefixEnsembleType)`: band and orchestra use the detection order (`InstrumentOrders.getOrder`, capitalised, including any customisation); **jazz uses a curated list**, because its detection order leads with "solo …" entries that would derail the next-instrument walk. `splitSuggestionExtraOptions(for: .jazz)` (Solo Alto Saxophone, Solo Trumpet, Soli…) appear only while typing toward them, or right after a solo. `splitSuggestionTypedOnlyNames` (Flute Oboe, F Horn, Eb Horn, Tuned Percussion, Vocal; from Ed Wilson's charts) are typed-only in every ensemble, through `splitSuggestionTypedOptions(for:alreadyOffered:)`, which leaves out names the list already shows. They aren't detection-order entries, so adding more needs no `defaultsVersion` bump (which would reset customised orders).

- **`instrumentIdentityKey(_:)`** answers "which instrument is this", collapsing aliases including reversed sax forms (via `preferredInstrumentDisplayName`) and the private alias table `splitSuggestionGroupKey`. Used by part counts, alias skipping and the used set.
- **`nextDistinctInstrumentIndex(after:in:)`** is the one place that finds the next instrument (skipping aliases of the previous one). `nextSuggestionIndex(after:in:usedKeys:)` adds one straggler: an unused bassoon after a bass clarinet.
- **`nextExpectedIndex`** — from the nearest named row above; the list is rotated so that instrument comes first.
- **`numberedSuggestion`** — from the nearest non-empty row above, in priority order: the clef companion (`clefCompanion`: "Baritone BC" → "Baritone TC") unless another row already has it; after "Solo X", "X 1" (`splitSuggestionAfterSolo`); "Flute 1" → "Flute 2" while under the family's count; otherwise the next instrument (`splitSuggestionStartingNumberedName`), as "Oboe 1", or bare for a single-part family ("Bass Trombone", not "Bass Trombone 1").
- **`splitSuggestionTypicalPartCount(_:ensemble:)`** — per ensemble: band is the base (flute 2, clarinet 3, alto sax 2, tenor sax 1, trumpet/cornet 3, horn 4, trombone 3, percussion 4, single-part families 1, default 2); jazz overrides saxes and brass (tenor sax 2, trumpet/cornet/trombone 4); orchestra overrides clarinet 2, trumpet 2, violin 2, viola/cello/double bass 1.
- **`suggestions`** — `splitSuggestionDisplayNames` (numbered variants collapsed, saxes as full names) of the rotated list; with text typed, prefix matches then contains matches; `numberedSuggestion` prepended; at most 8. Filtering uses what was typed (`committedTypedText`) while arrowing, so arrowing onto "Flute" doesn't collapse the list.

| Key | Behaviour |
|-----|-----------|
| ↓ / ↑ | Move through the suggestions, **writing each into the field**; ↑ above the first restores what was typed |
| Return | Close the list and move to the next row; on the last row, save (if `canSave`) |
| Tab | Normal focus traversal; on the last row, save |
| Escape | Restore what was typed |
| typing | Resets the highlighted suggestion |

`isOnlyFile` (Split only; Bulk Rename leaves it off) gives the row the `onlyFile` name.

## Step 3 — Prefix order (`PrefixOrderStepView`)

`Split/SplitPrefixStep.swift`. Split's Step 3 **and** Bulk Part Rename's Step 2 (`toolTitle`/`stepLabel` set the header). Entered from Step 2 when "Prefix score order" is on: `saveSplitPDF()` builds one `PrefixItem` per active file (`proposedName` from `splitOutputFileName`, `page` = its first kept page) and bumps `prefixRoundID`, which is the view's `.id` so each visit starts with fresh `@State`.

- **Ordering.** `autoSorted` = `scoreOrderSorted(_:by:)` (`Logic/RenameLogic.swift`, shared with the CLI's `--score-order`): the score (rank 0, `isScore`) first, matched parts in instrument order (`matchInstrumentOrder`, leftmost match), unrecognised last. The ensemble picker and **Re-sort** re-run it. Unrecognised items sit in an orange section; the top one's ↑ promotes it into the matched list.
- **Numbering.** `scoreOrderNumbers(forOrderedItems:)`, mirroring the Score Order Sorter: **score → 0**, a `manualNumber` keeps its number (reserved), everything else counts from 1, skipping reserved numbers — so `00` is reserved for the score even when there isn't one. `isSkipped` items get no number and aren't written. `PrefixItem.manualNumber` is set by double-clicking the number badge, which opens `PrefixEditSheet` (`.sheet(item:)`).
- **Display equals save.** `scoreOrderFileNames(forOrderedItems:separator:)` (`"01 - Piece - Flute.pdf"`) is the one place the prefix is put on a name. The preview and `applyPrefixToFolder` both use it; Step 3 skips become skipped pages. (Once the preview was 0-based and the save re-derived its own numbers, ignoring the old free-form prefix — display didn't match save.) The separator is `@AppStorage("prefixSeparator")`.
- **Folders.** With a `PrefixFolderSorting`, recognised rows group under folder headers — see [rename.md § Sort into folders](rename.md#sort-into-folders). `onApply` gets each item's `folder`.
- **Apply & Save** (Return) → Split's `applyPrefixAndSaveSplit`: the output-folder panel, then `applyPrefixToFolder`. Escape goes back.

## Reading part names off the page — `Logic/PartRecognition.swift`, `Logic/PageTextCache.swift` (#17)

On-device text recognition with Vision; nothing leaves the Mac. Used by Step 2's preview starting point, Step 1's Suggest Splits and the CLI's `read-parts`.

**Recognition.** `recognizePageText(_:mode:)` renders the page through `renderScan` (Core Graphics, safe off the main thread), keeps the top 40% (`partNameReadFraction`) and runs `VNRecognizeTextRequest` without language correction. Boxes are fractions of the page, y from the top. It returns **nil when the page couldn't be rendered or Vision failed** (GitHub's runners, some Macs), `[]` for a page with no text. `recognizePages` reads many in parallel with `DispatchQueue.concurrentPerform`, with `isCancelled` and a per-page `progress`. **Measured on the *Ebony Concerto* scans: about 0.1 s a page in parallel, against 0.9 s one at a time.**

**`.accurate`, not `.fast`.** `PartReadMode.fast` exists but nothing in the app uses it: on hand-copied parts it doesn't see the lettering at all (it returned only library stamps and scribbles where `.accurate` read "Eb Alte Sexabhene I"), and in parallel it saved little (40 pages: 2.6 s against 3.7 s). Step 2 and Suggest Splits therefore share one cache of accurate readings.

**`PageTextCache`** (`@MainActor`, `.shared`): recognised lines per `PDFPage`, holding the page weakly with the crop box and rotation it was read at, so another PDF or a re-cut page is read afresh. `read(_ page:)` reads one page on an `OperationQueue` (a few at once, for Step 2's rows); `read(_ pages:cancel:progress:)` reads many through `recognizePages`, answering cached pages straight away. Pages built in memory (no `pageRef`) can't be read: nil.

**Interpretation** (pure, `PartRecognitionTests`):

| Function | Behaviour |
|----------|-----------|
| `InstrumentMatcher(order:)` / `.match(_:forgiving:)` | Whole-word instrument match against the instrument order: leftmost, longest at the same place. Jazz's `solo …` entries are left out (`recognisedPartName` adds "Solo" back). With `forgiving`, a line with no exact match may match a misreading: `misreadDistance` (edit distance with **lookalike letters at half cost**: j/t, i/t, e/o, a/o, n/m, b/p…) ≤ letters ÷ 4, for names of four letters or more, never for `notInstrumentWords` (brass, harmon, solo, cont…). |
| `looksLikeScorePage` | Three or more different instruments (`instrumentIdentityKey`) in the read area: a score's staff labels. |
| `partNameMatch` / `partNameLine` | The part name: a line in the **top 20%** (`partNameTopFraction`), starting in the left two-thirds (`partNameRightLimit`), at least `partNameMinHeight` (≈ 9 pt) tall, ≤ 6 words, not bracketed (cues), not a repeated title, naming an instrument (forgiving when confidence ≥ 0.5). Highest wins, then larger type. None on a score page. |
| `recognisedPartName` | The name **built from the instrument matched**, not the text read: `preferredInstrumentDisplayName`, a bare Alto/Tenor/Bari/Baritone in the order's sax section is the saxophone, "Solo" if the line says so, plus a part number after it (1–9 or I–V) or an ordinal before it. "Jrumbet IV in Bb" → "Trumpet 4". |
| `partNameFocus` | Step 2's starting point: the name's box, else the most top-left line with two or more letters or digits. |
| `titlePages` | Title-like lines (`isTitleLikeLine`: top quarter, confident, ≥ 6 letters, no instrument, no tempo word or "=") clustered fuzzily across pages. A cluster **on the first page** that recurs in separate runs (not on ≥ 80% of pages) marks the pages that start parts: `.repeated(pages)`. A title only on the first page: `.onlyFirst`. |
| `readParts(_:order:) -> PartReading` | Each page's name ("Score" for a score page) and the suggested parts. Fewer than half the pages read, no text at all, or nothing to go on → no parts and a `problem` for the person. With `.repeated` titles **every titled page starts a part**, named from its own name or "" — so a misread name still gets its split, and a doubling ("Bb Clarinet" in a sax part) or a cue doesn't make one. `.onlyFirst` → one part. Otherwise where the name changes (`suggestedParts(pageNames:)`). `method` says which. |

**On the real scans** (98 single pages after Split Double Pages, plus a 40-page score): every part boundary was right in the three multi-part PDFs (horn and five trumpets, five rhythm parts, three trombones), every single-part PDF came back as one part and the score as "Score". 14 of 20 part names were right or right but for the number; six were unreadable ("Jrumtat", "DYSMS", "Hert", "Ixombrre") and left blank.

## Saving

Both paths ask for an output folder (`NSOpenPanel`, `canCreateDirectories`, opening in `outputDirectory(forSourceFile: model.sourceURL)`):
- **No prefix step:** `saveSplitPDF()` → folder → names from `splitOutputFileName` with `splitPartFolders()`.
- **Prefix step:** `applyPrefixToFolder` → `model.pdfManager.splitPlans` with an empty base and separator, the full numbered names as suffixes, and the Step 3 folders.

`PDFManager.splitPlans(...)` turns the names, page mapping, skips and folders into `[SplitFilePlan]`; **`writeSplitFiles`** (`Logic/SplitLogic.swift`, shared with the CLI) writes them: each file's pages are copied into a new document, stamped (`applyingStamp`, with page 0 as the part's first page), its folder created, and saved through `savePDFDocument`. Existing files are replaced. Failures come back as a `SplitWriteReport`; `PDFManager.splitSaveMessage` words them ("Partial Success" / "Save Failed" with each reason). `PDFManager.saveSplitPDF(...)` still does all of this synchronously for tests.

**Saving runs in the background** (`Split/SplitSaveProgress.swift`, #34). It used to run on the main thread and beachballed on large scans. `writeSplitFiles` and everything it calls (`applyingStamp` → `stampedDocument` → `drawStamp` and the stamp model, `savePDFDocument`) are `nonisolated`. It takes an optional `progress` callback (before each file, then once with `nil`) and an `isCancelled` check between files; files not attempted are listed in `SplitWriteReport.notWritten`. The CLI passes neither.
- `SplitView.writeInBackground` shows the `SplitSaveProgressView` sheet (`saveProgress`, a `SplitSaveProgress` object), then runs `SplitSaveProgress.run` in a detached task.
- **The task never touches the document on screen** (PDFKit mustn't be used from two threads at once). It opens its own copy from a `SplitSaveSource`: `.file(sourceURL)` when `pdfDocument.documentURL` is still the loaded file, otherwise `.data(dataRepresentation())`, a snapshot taken on the main actor after the sheet appears. Swap with Next, Fix Booklet Order and Split Double Pages all build new in-memory documents, so they take the snapshot route. The choice goes by `documentURL`, which every rebuilt document lacks, not by `documentRebuilt`. `open(expectingPageCount:)` refuses a copy whose page count differs, such as a file changed on disk since loading.
- **Cancel** (the sheet's button, or Escape) stops after the current file. In the normal path the files already written stay, and an alert says how many and lists the rest; the original isn't trashed.

`saveSplitFiles(names:plans:into:finish:)` wraps both routes:
- **Normally** it saves straight into the folder, then (on success) `trashSourceFileIfRequested()`.
- **When a name lands on the original** (`splitOutputReplacesSource` — a part only cut from A3 and saved beside itself), it asks "Replace the Original?" unless Move original to Trash is on, writes everything to an `.itemReplacementDirectory` temp folder first (so the original is read in full before anything touches it), trashes the original if asked, then moves the files into place (`replaceItemAt` over existing ones). Cancelling here discards the temp folder: nothing is saved and the original is untouched.

**Move original to Trash** — a checkbox in Step 2 bound to `@AppStorage("deleteSourceAfterSplit")` (shared with `SplitView`; persisted, off by default). After a *successful* save `FileManager.trashItem` moves `model.sourceURL` to the Trash (recoverable). A failure is an alert but not fatal (the files are written). The result is `sourceWasTrashed`, shown on the summary as "Original moved to the Trash."

**Summary.** `RenameSummaryView` lists the names (with folders) and offers Start Over (⌘⌫) and Show in Finder. **Dropping a PDF on it restarts the flow** (`handleSummaryPDFDrop` → `openFile`, which resets everything); the Rename tab's done screens do the same.
