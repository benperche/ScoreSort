# ScoreSort 1.10.0

This update contains a lot of improvements to the Combine tab, and a few bug fixes in the rest of the app.

# 🔗 Combine PDFs

## Major New Feature: Booklets!
- **Booklets.** Switch the output menu at the bottom left from *Single pages* to **Booklet**, and every part is laid out as its own fold-and-staple booklet — the whole folder in one print job, instead of one document at a time. Full size prints multiple A4 parts onto A3 paper. (You can also print in A5 onto an A4 booklet if you want to.) Each copy of a part becomes its own booklet, and short parts are padded out to a whole folded sheet automatically. **Two-page parts** are laid out flat — both pages side by side on one sheet — so you can open them on the stand and never turn a page mid-piece.
- **Choose where the page turns fall.** When creating a booklet, you can specify how to arrange the pages for sensible page turns. When in booklet mode, try the **Page Turns** (⌘T) button to view each part and specify where you want to place your page breaks. 
- **Booklet page scale.** Published music rarely matches A4 exactly, so a **Scale** box beside the output menu sizes each page within its half of the sheet — above 100% to fill more of the page, below it for more space around the music.
- **Two-sided printing setup.** macOS doesn't let an app choose your two-sided setting, and printers differ in which edge they turn the paper on. **Set Up Two-Sided Printing…** in the output menu then prints one numbered test sheet: fold it, say whether the pages came out the right way up, and ScoreSort sets the rest for you, set for each printer you use (for if you use the print button directly rather than saving a PDF). Speaking of:
- **Print without saving first.** A new **Print…** button (⌘P) sends the combined PDF straight to the print dialog in one step, alongside Create PDF and Open in Preview.

## Other Improvements
- **Press Space to look at a file in the list.** Quick Look opens on the file you've got selected, just like in Finder — arrow keys move to the next part, Space or Escape closes it again. Handy for checking you've got the right part before committing it to paper.
- **The Presets button looks like a button.** It now matches the Stamp and Clear Files buttons either side of it, and stays visibly switched on while the presets panel is open.

# 🐞 Fixed

- **Renamer: switching ensemble works every time.** After the first change, picking a different ensemble moved the buttons but carried on matching against the previous ensemble's instruments — so on Orchestra, say, an Oboe or Violin part could come up "not recognised" because it was still checking the Jazz Band list.

- **Split: keyboard navigation works again.** Clicking an output file left the arrow keys unable to page through the PDF, and in Step 2 Tab jumped to a preview arrow instead of the next instrument name. Sorry!

- **⌘W now closes the window as you'd hope** — it previously did nothing.

- **One View menu instead of two.** The menu bar had two menus both called *View*; the tab shortcuts now live in the standard one alongside Full Screen.
