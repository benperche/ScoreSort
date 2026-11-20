# Rotate Pages (tab 3, ⌘4)

Files: `ScoreSort/Rotate/RotateTab.swift` (`RotateView`, `RotatePreviewSection`). The view model is the shared `PDFManager` type, its own `@StateObject` here; its `saveRotatedPDF(...)` and the `RotationAngle` / `RotationMode` enums are in the main file ([shared.md](shared.md#shared-infrastructure)).

Gotchas that concern this tab: [gotchas.md § PDFKit and PDF geometry](gotchas.md#pdfkit-and-pdf-geometry) (rotation is metadata, clockwise), [§ Menus and keyboard](gotchas.md#menus-and-keyboard).

## What it does

Corrects pages that came out of the scanner sideways or upside down, by changing each page's **rotation metadata** (`PDFPage.rotation`, clockwise degrees). Page content is never transformed, which is the standard PDF approach and what Preview does. A page rotated here therefore keeps a portrait media box with a rotation flag, which is why Split's A3 detection and splitting, and the stamp flattener, all read rotation before measuring ([gotcha](gotchas.md#pdfkit-and-pdf-geometry)). Stamping is deliberately not offered here: flattening would bake the rotation in.

## State and controls (`RotateView`)

| State | Purpose |
|-------|---------|
| `baseRotation: RotationAngle` | "Step 1: Base Rotation (All Pages)" — None / 90° / 180° / 270°, segmented |
| `additionalRotationMode: RotationMode` | "Step 2: Additional Rotation" — none / odd pages / even pages (radio group) |
| `additionalRotationAngle: RotationAngle` | 90° / 180° / 270°, shown only when a mode is chosen; defaults to 180° |
| `pageRotationOverrides: [Int: Int]` | per-page extra rotation from Rotate Left/Right, normalised to 0…359 |
| `currentPage` | the page shown |

`RotationAngle` is `none = 0, rotate90 = 90, rotate180 = 180, rotate270 = 270` with `.degrees`; `RotationMode` is `.odd`, `.even`, `.none`. All rotation state resets when the document is cleared.

**Preview** — `RotatePreviewSection`: navigation buttons, Rotate Left / Right buttons around "Page N of M" and a description ("Rotated 90° (this page)"), and Before / After `PDFPageView`s. The middle of the navigation row is sized by hidden copies of its longest texts ("Page M of M" in monospaced digits, the semibold "Rotated 270° (this page)"), so the rotate buttons never move as the caption changes (#35). Step 1's segmented picker hides its own label (the "Rotate all pages:" text is the label; "Base rotation" stays as its accessibility label). The previews take all spare height: the content stack has no spacing, and the padding either side of the divider does the spacing. After passes `totalRotationForCurrentPage` (base + odd/even + override, mod 360) as the view's extra rotation. `PDFPageView` renders the page to an image rather than using a `PDFView`, because a `PDFView` showing an image-only page runs Live Text recognition, which spammed the console with TextRecognition "Unable to find a valid E5" warnings on every preview update.

## Keys and menus

`.onKeyPress` on the whole tab (`.focusable()`, gated on `selectedTab == 3` and a loaded PDF): ← / → previous/next page, ⌘← / ⌘→ first/last, **`,`** rotate this page left, **`.`** rotate it right. The same navigation keys as Split Step 1 and the Stamp preview.

Menu slice: Choose PDF… (⌘O), Save Rotated PDF (⌘S), Clear File (⌘⌫); Actions: Rotate Left, Rotate Right, Show in Finder (⇧⌘F, the source file). See [shared.md](shared.md#the-tabcommands--tabslice--menuaction-bridge).

## Saving

`saveRotatedPDF(document:)` opens an `NSSavePanel` (`<name>_rotated.pdf`, in `outputDirectory(forSourceFile: pdfManager.sourceURL)`). `PDFManager.saveRotatedPDF(to:baseRotation:additionalRotationMode:additionalRotationAngle:pageRotationOverrides:completion:)` copies every page into a new `PDFDocument`, adds base + per-page + odd/even degrees to each copy's `rotation`, and saves it through `savePDFDocument(_:to:)`, so a failure says why ("Couldn’t Save the PDF" with the reason, e.g. a read-only folder). The result goes to the `PDFAlertHandler`, which the view shows with `showNSAlert`.

Its open and save panels are sheets on the window (`beginPanelSheet`, [gotcha](gotchas.md#swiftui-and-appkit)).
