//
//  SplitModel.swift
//  ScoreSort
//
//  The Split tab's Step 1 state: the document, where it's split, what's skipped, the
//  file names, the page on screen, the selection and undo. `SplitView` holds one as a
//  `@StateObject` and keeps everything on screen (stages, sheets, banners, keys, saving).
//  Pure split maths live in Logic/SplitLogic.swift.
//

import SwiftUI
@preconcurrency import PDFKit
import Combine

/// Controls whether the Delete key (and the Skip button) targets a single page or
/// the whole output file that contains the current page.
enum SkipMode { case page, file }

/// Snapshot of the undoable Step-1 split state (file boundaries, skipped pages, and
/// custom names). Does not include the PDF document — document-rebuild actions (page
/// swap, booklet reorder, double-page split) are not part of this undo stack.
private struct SplitSnapshot {
    var fileSizes: [Int]
    var skippedPages: Set<Int>
    var customFileNames: [Int: String]
}

/// The most recently applied booklet order, kept so it can be repeated on another file.
struct SplitBookletOrder: Equatable {
    /// The file's page count (only a file of the same length can take it).
    let n: Int
    /// `order[readingPos]` is the scan position within the file.
    let order: [Int]
}

final class SplitModel: ObservableObject {
    /// Loads the PDF and remembers where it came from (`sourceURL`, `currentFileName`).
    /// Only the model changes its document; `DropZoneView` is handed it for display, with
    /// an `onOpen` that comes back here.
    let pdfManager: PDFManager
    private var managerChanges: AnyCancellable?

    // fileSizes stores the page count for each output file in order.
    // e.g. [2, 2, 1, 3] means 4 files with 2, 2, 1, and 3 pages respectively.
    // This makes split point manipulation natural: adding a split just partitions
    // an existing entry, removing one merges two adjacent entries.
    @Published var fileSizes: [Int] = []
    /// Pages per file for Apply and Re-stride (1–20).
    @Published var stride: Int = 2
    @Published var currentPage: Int = 0
    @Published var baseFileName: String = ""
    /// File index → the part of its name after the base (Step 2's fields).
    @Published var customFileNames: [Int: String] = [:]
    /// Pages to omit from output. A file whose every page is in this set is treated as "fully skipped".
    @Published var skippedPages: Set<Int> = []
    /// File indices currently highlighted in the output-files list (for multi-select + Delete).
    @Published var selectedFileIndices: Set<Int> = []
    /// Whether Delete / the Skip button targets the current page or the whole file.
    /// Defaults to `.file`; `.page` after a double-page split.
    @Published var skipMode: SkipMode = .file
    /// The loaded document's bookmarks as the files they'd split into; empty when it has none.
    /// Kept so Actions ▸ Use Bookmarks… can re-open the prompt after "Ignore".
    @Published var documentBookmarks: [BookmarkSection] = []
    /// The most recently applied booklet order, stored so the user can repeat it.
    @Published var lastBookletOrder: SplitBookletOrder? = nil
    /// True once ScoreSort has rebuilt this document's pages — Split Double Pages, Swap with
    /// Next, Fix Booklet Order. Saving it then makes a new PDF even as a single file (an A3
    /// part split to A4, say), so one output file is allowed through to naming.
    @Published var documentRebuilt = false

    /// Undo/redo stacks for Step-1 split edits (markers, skips, stride), capped at 50.
    private var undoStack: [SplitSnapshot] = []
    private var redoStack: [SplitSnapshot] = []
    private static let undoLimit = 50

    init(pdfManager: PDFManager = PDFManager()) {
        self.pdfManager = pdfManager
        // The view reads the document through the model, so the manager's changes are ours.
        managerChanges = pdfManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - The document

    var document: PDFDocument? { pdfManager.pdfDocument }

    var totalPages: Int { document?.pageCount ?? 0 }

    // MARK: - Derived from fileSizes

    /// Split markers derived from fileSizes: the page that starts each file (except the first).
    var splitMarkers: Set<Int> {
        var markers: Set<Int> = []
        var pos = 0
        for size in fileSizes.dropLast() {
            pos += size
            markers.insert(pos)
        }
        return markers
    }

    var pageToFileMapping: [Int: Int] {
        guard !fileSizes.isEmpty else { return [:] }
        var mapping: [Int: Int] = [:]
        var pos = 0
        for (fileIndex, size) in fileSizes.enumerated() {
            for pageIndex in pos..<(pos + size) {
                mapping[pageIndex] = fileIndex
            }
            pos += size
        }
        return mapping
    }

    var numberOfFiles: Int { fileSizes.count }

    /// The pages of output file `fileIndex`: a run of `fileSizes[fileIndex]` pages. Worked out
    /// from `fileSizes` directly — building the whole page → file map for it, as this used to,
    /// ran several times per file card on every redraw.
    func pagesForFile(_ fileIndex: Int) -> [Int] {
        Array(splitFilePages(fileIndex, fileSizes: fileSizes))
    }

    /// The output file `page` belongs to.
    func fileIndex(containing page: Int) -> Int? {
        var pos = 0
        for (i, size) in fileSizes.enumerated() {
            if page >= pos && page < pos + size { return i }
            pos += size
        }
        return nil
    }

    /// The output file holding the page on screen.
    var currentFileIndex: Int? { fileIndex(containing: currentPage) }

    /// True if every page in the output file is in skippedPages.
    func isFileFullySkipped(_ fileIndex: Int) -> Bool {
        let pages = pagesForFile(fileIndex)
        return !pages.isEmpty && pages.allSatisfy { skippedPages.contains($0) }
    }

    /// True if some (but not all) pages in the output file are in skippedPages.
    func isFilePartiallySkipped(_ fileIndex: Int) -> Bool {
        let pages = pagesForFile(fileIndex)
        let n = pages.filter { skippedPages.contains($0) }.count
        return n > 0 && n < pages.count
    }

    /// Number of output files that have at least one non-skipped page.
    var activeFileCount: Int {
        (0..<numberOfFiles).filter { !isFileFullySkipped($0) }.count
    }

    /// Indices of output files whose every page is skipped.
    var skippedFileIndices: Set<Int> {
        Set((0..<numberOfFiles).filter { isFileFullySkipped($0) })
    }

    /// Whether Step 1 can move on to naming: there must be something new to save — two or
    /// more files, some pages left out, or pages ScoreSort has rebuilt.
    var canContinueToNaming: Bool {
        splitOutputIsWorthSaving(activeFiles: activeFileCount, skippedPages: skippedPages.count,
                                 pagesRebuilt: documentRebuilt)
    }

    /// True when the current file has a multiple of 4 pages (≥ 4), so a booklet reorder
    /// is meaningful.
    var canFixBookletOrder: Bool {
        guard let fi = currentFileIndex else { return false }
        let n = fileSizes[fi]
        return n >= 4 && n % 4 == 0
    }

    // MARK: - Undo / redo (Step 1 split edits)

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func currentSnapshot() -> SplitSnapshot {
        SplitSnapshot(fileSizes: fileSizes, skippedPages: skippedPages, customFileNames: customFileNames)
    }

    /// Record the current state before a mutating action so ⌘Z can revert it.
    private func pushUndo() {
        undoStack.append(currentSnapshot())
        redoStack.removeAll()
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
    }

    private func restore(_ s: SplitSnapshot) {
        fileSizes = s.fileSizes
        skippedPages = s.skippedPages
        customFileNames = s.customFileNames
        selectedFileIndices = []
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        restore(next)
    }

    /// Forgets the undo history — a new document, or one whose pages moved (a reorder makes
    /// earlier snapshots' page-based skips point at the wrong pages).
    func clearUndoHistory() {
        undoStack = []
        redoStack = []
    }

    // MARK: - Split edits

    /// Clear All: one file, no names, nothing skipped.
    func clearAllSplits() {
        pushUndo()
        fileSizes = totalPages > 0 ? [totalPages] : []
        customFileNames.removeAll()
        skippedPages = []
        selectedFileIndices = []
    }

    /// Apply: a split every `stride` pages, from scratch.
    func applyStride() {
        pushUndo()
        fileSizes = splitSizes(totalPages: totalPages, stride: stride)
        customFileNames.removeAll()
        skippedPages = []
        selectedFileIndices = []
    }

    /// Re-applies the current stride from `currentPage` to the end of the document,
    /// leaving all existing splits before `currentPage` untouched.
    ///
    /// If `currentPage` falls in the middle of an existing file segment, that segment
    /// is trimmed to end at `currentPage` before the new stride begins.
    ///
    /// Example: stride = 4, fileSizes = [4, 4, 4 …], currentPage = 3
    ///   → fileSizes becomes [3, 4, 4, 4 …]
    func restrideFromCurrentPage() {
        guard currentPage > 0, totalPages > currentPage else { return }
        pushUndo()

        // Walk existing fileSizes, keeping every segment that ends at or before
        // currentPage.  If currentPage falls inside a segment, keep only the
        // portion before currentPage (i.e. trim that segment).
        var prefixSizes: [Int] = []
        var pos = 0
        for size in fileSizes {
            let end = pos + size
            if end <= currentPage {
                prefixSizes.append(size)
                pos = end
            } else {
                // currentPage is inside this segment (or at its very start).
                if pos < currentPage {
                    prefixSizes.append(currentPage - pos)
                }
                break
            }
        }

        let remaining = totalPages - currentPage
        let suffixSizes = splitSizes(totalPages: remaining, stride: stride)
        fileSizes = prefixSizes + suffixSizes

        // Clear custom names for the re-strided region; prefix names stay intact.
        customFileNames = customFileNames.filter { $0.key < prefixSizes.count }
    }

    /// Space: splits a file at `page`, or merges the file starting there into the one before.
    func toggleSplitAt(page: Int) {
        pushUndo()
        let newSizes = toggleSplit(in: fileSizes, at: page)
        // Names follow the page their file starts on, not its position in the list.
        customFileNames = remapFileNames(customFileNames, from: fileSizes, to: newSizes)
        fileSizes = newSizes
    }

    /// Toggle skip on all pages of the given file indices.
    /// If every file in the set is already fully skipped, they are un-skipped; otherwise all are skipped.
    func toggleSkipFiles(_ fileIndices: Set<Int>) {
        pushUndo()
        let allFullySkipped = fileIndices.allSatisfy { isFileFullySkipped($0) }
        for idx in fileIndices {
            let pages = pagesForFile(idx)
            if allFullySkipped {
                skippedPages.subtract(pages)
            } else {
                skippedPages.formUnion(pages)
            }
        }
        selectedFileIndices = []
    }

    /// Toggle skip on a single page.
    func toggleSkipPage(_ page: Int) {
        pushUndo()
        if skippedPages.contains(page) {
            skippedPages.remove(page)
        } else {
            skippedPages.insert(page)
        }
    }

    /// Delete / Forward-Delete, and the Skip button. Behaviour depends on `skipMode`:
    ///   • `.page` — toggles skip on the current page only.
    ///   • `.file` — toggles skip on all selected file cards (or the file at the current page).
    func toggleSkipForDeleteKey() {
        switch skipMode {
        case .page:
            toggleSkipPage(currentPage)
        case .file:
            let targets = selectedFileIndices.isEmpty
                ? Set([currentFileIndex].compactMap { $0 })
                : selectedFileIndices
            if !targets.isEmpty { toggleSkipFiles(targets) }
        }
    }

    /// Splits at the bookmarks; with a `nameStyle`, also names the files from their titles.
    /// Replaces the split state like a fresh load would, so it starts a new undo history.
    func applyBookmarks(_ sections: [BookmarkSection], nameStyle: BookmarkNameStyle?) {
        guard sections.reduce(0, { $0 + $1.pageCount }) == totalPages else { return }
        fileSizes = sections.map { $0.pageCount }
        customFileNames.removeAll()
        baseFileName = pdfManager.currentFileName ?? ""
        if let nameStyle {
            let names = bookmarkSplitNames(titles: sections.map { $0.title },
                                           fallbackBaseName: baseFileName,
                                           style: nameStyle)
            baseFileName = names.baseName
            for (i, suffix) in names.suffixes.enumerated() where !suffix.isEmpty {
                customFileNames[i] = suffix
            }
        }
        skippedPages = []
        selectedFileIndices = []
        clearUndoHistory()
    }

    // MARK: - Moving around

    /// ← (⌘← to the first page). The selection follows the page.
    func goToPreviousPage(toFirst: Bool = false) {
        if toFirst {
            currentPage = 0
        } else if currentPage > 0 {
            currentPage -= 1
        }
        if let fi = currentFileIndex { selectedFileIndices = [fi] }
    }

    /// → (⌘→ to the last page). The selection follows the page.
    func goToNextPage(toLast: Bool = false) {
        if toLast {
            currentPage = totalPages - 1
        } else if currentPage < totalPages - 1 {
            currentPage += 1
        }
        if let fi = currentFileIndex { selectedFileIndices = [fi] }
    }

    /// ↓: the start of the next file; with `extendingSelection` (⇧) the selection grows to it.
    func goToNextFile(extendingSelection: Bool = false) {
        let fileStarts = [0] + splitMarkers.sorted()
        guard let next = fileStarts.first(where: { $0 > currentPage }),
              let fi = fileIndex(containing: next) else { return }
        currentPage = next
        if extendingSelection {
            // Extend the range from the anchor (lowest selected index)
            let anchor = selectedFileIndices.min() ?? fi
            selectedFileIndices = Set(anchor...max(anchor, fi))
        } else {
            selectedFileIndices = [fi]
        }
    }

    /// ↑: the start of the previous file; with `extendingSelection` (⇧) the selection grows to it.
    func goToPreviousFile(extendingSelection: Bool = false) {
        let fileStarts = [0] + splitMarkers.sorted()
        guard let prev = fileStarts.last(where: { $0 < currentPage }),
              let fi = fileIndex(containing: prev) else { return }
        currentPage = prev
        if extendingSelection {
            let anchor = selectedFileIndices.max() ?? fi
            selectedFileIndices = Set(min(anchor, fi)...anchor)
        } else {
            selectedFileIndices = [fi]
        }
    }

    /// A click on a file card: ⇧ extends the selection, ⌘ toggles one card, a plain click
    /// selects the card and shows its first page.
    func selectFile(_ fileIndex: Int, command: Bool, shift: Bool) {
        if shift, let anchor = selectedFileIndices.min() {
            let lo = min(anchor, fileIndex)
            let hi = max(anchor, fileIndex)
            selectedFileIndices = Set(lo...hi)
        } else if command {
            if selectedFileIndices.contains(fileIndex) {
                selectedFileIndices.remove(fileIndex)
            } else {
                selectedFileIndices.insert(fileIndex)
            }
        } else {
            selectedFileIndices = [fileIndex]
            if let firstPage = pagesForFile(fileIndex).first {
                currentPage = firstPage
            }
        }
    }
}
