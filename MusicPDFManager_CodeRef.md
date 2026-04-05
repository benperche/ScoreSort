# Music PDF Manager — Code Reference
> Single file: `ScanReorienterApp_complete.swift` (3219 lines)
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
```

Window min size: 900×700.

---

## Tab 0 — Combine PDFs

**View:** `CombineView`  
**ViewModel:** `CombineManager: ObservableObject`  
**Model:** `CombineFile: Identifiable` (id, url, name, pageCount, copies: Int)  
**Row:** `CombineFileRow`

### CombineManager key methods
| Method | Purpose |
|--------|---------|
| `addFiles(urls:)` | Reads PDFs via PDFKit, appends CombineFile |
| `removeFiles(ids:)` | Removes by UUID set |
| `updateCopies(for:copies:)` | Clamps to min 1 |
| `moveUp/Down(id:)` | `swapAt` |
| `createCombinedPDF(to:addBlankPages:)` | Writes to URL |
| `openInPreview(addBlankPages:)` | Writes temp file → NSWorkspace.open |

**Computed:** `totalFiles` = sum of copies; `totalPages` = sum of pageCount×copies.

**Blank page logic:** If `addBlankPages` and file has odd pageCount, insert a blank PDFPage after its last copy's pages.

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
Three static arrays: `band`, `jazz`, `orchestra`. Loaded via `getOrder(for: EnsembleType)`.  
`customInstrumentOrder` starts from the active preset; `hasCustomOrder` flag prevents preset changes from overwriting user edits.

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

**View:** `SplitView`  
**ViewModel:** `PDFManager` (shared type, also used by RotateView — each tab creates its own `@StateObject`)  
**Key state:** `splitMarkers: Set<Int>`, `customFileNames: [Int: String]`, `baseFileName: String`

Split markers define where new files begin. `pageToFileMapping` computed from markers → consecutive page ranges → file indices.

Output naming: if `customFileNames[fileIndex]` exists and non-empty → `"\(baseFileName)\(suffix).pdf"`, else `"\(baseFileName)_\(fileIndex+1).pdf"`.

Base filename edited via popup sheet (not inline lock button — previous bug fix).

Keyboard: Space = toggle marker on current page; ←/→ = navigate. Focus must be on preview area.

---

## Tab 3 — Rotate Pages

**View:** `RotateView`  
**ViewModel:** `PDFManager`

Controls: `baseRotation: RotationAngle` (all pages) + `additionalRotationMode: RotationMode` (odd/even/none) + `additionalRotationAngle`.

Preview: `PDFPageView: NSViewRepresentable` wrapping `PDFView`. Renders page to `NSImage` first (via `renderFullImage`) to avoid mutating shared page state, then sets `clonedPage.rotation`.

Save: `PDFManager.saveRotatedPDF(to:baseRotation:additionalRotationMode:additionalRotationAngle:)` — iterates pages, mutates `page.rotation` on copy, writes new document.

### Supporting enums
```swift
enum RotationAngle: Int { case none=0, rotate90=90, rotate180=180, rotate270=270 }
enum RotationMode { case odd, even, all, none }
```

---

## Shared Infrastructure

**`PDFManager: ObservableObject`** — used by both SplitView and RotateView (separate instances).  
- `loadPDF(from:)`, `clearPDF()`  
- `saveRotatedPDF(...)`, `saveSplitPDF(...)`

**`PDFPageView: NSViewRepresentable`** — safe preview clone via `renderFullImage(from:) -> NSImage?` using `NSGraphicsContext` / `CGContext`.

---

## Known Patterns & Gotchas

- **`.sheet(item:)` not `.sheet(isPresented:)`** — used for ManualAssignmentView to avoid blank sheet bug.
- **Instrument detection is leftmost-match**, not longest-match or order-match, to handle compound names.
- **`bass clarinet` before `clarinet`** in lists — length-sort in detectInstrument handles this, but the order in the static arrays also matters as a tie-break (same position → lower original index wins).
- **`canCreateDirectories = true`** set on NSOpenPanel for folder selection.
- **Print automation not possible** — NSPrintOperation / AppleScript all fail reliably; "Open in Preview" + ⌘P is the documented workflow.
- **App quits on window close** via `NSApplicationDelegateAdaptor(AppDelegate.self)` returning `true` from `applicationShouldTerminateAfterLastWindowClosed`.
