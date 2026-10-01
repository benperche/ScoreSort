# Release notes — next release (draft)

_Draft for the next release after 1.10.1. Keep adding to this as more changes land._

## ✨ General Improvements

## 🏷️ Rename Files

## 🔗 Combine PDFs

## ✂️ Split PDF

## 🔖 Stamp

## 🐞 Fixed

- **Combine says what went wrong instead of “Failed to create PDF”.** If a file in the list has been moved, renamed, deleted or can’t be read since you added it, ScoreSort now names it and says why, rather than giving a one-line error — or, if only some files were affected, quietly leaving those parts out of the PDF. Problems saving to a folder (such as a read-only shared drive) are explained too.
- **Combined PDFs keep their table of contents on macOS 27.** Booklets, and any combined PDF with a stamp on it, were being saved without their bookmarks, so there was no list of parts in Preview's sidebar and the Split tab couldn't find the part boundaries by itself. The bookmarks are saved again, for Create PDF and Open in Preview.
