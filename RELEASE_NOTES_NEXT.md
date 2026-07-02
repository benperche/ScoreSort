# Release notes — next release (draft)

_Draft for the next release after 1.7.0. Keep adding to this as more changes land._

## ✨ General Improvements

## 🏷️ Rename Files

## 🔗 Combine PDFs
* Editing a preset in Preferences now updates the sidebar live — no need to switch ensembles to see the change.
* Smarter preset matching when a chart's parts don't line up with the preset: a single "Clarinet" file now correctly absorbs the copies of both "Clarinet 1" and "Clarinet 2", and a generic part like "Clarinet" no longer gets mis-assigned to "Bass Clarinet".
* Preset matching now understands instrument abbreviations and aliases — "Alto Sax" ↔ "Alto Saxophone", "French Horn" ↔ "Horn", "Vln" ↔ "Violin", and so on.
* Euphonium/Baritone parts now match by clef: a "Euphonium BC" preset entry is assigned the bass-clef file and never the treble-clef one (and vice versa), so players get the right part to print. The default Wind Band preset now specifies "Euphonium BC".

## ✂️ Split PDF

## 🐞 Fixed
