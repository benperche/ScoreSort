# Release notes — next release (draft)

_Draft for the next release after 1.6.0. Keep adding to this as more changes land._

## ✨ General Improvements
* Drop a new file onto the "Done" screen to start the next job immediately, without clicking Start Over (Rename, Bulk Rename, and Split).

## 🏷️ Rename Files
* Batch renaming: you can now rename multiple folders worth of pieces at once. Drag in a single parent folder of nested folders or multiple individual folders and the app will help you rename them one after another.
* You can now rename image scans as well as PDFs in the Score Order Sorter

## 🔗 Combine PDFs
* Drag to reorder files. Collate groups move as a unit, and you can drop a file onto a group to add it in.

## ✂️ Split PDF
* Undo/redo while splitting. ⌘Z / ⌘⇧Z now undo and redo split-point, skip, and re-stride edits in Step 1 of the splitter.
* Drag to pan the part preview. In the naming step you can drag the page-preview strip (or its minimap) to reposition it, not just use the arrow buttons.
* Much smarter instrument-name suggestions in Step 2, now driven by the selected ensemble (Wind Band / Jazz Band / Orchestra):
    * Suggestions follow that ensemble's actual score order — e.g. in a band, Horn now follows Trumpet. The ensemble picker is always available in the naming step (it drives the suggestions, so you can switch it any time).
    * Ensemble-aware part counts — a band has 1 tenor sax and 3 trumpets, a big band has 2 and 4
    * Suggest full instrument names ("Alto Saxophone", not "Alto Sax")
    * Better handling of the clarinet family, the baritone/euphonium
* Duplicate-name warning. The naming step warns when two files are about to get the same name. If no score-order prefix is being added (so they'd truly collide), saving is blocked until you fix it.
* General improvements to the instrument prefix screen in 'Step 3'

## 🐞 Fixed
* Keyboard shortcuts are now strictly limited to the current tab
* The part-name preview no longer clips the instrument name at the top of the page.
* Dragging a new PDF onto the splitter's "Done" screen no longer leaves a blank Step 1 preview.
