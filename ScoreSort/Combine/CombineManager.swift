//
//  CombineManager.swift
//  ScoreSort
//
//  The Combine tab's data layer: CombineFile and CollateGroup, the output options
//  (CombineLayout, CombineOutputOptions) and CombineManager — adding, ordering and grouping
//  files, and building the combined document that Create PDF, Print and Open in Preview share
//  (`buildDocument`). Moved out of CombineTab.swift.
//

import SwiftUI
import AppKit
@preconcurrency import PDFKit
import UniformTypeIdentifiers
import Combine

// MARK: - Combine File Model

/// A named group of files whose pages are interleaved (collated) when combining.
/// e.g. 4 copies of [Perc1, Perc2, Timpani] → Perc1, Perc2, Timp, Perc1, Perc2, Timp, …
struct CollateGroup: Identifiable, Equatable {
    let id: UUID
    var copies: Int
}

struct CombineFile: Identifiable, Equatable, FollowsMovedFile {
    let id = UUID()
    /// Where the file was last found. Kept current by `CombineManager.refreshFileLocations()`,
    /// because the file is read again when the PDF is made, not just when it's added.
    var url: URL
    var name: String
    let pageCount: Int
    var copies: Int
    /// Non-nil when this file is part of a collate group.
    var collateGroupId: UUID? = nil
    /// True for synthetic blank-page entries (url is unused).
    var isBlankPage: Bool = false
    /// Booklet output only. `nil` means "whatever suits this length" —
    /// `bookletDefaultLayout(pageCount:)` — so a part only carries a value once someone has
    /// deliberately chosen one.
    var bookletLayout: BookletPartLayout? = nil
    /// Finds the file again if it's moved or renamed in Finder after being added. `nil` for
    /// blank pages, or if macOS couldn't make one (the path is then all there is).
    var bookmark: Data? = nil

    /// The layout this part will actually print with.
    var effectiveBookletLayout: BookletPartLayout {
        bookletLayout ?? bookletDefaultLayout(pageCount: pageCount)
    }
}

// MARK: - Output options

/// How the combined pages are laid out on the page.
enum CombineLayout: String, CaseIterable, Identifiable, Codable {
    /// One reading page per PDF page — what the tool has always done.
    case singlePages
    /// Each part imposed as its own saddle-stitch booklet, two pages to a sheet face.
    case booklet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .singlePages: return "Single pages"
        case .booklet:     return "Booklet (fold & staple)"
        }
    }
}

/// Everything about the *shape* of the output, as opposed to which files go into it.
/// Passed down to `buildDocument` so Create PDF, Open in Preview and Print can't drift.
struct CombineOutputOptions {
    var layout: CombineLayout = .singlePages
    var sheetSize: BookletSheetSize = .doubleSize
    /// Booklet only — how big each page is drawn within its half of the sheet. 1.0 fits the
    /// half exactly; published music rarely matches A4, so this is the dial for that.
    var bookletPageScale: Double = 1.0
    var addBlankPages = false
    /// Booklet only — leaves out sheet backs that would be entirely blank, for a job going out
    /// single-sided. Only safe when no part needs its back; the UI won't offer it otherwise.
    var singleSided = false
    /// Booklet only — which way the printer turns the paper, so imposition can lay the back
    /// of each sheet out to suit. Not a request to the printer: the print panel resets duplex
    /// from the printer's own preset, so this describes what the printer will do, rather than
    /// telling it what to do.
    var duplexFlip: BookletDuplexFlip = .longEdge

    /// What Print asks the print panel for: two-sided for a booklet, unless it's going out
    /// single-sided. Only a hint (the panel resets duplex from the printer's preset), but a
    /// single-sided job shouldn't ask for duplex at all.
    var wantsTwoSidedPrinting: Bool { layout == .booklet && !singleSided }
}

// MARK: - Combine Manager
class CombineManager: ObservableObject {
    @Published var files: [CombineFile] = []
    @Published var collateGroups: [UUID: CollateGroup] = [:]

    // ── Totals ────────────────────────────────────────────────────────────────
    // Collate groups: N copies of the whole set  (fileCount × copies pages).
    // Standalone files: copies × their own page count.
    var totalFiles: Int {
        var count = 0
        var i = 0
        while i < files.count {
            if let gid = files[i].collateGroupId, let g = collateGroups[gid] {
                var n = 0
                while i < files.count && files[i].collateGroupId == gid { n += 1; i += 1 }
                count += n * g.copies
            } else {
                count += files[i].copies; i += 1
            }
        }
        return count
    }

    var totalPages: Int {
        var count = 0
        var i = 0
        while i < files.count {
            if let gid = files[i].collateGroupId, let g = collateGroups[gid] {
                var p = 0
                while i < files.count && files[i].collateGroupId == gid { p += files[i].pageCount; i += 1 }
                count += p * g.copies
            } else {
                count += files[i].pageCount * files[i].copies; i += 1
            }
        }
        return count
    }

    /// Sheets of paper booklet output will consume. Mirrors `buildDocument`'s segmentation:
    /// every copy of every real file starts its own booklet, and blank-page entries join the
    /// booklet in front of them (they carry no bookmark, so that's how imposition groups them).
    var totalBookletSheets: Int {
        var sheets = 0
        var current = 0                       // reading pages in the booklet being accumulated
        func flush() { sheets += bookletPaddedCount(current) / 4; current = 0 }
        func add(_ f: CombineFile) {
            if f.isBlankPage { current += 1 } else { flush(); current = f.pageCount }
        }

        var i = 0
        while i < files.count {
            if let gid = files[i].collateGroupId, let g = collateGroups[gid] {
                var group: [CombineFile] = []
                while i < files.count && files[i].collateGroupId == gid { group.append(files[i]); i += 1 }
                for _ in 0..<g.copies { for f in group { add(f) } }
            } else {
                let f = files[i]; i += 1
                for _ in 0..<f.copies { add(f) }
            }
        }
        flush()
        return sheets
    }

    // ── Undo ──────────────────────────────────────────────────────────────────
    // Snapshots both files and collateGroups so undo/redo always restores a
    // consistent pair.
    private func registerUndo(undoManager: UndoManager?, actionName: String,
                              restoringFiles beforeFiles: [CombineFile],
                              restoringGroups beforeGroups: [UUID: CollateGroup]) {
        let postFiles  = files
        let postGroups = collateGroups
        undoManager?.setActionName(actionName)
        undoManager?.registerUndo(withTarget: self) { manager in
            manager.files         = beforeFiles
            manager.collateGroups = beforeGroups
            manager.registerUndo(undoManager: undoManager, actionName: actionName,
                                 restoringFiles: postFiles, restoringGroups: postGroups)
        }
    }

    // ── File management ───────────────────────────────────────────────────────
    func addBlankPage(after selectedIDs: Set<UUID>, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        let dummy = URL(fileURLWithPath: "/dev/null")
        let entry = CombineFile(url: dummy, name: "Blank Page", pageCount: 1, copies: 1, isBlankPage: true)
        if let lastIdx = files.indices.last(where: { selectedIDs.contains(files[$0].id) }) {
            files.insert(entry, at: lastIdx + 1)
        } else {
            files.append(entry)
        }
        registerUndo(undoManager: undoManager, actionName: "Add Blank Page",
                     restoringFiles: bf, restoringGroups: bg)
    }

    func addFiles(urls: [URL], undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "pdf" {
                guard let document = PDFDocument(url: url) else { continue }
                files.append(CombineFile(url: url, name: url.lastPathComponent, pageCount: document.pageCount,
                                         copies: 1, bookmark: fileBookmark(for: url)))
            } else {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
                let frameCount = CGImageSourceGetCount(src)
                guard frameCount > 0 else { continue }
                files.append(CombineFile(url: url, name: url.lastPathComponent, pageCount: frameCount,
                                         copies: 1, bookmark: fileBookmark(for: url)))
            }
        }
        if files.count != bf.count {
            registerUndo(undoManager: undoManager, actionName: "Add Files",
                         restoringFiles: bf, restoringGroups: bg)
        }
    }

    /// Points each file at where it is now, following any move or rename since it was added —
    /// and takes the new name with it, so the list and the table of contents match the file.
    /// Called before every output, since that's when the files are read again. A file that
    /// can't be found keeps its old path, and the output then reports it by name.
    func refreshFileLocations() {
        var updated = files
        for i in updated.indices where !updated[i].isBlankPage {
            if updated[i].followMove() { updated[i].name = updated[i].url.lastPathComponent }
        }
        if updated != files { files = updated }
    }

    func removeFiles(ids: Set<UUID>, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        files.removeAll { ids.contains($0.id) }
        // Dissolve any group that now has fewer than 2 members
        var toDissolve: [UUID] = []
        for gid in collateGroups.keys {
            if files.filter({ $0.collateGroupId == gid }).count < 2 { toDissolve.append(gid) }
        }
        for gid in toDissolve {
            for i in files.indices where files[i].collateGroupId == gid { files[i].collateGroupId = nil }
            collateGroups.removeValue(forKey: gid)
        }
        registerUndo(undoManager: undoManager, actionName: "Remove File",
                     restoringFiles: bf, restoringGroups: bg)
    }

    func clearAll(undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        files.removeAll()
        collateGroups.removeAll()
        registerUndo(undoManager: undoManager, actionName: "Clear All",
                     restoringFiles: bf, restoringGroups: bg)
    }

    /// Applies `layout` to every part that hasn't been given one explicitly, plus `current`
    /// itself. Parts someone has already decided on are left alone — having set one part by hand,
    /// it would be rude to overwrite that from a different part's screen.
    ///
    /// Returns how many parts took the layout and how many kept a choice already made, so the
    /// caller can say what happened.
    @discardableResult
    func applyBookletLayoutToUndecided(_ layout: BookletPartLayout,
                                       including current: UUID?,
                                       undoManager: UndoManager?) -> (applied: Int, kept: Int) {
        let beforeFiles = files, beforeGroups = collateGroups
        var applied = 0, kept = 0
        for i in files.indices where !files[i].isBlankPage {
            if files[i].bookletLayout == nil || files[i].id == current {
                files[i].bookletLayout = layout
                applied += 1
            } else {
                kept += 1
            }
        }
        if files != beforeFiles {
            registerUndo(undoManager: undoManager, actionName: "Apply Booklet Layout",
                         restoringFiles: beforeFiles, restoringGroups: beforeGroups)
        }
        return (applied, kept)
    }

    /// Sets the booklet layout on every file in `ids`. Undoable as one step, like the other
    /// list edits.
    func setBookletLayout(_ layout: BookletPartLayout, for ids: Set<UUID>, undoManager: UndoManager?) {
        guard !ids.isEmpty else { return }
        let beforeFiles = files, beforeGroups = collateGroups
        for i in files.indices where ids.contains(files[i].id) && !files[i].isBlankPage {
            files[i].bookletLayout = layout
        }
        guard files != beforeFiles else { return }
        registerUndo(undoManager: undoManager, actionName: "Change Booklet Layout",
                     restoringFiles: beforeFiles, restoringGroups: beforeGroups)
    }

    func updateCopies(for id: UUID, copies: Int, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        if let index = files.firstIndex(where: { $0.id == id }) {
            files[index].copies = max(1, copies)
        }
        registerUndo(undoManager: undoManager, actionName: "Change Copies",
                     restoringFiles: bf, restoringGroups: bg)
    }

    // ── Reordering ────────────────────────────────────────────────────────────
    func moveUp(ids: Set<UUID>, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        // Process ascending so adjacent items move as a block.
        let selectedIndices = files.indices.filter { ids.contains(files[$0].id) }.sorted()
        for index in selectedIndices {
            guard index > 0 else { continue }
            guard !ids.contains(files[index - 1].id) else { continue }
            files.swapAt(index, index - 1)
        }
        if files.map(\.id) != bf.map(\.id) {
            registerUndo(undoManager: undoManager, actionName: "Move Up",
                         restoringFiles: bf, restoringGroups: bg)
        }
    }

    func moveDown(ids: Set<UUID>, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        // Process descending for the same block-preservation reason.
        let selectedIndices = files.indices.filter { ids.contains(files[$0].id) }.sorted().reversed()
        for index in selectedIndices {
            guard index < files.count - 1 else { continue }
            guard !ids.contains(files[index + 1].id) else { continue }
            files.swapAt(index, index + 1)
        }
        if files.map(\.id) != bf.map(\.id) {
            registerUndo(undoManager: undoManager, actionName: "Move Down",
                         restoringFiles: bf, restoringGroups: bg)
        }
    }

    /// Moves the given files (a group-expanded block; order preserved) so they land
    /// immediately before `targetId`, or to the end when `targetId` is nil. Callers
    /// snap `targetId` to a collate-group boundary, so groups stay contiguous.
    func move(ids: Set<UUID>, before targetId: UUID?, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        let moving = files.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return }
        var remaining = files.filter { !ids.contains($0.id) }
        let insertIndex: Int
        if let targetId, let idx = remaining.firstIndex(where: { $0.id == targetId }) {
            insertIndex = idx
        } else {
            insertIndex = remaining.count   // target nil or itself moved → append
        }
        remaining.insert(contentsOf: moving, at: insertIndex)
        files = remaining
        if files.map(\.id) != bf.map(\.id) {
            registerUndo(undoManager: undoManager, actionName: "Reorder Files",
                         restoringFiles: bf, restoringGroups: bg)
        }
    }

    /// Adds the given files into an existing collate group (drag-onto-group). The files
    /// are reassigned to `groupId` and pulled in contiguously after the group's current
    /// last member. Files already in the group are ignored; any source group left with
    /// fewer than 2 members is dissolved.
    func addToGroup(ids: Set<UUID>, groupId: UUID, undoManager: UndoManager?) {
        guard collateGroups[groupId] != nil else { return }
        let bf = files; let bg = collateGroups
        let addingIds = ids.filter { id in
            files.first(where: { $0.id == id })?.collateGroupId != groupId
        }
        guard !addingIds.isEmpty else { return }

        var moving = files.filter { addingIds.contains($0.id) }
        for i in moving.indices { moving[i].collateGroupId = groupId }
        var remaining = files.filter { !addingIds.contains($0.id) }
        if let lastIdx = remaining.lastIndex(where: { $0.collateGroupId == groupId }) {
            remaining.insert(contentsOf: moving, at: lastIdx + 1)
        } else {
            remaining.append(contentsOf: moving)
        }
        files = remaining
        cleanupSmallGroups()
        registerUndo(undoManager: undoManager, actionName: "Add to Collate Group",
                     restoringFiles: bf, restoringGroups: bg)
    }

    /// Dissolves any collate group left with fewer than 2 members.
    private func cleanupSmallGroups() {
        for gid in collateGroups.keys where files.filter({ $0.collateGroupId == gid }).count < 2 {
            for i in files.indices where files[i].collateGroupId == gid { files[i].collateGroupId = nil }
            collateGroups.removeValue(forKey: gid)
        }
    }

    // ── Collate groups ────────────────────────────────────────────────────────
    /// Groups the given files into a collate set, pulling them together
    /// contiguously at the position of the first selected file.
    /// Sets each file's copies from an ensemble preset's parts, matched on file names
    /// (`matchPreset`, shared with the command line: longest part name first, so "Bass
    /// Clarinet" beats "Clarinet"; one entry over several numbered parts is shared out).
    /// Files that match nothing keep their copies. One undo step per file changed.
    @discardableResult
    func applyPreset(parts: [PresetPart], undoManager: UndoManager?) -> PresetMatchResult {
        let result = matchPreset(parts: parts, files: files.map { ($0.id, $0.name) })
        for (fileId, copies) in result.copies {
            updateCopies(for: fileId, copies: copies, undoManager: undoManager)
        }
        return result
    }

    func createCollateGroup(fileIds: Set<UUID>, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        let orderedIndices = files.indices.filter { fileIds.contains(files[$0].id) }
        guard orderedIndices.count >= 2 else { return }

        let insertionIndex = orderedIndices[0]
        let groupFilesInOrder = orderedIndices.map { files[$0] }

        // Remove in reverse order so lower indices stay stable
        for idx in orderedIndices.reversed() { files.remove(at: idx) }

        // All removed files had index >= insertionIndex, so insertionIndex is unchanged
        let newGroupId = UUID()
        for (offset, var file) in groupFilesInOrder.enumerated() {
            file.collateGroupId = newGroupId
            files.insert(file, at: insertionIndex + offset)
        }
        collateGroups[newGroupId] = CollateGroup(id: newGroupId, copies: 1)

        registerUndo(undoManager: undoManager, actionName: "Group Files",
                     restoringFiles: bf, restoringGroups: bg)
    }

    /// Dissolves a collate group, restoring its files as independent entries.
    func dissolveGroup(id: UUID, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        for i in files.indices where files[i].collateGroupId == id { files[i].collateGroupId = nil }
        collateGroups.removeValue(forKey: id)
        registerUndo(undoManager: undoManager, actionName: "Ungroup Files",
                     restoringFiles: bf, restoringGroups: bg)
    }

    func updateGroupCopies(id: UUID, copies: Int, undoManager: UndoManager?) {
        let bf = files; let bg = collateGroups
        collateGroups[id]?.copies = max(1, copies)
        registerUndo(undoManager: undoManager, actionName: "Change Copies",
                     restoringFiles: bf, restoringGroups: bg)
    }

    // ── PDF output ────────────────────────────────────────────────────────────
    // Standalone files: all copies of that file together (existing behaviour).
    // Collate groups: the set of files repeats N times interleaved —
    //   [file1, file2, file3] × 4 → f1,f2,f3, f1,f2,f3, f1,f2,f3, f1,f2,f3
    /// Assembles the combined document. Shared by "Create PDF" and "Open in Preview" so the
    /// two can never drift apart. Returns the document, its page count, and the bookmark
    /// labels with the page index each part starts at — those indices double as "first page
    /// of each part" for stamping.
    /// `rotateBackFaces` is the duplex compensation, and it is **only** applied on the way to a
    /// printer. Turning it on makes every second sheet face appear upside down, which is right
    /// on paper but looks broken on screen — so Create PDF and Open in Preview produce upright
    /// reading spreads and only Print (and the test sheet) carry it.
    /// `unreadable` lists the input files that couldn't be opened this time round (each once,
    /// in list order). Files are reopened here rather than when they're added, so one that has
    /// since moved, or that macOS won't let the app read, used to vanish from the output — and if
    /// every file did, the empty document failed to save with no explanation.
    private func buildDocument(options: CombineOutputOptions, stampJob: StampJob?,
                               rotateBackFaces: Bool = false)
        -> (doc: PDFDocument, pageCount: Int, bookmarks: [(label: String, pageIndex: Int)],
            unreadable: [URL], stampProblem: String?) {
        var doc = PDFDocument()
        var idx = 0
        var bookmarks: [(label: String, pageIndex: Int)] = []
        var partLayouts: [BookletPartLayout] = []
        var unreadable: [URL] = []
        func noteUnreadable(_ url: URL) {
            if !unreadable.contains(url) { unreadable.append(url) }
        }

        func addPages(from file: CombineFile, copyIndex: Int, totalCopies: Int) {
            if file.isBlankPage {
                if let blank = createBlankPage() { doc.insert(blank, at: idx); idx += 1 }
                return
            }
            let ext = file.url.pathExtension.lowercased()
            let baseName = file.name.hasSuffix(".pdf") ? String(file.name.dropLast(4)) : file.name
            let label = totalCopies > 1 ? "\(baseName) \(copyIndex + 1)/\(totalCopies)" : baseName
            bookmarks.append((label: label, pageIndex: idx))
            // Parallel to `bookmarks`, so each booklet segment can be matched to the part it
            // came from. One entry per part *per copy*, exactly like the bookmarks.
            partLayouts.append(file.effectiveBookletLayout)
            if ext != "pdf" {
                let pages = pdfPages(fromImageAt: file.url)
                if pages.isEmpty { noteUnreadable(file.url) }
                for page in pages { doc.insert(page, at: idx); idx += 1 }
            } else {
                guard let src = PDFDocument(url: file.url), src.pageCount > 0 else {
                    noteUnreadable(file.url)
                    return
                }
                for p in 0..<src.pageCount {
                    if let page = src.page(at: p) { doc.insert(page, at: idx); idx += 1 }
                }
                // Booklet output pads each part to a whole folded sheet, which subsumes
                // padding to an even page count — so this only applies to single-page output.
                if options.addBlankPages && options.layout != .booklet && src.pageCount % 2 == 1 {
                    if let blank = createBlankPage() { doc.insert(blank, at: idx); idx += 1 }
                }
            }
        }

        var i = 0
        while i < files.count {
            if let gid = files[i].collateGroupId, let group = collateGroups[gid] {
                var groupFiles: [CombineFile] = []
                while i < files.count && files[i].collateGroupId == gid { groupFiles.append(files[i]); i += 1 }
                for ci in 0..<group.copies { for f in groupFiles { addPages(from: f, copyIndex: ci, totalCopies: group.copies) } }
            } else {
                let file = files[i]; i += 1
                for ci in 0..<file.copies { addPages(from: file, copyIndex: ci, totalCopies: file.copies) }
            }
        }

        var pageCount = idx

        // Stamp *before* the outline is built — flattening rebuilds the pages and drops any
        // existing outline, but leaves page indices untouched, so the bookmark loop below
        // still lines up.
        // A stamp that couldn't be applied stops the output rather than producing it unstamped.
        var stampProblem: String?
        do {
            doc = try applyingStamp(stampJob, to: doc, partFirstPages: bookmarks.map { $0.pageIndex })
        } catch {
            stampProblem = error.localizedDescription
        }

        // Then impose, still before the outline: imposition rebuilds the pages too, and it
        // must run on reading pages so stamps land where the reader sees them. Each bookmark
        // marks the first page of a part — and there's one per *copy*, so seven copies of a
        // part become seven separately foldable booklets rather than one seven-times-long one.
        if options.layout == .booklet {
            let segments = bookletSegments(pageCount: doc.pageCount,
                                           partFirstPages: bookmarks.map { $0.pageIndex })
            // Match each segment to the part that starts inside it, the same way the outline is
            // remapped below — the arrays aren't always the same length, so position won't do.
            let layouts: [BookletPartLayout] = segments.map { segment in
                guard let i = bookmarks.indices.first(where: { segment.contains(bookmarks[$0].pageIndex) })
                else { return bookletDefaultLayout(pageCount: segment.count) }
                return partLayouts[i]
            }
            if let imposed = imposedBookletDocument(doc, segments: segments,
                                                    sheetSize: options.sheetSize,
                                                    pageScale: options.bookletPageScale,
                                                    rotateBackFaces: rotateBackFaces,
                                                    layouts: layouts,
                                                    omitBlankFaces: options.singleSided) {
                doc = imposed.doc
                pageCount = imposed.doc.pageCount
                // Re-aim each bookmark at the sheet its booklet starts on. Match by looking
                // up which segment contains the reading page rather than by position:
                // bookletSegments can prepend a segment at page 0, and a file that failed to
                // load contributes a label but no pages, so the two arrays aren't always the
                // same length. `segments` and `sheetStarts` are index-aligned by construction.
                for i in bookmarks.indices {
                    if let s = segments.firstIndex(where: { $0.contains(bookmarks[i].pageIndex) }) {
                        bookmarks[i].pageIndex = imposed.sheetStarts[s]
                    }
                }
            }
        }

        // Stamping and imposition return a document PDFKit opened from data, and on macOS 27
        // an outline set on one of those is dropped when it's saved. Moving the pages into a
        // fresh document keeps the table of contents in the file. Page indices are unchanged.
        doc = outlineReadyDocument(from: doc)

        let root = PDFOutline()
        for (label, pageIndex) in bookmarks {
            if let page = doc.page(at: pageIndex) {
                let item = PDFOutline()
                item.label = label
                // PDF coordinates start at the bottom-left, so `.zero` is the *foot* of the page:
                // a viewer jumping there puts the bottom of the right page at the top of the
                // window, which reads as landing on the next part — and nothing ever lands at the
                // top of page 1. Aim at the top-left of the visible box instead.
                let box = page.bounds(for: .cropBox)
                item.destination = PDFDestination(page: page,
                                                  at: CGPoint(x: box.minX, y: box.maxY))
                root.insertChild(item, at: root.numberOfChildren)
            }
        }
        doc.outlineRoot = root

        return (doc, pageCount, bookmarks, unreadable, stampProblem)
    }

    func createCombinedPDF(to url: URL, options: CombineOutputOptions,
                           stampJob: StampJob? = nil, completion: PDFAlertHandler) {
        refreshFileLocations()
        let built = buildDocument(options: options, stampJob: stampJob)
        guard built.unreadable.isEmpty else {
            completion("Couldn’t Read Some Files", unreadableFilesMessage(built.unreadable), true)
            return
        }
        if let problem = built.stampProblem {
            completion("Couldn’t Stamp the Parts", problem, true)
            return
        }
        if let problem = savePDFDocument(built.doc, to: url) {
            completion("Couldn’t Save the PDF", problem, true)
            return
        }
        let unit = options.layout == .booklet ? "booklet sheet sides" : "pages"
        completion("PDF Created Successfully",
                   "Combined PDF with \(built.pageCount) \(unit) saved to:\n\(url.path)", false)
    }

    func openInPreview(options: CombineOutputOptions, stampJob: StampJob? = nil, onError: PDFAlertHandler) {
        refreshFileLocations()
        let built = buildDocument(options: options, stampJob: stampJob)
        guard built.unreadable.isEmpty else {
            onError("Couldn’t Read Some Files", unreadableFilesMessage(built.unreadable), true)
            return
        }
        if let problem = built.stampProblem {
            onError("Couldn’t Stamp the Parts", problem, true)
            return
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("CombinedForPrint.pdf")
        if let problem = savePDFDocument(built.doc, to: tempURL) {
            onError("Couldn’t Open in Preview", problem, true)
            return
        }
        NSWorkspace.shared.open(tempURL)
    }

    /// Builds the document and hands it straight to the system print dialog, so a whole
    /// folder of booklets is one print job rather than one per part.
    @MainActor
    func printCombined(options: CombineOutputOptions, stampJob: StampJob? = nil,
                       in window: NSWindow?, onError: PDFAlertHandler) {
        refreshFileLocations()
        let built = buildDocument(options: options, stampJob: stampJob,
                                  rotateBackFaces: shouldRotateBackFaces(options))
        guard built.unreadable.isEmpty else {
            onError("Couldn’t Read Some Files", unreadableFilesMessage(built.unreadable), true)
            return
        }
        if let problem = built.stampProblem {
            onError("Couldn’t Stamp the Parts", problem, true)
            return
        }
        printPDFDocument(built.doc,
                         jobName: "ScoreSort \u{2014} Combined",
                         wantsTwoSided: options.wantsTwoSidedPrinting,
                         in: window,
                         onError: onError)
    }

    /// Whether output bound for a printer needs the back of each sheet turned over.
    private func shouldRotateBackFaces(_ options: CombineOutputOptions) -> Bool {
        options.layout == .booklet && options.duplexFlip.rotatesBackFaces
    }


    private func createBlankPage() -> PDFPage? {
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842) // A4
        let blankPage = PDFPage()
        blankPage.setBounds(pageRect, for: .mediaBox)
        return blankPage
    }

}
