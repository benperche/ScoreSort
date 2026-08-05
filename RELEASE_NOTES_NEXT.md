# Release notes — next release (draft)

_Draft for the next release after 1.8.0. Keep adding to this as more changes land._

## ✨ General Improvements

- **New tool: Stamp** (⌘5). Add a small text overlay — "Example School Band", "Property of the Music Dept" — to your parts, like a rubber stamp. Set the text and style (font, size, bold/italic, colour) and an optional box around it, then put it anywhere on the page: click one of the nine quick positions, or just **drag the stamp around on the preview**. Save as many named stamps as you like.
- The Stamp tab also stamps files you already have — PDFs and images (JPEG, PNG, TIFF, HEIC), which come out as PDFs. Drag in some files or a folder to do a whole set at once with the same settings. Choose to stamp every page or just the first page of each file, and either **replace the originals** or save copies under names you type.
- Stamps are burned into the page, so they print everywhere and can't be deleted out of the PDF.
- **Dates in stamps**: type `{date}` or `{year}` in the stamp text and it's filled in when the stamp is applied — handy for "this copy was made on…" copyright lines. Dates are day-first (14/03/2026) by default, with long, ISO and month-first available.

## 🔗 Combine PDFs

- New **Stamp** button in the toolbar: stamp the combined PDF as it's created, choosing a stamp you've setup in the stamp tab. You can control whether it goes on every page or just the first page of each part.
- **Presets can carry a stamp**: give a preset your school or ensemble's stamp, and applying it arms that stamp for the output. You can still switch it off from the Stamp button whenever you don't want it.

## ✂️ Split PDF

- New **Stamp** button in the Step 1 toolbar: every split file gets stamped as it's written, on every page or just its first page — and Step 1's preview shows the stamp on the pages that will get one.

- **More instruments in the naming suggestions**: alto and bass flute, oboe d'amore, cor anglais, clarinet in B♭ and A, drum kit, vibraphone, mallet percussion, and a combined "Trombone Baritone Bassoon" part for early-grade band music. Spelling variants (drums / drum set / drum kit, vibes / vibraphone, cor anglais / english horn) now count as the same instrument, so the suggestions move on to the next part instead of cycling through variants — while B♭ vs A clarinet and baritone B.C. vs T.C. stay separately selectable.
- The Step 1 toolbar is tidier: "Split as A3" and "Fix Booklet Order" share one **Fix Scan** menu, and "Clear All Splits" has moved next to **Apply** in the Split Pattern box, where it belongs. All three are still in the Actions menu too.
- Steps 1, 2 and 3 now share a consistent heading, so the title doesn't jump around as you move between them.

## 🐞 Fixed

- **Combine: clicking a file works the way it should.** Clicking anywhere on a file now selects just that file, ⌘-click (or the tick box) adds to the selection, and clicking blank space below the list clears it. Previously every click behaved as though ⌘ was held down.
- **Combine: ⌫ removes the selected files again.** The menu-bar redesign in 1.8.0 dropped the delete key without replacing it, so it silently stopped working even though the shortcuts panel still listed it.
