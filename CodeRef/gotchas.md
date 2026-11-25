# Known patterns and gotchas

Things that look wrong, or look like they could be simpler, but are the way they are for a reason. Each area file links to the sections that concern it. The *whys* behind design decisions are also in `CLAUDE.md`'s "Design decisions" section.

## PDFKit and PDF geometry

- **`page.rotation` is clockwise degrees** (the PDF spec's `/Rotate`). At 90° the native top edge swings to the visual right, so the visual *left* half of a 90° page is the native **bottom** half (low y); the inverse holds at 270°. Counter-intuitive, but it matches Preview. Anything that measures or cuts a page must swap width and height when `rotation % 180 != 0` and cut along native y for 90°/270°: `isA3Landscape`, `looksLikeDoublePageScan`, `isUniformSheetScan`, `splitPage`, `visualPageBox`, `instrumentPreviewPageSize`. → [split.md](split.md#split-double-pages--splitscansplitsheetswift-logicscansplitlogicswift)
- **The Rotate tab changes rotation *metadata*, never page content** — the standard approach, handled correctly by Preview. Rotated pages keep a portrait media box with a rotation flag, which is why the rule above matters. → [rotate.md](rotate.md)
- **Read the crop box, not the media box, when drawing.** A split half (Split Double Pages, `splitA3Pages`) has its crop box *and* media box set to the half, but anything still carrying a full-sheet media box with a half-sheet crop box would bring the discarded half back. `visualPageBox` uses the crop box; `getDrawingTransform(.cropBox, …)` bakes in the page's rotation, so stamps and imposed pages land where the reader sees them. (`isA3Landscape` measures the media box — fine for a fresh scan.)
- **Stamping and imposition flatten, so they drop outlines, annotations and links.** `stampedDocument` and `imposedBookletDocument` rebuild every page through a `CGPDFContext`. Page indices survive, so anything that stamps must do so *before* building a `PDFOutline`; Combine's order is stamp → impose → outline. → [stamp.md](stamp.md), [combine.md](combine.md#output)
- **On macOS 27, an outline set on a document PDFKit *opened* is not saved.** PDFKit writes a `PDFDocument(data:)`/`PDFDocument(url:)` document with the outline it was opened with unless pages were inserted or removed, so a newly assigned (or edited) `outlineRoot` shows in memory but the file has no `/Outlines` and reopens with `outlineRoot == nil`. Only the outline: rotation, crop boxes, annotations and document attributes on the same document save normally (probed). Stamping and imposition return exactly such documents, so stamped and booklet Combine output silently lost its table of contents. **Attach outlines to `outlineReadyDocument(from:)`** (`Logic/OutlineLogic.swift`), which moves the pages into a fresh `PDFDocument()`. `write(to:withOptions:)` doesn't help except `.burnInAnnotationsOption`, which would flatten source links and markup. Test by writing and reopening with Core Graphics–drawn fixtures (`CombineBookmarkSavingTests`): `PDFPage()`-built documents dodge the bug.
- **An outline destination at `.zero` is the foot of the page** in PDF coordinates, which lands a viewer on the *next* part. Aim at the top-left of the crop box.
- **Flatten through CGPDF, not `PDFPage.pageRef`**: image pages (`PDFPage(image:)`) and blank pages (`PDFPage()`) have no `pageRef`.
- **Never call PDFKit drawing from `concurrentPerform`.** Scan analysis renders `CGPDFPage`s through Core Graphics (`renderScan`), applying PDFKit's crop box and rotation by hand; PDFKit's `draw` is about 3× slower on 600 dpi CCITT scans and not thread-safe. The analysis functions are `nonisolated` because the module defaults to `MainActor`.
- **A `PDFPage` can't draw once its document is released.** Hold the document (Stamp's `previewDocument`).
- **`PDFPageView` is an image, not a `PDFView`**: a `PDFView` showing an image-only page runs Live Text recognition, which spammed the console with TextRecognition "Unable to find a valid E5" warnings on every update. → [shared.md](shared.md#shared-infrastructure)
- **`PDFDocument.write(to:)` returns only a Bool.** Save through `savePDFDocument(_:to:)` (`Logic/PDFSaving.swift`) so a failure says why. Rotate's save uses it too now (#31).

## Split

- **`fileSizes: [Int]` is the source of truth for splits**; `splitMarkers` and `pageToFileMapping` are derived, `splitMarkers` for drawing only. → [split.md](split.md#the-model-filesizes-int)
- **`suppressDocumentReset` is the "replace in place" flag**: anything that replaces `pdfManager.pdfDocument` without wanting a full reset (swap, booklet order) sets it immediately before the assignment; `onChange` clears it, drops the undo stacks and returns, keeping `fileSizes`, `skippedPages` and `customFileNames`.
- **`suppressNextA3Detection` stops Split Double Pages being re-offered** for a document ScoreSort just produced, and only `applyScanSplit` sets it, immediately before the assignment. It is single-use: `onChange` clears it on the new-document path once checked, on the in-place path and when the document is cleared. Don't set it in an in-place rebuild (swap, booklet order): those return before the check, and the flag used to linger and suppress the offer (and the near-miss hint) on the next PDF opened (#29).
- **Set state that must survive the new-document reset *after* it**, not before the assignment: Split Double Pages hands its skips over in `pendingScanSplitSkips`, which `onChange` applies (with `skipMode = .page`) after resetting. Set before, the reset silently undid them.
- **`skipMode` is `.page` after a double-page split**: blanks come one page at a time.
- **Booklet maths: `order[readingPos] = scanPos`.** Deimposition arrays index *into* the file segment's pages: `pages[order[readingPos]]` is the absolute page placed at `readingPos`. Combine's imposition is the inverse of the same function, so the geometry has one source of truth.
- **The page-reorder UI lives inside Step 1.** A separate `A3PageOrderView` stage was built and removed (slow, with `FocusState` and keyboard problems); Swap with Next (S) and Fix Booklet Order replaced it. Don't resurrect a separate reorder stage.
- **Names follow their page** (`remapFileNames`), and every split file name goes through `splitOutputFileName` — Step 1, Step 2, Step 3, the summary, the save and the CLI — so they can't disagree. An empty base name is a real state.
- **Bookmarks are offered, never silently applied**, and name matching **falls back rather than half-filling**: if titles don't parse cleanly, use the defaults instead of guessing.

## Combine

- **Unmatched preset parts and files are left orange on purpose.** Real ensembles (Sydney school bands) have irregular parts — a bass-guitar player covering whatever part exists — that Ben is always happy to assign by hand. Prefer graceful fallback to a partial or clever fill. → [combine.md](combine.md#applying-a-preset--matchpresetpartsfiles)
- **Applying a preset ignores collate groups**: it sets `copies` on each matched `CombineFile`, but a grouped file's copies are unused — the output repeats the group `group.copies` times. Worth deciding if presets and groups are ever mixed.
- **Collate groups stay contiguous** because `createCollateGroup` and `addToGroup` place members together and every move goes through `expandForGroups`; nothing else enforces it, and nothing currently breaks it.
- **`EnsemblePresetStore` (`ensemble-presets.json`) and the Renamer's `InstrumentOrders` (`instrument-orders.json`) are independent**, as is `StampStore` (`stamps.json`). Three files, no shared state.
- **Inputs are reopened at build time, not when added.** Follow moved files by bookmark (`FollowsMovedFile`) before every output, and report what still can't be read rather than skipping it. A bookmark follows a file into the Trash, so `currentLocation(ofBookmark:)` treats a Trash path as gone.
- **Focus and selection are separate, and only selection is drawn** (`.focusEffectDisabled()`): see [combine.md](combine.md#combineview) before "fixing" Tab, the cursor row or self-focusing.

## Rename and instrument detection

- **Instrument detection is leftmost match**, not longest or first-in-order: names are tried longest first (so "bass clarinet" beats "clarinet"), each match's position is recorded, and the leftmost wins ("Baritone BC Bassoon" is a baritone). The order arrays' own order is a secondary tie-break. `detectScoreOrderInstrument`, `matchInstrumentOrder` and `partFolderName` all work this way. → [rename.md](rename.md)
- **Changing the built-in instrument orders: add names, then bump `InstrumentOrders.defaultsVersion`** (currently 9). Existing files are merged, not replaced: an order the user edited keeps its edits and gains the new names after their neighbours; an unedited one (equal to its `_base_…`) takes the new order outright, so a reordering still reaches it. Up to version 8 a bump wiped hand edits. A new name that's rare, or would otherwise come up first for every piece, also goes in `splitSuggestionWalkExcluded` (and `splitSuggestionTypedOnlyNames`), so the Split naming walk doesn't offer it as the next part. Settings ▸ Renamer saves its order into the same file (`InstrumentOrders.saveOrder`), so a saved order is an edited one and is merged, never replaced. (A file that *can't* be read is set aside first; see Saved files.)
- **Roman-numeral normalisation needs a leading space** (`" ii"`), so "celli" doesn't become "cell1"; IV is tried before I so "violin iv" isn't "violin 1v".
- **Clef matters in preset matching but not in Split's identity**: `instrumentIdentityKey` collapses Euphonium/Baritone BC and TC, the preset matcher keeps them apart because it decides which part to print.
- **Split suggestions show full saxophone names** ("Alto Saxophone") via `preferredInstrumentDisplayName`, while detection still matches "alto sax"; the suggestion walk skips aliases via `instrumentIdentityKey`.
- **Tests must never set `RenamerManager.prefixSeparator`** (it writes real defaults), and set `partFolderMode = .off` on a new `RenamerManager()`. → [tests.md](tests.md#rules-for-tests)

- **Every rename is recorded for Undo Rename** (`Logic/RenameJournal.swift`). A new rename path must record its moves (`recordRenames`, folders through `createFolderRecording`) or Undo can't put it back. Tests never write the real journal: `RenameJournal.defaultURL` is nil under tests. → [rename.md](rename.md)

## Saved files

- **Saved lists go through `Logic/SavedListFile.swift`.** Presets and stamps used to decode the whole array with `try?` and come up empty on any failure — and the next save wrote that emptiness over the user's file. Now `readSavedList` tells *missing* from *loaded* (entry by entry, so one bad entry doesn't take the rest) from *unreadable*, and `SavedListFile` sets an unreadable file aside under a dated name (`ensemble-presets (unreadable 2026-11-16).json`, numbered rather than replacing an earlier copy) **before** anything can save over it; a file with some bad entries is copied aside whole before being rewritten. If the file can't be moved or copied aside, **saving is refused** rather than risked. A failed save is reported once (again only after one has worked). The on-disk format stays a bare JSON array, so older app versions and the CLI read the same files.
- **Stores never show alerts.** `EnsemblePresetStore` and `StampStore` publish `notices: [SavedFileNotice]`; `SavedFileNoticeBanner` (`.savedFileNotices()` on the main window) shows them as dismissable strips above the tabs, with Show in Finder.
- **`instrument-orders.json` is protected the same way**: `InstrumentOrders.prepareFile(at:)` sets an unreadable file (typically a broken hand edit) aside before writing the defaults — this used to be overwritten silently — and posts `launchNotice` for the same banner. If it can't be moved, it's left alone and the built-in order is used.
- **The CLI only reads** (`readSavedList` in `savedPresets(at:)` / `savedStamps(at:)`): it never sets a file aside or rewrites it, and doesn't build a `StampStore()`, which seeds a placeholder stamp. It does say why — an unreadable file is an error with the reason, skipped entries a note — rather than reporting "no presets". → [cli-mcp.md](cli-mcp.md)
- **Stores take an injectable `fileURL`** (`nil` = memory only). Tests never use the default URL.

## Menus and keyboard

- **Menus bind only non-editing modifier shortcuts.** SwiftUI `CommandMenu` shortcuts intercept keys globally **even when the item is `.disabled()`** — a menu ⌘A broke ⌘A in the save panel's text field. So ⌘A, ⌘Z, ⌫ and all bare keys (Space, S, R, `,` `.`, arrows) stay in each tab's `onKeyPress` or `NSEvent` handler with text-field guards, and are listed in `ShortcutsHelpView`. → [shared.md](shared.md#menu-bar)
- **Delete/backspace uses `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`**: SwiftUI's `onKeyPress` doesn't reliably catch it on macOS. Return the event (don't consume it) when an `NSTextView` is first responder or a sheet is key.
- **Every key handler and monitor checks `appState.selectedTab`**: `TabView` keeps hidden tabs mounted, and the monitors are app-global. Only the active tab writes the menu slice, for the same reason.
- **The Actions menu's title is fixed**: SwiftUI can't reliably retitle a `CommandMenu`; only its contents swap.
- **A pull-down `Menu` is focusable by default** and can take the focus ring (and the arrow keys) from a page navigator — `StampMenuButton` is `.focusable(false)`.
- **The Stamp tab's arrows give way to the text editor**: its `onKeyPress` ignores keys while an `NSTextView` is first responder.

## SwiftUI and AppKit

- **Every icon-only button needs a spoken label** (#22): `.accessibilityLabel(...)` at the end of the icon's modifier chain (the button takes it from the image), or `.accessibilityHidden(true)` for a decorative icon whose button has text. Without one, VoiceOver reads the SF Symbol's name ("Backward Chevron Pointing To A Line"); `.help` is a tooltip, not a label. `AccessibilityTests.iconButtonsAreLabelled` scans the sources and fails on a new unlabelled one. Meaning shown only by colour (Combine's orange and blue rows, Split's current and selected cards) goes in `.accessibilityValue`. Mouse-only gestures need another way in: the scan preview has an adjustable cut (1% a step) and Skip/Keep actions, and the stamp has the nine-position grid. `PDFPageView` is one image element named by its page (`accessibilityName` adds "Before"/"After").

- **`.sheet(item:)`, not `.sheet(isPresented:)`** — the latter showed a blank sheet (first seen with `ManualAssignmentView`). And **one `.sheet` per view**: two on the same view fight over presentation (Combine routes its booklet intro and wizard through one `CombineSheet` enum).
- **Don't duplicate `FocusState` across parent and child**: pass `FocusState<T>.Binding`; a local copy steals the first click in a `TextField`.
- **`editMode` is iOS-only.** On macOS `ForEach.onMove` inside a `List` gives drag-to-reorder for free.
- **`.clipped()` doesn't restrict hit testing.** Use `.allowsHitTesting(false)` on an image drawn with `.fill` that would otherwise take clicks meant for views below (it bit `PageInstrumentPreview` in `SplitFileNamingRow`).
- **No segmented `Picker` in cells of a lazy grid**: an `NSSegmentedControl` in every `ScanSplitCard` crashed in AppKit (`-[NSSegmentedCell _segmentsDeselectedBySegment:]`) as the grid recycled cards. Use plain buttons drawn as a segmented control.
- **Nested `ForEach` inside a `LazyVStack` can draw a stale plan**: the Score Order Sorter's nested `ForEach(folderGroups) { ForEach(group.operations) }` kept showing an old grouping after it changed (rows read "Brass/…" with folders off while the status line was current). It's now one flat `ForEach(matchedListItems)` of `MatchedListItem`.
- **A nested `ObservableObject` doesn't notify views observing its owner**: reading `appState.stampFormatter.isBold` from a tab's body went stale. Observe the inner object directly (`StampStyleButtons` takes `@ObservedObject`).
- **Don't publish from inside a view update.** It logs "Publishing changes from within view updates". Defer with `DispatchQueue.main.async` (every `syncTabCommands()` call, Stamp's draft → store), use `Binding.deferredCommit()` on a segmented `Picker` bound to an `@Published`, call `refreshStateSoon()` from `makeNSView`/`updateNSView`, and guard assignments that would write the same value (it still fires `objectWillChange`).
- **Present a print dialog from the next runloop turn, on `NSApp.keyWindow`** while a sheet is up: presenting from inside a button's update pass logs "not legal to call -layoutSubtreeIfNeeded…", and a second sheet on the main window queues behind the first.
- **Open and save panels are sheets: `beginSheetModal(for:)`, never `begin {}`**, which greys out and locks the main window (the Word-style behaviour Ben asked for) and stops keystrokes leaking to the window behind. Use **`beginPanelSheet(_:completion:)`** (`ScoreSort/PanelPresentation.swift`): it attaches to the *key* window (so a panel opened from a sheet attaches to that sheet), else runs app-modal. Combine calls `beginSheetModal` itself, with `CombineMenuState.isPanelOpen` set around it; the AI Assistants pane likewise. The app-global `NSEvent` key monitors (Combine, Split, Rename) also return early when `NSApp.keyWindow?.isSheet`, so ⌫ in a panel's file list or a SwiftUI sheet never reaches the tab. Settings ▸ Combiner's preset CSV import/export still uses `runModal()` (app-modal, so nothing leaks).
- **Folder pickers set `canCreateDirectories = true`**; output panels start in the source file's folder (`outputDirectory(forSourceFile:)`).
- **Reset buttons are bordered (square) `Button`s, not `.buttonStyle(.plain)`**, which only registers hits on the glyphs. Labels: "Clear File" (Split, Rotate), "Clear Files" (Combine, Rename, Bulk Rename, Stamp).
- **Done screens accept drops**: dropping a new folder or PDF on a summary restarts the flow (Split, the Score Order Sorter, Bulk Rename) without clicking Start Over.
- **The app quits when its window closes** (`applicationShouldTerminateAfterLastWindowClosed`), but only once the main window has appeared — see [releasing.md](releasing.md#how-sparkle-is-wired).
- **`Unchecked<T>` has an explicit empty `deinit`** to dodge a Release-mode compiler crash. Leave it.

## Performance

- **Never re-render a page or reload a PDF per frame.** The first Stamp preview did both and was unusable; it now caches the page image and draws only the stamp in a `Canvas`. → [stamp.md](stamp.md#preview--stamppreviewcanvas)
- **Debounce saves while typing** (`StampStore.scheduleSave`, 0.4 s) and flush when leaving the tab.
- **Keep big pickers out of the redraw path**: the ~300-row font picker is `Equatable` and `.equatable()`.
- **Render many scan pages in parallel through Core Graphics**, never PDFKit (see PDFKit above); the CLI's `preview --top --sheet` path is what assistants use to read part names, so keep it fast and small.

## Printing and booklets

- **Print through PDFKit, never a hand-rolled view**: `PDFDocument.printOperation(for:scalingMode:autoRotate:)` works; `NSPrintOperation(view:)` with a custom page-drawing `NSView` (the first attempt) and AppleScript automation both fail. → [printing-booklets.md](printing-booklets.md#printing--logicprintlogicswift)
- **Duplex can't be set from code**: the print panel overwrites the duplex setting from the printer's preset as it appears (measured exhaustively; `PMSetDuplex` isn't in the public SDK). The layout compensates instead: `BookletDuplexFlip.longEdge` rotates every back face 180°.
- **The compensation applies on the print path only** (`printCombined` and the test sheet). Create PDF and Preview stay upright: exporting a booklet to print elsewhere is normal, and the printer is unknown at export time. Don't extend it to saved output.
- **The flip is stored per printer** (`BookletDuplexDefaults`), not in `@AppStorage`: it's a property of the machine.
- **When probing the print dialog, always set `info.jobDisposition = .save` first.** Dismissing a print sheet programmatically (e.g. `window.endSheet(_:)`) reads as OK and spools a real job to a real printer — it has happened.
- **Set `orientation` from the document's own page size, keep centring on, and use `.pageScaleDownToFit`.** Landscape sheets otherwise land on portrait paper; the fold must sit at the paper's centre (centring only translates); 1:1 clips at the printer's unprintable margin. `.pageScaleDownToFit` ignores `NSPrintInfo.scalingFactor`, so the dialog's Scale box is inert by design — scaling is `CombineOutputOptions.bookletPageScale`, applied in the imposition so it reaches Create PDF and Preview too.
- **Booklet printing is not a macOS feature** (a PPD option at best; AirPrint never offers it). ScoreSort imposes and prints an ordinary two-up PDF — a driver's Booklet option would double-impose.
- **Don't add creep compensation or a creep warning**: parts are folded and stapled, never trimmed. → [printing-booklets.md](printing-booklets.md#imposition--logicbookletlogicswift)

## Command line and MCP

- **"Is this the same file?" is `isSameFile`, never a path comparison** (#30). Mac disks usually ignore case, so `Part.PDF` and `part.pdf` are one file; so is a path through a symlinked folder. An exact `standardizedFileURL ==` let a stamped `Part.pdf` replace `Part.PDF`. `isSameFile` compares the file system's own identifier, so it's also right on case-sensitive disks, and it's false for a file that doesn't exist yet.
- **Change behaviour in the shared logic, not in a command**, or the app and the CLI drift. → [cli-mcp.md](cli-mcp.md)
- **MCP stdout is protocol only**: `run()` writes to a `dup` of fd 1 and points fd 1 at stderr. Never `print` to the protocol handle.
- **Only an explicit verb switches to command-line mode** (Xcode and Launch Services pass `-NS…` arguments), and never under tests.
- **MCP tool hints are per tool**, so they describe the worst case over its arguments (`preview` and `rename` are not read-only).
- **`find` searches only folders the user shared.** Searching Downloads/Desktop/Documents showed an assistant CVs and bank statements, and leaned on folder permissions Apple keeps tightening. A file dragged into a chat is a copy in the conversation, never on the Mac.
- **Never open a cloud-only file** (`SF_DATALESS`) to count its pages: reading it downloads it.
- **Connecting to Claude rewrites its config only while Claude is quit**, because Claude writes back its in-memory copy. Never test Connect from a Claude Code session running inside the Claude app: quitting Claude ends the session.
- **Run a debug binary from outside the repo**: it's coverage-instrumented and drops `default.profraw` in its working directory (and the debug MCP entry sets `LLVM_PROFILE_FILE=/dev/null`).
