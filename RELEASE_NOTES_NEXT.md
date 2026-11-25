# Release notes — next release (draft)

_Draft for the next release after 1.11.0. Keep adding to this as more changes land._

## ✨ General Improvements

- **ScoreSort works much better with VoiceOver.** Buttons that show only an icon now say what they do ("First page", "More copies", "Rotate this page left") instead of reading out the icon's name. Page previews say which page they show. What the Combine and Split lists show by colour (a part not in the preset, copies shared out, the file you're on) is spoken too. In Split Double Pages, VoiceOver can move a cut and skip or keep each page, and the Stamp tab's position buttons are named.
- **Open PDFs straight into ScoreSort from Finder.** Right-click a PDF, image or folder and choose **Open With ▸ ScoreSort**, or drop it on ScoreSort's Dock icon. Several files or a folder go to Combine (or to Stamp or Rename if that's the tab you're on); a single PDF goes to the tab you're on if it can take it, or ScoreSort asks whether to split, rotate, stamp or combine it. ScoreSort never becomes your default PDF app.
- **AI assistants can tell which ScoreSort tools only look at your files and which can change them.** Each tool now says so, and has a plain name, so an assistant app can ask you before the ones that matter.
- **If your saved ensemble presets or stamps can't be read, an AI assistant (or the command line) now says so and why**, instead of reporting that you have none. It also mentions any single preset or stamp it had to leave out. It never moves or changes the file; opening ScoreSort keeps a copy of it and tells you what happened.

- **ScoreSort is now free software**, under the GNU General Public License (version 3): anyone may use, share and improve it, as long as improved versions stay free too. About ScoreSort says so, and credits Sparkle, which keeps ScoreSort up to date.

- **Open and Save windows now slide down from the top of ScoreSort's window in every tool**, as they already did in Combine PDFs, and lock the window behind them until you're done. Before, in Split, Rotate, Stamp and Rename, pressing Delete in the file list of an Open window could skip pages or remove files in the tool behind it.

## 🏷️ Rename Files

- **The instrument order you set in Settings ▸ Renamer is now saved.** It used to be forgotten when you quit ScoreSort. Each ensemble keeps its own order, and **Reset to Default** brings back the built-in one (press Save to keep it).
- **More instruments recognised in score order**: Contra-alto Clarinet, Flugelhorn, Sousaphone, Bass Guitar, Synthesizer, Vocal and Choir (now in band and orchestra order, not just jazz), flex-band parts (Part 1 to Part 5), and Conductor, which is numbered 00 like the score.
- **Your own instrument order survives updates.** New instruments are now added into your order instead of replacing it with the built-in one.
- **Undo Rename.** Renamed a folder of parts and wish you hadn't? **Undo Rename** on the finished screen (or **Actions ▸ Undo Last Rename…**) puts every file back under its old name and removes any section folders the rename made. It works for a whole batch of folders, for Bulk Rename, and after quitting ScoreSort. Files you've moved or renamed since are left alone and listed.

## 🔗 Combine PDFs

- **Presets understand combined parts.** A part like **Flute Oboe** now gets copies for both the flutes and the oboes in your preset when the music has no separate oboe part. If there is a separate Flute part, Flute Oboe covers just the oboes. The row is tinted blue so you can see ScoreSort made the call. **Tuned Percussion** also counts as your preset's Mallet Percussion.
- **US Letter and Tabloid paper.** In North America, pictures, blank pages, booklets shrunk onto one sheet and the two-sided test sheet now come out on Letter instead of A4, and the booklet menu talks about Letter → Tabloid and half-letter booklets. ScoreSort follows your printer's paper (or your region) automatically; to choose, go to **Settings ▸ Combiner ▸ Paper size**. PDFs always keep their own page size, and nothing changes if you print on A4.

## ✂️ Split PDF

- **Many more part names to pick from when naming split parts** (offered as you type): combined parts like **Flute/Piccolo**, **Oboe/Cor Anglais**, **Trumpet/Flugelhorn** and **Alto Saxophone/Flute**; key-named parts like **Bb Clarinet**, **Eb Alto Saxophone** and **C Trumpet**; flex-band parts **Part 1** to **Part 5**; and **Conductor**, **Condensed Score**, **Lead Sheet**, **Choir**, **Sousaphone**, **Bass Guitar** and **Synthesizer**.
- **More part names to pick from when naming split parts.** Start typing and the list now offers **Flute Oboe**, **F Horn**, **Eb Horn**, **Tuned Percussion** and **Vocal**, as used in charts like Ed Wilson's.
- **Saving a split no longer freezes ScoreSort on big scans.** A progress bar shows each part as it's saved, and you can cancel part-way: the parts already saved are kept, and you're told which weren't.

## 🔄 Rotate Pages

- **The Rotate buttons stay put as you rotate a page**, so you can click the same one repeatedly to turn a page round. The page previews are a little bigger too, and the "Base rotation" label no longer wraps across three lines.

## 🔖 Stamp

## 🐞 Fixed

- **Your presets and stamps are protected if their file is ever damaged.** ScoreSort used to start again from an empty list, and the next change you made wrote over the old file. It now keeps the old file beside the new one, loads everything it can still read, and tells you where the copy is. It also tells you if saving them fails. The Renamer's instrument order has the same protection.
- **Previews made for an AI assistant no longer replace earlier ones.** Saving page previews into a folder that already held previews of the same PDF used to write over them without asking. It now stops and says so, like every other ScoreSort command.
- **If a stamp can't be put on a PDF, ScoreSort now says so** instead of saving the file without it and reporting success. This applies to the Stamp tab (where Replace leaves the original alone), stamped Combine and Split output, and AI assistants. It mostly happens with password-protected PDFs.
- **Rotate Pages says why a save failed**, for example that the folder is read-only, instead of just "Failed to save rotated PDF".
- **Split PDF offers Split Double Pages again after Swap with Next or Fix Booklet Order.** Using either one stopped the next scan you opened from being offered for splitting (or showing the A3 hint), even an obvious two-page scan.
- **AI assistants are told correctly what "blank pages" does when combining.** It adds a blank page after parts with an odd number of pages in ordinary (single-page) output; the description said it was for booklets, where it does nothing, because booklets always start each part on a fresh sheet.
- **AI assistants can no longer write over the PDF they're working from.** When stamping, splitting or cutting scans, ScoreSort could replace the original if its name differed only in capitals (`Part.PDF` and `Part.pdf`), or was reached through a shortcut folder. It now always refuses.
- **Photos and scanned images print sharply.** Pictures added to Combine or Stamp (JPEG, PNG, HEIC and so on) were turned into pages at about 72 dots per inch, so scans came out blurry when printed. They now keep their full detail.
