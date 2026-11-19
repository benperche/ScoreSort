# Release notes — next release (draft)

_Draft for the next release after 1.11.0. Keep adding to this as more changes land._

## ✨ General Improvements

- **Open PDFs straight into ScoreSort from Finder.** Right-click a PDF, image or folder and choose **Open With ▸ ScoreSort**, or drop it on ScoreSort's Dock icon. Several files or a folder go to Combine (or to Stamp or Rename if that's the tab you're on); a single PDF goes to the tab you're on if it can take it, or ScoreSort asks whether to split, rotate, stamp or combine it. ScoreSort never becomes your default PDF app.
- **AI assistants can tell which ScoreSort tools only look at your files and which can change them.** Each tool now says so, and has a plain name, so an assistant app can ask you before the ones that matter.

- **ScoreSort is now free software**, under the GNU General Public License (version 3): anyone may use, share and improve it, as long as improved versions stay free too. About ScoreSort says so, and credits Sparkle, which keeps ScoreSort up to date.

## 🏷️ Rename Files

## 🔗 Combine PDFs

## ✂️ Split PDF

- **Saving a split no longer freezes ScoreSort on big scans.** A progress bar shows each part as it's saved, and you can cancel part-way: the parts already saved are kept, and you're told which weren't.

## 🔄 Rotate Pages

- **The Rotate buttons stay put as you rotate a page**, so you can click the same one repeatedly to turn a page round. The page previews are a little bigger too, and the "Base rotation" label no longer wraps across three lines.

## 🔖 Stamp

## 🐞 Fixed

- **Your presets and stamps are protected if their file is ever damaged.** ScoreSort used to start again from an empty list, and the next change you made wrote over the old file. It now keeps the old file beside the new one, loads everything it can still read, and tells you where the copy is. It also tells you if saving them fails. The Renamer's instrument order has the same protection.
- **Previews made for an AI assistant no longer replace earlier ones.** Saving page previews into a folder that already held previews of the same PDF used to write over them without asking. It now stops and says so, like every other ScoreSort command.
- **Split PDF offers Split Double Pages again after Swap with Next or Fix Booklet Order.** Using either one stopped the next scan you opened from being offered for splitting (or showing the A3 hint), even an obvious two-page scan.
- **AI assistants are told correctly what "blank pages" does when combining.** It adds a blank page after parts with an odd number of pages in ordinary (single-page) output; the description said it was for booklets, where it does nothing, because booklets always start each part on a fresh sheet.
- **AI assistants can no longer write over the PDF they're working from.** When stamping, splitting or cutting scans, ScoreSort could replace the original if its name differed only in capitals (`Part.PDF` and `Part.pdf`), or was reached through a shortcut folder. It now always refuses.
