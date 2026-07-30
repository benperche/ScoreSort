# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

ScoreSort is a macOS SwiftUI app for managing music PDFs. It has five tools, each a tab: Combine PDFs, Sheet Music Renamer, Split PDF, Rotate Pages, Stamp. macOS 14.0+, Xcode 16+. Bundle id `benperche.ScoreSort`. Distributed via GitHub releases with Sparkle auto-update; App Store planned.

## Read this first

**`ScoreSort_CodeRef.md` is the authoritative map of the codebase** — a detailed, per-tab breakdown of every view, view model, data model, pure function, and known gotcha. Read it before exploring or modifying code; it is far faster than reading the source directly. Keep it updated when you change architecture.

## Code layout

The app is split by feature. **Each tab has its own file(s); shared app scaffolding remains in `ScoreSort/ScanReorienterApp_complete.swift` (~1,700 lines).**

- **Tabs:** `Combine/CombineTab.swift`; `Rename/RenameViews.swift` + `Rename/RenamerManager.swift`; `Split/SplitView.swift` (Step 1) + `Split/SplitNaming.swift` (Step 2) + `Split/SplitPrefixStep.swift` (Step 3, shared with Bulk Rename); `Rotate/RotateTab.swift`; `Stamp/StampTab.swift` (⌘5 — designs stamps + stamps existing PDFs) + `Stamp/StampStore.swift`. `StampTab.swift` also holds `StampMenuButton`, the toolbar pull-down Combine and Split use to stamp their own output.
- **Pure logic** (`ScoreSort/Logic/`): `InstrumentNames.swift` (preset matching + split instrument suggestions/detection), `SplitLogic.swift` (split maths, A3, bookmarks, booklet), `RenameLogic.swift` (folder-job helpers + score-order numbering), `FileUtilities.swift` (output dir, filename validation, permissions, page-range formatting), `StampLogic.swift` (stamp model, placement, drawing, flattening).
- **The main file (`ScanReorienterApp_complete.swift`)** now holds only the shared scaffolding: `@main` app + `ContentView`, `AppState`, the menu-command structs + `CombineMenuState`, Sparkle updater, About/AppDelegate, the welcome tour, **all three Preferences panes**, and shared infra (`DropZoneView`, `PDFPageView`, `PDFManager`, Sendable utils). The filename is legacy and doesn't match the app name (renamed from "Music PDF Manager" / "Music PDF Wrangler").

It's all **one module/target**, so functions/views call across files with no imports and access control is unchanged (helpers used across files are `internal`, not `private`). **When searching, grep the whole `ScoreSort/` tree.** The Xcode project uses **filesystem-synchronized groups**, so any `.swift` file added under `ScoreSort/` compiles automatically — no `.pbxproj` edits to add files. When extracting further, cut along `// MARK:` boundaries and build + run the full suite (incl. `ViewSmokeTests`, which host each tab and catch a view that fails to construct) after each move.

## Build, run, test

```bash
# Build (Release is the default config if -scheme/-configuration omitted)
xcodebuild -project ScoreSort.xcodeproj -scheme ScoreSort -configuration Debug build

# Run all tests
xcodebuild -project ScoreSort.xcodeproj -scheme ScoreSort test

# Run a single test suite or test (Swift Testing -> use the filter)
xcodebuild -project ScoreSort.xcodeproj -scheme ScoreSort test \
  -only-testing:ScoreSortTests/CombineManagerTests
```

Day-to-day, the app is normally built and run from Xcode with ⌘R.

## Tests

- Target `ScoreSortTests`, single file `ScoreSortTests/Music_PDF_ManagerTests.swift` (note the legacy name), `@testable import ScoreSort`.
- Uses the **Swift Testing** framework (`@Suite` / `@Test` / `#expect`), not XCTest.
- Tests target the **pure functions and view-model logic** (split-size math, instrument detection, roman-numeral normalisation, booklet deimposition permutations, A3 detection/splitting, combine page-count output). UI/integration is not tested.
- `writePDF(pages:to:)` is the shared helper that produces real PDFs via PDFKit for tests.

## Architecture notes that span files/concepts

- **MVVM with `ObservableObject` view models**, injected as `@EnvironmentObject` at app level: `AppState`, `RenamerManager`, `EnsemblePresetStore`, `StampStore`. `PDFManager` is shared by the Split and Rotate tabs as *separate* `@StateObject` instances. `CombineManager` backs the Combine tab.
- **Three independent persistence files** in `~/Library/Application Support/ScoreSort/`: `ensemble-presets.json` (Combine tab presets — names + per-part copy counts), `instrument-orders.json` (Renamer tab instrument order — name strings only, versioned, regenerated on launch if stale), and `stamps.json` (saved stamp designs, `StampStore`). These systems do not interact.
- **Stamp text is rich text** — `Stamp.richTextData` (RTF) is the source of truth when present, so bold/italic/font/size/colour vary run by run; `fontFamily`/`isBold`/… are only the *base* attributes for unformatted text. Editing goes through `StampTextEditor` (an `NSTextView`; SwiftUI's `TextEditor` can't carry attributes on macOS 14) and `AppState.stampFormatter`.
- **Stamping flattens into page content** (`Logic/StampLogic.swift`) — it rebuilds pages through a `CGPDFContext`, so it **drops document outlines and source annotations**. Anything that stamps must do so *before* building a `PDFOutline` (page indices survive). It reads the **crop box**, not the media box, or A3-split halves come back.
- **The menu bar is standard File / Edit / View + one adaptive "Actions" menu.** Each tab publishes a `TabSlice` (contextual Open/Save/Preview/Clear closures + a `[MenuAction]` list) into the app-level `TabCommands` bridge (`AppState.tabCommands`) via its own `syncTabCommands()`, called on `.onAppear` and relevant `.onChange`. **Only the active tab writes** — every `syncTabCommands()` guards on `appState.selectedTab == myTab`, so the slice always reflects the on-screen tab. The command structs (`FileCommands`/`ViewCommands`/`TabActionsCommands` in the main file) read the slice. `CombineMenuState` still exists for Combine's bare-key `onKeyPress` selection nav (arrows/c) + `isPanelOpen`.
- **Menus bind only non-editing modifier shortcuts** (⌘S/⌘O/⇧⌘P/⌘⌫/⌥⌘P/⌘1–5, plus Format's ⌘B/⌘I — safe because nothing else uses them and `StampTextFormatter` is inert unless a stamp text view is focused). Standard-editing keys (⌘A/⌘Z/⌫) and all bare keys (Space, S, R, `,` `.`, arrows) stay in each tab's `onKeyPress`/`NSEvent` handlers with their text-field guards, and are documented in `ShortcutsHelpView` (the ⌘` overlay) — the complete shortcut reference. The "Actions" menu title is fixed (SwiftUI can't reliably retitle a `CommandMenu`); its contents swap per tab.
- **PDF export methods never show UI** — they take a `PDFAlertHandler` callback (`(title, message, isError) -> Void`). Surface errors through that, not directly.
- **Instrument detection is leftmost-match** (not longest-match), with a length-descending sort as tie-breaker so "bass clarinet" beats "clarinet". The static order arrays' ordering also matters as a secondary tie-break.

## Known gotchas (see CodeRef "Known Patterns & Gotchas" for the full list)

- **`fileSizes: [Int]` is the source of truth for splits**; `splitMarkers` is a *derived* computed property for rendering only.
- **`suppressDocumentReset` / `suppressNextA3Detection`** are flags set immediately before replacing `pdfManager.pdfDocument` in-place (page swap, booklet reorder, A3) so `onChange` doesn't wipe split state or re-trigger detection.
- **`page.rotation` is clockwise degrees** (PDF spec). A3 splitting and `isA3Landscape` must swap width/height when `rotation % 180 != 0`, and split along the Y axis for 90°/270° pages. The Rotate tab uses rotation *metadata*, not geometric transforms.
- **`.sheet(item:)` not `.sheet(isPresented:)`** to avoid a blank-sheet bug.
- **Don't duplicate `FocusState` across parent/child** — pass the `Binding`; a local copy steals the first TextField click.
- **`editMode` is iOS-only**; on macOS `ForEach.onMove` inside a `List` gives drag-to-reorder for free.
- **Print automation is impossible** (NSPrintOperation/AppleScript all fail) — the supported flow is "Open in Preview" then ⌘P.

## Design decisions & rationale (from the build history)

These are non-obvious *whys* established across the sessions that built the app — respect them rather than re-litigating:

- **PDF export methods take a `PDFAlertHandler` callback instead of showing alerts** — done both for testability (it unblocked unit-testing `createCombinedPDF`) and because Ben deliberately wanted fewer alert dialogs in the UX. Don't reintroduce `NSAlert` inside manager/model methods.
- **⌘A / standard-editing keys are handled in `onKeyPress`, never as a `CommandMenu` `.keyboardShortcut`** — SwiftUI `CommandMenu` shortcuts intercept globally *even when the menu item is `.disabled()`*, which broke ⌘A inside the save panel's text field. This is why the menu bar deliberately binds only *non-editing* modifier shortcuts (see the architecture note above). Combine-tab shortcuts are additionally gated on `CombineMenuState.isPanelOpen`.
- **File open/save panels use `beginSheetModal(for:)`, not `begin { }`** — the sheet-modal form greys out and locks the main window (matching Word-style behaviour Ben asked for) and stops keystrokes leaking to the main window behind the panel.
- **The A3 page-reorder UI lives inside Step 1, not a separate stage.** A dedicated `A3PageOrderView` was built and then removed — it was slow and had `FocusState`/keyboard problems. The replacement is "Swap with Next" (`S`) in Step 1 plus the "Fix Booklet Order" sheet. Don't resurrect a separate reorder stage.
- **Delete/backspace uses `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`** — SwiftUI's `onKeyPress` does not reliably catch the delete key on macOS.
- **Preset/name matching prefers graceful fallback over partial fill** — if bookmark labels don't cleanly parse as `"NN - Piece - Part"`, fall back to default behaviour rather than half-filling. Unmatched files/parts are highlighted orange and left for manual matching on purpose: real ensembles (Sydney school bands) have irregular parts — e.g. bass-guitar players covering whatever part exists — that Ben is always happy to assign by hand.
- **Version comes from `Bundle.main` `CFBundleShortVersionString`**, not a hardcoded constant, and tracks the GitHub release version.
- **Distribution is unsigned direct distribution** (Gatekeeper "Open Anyway" workaround documented in the README), chosen over the App Store / paid signing at beta stage.

## Workflow conventions (from project memory)

- Work happens in a git worktree; merge and push directly to `main` — no extra feature branches needed.
- When switching worktrees, remember to switch the branch in Xcode too.
- **Commit after every substantial change** — i.e. at the end of each prompt that produces a working, building change, without waiting to be asked. Group the change into one descriptive commit; don't batch multiple prompts' worth of work into a single commit. Trivial/no-op changes don't need their own commit.
- **Batch your pushes, don't push after every commit.** Every push to `main` triggers a **legacy GitHub Pages build** (source = `main` `/docs`), which serves the Sparkle **appcast** at `benperche.github.io/ScoreSort/appcast.xml`. A rapid burst of pushes races those builds and can **wedge one in `building`**, which holds the `github-pages` environment lock and makes every later deploy fail with *"Deployment failed, try again later."* So: commit freely, but `git push` **once at the end** of a working session (or a small handful of times), not after each commit. GitHub's status page will still say "operational" — it's a per-repo stuck build, not an outage.
- **If Pages is stuck** (deploys failing / `gh api repos/benperche/ScoreSort/pages --jq .status` shows `building` and not clearing): request a fresh build to supersede the wedged one — `gh api -X POST repos/benperche/ScoreSort/pages/builds` — then confirm `…/pages/builds/latest` reaches `built` and the live appcast shows the new version. (Manual equivalent: Settings ▸ Pages / Environments ▸ github-pages.) The DMG + GitHub Release are unaffected by this — only the appcast feed is delayed.
