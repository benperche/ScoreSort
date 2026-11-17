# Booklets, two-sided setup and printing

Combine's booklet output and everything about printing. Files: `ScoreSort/Logic/BookletLogic.swift` (imposition), `Logic/BookletCalibration.swift` (the generated test sheet, per-printer duplex memory), `Logic/PrintLogic.swift` (the system print dialog), `Combine/BookletLayoutSheet.swift` (page-turn review), and in `Combine/CombineTab.swift`: `CombineOutputOptions`, `buildDocument`, `printCombined`, `BookletIntroView`, `BookletDuplexSetupView`, `CombineOutputMenuButton`, `BookletScaleField`.

The other direction — un-scrambling a *scanned* booklet into reading order — is Split's Fix Booklet Order: [split.md](split.md#fix-booklet-order-deimposition). The rest of Combine (the file list, presets, `buildDocument`'s order stamp → impose → outline): [combine.md](combine.md#output).

Gotchas: [gotchas.md § Printing and booklets](gotchas.md#printing-and-booklets).

**Booklet printing is not a macOS feature.** It comes from a printer driver's PPD when it exists at all, and AirPrint queues (the default since Apple deprecated PPD drivers in 10.15) never expose it. So ScoreSort imposes the sheets itself and prints an ordinary two-up PDF. Don't build on a driver's Booklet option; leaving one switched on would double-impose already-imposed sheets.

## Imposition — `Logic/BookletLogic.swift`

Reading order in, printer sheet order out. Used only by Combine (the CLI's `combine --booklet` goes through the same `buildDocument`).

| Symbol | Behaviour |
|--------|-----------|
| `BookletSheetSize` | `.doubleSize` (two pages side by side at full size — A4 parts give A3 sheets; needs an A3 printer) / `.fitA4Landscape` (scaled onto 842 × 595, an A5 booklet). `label`, `shortLabel` ("A3"/"A5"). |
| `bookletImpositionOrder(n:)` | `order[sheetSlot] = readingPos`, slots `[front-left, front-right, back-left, back-right]` per sheet. **The inverse of `coverFirstFrontBackOrder(n:)`** (Split's deimposition), so the sheet geometry has one source of truth. `[]` unless n ≥ 4 and n % 4 == 0. 1-based: N=4 → 4,1 · 2,3; N=8 → 8,1 · 2,7 · 6,3 · 4,5. |
| `bookletPaddedCount(_:)` | Up to a whole folded sheet: 0 → 0, 1 → 4, 5 → 8. |
| `BookletPartLayout` | Per part: `.folded` (saddle stitch, nested sheets — 4\|1, 2\|3) or `.flat` (reading order two-up, printed both sides, read open — 1\|2, 3\|4). Same imposition, different slot order: a choice of **where the page turns fall**, because publishers design page turns and the right answer differs part to part. `spreadDescription(pageCount:)` ("1 · 2–3 · 4"). |
| `bookletSpreads(pageCount:layout:)` | The pages visible at once, 1-based. Grouped over the padded length, then padding is trimmed: a 3-page flat part is "1–2 · 3", not "1–2 · 3–4" (naming a page that doesn't exist is worse than saying nothing). |
| `bookletDefaultLayout(pageCount:)` | `.flat` for exactly 2 pages (side by side, no turn — the one case where folded is simply worse), otherwise `.folded`. `CombineFile.bookletLayout == nil` means "this default". |
| `bookletSlotOrder(pageCount:layout:)` | `.folded` → `bookletImpositionOrder` of the padded count; `.flat` → `0..<padded`. Positions past the part's end are padding, left blank. |
| `bookletFitsOneSheetFace(pageCount:layout:)` | Everything fits on the front of the sheet (1 page, or 2 laid flat) — derived from the slot order, not hard-coded. Drives single-sided output. |
| `bookletSegments(pageCount:partFirstPages:)` | One range per booklet from the first page of each part. The first always starts at 0, so pages ahead of the first part (a blank inserted at the top) aren't dropped; out-of-range, duplicate and unsorted indices are ignored. |
| `bookletSheetCount(segments:)` | Sheets of paper: padded ÷ 4, summed. |
| `bookletPageScaleRange` | `0.5...1.5`, the clamp on `pageScale`; the UI (`BookletScaleField`, `@AppStorage("combineBookletScalePercent")`) clamps to the same range, so the field shows what the output uses. |
| `BookletDuplexFlip` | `.longEdge` (default) / `.shortEdge`; `rotatesBackFaces` is true for `.longEdge`. **Describes the printer's behaviour rather than requesting it** (duplex can't be set from code — see below). |
| `imposedBookletDocument(_:segments:sheetSize:pageScale:rotateBackFaces:layouts:omitBlankFaces:)` | Rebuilds the document as sheets, one booklet per segment → `(doc, sheetStarts)`, `sheetStarts` index-aligned with `segments` (an entry even for an empty segment, so outline labels line up). |

**How `imposedBookletDocument` draws.** The same `CGDataConsumer` + `beginPage(mediaBox:)` pipeline as `stampedDocument`, so **annotations, links and outlines are dropped** — the caller builds the outline on `outlineReadyDocument(from:)` of the result ([gotcha](gotchas.md#pdfkit-and-pdf-geometry)).
- Sheet size follows each segment's first page (`visualPageBox`, crop box, rotation-aware), so A5 parts give A4 sheets.
- Each half is drawn with `page.getDrawingTransform(.cropBox, rect: half, rotate: 0, preserveAspectRatio: true)` + `drawPDFPage`, which handles placement, scaling **and** the page's own `/Rotate` in one step. That's why both sheet sizes share the code and mixed page sizes degrade gracefully (each centred and fitted in its half).
- **`pageScale`** sizes each page *within its half*, about the half's centre: 1.0 fits exactly, 1.03 draws the music 3% larger, 0.95 leaves more air. Published music doesn't match A4, so this is the dial for it. It is safe because `ctx.clip(to: half)` happens first, in sheet coordinates (an oversized page is trimmed at the half's edge and can't bleed across the fold), and the scale is applied **before** the fit transform, so it scales the *fitted* page about the half's centre: the fold doesn't move and the halves stay mirror images. Because it lives in the imposition, it reaches **Create PDF and Open in Preview as well as Print**.
- **`rotateBackFaces`** turns every second face (each sheet's back) 180°. A long-edge duplexer turns a *landscape* sheet upside down between sides; confirmed on paper, where unrotated backs printed inverted.
- **`omitBlankFaces`** (single-sided) skips faces with nothing on them. They exist only to start the next part on a fresh sheet when printing two-sided. Only safe when *no* part needs its back, or a folded part would lose the half it pairs with — so `CombineView.canGoSingleSided` requires every part to `bookletFitsOneSheetFace`, and the toggle ("Single-sided — leave out the blank backs", `@AppStorage("combineSingleSided")`) is disabled otherwise.

**Creep is deliberately not compensated, and shouldn't be.** In a saddle-stitched booklet the inner sheets stick out at the fore-edge by the thickness of the sheets around them; compensation shifts inner pages toward the fold so margins line up *after trimming flush*. ScoreSort's users fold and staple — nothing is guillotined, so nothing is clipped, and untrimmed creep is a slight stair-step on the outer edge. It's negligible anyway (80 gsm ≈ 0.1 mm, so a 12-page part protrudes about 0.3 mm). Don't add compensation, and don't add a warning: it would flag a problem that never shows and could push someone into splitting a part into signatures for nothing.

### In Combine

`CombineOutputOptions` (`layout`, `sheetSize`, `bookletPageScale`, `addBlankPages`, `singleSided`, `duplexFlip`) is assembled by `CombineView.outputOptions` from the `CombineOutputMenuButton` pull-down: Single Pages / Booklet, sheet size, scale, Set Up Two-Sided Printing…, blank page after odd-length parts (single pages only — in booklet mode padding to whole sheets supersedes it), single-sided, and **Booklet Page Turns…** (⌘T).

`buildDocument` segments the stamped document at the bookmark indices (one per part per copy, so seven copies of a part are seven booklets), passes each segment's `effectiveBookletLayout`, and maps each bookmark to its sheet through `sheetStarts`. `totalBookletSheets` counts paper the same way for the output summary.

**Page-turn review** — `BookletLayoutReviewView` (`Combine/BookletLayoutSheet.swift`, ⌘T, booklet output only): one part at a time, large enough to see whether there's a rest at the foot of the page you'd turn — that's the whole decision, and it can't be worked out from page counts. Folded/Flat per part (`CombineManager.setBookletLayout`), and "apply to all" (`applyBookletLayoutToUndecided`), which leaves parts already decided and reports "Applied to N parts · M kept your setting". Pages render on the main actor a page at a time with a yield between (the module is `MainActor` by default, and making the PDF helpers `nonisolated` would cascade into the shared stamp code); the next part is fetched while one is read. `CombineFileRow` shows each part's layout inline too.

## Where the duplex compensation applies

`buildDocument(options:stampJob:rotateBackFaces:)` defaults the flag to false. Only **`printCombined`** (via `shouldRotateBackFaces`: booklet layout and a flip that rotates) and the **two-sided test sheet** (`bookletCalibrationSheet(… rotateBackFaces: duplexFlip.rotatesBackFaces)`) pass true:

| Output | Back faces |
|--------|------------|
| Create PDF | upright — a reading spread you can check on screen |
| Open in Preview | upright |
| Print… | rotated, to survive the duplexer |
| Set Up Two-Sided Printing… test sheet | rotated (it must match a real run) |

This is deliberate. Exporting a booklet to print later is a normal workflow — assembled at home in the morning, printed at a school that afternoon, or emailed to whoever does the printing. The printer is unknown at export time, so a saved file must be an ordinary, sensible booklet: readable on screen, page order solved, leaving whoever prints it to apply their knowledge of their own machine. Pre-rotating it would be the app being clever about hardware it knows nothing about, and would look like a bug to anyone opening the file. **Don't extend the compensation to Create PDF or Preview**, and don't frame exporting-then-printing as a mistake in user-facing text.

## Two-sided setup — `Logic/BookletCalibration.swift`

Which flip a printer needs **can't be found in software**, so the app asks the paper.

| Symbol | Behaviour |
|--------|-----------|
| `bookletCalibrationPages()` | Four A4 reading pages, each a large numeral and a line of instruction, drawn with `NSAttributedString` into a `CGPDFContext` through `NSGraphicsContext(cgContext:flipped: false)`. |
| `bookletCalibrationSheet(sheetSize:pageScale:rotateBackFaces:)` | Those pages through **the real `imposedBookletDocument`** — one physical sheet. Using the genuine imposition is the point: a mocked-up sheet would prove nothing about real booklets. |
| `BookletDuplexDefaults` | `flip(forPrinter:)` / `setFlip(_:forPrinter:)` over a `[String: String]` in `UserDefaults` (`combineDuplexFlipByPrinter`; `.longEdge` when unknown), and `currentPrinterName` (`NSPrintInfo.shared.printer.name`; empty when no printer is set up, which counts as its own "printer"). |

**Generated pages, not the user's music**: made-up pages can carry their own instructions and work before any files are added, so a new printer can be set up from a standing start. The test reduces to "fold it — do the pages read 1, 2, 3, 4 the right way up?", with no need to understand long versus short edges.

**The flow.** The first time the output menu is switched to Booklet (`@AppStorage("combineBookletIntroShown")`), `BookletIntroView` explains two-sided printing and offers to print the test sheet — it lives here rather than in the welcome tour because the tour shows once per install, and existing users are exactly the ones meeting booklets for the first time. Both it and **`BookletDuplexSetupView`** (the wizard: intro → print → "did it come out right?" → on "They're upside down" it flips the setting itself and offers another sheet) are cases of one `CombineSheet` enum behind a single `.sheet(item: $activeSheet)`: two `.sheet` modifiers on one view fight over presentation, and the intro hands straight to the wizard (`startAtCheck`).
- `printCalibrationSheet()` presents the print dialog on **`NSApp.keyWindow`**, which while the wizard is up is the wizard's own sheet window — a second sheet on the *main* window would queue behind the wizard instead of appearing.
- The hand-over is wrapped in `DispatchQueue.main.async` (twice: the intro dismisses, the wizard appears, then the print starts). Presenting the print dialog from inside the button's own update pass makes AppKit log "not legal to call -layoutSubtreeIfNeeded on a view which is already being laid out".
- **The intro, the wizard and the menu's help all warn that the dialog's preview shows every second side upside down.** With long-edge compensation that is the correct thing to send, but it reads as a fault, and the danger is someone "fixing" a setting that was right. The wording points them at the paper instead.

**The flip is stored per printer, not globally**, because it's a property of the machine: someone printing at home and at a school needs a different answer at each. `CombineView.duplexFlip` is therefore `@State`, loaded from `BookletDuplexDefaults` on appear and on every tab switch and written back on change — *not* `@AppStorage`. Known limit: the real printer is chosen inside the print dialog, after the document has been imposed, so a mid-dialog printer change can't be reacted to. This covers the ordinary case of the *default* printer differing between sites.

## Printing — `Logic/PrintLogic.swift`

**Printing goes through PDFKit, never a hand-rolled view.** `PDFDocument.printOperation(for:scalingMode:autoRotate:)` is the supported route. The first attempt drew pages into a custom `NSView` with `NSPrintOperation(view:)`; that and AppleScript automation both fail reliably. Only Combine prints (⌘P, `CombineManager.printCombined`, a whole folder of booklets as one job), plus the test sheet.

`printPDFDocument(_:jobName:wantsTwoSided:in:onError:)` (`@MainActor`) builds settings with `printSettings(for:basedOn:wantsTwoSided:)`, makes the operation with `printOperation(for:info:)`, sets the job title, shows the print and progress panels, and runs `runModal(for:delegate:didRun:contextInfo:)` on the window (bare `run()` only when there's none; the bare `runOperation()` has known silent failures). It takes a `PDFAlertHandler` and never raises an alert itself. The settings are a separate function so tests can assert them: the dialog can't be driven headlessly.

`printSettings` copies `NSPrintInfo.shared` (so the user's printer and paper carry through), zeroes the margins, and sets three things that matter — two of them counter-intuitive:
- **`orientation` from the first page's `visualPageBox`.** Booklet sheets are landscape; without this they land on portrait paper squashed into a corner. Setting `orientation` swaps the paper size, so an A4 queue becomes 842 × 595 — exactly an A5 booklet's sheet. `autoRotate` stays false, so PDFKit can't turn individual sheets and break the fold.
- **Centring is on.** The fold must land in the middle of the paper. Centring only *translates* the sheet, so it can't disturb the imposition (the worry that it shrinks the sheet was wrong).
- **`scalingMode: .pageScaleDownToFit`**, not `.pageScaleNone`: an imposed sheet is exactly full-bleed A4/A3, but printers have an unprintable margin, so 1:1 clips the outer edges of the music. Down-scaling is uniform, so the halves stay symmetrical about the fold, and this mode never scales up (which would wreck the layout). **Trade-off:** it ignores `NSPrintInfo.scalingFactor` (verified: 100% and 103% render byte-identical), so the dialog's Scale box is inert by design; `CombineOutputOptions.bookletPageScale` is the scaling control, and it also reaches Create PDF and Preview. `.pageScaleNone` honours `scalingFactor` but loses the fit protection that rescues an A3 booklet sent to A4 paper.

**Duplex can't be chosen from code.** `wantsTwoSided` (true for booklet output and the test sheet) is written to `info.printSettings["com_apple_print_PrintSettings_PMDuplexing"]` as `kPMDuplexNoTumble`, else `kPMDuplexNone` — there's no public setter (PrintCore exposes only the opaque `PMPrintSettings`; the key is `kPMDuplexingStr` with dots swapped for underscores, per `NSPrintInfo.h`). But **the print panel overwrites it from the printer's own preset the moment it appears.** Measured: asking for `kPMDuplexTumble` (3) came back as `kPMDuplexNoTumble` (2) every time — on `NSPrintInfo.shared` and on a fresh `NSPrintInfo`, written to `printSettings` and to `dictionary()`, as a 64-bit and an `SInt32` `NSNumber`, before and after the operation was created. So the request stays as a harmless hint (correct if a future macOS stops overriding it), and the *layout* compensates (`BookletDuplexFlip`). Don't "fix" this by re-applying duplex around the panel: running the panel standalone (`NSPrintPanel.runModal(with:)`) would lose the page preview, and forcing the value after it closes would silently override a deliberate choice.

**When probing the print dialog, always set `info.jobDisposition = .save` first**: dismissing a print sheet programmatically reads as OK and spools a real job.
