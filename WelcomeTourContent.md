# ScoreSort — Welcome Tour Content

Edit this file freely. When you're done, hand it back and the tour will be built from it exactly.

Each section below is one page of the tour. The structure is:
- **Icon** — SF Symbols name (don't worry about changing these, I'll match them to your content)
- **Title** — large heading on the card
- **Use-case** — one sentence: *who comes here and why*
- **Body** — the main explanation (2–4 sentences max; shorter is better on screen)
- **Tip** — the highlighted callout box at the bottom of the card (keyboard shortcut or power-user hint)

---

## Page 1 — Welcome

**Icon:** `music.note.list`
**Title:** Welcome to Music PDF Manager

**Body:**
Tools for music librarians, music educators, publishers and copyists working with scanned or digital music PDFs.
Each tab handles a different stage of a typical workflow, arranged in order from most commonly used to least common — this short tour gives you a quick overview of each one.
The app is designed to work closely with the macOS Finder. Usually the easiest way to get files into the app will be by dragging files or folders onto the relevant page of this app.

**Tip:** If your files are stored in Google Drive or Dropbox etc., you may want to install the relevant app so that all your folders and PDFs are accessible directly in Finder.

---

## Page 2 — Combine PDFs  `⌘1`

**Icon:** `doc.on.doc`
**Tab label:** Combine PDFs

**Use-case:** You have a set of separate PDF files — one per instrument part — and want to merge them into a single combined document ready for printing all in one go.

**Body:**
Drag your files or a whole folder into the file list, then reorder with ⌘↑ / ⌘↓ or by dragging.
You can save your usual instrument allocations as **Ensemble Presets** (Preferences → Combiner). These can be viewed in the Presets sidebar to help you remember the normal number of parts required. You can even use the **Apply to Files** button, which will attempt to match these allocations to the filenames of the parts you have dragged in.
Once you have set the number of parts required, you can save the combined file using **Create PDF**, or just **Open in Preview** to be able to print without saving the document.
Advanced: You can create a **Collate Set** for subsets of parts you want to print multiple times per player (select them and press **C**) so the pages are interleaved correctly for the correct page order. For example, if you need to print all percussion parts for each player in the ensemble, you can create a set of all the percussion parts, set the number of copies you need, and these will then come out of the printer in stacks ready to distribute without having to resort after printing.


**Tip:** ⌫ removes selected files · ⌘Z undoes any change · ⌘↑ / ⌘↓ reorders

---

## Page 3 — Rename Files  `⌘2`

**Icon:** `folder.badge.gearshape`
**Tab label:** Rename Files

**Use-case:** You have a folder of separately-scanned parts with unhelpful filenames (e.g. `scan001.pdf`) and need to rename them consistently, or sort them automatically into score order.

**Body:**
Drag a folder onto the **left side** to add numerical prefixes to already-named files so they display in score order (e.g. `01 - Beethoven Symphony 5 - Flute.pdf`).
    Drag in the folder, adjust the order as necessary, and re-number in one pass.

Drag a folder onto the **right side** to replace the filenames of a number of files at once (e.g. for parts downloaded from IMSLP). The preview window will show the top left of each file by default so you can check which part you are renaming. 
    Enter a base name (e.g. *Beethoven Symphony 5*) and fill in the instrument name for each file — the app will try to intelligently suggest instrument names and numbers based on what you type. Choose from the prefilled options using the arrow keys and the return key. (e.g. `Beethoven Symphony 5 - Violin 1.pdf`).
    Once you've filled all the names, optionally toggle **Prefix score order** to bring the files into the automatic score order prefix flow mentioned above.


**Tip:** In the renaming window, tab moves between instrument name fields · you can change the default score order in preferences

---

## Page 4 — Split PDF  `⌘3`

**Icon:** `scissors`
**Tab label:** Split PDF

**Use-case:** You have one large PDF — e.g. a complete scan of all parts bound together — and need to split it into separate instrument files.

**Body:**
Drop the PDF and use **← →** to move through pages. Press **Space** to place or remove a split marker, and **↑ ↓** to jump between the start of each output file. You can also automatically apply equally spaced markers at a certain 'stride'.
In Step 2, name each output file (like in the Rename Files flow). Toggle **Prefix score order** to add score-order numbers automatically in Step 3 (again, like in the Rename Files flow).

**Tip:** ⌘← / ⌘→ jumps to the first or last page in the split dialogue · Space toggles a split marker

---

## Page 5 — Rotate Pages  `⌘4`

**Icon:** `rotate.right`
**Tab label:** Rotate Pages

**Use-case:** Your scan has multiple pages that came out sideways or upside-down and need correcting before use 

**Body:**
Drop a PDF and navigate to any mis-rotated page with **← →**.
Rotate the current page, or apply a rotation to all pages at once. You can also apply a rotation to all odd or all even pages (for example, for if you scanned a score sideways, and every second page is upside down.)
Save the corrected file when you're done.

**Tip:** ← → navigates pages · rotating all pages is useful for landscape-scanned scores

---

## General notes for your edits

- Keep body text to 2–4 sentences per page — the card is not very tall
- The tip box is highlighted in a subtle colour (like a callout); one line is ideal
- Page 1 has no tab shortcut shown; pages 2–5 each show their ⌘ shortcut in the header
- If you want to rename or reorder the pages, go ahead — just keep the `## Page N` headings so I can parse them
- If any tab does something importantly different from my description, please correct it — especially the Rotate tab (save behaviour) and the Collate description

---

## Screenshot slots  *(fill in after tour is built)*

Once the tour is live, you can take one screenshot per tab and drop the files here. Ideal crop: the full app window, saved as PNG. I'll add them to the asset catalog and swap out the SF Symbols placeholders.

| Page | Screenshot filename (suggestion) |
|------|----------------------------------|
| 2 — Combine  | `tour-combine.png`  |
| 3 — Rename   | `tour-rename.png`   |
| 4 — Split    | `tour-split.png`    |
| 5 — Rotate   | `tour-rotate.png`   |
