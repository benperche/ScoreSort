# ScoreSort code reference

A map of the code, verified against it. Read this index, then **only the file for the area you're touching** — and keep that file up to date when you change how the area works.

**The app in brief.** One module (filesystem-synchronized groups, so a new `.swift` file under `ScoreSort/` just compiles; grep the whole tree). `ScoreSortEntry` (`CLI/Entry.swift`) is the `@main`: a command-line verb runs headless, anything else starts `ScoreSortApp` — a `WindowGroup` with five tabs (Combine ⌘1, Rename ⌘2, Split ⌘3, Rotate ⌘4, Stamp ⌘5), a Settings window (Combiner, Renamer, AI Assistants), and the File / Edit / View / Actions / Format menus fed by the active tab. MVVM with `ObservableObject`s: `AppState`, `RenamerManager`, `EnsemblePresetStore` and `StampStore` are app-level environment objects; `CombineManager` belongs to Combine; Split and Rotate each own a `PDFManager`. Pure logic lives in `ScoreSort/Logic/` and is shared by the tabs and the CLI/MCP server. Three independent saved files in `~/Library/Application Support/ScoreSort/`: `ensemble-presets.json`, `instrument-orders.json`, `stamps.json`.

| Looking for… | Source | Read |
|--------------|--------|------|
| App structure, menus and `TabSlice`, keyboard gating, shortcuts panel, welcome tour, Settings shell, `PDFManager`, `PDFPageView`, `DropZoneView`, file helpers | `ScanReorienterApp_complete.swift`, `Logic/FileUtilities.swift`, `Logic/PDFSaving.swift`, `Logic/OutlineLogic.swift`, `Logic/ImagePages.swift`, `SavedFileNoticeBanner.swift` | [shared.md](shared.md) |
| Combine PDFs: file list, collate groups, copies, presets and `matchPreset`, output, Quick Look | `Combine/`, `Logic/PresetMatching.swift`, `Logic/InstrumentNames.swift` | [combine.md](combine.md) |
| Booklets (imposition, page turns), two-sided setup, printing | `Logic/BookletLogic.swift`, `Logic/BookletCalibration.swift`, `Logic/PrintLogic.swift`, `Combine/BookletLayoutSheet.swift` | [printing-booklets.md](printing-booklets.md) |
| Rename Files: Score Order Sorter, batch folders, Bulk Part Rename, instrument orders, Sort into folders | `Rename/`, `Logic/RenameLogic.swift`, `Logic/PartFolders.swift` | [rename.md](rename.md) |
| Split PDF: Steps 1–3, bookmarks, Split Double Pages, Fix Booklet Order, naming suggestions, saving | `Split/`, `Logic/SplitLogic.swift`, `Logic/ScanSplitLogic.swift`, `Logic/InstrumentNames.swift` | [split.md](split.md) |
| Rotate Pages | `Rotate/RotateTab.swift` | [rotate.md](rotate.md) |
| Stamp: designs, rich text, preview, batch stamping, where stamping applies | `Stamp/`, `Logic/StampLogic.swift` | [stamp.md](stamp.md) |
| Command line, MCP server, Settings ▸ AI Assistants | `CLI/`, `Logic/AIConnection.swift` | [cli-mcp.md](cli-mcp.md) |
| Saved files (`SavedListFile`), and every other known trap | `Logic/SavedListFile.swift` | [gotchas.md](gotchas.md) |
| Test files and suites, test rules, CI | `ScoreSortTests/`, `.github/workflows/tests.yml` | [tests.md](tests.md) |
| Sparkle, the appcast and its deploy workflow, the release checklist | `docs/appcast.xml`, `.github/workflows/pages.yml`, `Info.plist` | [releasing.md](releasing.md) |
