# Release notes — next release (draft)

_Draft for the next release after 1.9.0. Keep adding to this as more changes land._

## ✨ General Improvements

- **⌘W closes the window** — it previously did nothing.
- **One View menu instead of two.** The menu bar had two menus both called *View*; the tab shortcuts now live in the standard one alongside Full Screen.

## 🏷️ Rename Files

## 🔗 Combine PDFs

- **Press Space to look at a file.** Quick Look opens on the file you've got selected, just like in Finder — arrow keys move to the next part, Space or Escape closes it again. Handy for checking you've got the right part before committing it to paper.
- **Print without saving first.** A new **Print…** button (⌘P) sends the combined PDF straight to the printer, alongside Create PDF and Open in Preview.
- **Booklets.** Switch the output menu at the bottom left from *Single pages* to **Booklet**, and every part is laid out as its own fold-and-staple booklet — the whole folder in one print job, instead of one document at a time. Choose full size (A4 parts onto A3 paper) or **fit A4 landscape**, which gives an A5 booklet that prints on any printer. Each copy of a part becomes its own booklet, and short parts are padded out to a whole folded sheet automatically. **Two-page parts** are laid out flat instead — both pages side by side on one sheet — so you can open them on the stand and never turn a page mid-piece.
- **Choose where the page turns fall.** Publishers design page turns, so a four-page part is sometimes meant to fold (you see 1, then 2–3, then 4) and sometimes to sit flat (1–2, then 3–4) — and it can differ from part to part in the same folder. In Booklet mode each part gains an **Opens to** column showing exactly which pages will face each other, and you can change it per part, or for everything you've selected at once. **Page Turns…** (⌘T) beside the Scale box opens a larger view that steps through one part at a time, showing its pages at a readable size with the turns marked in orange, so you can look for the rest at the bottom of the page you'd be turning without leaving the app. Set them part by part, or use **Apply to All Parts** — which leaves alone any part you've already set yourself, and tells you what it did.
- **Booklet page scale.** Published music rarely matches A4 exactly, so a **Scale** box beside the output menu sizes each page within its half of the sheet — above 100% to fill more of the page, below it for more space around the music.
- **A calmer file list.** The green highlight around the file list is gone. It only ever meant "the list has the keyboard", which was never in doubt — the rows themselves show what's selected.
- **The Presets button looks like a button.** It now matches the Stamp and Clear Files buttons either side of it, and stays visibly switched on while the presets panel is open.
- **Two-sided printing setup.** macOS doesn't let an app choose your two-sided setting, and printers differ in which edge they turn the paper on. The first time you choose Booklet, ScoreSort explains what it needs from you. **Set Up Two-Sided Printing…** in the output menu then prints one numbered test sheet: fold it, say whether the pages came out the right way up, and ScoreSort sets the rest for you. It's remembered separately for each printer, so home and school can each keep their own answer.

## ✂️ Split PDF

## 🔖 Stamp

## 🐞 Fixed

- **Split: keyboard navigation works again.** Clicking an output file left the arrow keys unable to page through the PDF, and in Step 2 Tab jumped to a preview arrow instead of the next instrument name. Both were side effects of the new Stamp button in 1.9.0.
