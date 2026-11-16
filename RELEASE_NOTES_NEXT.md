# Release notes — next release (draft)

_Draft for the next release after 1.11.0. Keep adding to this as more changes land._

## ✨ General Improvements

- **AI assistants can tell which ScoreSort tools only look at your files and which can change them.** Each tool now says so, and has a plain name, so an assistant app can ask you before the ones that matter.

## 🏷️ Rename Files

## 🔗 Combine PDFs

## ✂️ Split PDF

## 🔖 Stamp

## 🐞 Fixed

- **Your presets and stamps are protected if their file is ever damaged.** ScoreSort used to start again from an empty list, and the next change you made wrote over the old file. It now keeps the old file beside the new one, loads everything it can still read, and tells you where the copy is. It also tells you if saving them fails. The Renamer's instrument order has the same protection.
- **Previews made for an AI assistant no longer replace earlier ones.** Saving page previews into a folder that already held previews of the same PDF used to write over them without asking. It now stops and says so, like every other ScoreSort command.
