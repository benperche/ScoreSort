# Release notes — next release (draft)

_Draft for the next release after 1.10.1. Keep adding to this as more changes land._

## ✨ General Improvements

- **Page previews in the Split and Rotate tabs are lighter.** macOS was quietly running text recognition on every preview of a scanned page, using processor time for nothing. Previews are now plain pictures, drawn once per page.
- **Ask an AI assistant to do the job, and it can use ScoreSort.** Tell an AI like Claude "split this scan into parts, name them and number them in score order" and it can now work ScoreSort for you. It looks at the pages to read the part names, then uses ScoreSort's own splitting, double-page scan cutting, score-order renaming, combining with your presets, and stamping, so the files come out exactly as they would from the app. It works as a command-line tool for AI tools with a terminal, and as an "MCP server" for chat apps such as the Claude desktop app. It can also combine a folder of parts for one of your ensemble presets and sort out who plays what — spotting players with no part (say, two bass guitars) and giving them the closest one (the tuba part), spreading percussion across the percussion parts, and asking you before it hands anyone a part in the wrong key. You don't need to know where files are: "the Holst scan in my Downloads" is enough. It never replaces a file unless told to, and it can show what it's about to do first. Setup is in the README.

## 🏷️ Rename Files

## 🔗 Combine PDFs

- **Moving files after adding them no longer breaks Combine.** ScoreSort now keeps track of each file you add, so if you move or rename it in Finder before making the PDF, it still finds it — and the list and table of contents pick up the new name. (A file you've moved to the Trash counts as gone.)

## ✂️ Split PDF

- **Scans of double pages are much easier to split.** The A3 splitter has grown into **Split Double Pages**, built for overhead and book scanners. Every scan is shown in one window: two-page scans are cut at the gap between the pages — wherever it actually is, not just down the middle — single pages are left whole, and black scanner background or empty facing pages are set aside to skip. Drag a cut line to move it, switch any scan between one page and two, or click a page to skip or keep it. Skipped pages stay in Step 1, greyed out, so nothing is lost. It's offered when you open such a scan, or from **Fix Scan ▸ Split Double Pages…**. For scans of identical sheets, like A3 from a flatbed scanner, every page gets the **same cut** — down the middle, or wherever you drag any one of them — so you can just press Return and go.
- **ScoreSort now asks what to do with a PDF's bookmarks — and can name the files from them.** When you open a PDF that already has bookmarks, a sheet shows the names its bookmarks would give the files — tidied up, so a title like `Bernstein_-_Prelude,_Fugue_and_Riffs_-_Trumpet_I` becomes the piece name plus "Trumpet I". Choose **Split & Name Files** to split at the bookmarks and use their titles as the file names (either "Piece - Flute 1" or just the bookmark title on its own), **Split Only** to keep the split points and name the files yourself, or **Ignore Bookmarks** to start from scratch. Before, the splits appeared without warning and the titles were only used for PDFs made by ScoreSort's own Combine tab. Changed your mind? **Actions ▸ Use Bookmarks…** brings the sheet back.
- **File names stay with their parts when you add or remove a split.** Names you'd already filled in used to slide onto the wrong files if you changed a split point earlier in the document.
- **The file list in Step 1 shows the real file names**, with your chosen separator, instead of a rough placeholder.

## 🔖 Stamp

- **Moving files after adding them no longer breaks stamping.** If you move or rename a queued file in Finder, the Stamp tab still finds it — “Replace original files” stamps it where it is now, and a new name carries through to “Save as new files” unless you’ve typed your own. If a file can’t be stamped, ScoreSort now says why.

## 🐞 Fixed

- **Naming a part shows a page that's actually in it.** If a part's first page was skipped (a black scanner edge, a blank page), the preview in Step 2, and the thumbnail in Step 3, showed that skipped page instead of the first real page of music.
- **The little page map beside each page preview when naming parts (Split and Bulk Rename) now marks exactly what you can see.** Its rectangle used to be about three times taller than the area actually shown, and you couldn't pan all the way to the bottom of a page.
- **After splitting a scan, Delete skips one page again**, not the whole file, as intended — so removing a stray blank page doesn't take the rest of the part with it.
- **Combine says what went wrong instead of “Failed to create PDF”.** If a file in the list has been deleted or can’t be read since you added it, ScoreSort now names it and says why, rather than giving a one-line error — or, if only some files were affected, quietly leaving those parts out of the PDF. Problems saving to a folder (such as a read-only shared drive) are explained too.
- **Combined PDFs keep their table of contents on macOS 27.** Booklets, and any combined PDF with a stamp on it, were being saved without their bookmarks, so there was no list of parts in Preview's sidebar and the Split tab couldn't find the part boundaries by itself. The bookmarks are saved again, for Create PDF and Open in Preview.
