# Release notes — next release (draft)

_Draft for the next release after 1.10.1. Keep adding to this as more changes land._

## ✨ General Improvements

## 🏷️ Rename Files

## 🔗 Combine PDFs

- **Moving files after adding them no longer breaks Combine.** ScoreSort now keeps track of each file you add, so if you move or rename it in Finder before making the PDF, it still finds it — and the list and table of contents pick up the new name. (A file you've moved to the Trash counts as gone.)

## ✂️ Split PDF

- **Scans of double pages are much easier to split.** The A3 splitter has grown into **Split Double Pages**, built for overhead and book scanners. Every scan is shown in one window: two-page scans are cut at the gap between the pages — wherever it actually is, not just down the middle — single pages are left whole, and black scanner background or empty facing pages are set aside to skip. Drag a cut line to move it, switch any scan between one page and two, or click a page to skip or keep it. Skipped pages stay in Step 1, greyed out, so nothing is lost. It's offered when you open such a scan, or from **Fix Scan ▸ Split Double Pages…**.
- **ScoreSort now asks what to do with a PDF's bookmarks — and can name the files from them.** When you open a PDF that already has bookmarks, a sheet shows the names its bookmarks would give the files — tidied up, so a title like `Bernstein_-_Prelude,_Fugue_and_Riffs_-_Trumpet_I` becomes the piece name plus "Trumpet I". Choose **Split & Name Files** to split at the bookmarks and use their titles as the file names (either "Piece - Flute 1" or just the bookmark title on its own), **Split Only** to keep the split points and name the files yourself, or **Ignore Bookmarks** to start from scratch. Before, the splits appeared without warning and the titles were only used for PDFs made by ScoreSort's own Combine tab. Changed your mind? **Actions ▸ Use Bookmarks…** brings the sheet back.
- **File names stay with their parts when you add or remove a split.** Names you'd already filled in used to slide onto the wrong files if you changed a split point earlier in the document.
- **The file list in Step 1 shows the real file names**, with your chosen separator, instead of a rough placeholder.

## 🔖 Stamp

- **Moving files after adding them no longer breaks stamping.** If you move or rename a queued file in Finder, the Stamp tab still finds it — “Replace original files” stamps it where it is now, and a new name carries through to “Save as new files” unless you’ve typed your own. If a file can’t be stamped, ScoreSort now says why.

## 🐞 Fixed

- **After splitting a scan, Delete skips one page again**, not the whole file, as intended — so removing a stray blank page doesn't take the rest of the part with it.
- **Combine says what went wrong instead of “Failed to create PDF”.** If a file in the list has been deleted or can’t be read since you added it, ScoreSort now names it and says why, rather than giving a one-line error — or, if only some files were affected, quietly leaving those parts out of the PDF. Problems saving to a folder (such as a read-only shared drive) are explained too.
- **Combined PDFs keep their table of contents on macOS 27.** Booklets, and any combined PDF with a stamp on it, were being saved without their bookmarks, so there was no list of parts in Preview's sidebar and the Split tab couldn't find the part boundaries by itself. The bookmarks are saved again, for Create PDF and Open in Preview.
