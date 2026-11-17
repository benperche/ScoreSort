//
//  SplitView.swift
//  ScoreSort
//
//  Split PDF tab — Step 1 (SplitView) plus its Step-1 machinery: booklet-reorder
//  UI, the booklet-order sheet and the split controls section. The "Split Double
//  Pages" sheet is in ScanSplitSheet.swift.
//  Pure split maths live in Logic/SplitLogic.swift.
//

import SwiftUI
@preconcurrency import PDFKit
import UniformTypeIdentifiers
import Combine

// MARK: - Split View
private enum SplitStage { case split, naming, prefix, summary }

/// Snapshot of the undoable Step-1 split state (file boundaries, skipped pages, and
/// custom names). Does not include the PDF document — document-rebuild actions (page
/// swap, booklet reorder, A3 split) are not part of this undo stack.
private struct SplitSnapshot {
    var fileSizes: [Int]
    var skippedPages: Set<Int>
    var customFileNames: [Int: String]
}

/// Controls whether the Delete key (and the Skip button) targets a single page or
/// the whole output file that contains the current page.
enum SkipMode { case page, file }

// MARK: - Booklet Reorder Helpers

/// A pending request to reorder the pages of one output-file segment.
struct BookletFixRequest: Identifiable {
    let id = UUID()
    let fileIndex: Int
    /// Absolute page indices (in the full document) that form this file segment, sorted.
    let pages: [Int]
    /// A snapshot of the document at the time the request was created.
    let document: PDFDocument
}

struct SplitView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var stampStore: StampStore
    @StateObject private var pdfManager = PDFManager()
    // fileSizes stores the page count for each output file in order.
    // e.g. [2, 2, 1, 3] means 4 files with 2, 2, 1, and 3 pages respectively.
    // This makes split point manipulation natural: adding a split just partitions
    // an existing entry, removing one merges two adjacent entries.
    @State private var fileSizes: [Int] = []
    @State private var stride: Int = 2
    @State private var currentPage: Int = 0
    @State private var splitStage: SplitStage = .split
    @State private var baseFileName: String = ""
    @State private var customFileNames: [Int: String] = [:]
    /// Shared pan offset for all naming-stage previews (PDF points from the default top-left position).
    /// Reset whenever a new PDF is loaded so it always starts at the instrument-name corner.
    @State private var previewOffset: CGPoint = .zero
    @State private var prefixItems: [PrefixItem] = []
    /// Incremented each time we enter the prefix stage so SwiftUI creates a fresh
    /// PrefixOrderStepView rather than reusing the old one with stale @State.
    @State private var prefixRoundID: Int = 0
    @State private var summaryNames: [String] = []
    @State private var pendingFolderURL: URL? = nil
    /// Pages to omit from output. A file whose every page is in this set is treated as "fully skipped".
    @State private var skippedPages: Set<Int> = []
    /// File indices currently highlighted in the output-files list (for multi-select + Delete).
    @State private var selectedFileIndices: Set<Int> = []
    /// Undo/redo stacks for Step-1 split edits (markers, skips, stride). Captured as
    /// view-local @State because the split state lives in this view, not a manager.
    @State private var undoStack: [SplitSnapshot] = []
    @State private var redoStack: [SplitSnapshot] = []
    /// Retained reference to the local NSEvent monitor that handles the delete key.
    @State private var splitViewKeyMonitor: Any?
    /// The loaded document's bookmarks as the files they'd split into; empty when it has none.
    /// Kept so Actions ▸ Use Bookmarks… can re-open the prompt after "Ignore".
    @State private var documentBookmarks: [BookmarkSection] = []
    /// Non-nil when the "this PDF has bookmarks" sheet should be presented.
    @State private var bookmarkOffer: BookmarkOffer? = nil
    /// Non-nil when the "Split Double Pages" sheet should be presented — offered on opening
    /// a scan of double pages (A3 sheets, or an overhead scanner's mix of spreads and
    /// single pages), or chosen from the menu.
    @State private var scanSplitRequest: ScanSplitRequest? = nil
    /// The pages to skip in a just-split document, applied once `onChange` has reset the
    /// split state for it (the reset would otherwise clear them).
    @State private var pendingScanSplitSkips: Set<Int>? = nil
    /// Set before programmatically loading an A3-split document so onChange skips re-detection.
    @State private var suppressNextA3Detection = false
    /// Set before swapping pages so onChange skips the full state-reset (preserving split markers).
    @State private var suppressDocumentReset = false
    /// Shows a gentle hint banner when a PDF looks like an A3 scan but didn't trigger auto-detection.
    @State private var a3HintVisible = false
    /// Shows a brief tip banner after a scan's double pages are split.
    @State private var a3SplitNoticeVisible = false
    /// True once ScoreSort has rebuilt this document's pages — Split Double Pages, Swap with
    /// Next, Fix Booklet Order. Saving it then makes a new PDF even as a single file (an A3
    /// part split to A4, say), so one output file is allowed through to naming.
    @State private var documentRebuilt = false
    @State private var scanSplitNotice: AttributedString = ""
    /// Shows a brief tip banner after the first booklet fix, pointing to the per-card redo icon.
    @State private var bookletRedoNoticeVisible = false
    /// Whether Delete / the Skip button targets the current page or the whole file.
    /// Defaults to `.file`; set to `.page` automatically after an A3 split.
    @State private var skipMode: SkipMode = .file
    /// Non-nil when the "Fix Booklet Order" sheet should be presented.
    @State private var bookletFixRequest: BookletFixRequest? = nil
    /// A save in progress (the files are written in the background behind its sheet).
    @State private var saveProgress: SplitSaveProgress? = nil
    /// The most recently applied booklet order, stored so the user can repeat it.
    /// Tuple carries the file's page count (for eligibility check) and the order array.
    @State private var lastBookletOrder: (n: Int, order: [Int])? = nil
    @FocusState private var isViewFocused: Bool
    @AppStorage("filenameSeparator") private var filenameSeparator: String = " - "
    @AppStorage("prefixEnabled") private var prefixEnabled: Bool = true
    @AppStorage("prefixEnsembleType") private var prefixEnsembleType: EnsembleType = .band
    /// When on, the original PDF is moved to the Trash after the split files are written.
    /// Persisted so users who always want it don't re-tick every time; it's recoverable
    /// (Trash, not permanent delete) and the summary screen confirms when it happened.
    @AppStorage("deleteSourceAfterSplit") private var deleteSourceAfterSplit: Bool = false
    /// "Sort into folders" (Step 2's menu). One remembered setting, shared with the Renamer and
    /// Settings ▸ Renamer: it stays as last chosen, across pieces and launches.
    @AppStorage(PartFolderMode.defaultsKey) private var partFolderMode: PartFolderMode = .off
    @AppStorage(PartFolderMode.numberedDefaultsKey) private var numberedFolders: Bool = false
    @AppStorage("splitStampEnabled") private var stampEnabled: Bool = false
    @AppStorage("splitStampScope") private var stampScope: StampScope = .firstPageOfEachPart
    /// Set true after a successful save when the source file was actually trashed, so the
    /// summary screen can confirm it. Reset whenever a new save round begins.
    @State private var sourceWasTrashed = false

    var totalPages: Int {
        pdfManager.pdfDocument?.pageCount ?? 0
    }

    // Split markers derived from fileSizes: the page that starts each file (except the first).
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

    var numberOfFiles: Int {
        fileSizes.count
    }

    /// Returns all page indices for a given output file index (sorted).
    func pagesForFile(_ fileIndex: Int) -> [Int] {
        pageToFileMapping.filter { $0.value == fileIndex }.keys.sorted()
    }

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

    /// Whether Step 1 can move on to naming: there must be something new to save — two or
    /// more files, some pages left out, or pages ScoreSort has rebuilt.
    var canContinueToNaming: Bool {
        splitOutputIsWorthSaving(activeFiles: activeFileCount, skippedPages: skippedPages.count,
                                 pagesRebuilt: documentRebuilt)
    }

    /// Indices of output files whose every page is skipped.
    var skippedFileIndices: Set<Int> {
        Set((0..<numberOfFiles).filter { isFileFullySkipped($0) })
    }

    var body: some View {
        // The onChange lives at the Group level — outside all stage views — so it
        // fires regardless of which stage (split / naming / prefix / summary) is
        // currently active.  Previously it was buried inside splitStageBody and
        // therefore silent when a new PDF arrived during naming or later stages,
        // causing stale customFileNames from an earlier file to bleed through.
        Group {
            switch splitStage {
            case .summary:
                RenameSummaryView(
                    finalNames: summaryNames,
                    outputFolderURL: pendingFolderURL,
                    sourceTrashedNote: sourceWasTrashed ? "Original moved to the Trash." : nil,
                    onStartOver: {
                        pdfManager.clearPDF() // onChange handles full state reset
                    }
                )
                // Drop a new PDF here to restart without clicking Start Over — loading a
                // document fires the Group-level onChange, which resets the whole flow.
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleSummaryPDFDrop(providers) }
            case .prefix:
                PrefixOrderStepView(
                    toolTitle: "Split PDF",
                    stepLabel: "Step 3",
                    initialItems: prefixItems,
                    ensembleType: $prefixEnsembleType,
                    folderSorting: PrefixFolderSorting(mode: $partFolderMode, numbered: numberedFolders) { id, mode, ensemble in
                        defaultPartFolder(forFile: id, mode: mode, ensemble: ensemble)
                    },
                    onBack: { splitStage = .naming },
                    onApply: { orderedItems in
                        applyPrefixAndSaveSplit(orderedItems: orderedItems)
                    }
                )
                .id(prefixRoundID)
            case .naming:
                if let document = pdfManager.pdfDocument {
                    SplitNamingStageView(
                        pdfDocument: document,
                        fileSizes: fileSizes,
                        skippedPages: skippedPages,
                        skippedFileIndices: skippedFileIndices,
                        baseFileName: $baseFileName,
                        customFileNames: $customFileNames,
                        previewOffset: $previewOffset,
                        pagesRebuilt: documentRebuilt,
                        partFolderMode: $partFolderMode,
                        onBack: { splitStage = .split },
                        onClear: {
                            splitStage = .split
                            pdfManager.clearPDF()
                        },
                        onSave: { saveSplitPDF() }
                    )
                }
            case .split:
                splitStageBody
            }
        }
        .onChange(of: pdfManager.pdfDocument) { _, newValue in
            if let doc = newValue {
                // Page-swap replaces the document in-place: preserve all split state.
                // But drop the undo history — a reorder (swap/booklet/A3) can make prior
                // snapshots' page-based skip indices map onto the wrong pages.
                if suppressDocumentReset {
                    suppressDocumentReset = false
                    undoStack = []
                    redoStack = []
                    return
                }

                // New PDF loaded — reset the entire split flow so no state from
                // a previous file can survive into the naming or prefix stages.
                isViewFocused = true
                // Reset navigation: dropping a new file straight onto the done screen
                // skips the clear step, so a stale currentPage could point past the new
                // (shorter) document and blank the Step 1 preview.
                currentPage = 0
                customFileNames.removeAll()
                previewOffset = .zero
                skippedPages = []
                selectedFileIndices = []
                skipMode = .file
                documentRebuilt = false
                undoStack = []
                redoStack = []

                // A scan of double pages (A3 sheets, or a book scanner's spreads) — offer to
                // split them, unless this load is the result of doing exactly that. The
                // split state is set up first so Step 1 is consistent behind the sheet;
                // the bookmark offer waits until the sheet is answered.
                if !suppressNextA3Detection && (isA3Landscape(doc) || looksLikeDoublePageScan(doc)) {
                    setupSplitState(offerBookmarks: false)
                    scanSplitRequest = ScanSplitRequest(document: doc, fromLoad: true)
                    return
                }
                // If the page proportions look A3-like but the checks above didn't fire
                // (e.g. unusual scanner DPI), show a gentle hint banner instead.
                if !suppressNextA3Detection && looksLikeA3Landscape(doc) {
                    withAnimation { a3HintVisible = true }
                }
                suppressNextA3Detection = false
                setupSplitState()
                // A just-split scan: skip the pieces the sheet marked (after the reset
                // above, which clears skips), and make Delete act on single pages.
                if let skips = pendingScanSplitSkips {
                    pendingScanSplitSkips = nil
                    skippedPages = skips.filter { $0 < totalPages }
                    skipMode = .page
                    documentRebuilt = true
                }
            } else {
                // PDF cleared — reset all split flow state so nothing bleeds
                // into the next session regardless of which stage we were on.
                fileSizes = []
                currentPage = 0
                customFileNames.removeAll()
                previewOffset = .zero
                splitStage = .split
                baseFileName = ""
                prefixItems = []
                summaryNames = []
                pendingFolderURL = nil
                skippedPages = []
                selectedFileIndices = []
                skipMode = .file
                documentRebuilt = false
                undoStack = []
                redoStack = []
                sourceWasTrashed = false
                lastBookletOrder = nil
                bookletRedoNoticeVisible = false
                a3HintVisible = false
                documentBookmarks = []
                bookmarkOffer = nil
            }
        }
        .onAppear { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: appState.selectedTab)     { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: splitStage)               { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: fileSizes)                { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: skippedPages)             { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: pdfManager.pdfDocument)   { DispatchQueue.main.async { syncTabCommands() } }
        .sheet(item: $saveProgress) { progress in
            SplitSaveProgressView(progress: progress)
        }
        .sheet(item: $scanSplitRequest) { request in
            ScanSplitSheet(
                request: request,
                onSplit: { choice in
                    scanSplitRequest = nil
                    applyScanSplit(choice, to: request.document)
                },
                onCancel: {
                    scanSplitRequest = nil
                    // Offered on opening: carry on to the bookmark prompt, one sheet at a
                    // time — let this one finish dismissing first.
                    if request.fromLoad {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { offerBookmarksIfAny() }
                    }
                }
            )
        }
        .sheet(item: $bookmarkOffer) { offer in
            BookmarkSplitChoiceView(
                offer: offer,
                onSplitAndName: { style in
                    bookmarkOffer = nil
                    applyBookmarks(offer.sections, nameStyle: style)
                },
                onSplitOnly: {
                    bookmarkOffer = nil
                    applyBookmarks(offer.sections, nameStyle: nil)
                },
                onIgnore: { bookmarkOffer = nil }
            )
        }
        .sheet(item: $bookletFixRequest) { req in
            let n = req.pages.count
            let matchCount = fileSizes.filter { $0 == n }.count
            BookletOrderSheet(
                request: req,
                matchingFileCount: matchCount,
                onApply: { order in
                    bookletFixRequest = nil
                    applyBookletOrder(pages: req.pages, order: order)
                },
                onApplyToAll: matchCount > 1 ? { order in
                    bookletFixRequest = nil
                    applyBookletOrderToAllMatchingFiles(order: order, n: n)
                } : nil,
                onCancel: { bookletFixRequest = nil }
            )
        }
    }

    @ViewBuilder
    private var splitStageBody: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack {
                // Title on one line with the step beneath it — as one string it wrapped to
                // two lines and squeezed the buttons.
                VStack(alignment: .leading, spacing: 1) {
                    Text("Split PDF")
                        .font(.title2)
                        .fontWeight(.semibold)
                    if pdfManager.pdfDocument != nil {
                        Text("Step 1 — set split points")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .fixedSize()

                Spacer()

                if pdfManager.pdfDocument != nil {
                    StampMenuButton(isEnabled: $stampEnabled, scope: $stampScope)

                    // Both of these correct how a scan came in, and both are occasional, so
                    // they share one pull-down instead of two permanent buttons.
                    Menu {
                        Button("Split Double Pages\u{2026}") { requestScanSplit() }
                        Button("Fix Booklet Order") { requestBookletFix() }
                            .disabled(!canFixBookletOrder)
                    } label: {
                        Label("Fix Scan", systemImage: "wrench.and.screwdriver")
                    }
                    .fixedSize()
                    .help("Cut two-page scans into single pages, or correct booklet scanning order")

                    Button(action: { pdfManager.clearPDF() }) {
                        Label("Clear File", systemImage: "xmark.circle.fill")
                    }
                    .help("Remove the current file and start over")
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if a3HintVisible {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.split.2x1")
                        .foregroundColor(.secondary)
                    Text("This looks like it might be a scan of double pages — two pages side by side.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button("Split Double Pages…") {
                        withAnimation { a3HintVisible = false }
                        requestScanSplit()
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { a3HintVisible = false } }
                        label: { Image(systemName: "xmark").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color(NSColor.windowBackgroundColor))
                .overlay(Rectangle().frame(height: 1).foregroundColor(Color.secondary.opacity(0.2)), alignment: .bottom)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if a3SplitNoticeVisible {
                HStack(spacing: 8) {
                    Image(systemName: "scissors")
                        .foregroundColor(.orange)
                    Text(scanSplitNotice)
                        .font(.callout)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { a3SplitNoticeVisible = false } }
                        label: { Image(systemName: "xmark").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if bookletRedoNoticeVisible {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.badge.play")
                        .foregroundColor(.accentColor)
                    Text("Booklet order saved — tap **⬚▶** on any matching file card to apply the same order instantly")
                        .font(.callout)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { bookletRedoNoticeVisible = false } }
                        label: { Image(systemName: "xmark").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Main content area
            if let document = pdfManager.pdfDocument {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        // Left: Page preview and controls
                        VStack(spacing: 16) {
                            // Page navigation and controls
                            SplitControlsSection(
                                currentPage: $currentPage,
                                splitMarkers: splitMarkers,
                                fileSizes: fileSizes,
                                totalPages: totalPages,
                                skippedPages: skippedPages,
                                skipMode: $skipMode,
                                onToggleMarker: { toggleSplitAt(page: currentPage) },
                                onSkipCurrentFile: {
                                    if let fi = pageToFileMapping[currentPage] {
                                        toggleSkipFiles([fi])
                                    }
                                },
                                onSkipCurrentPage: { toggleSkipPage(currentPage) },
                                onSwapWithNext: swapCurrentPageWithNext,
                                onRestride: restrideFromCurrentPage
                            )

                            Divider()

                            // Preview
                            PDFPageView(
                                page: document.page(at: currentPage),
                                rotation: 0,
                                stamp: previewStamp
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.horizontal)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                isViewFocused = true
                            }
                        }
                        .frame(width: geometry.size.width * 0.5)
                        .focusable()
                        .focused($isViewFocused)
                        
                        Divider()
                        
                        // Right: Stride controls + file preview
                        VStack(alignment: .leading, spacing: 12) {
                            // ── Stride / pattern controls ─────────────────────
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Split Pattern")
                                    .font(.headline)

                                HStack(spacing: 8) {
                                    Text("Stride:")
                                        .foregroundColor(.secondary)
                                    Stepper(value: $stride, in: 1...20, label: {
                                        Text("\(stride) \(stride == 1 ? "page" : "pages")")
                                            .frame(minWidth: 55, alignment: .leading)
                                    })
                                    Button("Apply") {
                                        applyStride()
                                    }
                                    .buttonStyle(.bordered)
                                    .help("Re-apply stride from scratch, clearing any manual adjustments")

                                    Spacer()

                                    // Lives here rather than the toolbar: it belongs with
                                    // Apply, which is the other thing that sets every split
                                    // marker at once.
                                    Button(action: clearAllMarkers) {
                                        Label("Clear All", systemImage: "trash")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(splitMarkers.isEmpty)
                                    .help("Remove every split marker and start the pattern again")
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("**Stride** is the number of pages per output file. Press **Apply** to place split markers every N pages automatically.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("Then navigate with ← → and press **Space** to fine-tune. Pressing Space in the *middle* of a file adds a split there. Pressing Space at the *start* of a file (highlighted in orange) removes that split and merges the file with the one above.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("If one part is shorter than the rest (e.g. a 3-page piccolo part in a 4-page-stride set), navigate to where the next part *should* start and press **R** to re-apply the stride from that page to the end, keeping all earlier splits intact.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.controlBackgroundColor))
                            )

                            // ── Output files list ─────────────────────────────
                            let skippedCount = numberOfFiles - activeFileCount
                            Group {
                                if skippedCount > 0 {
                                    Text("Output Files (\(activeFileCount) active · \(skippedCount) skipped)")
                                        .font(.headline)
                                } else {
                                    Text("Output Files (\(numberOfFiles))")
                                        .font(.headline)
                                }
                            }

                            ScrollView {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(0..<numberOfFiles, id: \.self) { fileIndex in
                                        let filePageCount = fileIndex < fileSizes.count ? fileSizes[fileIndex] : 0
                                        let canFix  = filePageCount >= 4 && filePageCount % 4 == 0
                                        let canRedo = lastBookletOrder?.n == filePageCount && canFix
                                        let bookletFixAction: (() -> Void)? = canFix ? {
                                            let pages = pagesForFile(fileIndex)
                                            guard let doc = pdfManager.pdfDocument else { return }
                                            bookletFixRequest = BookletFixRequest(
                                                fileIndex: fileIndex,
                                                pages: pages,
                                                document: doc
                                            )
                                        } : nil
                                        let bookletRedoAction: (() -> Void)? = canRedo ? {
                                            guard let last = lastBookletOrder else { return }
                                            let pages = pagesForFile(fileIndex)
                                            applyBookletOrder(pages: pages, order: last.order)
                                        } : nil
                                        FilePreviewCard(
                                            fileIndex: fileIndex,
                                            pageToFileMapping: pageToFileMapping,
                                            totalPages: totalPages,
                                            baseFileName: baseFileName,
                                            customFileNames: customFileNames,
                                            currentPage: currentPage,
                                            isFullySkipped: isFileFullySkipped(fileIndex),
                                            isPartiallySkipped: isFilePartiallySkipped(fileIndex),
                                            skippedPages: skippedPages,
                                            isSelected: selectedFileIndices.contains(fileIndex),
                                            // Both of these take focus back to the page
                                            // navigator. Clicking a card used to leave focus
                                            // wherever it landed, so ← → stopped paging until
                                            // you clicked the preview — the tap handler there
                                            // has always done this.
                                            onNavigate: { pageIndex in
                                                currentPage = pageIndex
                                                isViewFocused = true
                                            },
                                            onSelect: { isCmd, isShift in
                                                handleFileSelection(fileIndex, isCmd: isCmd, isShift: isShift)
                                                isViewFocused = true
                                            },
                                            onFixBookletOrder: bookletFixAction,
                                            onRedoBookletOrder: bookletRedoAction
                                        )
                                    }
                                }
                            }

                            // Action button
                            HStack {
                                Spacer()
                                Button(action: { splitStage = .naming }) {
                                    Label("Next: Name Files", systemImage: "arrow.right.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(!canContinueToNaming)
                            }
                        }
                        .padding()
                        .frame(width: geometry.size.width * 0.5)
                    }
                    .onKeyPress { press in
                        guard appState.selectedTab == 2 else { return .ignored }   // Split tab only
                        switch press.key {
                        case .leftArrow:
                            if press.modifiers.contains(.command) {
                                currentPage = 0
                            } else if currentPage > 0 {
                                currentPage -= 1
                            }
                            // Keep selection in sync with whichever file the page lands in
                            if let fi = pageToFileMapping[currentPage] { selectedFileIndices = [fi] }
                            return .handled
                        case .rightArrow:
                            if press.modifiers.contains(.command) {
                                currentPage = totalPages - 1
                            } else if currentPage < totalPages - 1 {
                                currentPage += 1
                            }
                            if let fi = pageToFileMapping[currentPage] { selectedFileIndices = [fi] }
                            return .handled
                        case .downArrow:
                            let fileStartsDown = ([0] + splitMarkers.sorted())
                            if let next = fileStartsDown.first(where: { $0 > currentPage }),
                               let fi = pageToFileMapping[next] {
                                currentPage = next
                                if press.modifiers.contains(.shift) {
                                    // Extend the range from the anchor (lowest selected index)
                                    let anchor = selectedFileIndices.min() ?? fi
                                    selectedFileIndices = Set(anchor...max(anchor, fi))
                                } else {
                                    selectedFileIndices = [fi]
                                }
                            }
                            return .handled
                        case .upArrow:
                            let fileStartsUp = ([0] + splitMarkers.sorted())
                            if let prev = fileStartsUp.last(where: { $0 < currentPage }),
                               let fi = pageToFileMapping[prev] {
                                currentPage = prev
                                if press.modifiers.contains(.shift) {
                                    let anchor = selectedFileIndices.max() ?? fi
                                    selectedFileIndices = Set(min(anchor, fi)...anchor)
                                } else {
                                    selectedFileIndices = [fi]
                                }
                            }
                            return .handled
                        case .space:
                            if currentPage > 0 {
                                toggleSplitAt(page: currentPage)
                            }
                            return .handled
                        case .return:
                            // Advance to naming (same gate as the "Next: Name Files" button).
                            if canContinueToNaming {
                                splitStage = .naming
                                return .handled
                            }
                            return .ignored
                        default:
                            // S — swap current page with the next one
                            if press.characters == "s" || press.characters == "S" {
                                swapCurrentPageWithNext()
                                return .handled
                            }
                            // R — re-apply stride from the current page to the end
                            if press.characters == "r" || press.characters == "R" {
                                restrideFromCurrentPage()
                                return .handled
                            }
                            return .ignored
                        }
                    }
                }
            } else {
                // No PDF loaded - show drop zone
                DropZoneView(pdfManager: pdfManager,
                             subtitle: "Divide a large PDF — e.g. a complete bound scan of all parts — into separate instrument files")
            }
        }
        .focused($isViewFocused)
        .onAppear {
            isViewFocused = true
            // SwiftUI's onKeyPress doesn't reliably fire for the delete/backspace key
            // on macOS — the system routes it through a different responder path first.
            // A local NSEvent monitor catches it at the app level before that happens.
            splitViewKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Only act while the Split tab is the one on screen — this app-global
                // monitor would otherwise fire on other tabs (it stays installed because
                // TabView keeps hidden tabs mounted).
                guard appState.selectedTab == 2 else { return event }
                // Don't steal keys from text fields (stride stepper, name fields, etc.)
                let inTextField = NSApp.keyWindow?.firstResponder is NSTextView
                // ⌘Z / ⌘⇧Z — undo/redo Step-1 split edits. Caught here (not via a menu
                // command) so it works without an Edit-menu UndoManager and never bonks.
                if !inTextField, event.keyCode == 6, event.modifierFlags.contains(.command) {
                    DispatchQueue.main.async {
                        if event.modifierFlags.contains(.shift) { self.redoSplit() } else { self.undoSplit() }
                    }
                    return nil
                }
                guard event.keyCode == 51 || event.keyCode == 117 else { return event }
                if inTextField { return event }
                DispatchQueue.main.async { self.handleDeleteKey() }
                return nil  // consume — prevents the system bonk
            }
        }
        .onDisappear {
            if let m = splitViewKeyMonitor { NSEvent.removeMonitor(m) }
            splitViewKeyMonitor = nil
        }
    } // end splitStageBody
    
    // ── Undo / redo (Step 1 split edits) ──────────────────────────────────────
    private func currentSplitSnapshot() -> SplitSnapshot {
        SplitSnapshot(fileSizes: fileSizes, skippedPages: skippedPages, customFileNames: customFileNames)
    }

    /// Record the current state before a mutating action so ⌘Z can revert it.
    private func pushUndo() {
        undoStack.append(currentSplitSnapshot())
        redoStack.removeAll()
        if undoStack.count > 50 { undoStack.removeFirst() }
    }

    private func restoreSplit(_ s: SplitSnapshot) {
        fileSizes = s.fileSizes
        skippedPages = s.skippedPages
        customFileNames = s.customFileNames
        selectedFileIndices = []
    }

    private func undoSplit() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(currentSplitSnapshot())
        restoreSplit(prev)
    }

    private func redoSplit() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSplitSnapshot())
        restoreSplit(next)
    }

    private func openPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.title = "Select PDF"
        panel.begin { response in
            if response == .OK, let url = panel.url { pdfManager.loadPDF(from: url) }
        }
    }

    /// Publishes the Split tab's actions to the menu bridge while Split is active.
    /// The primary action + tab actions are contextual to the current step.
    private func syncTabCommands() {
        guard appState.selectedTab == 2 else { return }
        let loaded = pdfManager.pdfDocument != nil
        var slice = TabSlice()
        slice.openTitle  = "Choose PDF\u{2026}"
        slice.open       = { openPDF() }
        slice.clearTitle = "Clear File"
        slice.clear      = loaded ? { pdfManager.clearPDF() } : nil

        switch splitStage {
        case .split:
            let canProceed = loaded && canContinueToNaming
            slice.primaryTitle = "Continue to Naming"
            slice.primarySave  = canProceed ? { splitStage = .naming } : nil
            // Always list the actions (disabled until a PDF is loaded) so the menu
            // shows what's possible even in the empty state.
            slice.tabActions = [
                MenuAction(title: "Split Double Pages\u{2026}", isEnabled: loaded, perform: { requestScanSplit() }),
                MenuAction(title: "Fix Booklet Order", isEnabled: loaded && canFixBookletOrder, perform: { requestBookletFix() }),
                MenuAction(title: "Use Bookmarks\u{2026}", isEnabled: loaded && !documentBookmarks.isEmpty, perform: { offerBookmarksIfAny() }),
                MenuAction(title: "Clear All Splits", isEnabled: loaded && !splitMarkers.isEmpty, perform: { clearAllMarkers() }),
            ]
        case .naming:
            slice.primaryTitle = "Save Split Files"
            slice.primarySave  = { saveSplitPDF() }
            slice.tabActions   = [MenuAction(title: "Back to Split", perform: { splitStage = .split })]
        case .prefix:
            slice.tabActions = [MenuAction(title: "Back to Naming", perform: { splitStage = .naming })]
        case .summary:
            // Start Over is the "clear" action here — reuse ⌘⌫ (File ▸ Start Over).
            slice.clearTitle = "Start Over"
            slice.clear = { pdfManager.clearPDF() }
        }

        // Show in Finder — reveal the output folder on the summary, else the source file.
        let revealTarget = (splitStage == .summary ? pendingFolderURL : nil) ?? pdfManager.sourceURL
        slice.tabActions.append(MenuAction(title: "Show in Finder", key: KeyEquivalent("f"), modifiers: [.command, .shift],
                                           isEnabled: revealTarget != nil, perform: { revealInFinder(revealTarget) }))
        appState.tabCommands.slice = slice
    }

    private func clearAllMarkers() {
        pushUndo()
        fileSizes = totalPages > 0 ? [totalPages] : []
        customFileNames.removeAll()
        skippedPages = []
        selectedFileIndices = []
    }

    private func applyStride() {
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
    private func restrideFromCurrentPage() {
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

    private func toggleSplitAt(page: Int) {
        pushUndo()
        let newSizes = toggleSplit(in: fileSizes, at: page)
        // Names follow the page their file starts on, not its position in the list.
        customFileNames = remapFileNames(customFileNames, from: fileSizes, to: newSizes)
        fileSizes = newSizes
    }

    /// Toggle skip on all pages of the given file indices.
    /// If every file in the set is already fully skipped, they are un-skipped; otherwise all are skipped.
    private func toggleSkipFiles(_ fileIndices: Set<Int>) {
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

    /// Called by the NSEvent monitor when Delete or Forward-Delete is pressed.
    /// Behaviour depends on `skipMode`:
    ///   • `.page` — toggles skip on the current page only.
    ///   • `.file` — toggles skip on all selected file cards (or the file at the current page).
    private func handleDeleteKey() {
        switch skipMode {
        case .page:
            toggleSkipPage(currentPage)
        case .file:
            let targets = selectedFileIndices.isEmpty
                ? Set([pageToFileMapping[currentPage]].compactMap { $0 })
                : selectedFileIndices
            if !targets.isEmpty { toggleSkipFiles(targets) }
        }
    }

    /// Toggle skip on a single page.
    private func toggleSkipPage(_ page: Int) {
        pushUndo()
        if skippedPages.contains(page) {
            skippedPages.remove(page)
        } else {
            skippedPages.insert(page)
        }
    }

    /// Handle a tap on a file card in the output-files list.
    private func handleFileSelection(_ fileIndex: Int, isCmd: Bool, isShift: Bool) {
        if isShift, let anchor = selectedFileIndices.min() {
            let lo = min(anchor, fileIndex)
            let hi = max(anchor, fileIndex)
            selectedFileIndices = Set(lo...hi)
        } else if isCmd {
            if selectedFileIndices.contains(fileIndex) {
                selectedFileIndices.remove(fileIndex)
            } else {
                selectedFileIndices.insert(fileIndex)
            }
        } else {
            selectedFileIndices = [fileIndex]
            // Also navigate the preview to the first page of this file.
            if let firstPage = pagesForFile(fileIndex).first {
                currentPage = firstPage
            }
        }
        // Clicking a card in the right panel takes focus away from the key-press
        // handler. Restore it so Delete/Space/arrows work without an extra click.
        isViewFocused = true
    }

    /// If the "Move original to Trash after splitting" option is on, moves the loaded
    /// source file to the Trash. Returns true if a file was actually trashed. Called only
    /// after the split files have been written successfully, so the original is never
    /// removed before its replacements exist. Failures are surfaced but non-fatal.
    private func trashSourceFileIfRequested() -> Bool {
        guard deleteSourceAfterSplit, let url = pdfManager.sourceURL else { return false }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return true
        } catch {
            showNSAlert(title: "Couldn't Move Original to Trash",
                        message: "The split files were saved, but the original file could not be moved to the Trash:\n\n\(error.localizedDescription)",
                        isError: true)
            return false
        }
    }

    /// Loads a PDF dropped on the "done" summary screen, restarting the split flow.
    /// The Group-level `onChange(of: pdfManager.pdfDocument)` resets all split state
    /// (and re-runs A3 detection), so no extra cleanup is needed here.
    private func handleSummaryPDFDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url = url else { return }
            DispatchQueue.main.async {
                if url.pathExtension.lowercased() == "pdf" {
                    pdfManager.loadPDF(from: url)
                } else {
                    showNSAlert(title: "Unsupported File Type",
                                message: "This tab only accepts PDF files.",
                                isError: true)
                }
            }
        }
        return true
    }

    /// The stamp job to burn into each output file, or nil when stamping is switched off.
    private var activeStampJob: StampJob? {
        guard stampEnabled, let stamp = stampStore.selectedStamp else { return nil }
        return StampJob(stamp: stamp, scope: stampScope)
    }

    /// The stamp to show on the Step 1 preview — only when the page on screen is one that
    /// will actually be stamped, so the preview doesn't promise a stamp that never arrives.
    /// A page that's being skipped isn't written at all, so it gets nothing either.
    private var previewStamp: Stamp? {
        guard let job = activeStampJob, !skippedPages.contains(currentPage) else { return nil }
        switch job.scope {
        case .everyPage:
            return job.stamp
        case .firstPageOfEachPart:
            // Page 0 starts the first file; every split marker starts another.
            let startsAPart = currentPage == 0 || splitMarkers.contains(currentPage)
            return startsAPart ? job.stamp : nil
        }
    }

    func saveSplitPDF() {
        guard let document = pdfManager.pdfDocument,
              canContinueToNaming, saveProgress == nil else { return }

        if prefixEnabled {
            // Go straight to Step 3 — folder picker comes after the user confirms order.
            // Only include files that have at least one non-skipped page.
            var items: [PrefixItem] = []
            var pagePos = 0
            for fileIndex in 0..<fileSizes.count {
                let fileSize = fileSizes[fileIndex]
                if !isFileFullySkipped(fileIndex) {
                    let proposed = splitOutputFileName(base: baseFileName, separator: filenameSeparator,
                                                       suffix: customFileNames[fileIndex] ?? "", fileIndex: fileIndex,
                                                       onlyFile: activeFileCount == 1)
                    let firstPage = document.page(at: firstKeptPage(fileStart: pagePos, fileSize: fileSize,
                                                                    skippedPages: skippedPages))
                    items.append(PrefixItem(id: fileIndex, proposedName: proposed, page: firstPage))
                }
                pagePos += fileSize
            }
            prefixItems = items
            prefixRoundID += 1
            splitStage = .prefix
        } else {
            // No prefix step — show folder picker now and save directly.
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.title = "Select Output Folder"
            panel.message = "Choose where to save the split PDF files"
            panel.directoryURL = outputDirectory(forSourceFile: pdfManager.sourceURL)

            panel.begin { response in
                guard response == .OK, let folderURL = panel.url else { return }
                let folders = splitPartFolders()
                var names: [String] = []
                for i in 0..<fileSizes.count {
                    guard !isFileFullySkipped(i) else { continue }
                    names.append(partFolderPath(splitOutputFileName(base: baseFileName, separator: filenameSeparator,
                                                                    suffix: customFileNames[i] ?? "", fileIndex: i,
                                                                    onlyFile: activeFileCount == 1),
                                                folder: folders[i]))
                }
                let plans = pdfManager.splitPlans(baseFileName: baseFileName,
                                                  customFileNames: customFileNames,
                                                  pageToFileMapping: pageToFileMapping,
                                                  skippedPages: skippedPages,
                                                  separator: filenameSeparator,
                                                  partFolders: folders)
                saveSplitFiles(names: names, plans: plans, into: folderURL, finish: { trashed in
                    sourceWasTrashed = trashed
                    pendingFolderURL = folderURL
                    summaryNames = names
                    splitStage = .summary
                })
            }
        }
    }

    /// Called by PrefixOrderStepView when the user confirms the prefix ordering.
    /// Shows the folder picker, then writes all split files in one pass.
    private func applyPrefixAndSaveSplit(orderedItems: [PrefixItem]) {
        guard saveProgress == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Select Output Folder"
        panel.message = "Choose where to save the split PDF files"
        panel.directoryURL = outputDirectory(forSourceFile: pdfManager.sourceURL)

        panel.begin { response in
            guard response == .OK, let folderURL = panel.url else { return }
            applyPrefixToFolder(folderURL, orderedItems: orderedItems)
        }
    }

    /// Initialises the split state for a newly loaded (non-A3) document: one file, named
    /// after the PDF. If the document has bookmarks, asks what to do with them rather
    /// than applying them unannounced.
    private func setupSplitState(offerBookmarks: Bool = true) {
        fileSizes = totalPages > 0 ? [totalPages] : []
        baseFileName = pdfManager.currentFileName ?? ""
        documentBookmarks = pdfManager.pdfDocument.flatMap { bookmarkSections(in: $0) } ?? []
        if splitStage != .split { splitStage = .split }
        if offerBookmarks { offerBookmarksIfAny() }
    }

    /// Opens "Split Double Pages" for the current document.
    private func requestScanSplit() {
        guard let doc = pdfManager.pdfDocument else { return }
        scanSplitRequest = ScanSplitRequest(document: doc, fromLoad: false)
    }

    /// Replaces the document with its split pages. The new document goes through the
    /// normal new-PDF reset in `onChange` (page count and every index change), which then
    /// applies `pendingScanSplitSkips`.
    private func applyScanSplit(_ choice: ScanSplitChoice, to source: PDFDocument) {
        let split = splitScans(source, layouts: choice.layouts, leftFirst: choice.leftFirst)
        guard split.pageCount > 0 else { return }
        // Nothing was cut and nothing skipped: leave the document (and any split points) alone.
        if split.pageCount == source.pageCount && choice.skippedPages.isEmpty { return }

        pendingScanSplitSkips = choice.skippedPages
        suppressNextA3Detection = true
        pdfManager.pdfDocument = split

        let skipped = choice.skippedPages.count
        var notice = try! AttributedString(markdown: "Split into \(split.pageCount) pages")
        if skipped > 0 {
            notice += try! AttributedString(markdown: " — \(skipped) black or empty \(skipped == 1 ? "page is" : "pages are") skipped (press **Delete** on one to keep it)")
        }
        notice += try! AttributedString(markdown: ". Use **Swap with Next** (S) to fix page order if needed.")
        scanSplitNotice = notice
        withAnimation(.easeInOut(duration: 0.2)) { a3SplitNoticeVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            withAnimation(.easeInOut(duration: 0.2)) { a3SplitNoticeVisible = false }
        }
    }

    /// Presents the bookmark sheet when the loaded document has usable bookmarks.
    private func offerBookmarksIfAny() {
        guard pdfManager.pdfDocument != nil, !documentBookmarks.isEmpty else { return }
        bookmarkOffer = BookmarkOffer(sections: documentBookmarks,
                                      sourceName: pdfManager.currentFileName ?? "")
    }

    /// Splits at the bookmarks; with a `nameStyle`, also names the files from their titles.
    /// Replaces the split state like a fresh load would, so it starts a new undo history.
    private func applyBookmarks(_ sections: [BookmarkSection], nameStyle: BookmarkNameStyle?) {
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
        undoStack = []
        redoStack = []
    }

    /// True when the current file segment has ≥ 4 pages and a count divisible by 4,
    /// meaning a booklet reorder is meaningful.
    var canFixBookletOrder: Bool {
        guard let fi = pageToFileMapping[currentPage] else { return false }
        guard fi < fileSizes.count else { return false }
        let n = fileSizes[fi]
        return n >= 4 && n % 4 == 0
    }

    /// Builds a `BookletFixRequest` for the current file segment and presents the sheet.
    private func requestBookletFix() {
        guard let doc = pdfManager.pdfDocument,
              let fi = pageToFileMapping[currentPage] else { return }
        let pages = pagesForFile(fi)
        bookletFixRequest = BookletFixRequest(fileIndex: fi, pages: pages, document: doc)
    }

    /// `true` when the last booklet order can be re-applied to the current file —
    /// i.e. a previous order was saved AND the current file has the same page count.
    var canRedoBookletOrder: Bool {
        guard let last = lastBookletOrder,
              let fi = pageToFileMapping[currentPage],
              fi < fileSizes.count else { return false }
        return fileSizes[fi] == last.n
    }

    /// Re-applies the last booklet order to the current file segment.
    private func redoBookletOrder() {
        guard let last = lastBookletOrder,
              let fi = pageToFileMapping[currentPage] else { return }
        let pages = pagesForFile(fi)
        guard pages.count == last.n else { return }
        applyBookletOrder(pages: pages, order: last.order)
    }

    /// Reorders the pages of a file segment in the loaded document without resetting
    /// split markers or skipped-page state.
    ///
    /// - Parameters:
    ///   - pages: Absolute page indices (in the full document) for the segment.
    ///   - order: Permutation where `order[readingPos]` is the *local* index within
    ///            `pages` that should appear at that reading position.
    private func applyBookletOrder(pages: [Int], order: [Int]) {
        guard let doc = pdfManager.pdfDocument else { return }
        let newDoc = PDFDocument()

        // Build the new absolute-page sequence, swapping only the segment's positions.
        for absIdx in 0..<doc.pageCount {
            let srcAbsIdx: Int
            if let localIdx = pages.firstIndex(of: absIdx) {
                // This slot belongs to the segment — use the permuted source.
                srcAbsIdx = pages[order[localIdx]]
            } else {
                srcAbsIdx = absIdx
            }
            if let page = doc.page(at: srcAbsIdx) {
                newDoc.insert(page, at: newDoc.pageCount)
            }
        }

        // Update skippedPages: re-map skipped pages within the segment to their new positions.
        var newSkipped = skippedPages
        for absIdx in pages { newSkipped.remove(absIdx) }
        for (newLocal, oldLocal) in order.enumerated() {
            if skippedPages.contains(pages[oldLocal]) {
                newSkipped.insert(pages[newLocal])
            }
        }
        skippedPages = newSkipped

        // On the very first fix, show a brief tip pointing to the per-card redo icon.
        if lastBookletOrder == nil {
            withAnimation(.easeInOut(duration: 0.2)) { bookletRedoNoticeVisible = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
                withAnimation(.easeInOut(duration: 0.2)) { bookletRedoNoticeVisible = false }
            }
        }

        // Save the order so the user can repeat it with Redo.
        lastBookletOrder = (n: pages.count, order: order)

        // Replace the document while preserving all other split state.
        suppressNextA3Detection = true
        documentRebuilt         = true
        suppressDocumentReset   = true
        pdfManager.pdfDocument  = newDoc
    }

    /// Applies a booklet order to **every** file segment in the document whose page
    /// count equals `n`, in a single document rebuild pass.  This avoids the
    /// multiple-replacement problem (each `onChange` would clear `suppressDocumentReset`
    /// before the next call could use it).
    private func applyBookletOrderToAllMatchingFiles(order: [Int], n: Int) {
        guard let doc = pdfManager.pdfDocument else { return }
        let newDoc = PDFDocument()
        var newSkipped = skippedPages
        var processedFiles = Set<Int>()

        for absIdx in 0..<doc.pageCount {
            guard let fi = pageToFileMapping[absIdx] else {
                // Shouldn't normally happen, but copy the page as-is.
                if let page = doc.page(at: absIdx) { newDoc.insert(page, at: newDoc.pageCount) }
                continue
            }

            let filePages = pagesForFile(fi)

            if filePages.count == n && !processedFiles.contains(fi) {
                // First encounter of a matching file — insert all pages in reading order.
                processedFiles.insert(fi)
                for oldLocal in order {
                    if let page = doc.page(at: filePages[oldLocal]) {
                        newDoc.insert(page, at: newDoc.pageCount)
                    }
                }
                // Remap skipped pages within this file.
                for absPage in filePages { newSkipped.remove(absPage) }
                for (newLocal, oldLocal) in order.enumerated() {
                    if skippedPages.contains(filePages[oldLocal]) {
                        newSkipped.insert(filePages[newLocal])
                    }
                }
            } else if filePages.count == n {
                // Already inserted by the block above — skip.
                continue
            } else {
                // Non-matching file — copy page as-is.
                if let page = doc.page(at: absIdx) { newDoc.insert(page, at: newDoc.pageCount) }
            }
        }

        skippedPages = newSkipped
        lastBookletOrder = (n: n, order: order)
        suppressNextA3Detection = true
        documentRebuilt         = true
        suppressDocumentReset   = true
        pdfManager.pdfDocument  = newDoc
    }

    /// Swaps the current page with the next one in the loaded document, preserving
    /// all split markers, skipped pages, and custom file names.
    /// Uses `suppressDocumentReset` so `onChange` skips the normal full-reset path.
    private func swapCurrentPageWithNext() {
        guard let document = pdfManager.pdfDocument,
              currentPage < document.pageCount - 1 else { return }

        let newDoc = PDFDocument()
        for i in 0..<document.pageCount {
            let srcIdx: Int
            if i == currentPage         { srcIdx = currentPage + 1 }
            else if i == currentPage + 1 { srcIdx = currentPage }
            else                          { srcIdx = i }
            if let page = document.page(at: srcIdx) {
                newDoc.insert(page, at: newDoc.pageCount)
            }
        }
        suppressNextA3Detection = true
        documentRebuilt         = true
        suppressDocumentReset   = true
        pdfManager.pdfDocument  = newDoc
        // currentPage stays the same so the preview immediately shows
        // what was just moved down one slot.
    }

    /// The folder "Sort into folders" puts file `i` in (none when it's off), from its Step 2
    /// part name — or, for a single file kept under its own name, the whole name.
    private func defaultPartFolder(forFile i: Int, mode: PartFolderMode, ensemble: EnsembleType) -> String? {
        let suffix = customFileNames[i] ?? ""
        let fileName = splitOutputFileName(base: baseFileName, separator: filenameSeparator, suffix: suffix,
                                           fileIndex: i, onlyFile: activeFileCount == 1)
        return partFolderName(partName: suffix, fileName: fileName, mode: mode, ensemble: ensemble,
                              numbered: numberedFolders)
    }

    /// Each file's folder when saving straight from Step 2 (no prefix step).
    private func splitPartFolders() -> [Int: String] {
        var folders: [Int: String] = [:]
        for i in 0..<fileSizes.count {
            folders[i] = defaultPartFolder(forFile: i, mode: partFolderMode, ensemble: prefixEnsembleType)
        }
        return folders
    }

    private func applyPrefixToFolder(_ folderURL: URL, orderedItems: [PrefixItem]) {
        let sep = UserDefaults.standard.string(forKey: "prefixSeparator") ?? " - "

        // Same numbering and names the user saw in Step 3 (shared with the command line).
        // saveSplitPDF composes "\(base)\(separator)\(suffix).pdf", so with an empty base and
        // separator the suffix is the whole name, minus ".pdf".
        let fullNames = scoreOrderFileNames(forOrderedItems: orderedItems, separator: sep)
        var finalCustomNames: [Int: String] = [:]
        var finalNamesForSummary: [String] = []
        var omittedPages = skippedPages   // Step-1 skips, plus any Step-3 skips below
        // The folders as Step 3 showed them, including any the user chose there.
        var folders: [Int: String] = [:]
        for item in orderedItems { folders[item.id] = item.folder }

        for item in orderedItems {
            guard let fullName = fullNames[item.id] else {
                // Skipped in Step 3 → drop this segment's pages so the file isn't written.
                omittedPages.formUnion(pagesForFile(item.id))
                continue
            }
            finalCustomNames[item.id] = fullName.hasSuffix(".pdf") ? String(fullName.dropLast(4)) : fullName
            finalNamesForSummary.append(partFolderPath(fullName, folder: folders[item.id]))
        }

        let plans = pdfManager.splitPlans(baseFileName: "",
                                          customFileNames: finalCustomNames,
                                          pageToFileMapping: pageToFileMapping,
                                          skippedPages: omittedPages,
                                          separator: "",
                                          partFolders: folders)
        saveSplitFiles(names: finalNamesForSummary, plans: plans, into: folderURL, finish: { trashed in
            sourceWasTrashed = trashed
            pendingFolderURL = folderURL   // stored here so summary can offer "Show in Finder"
            summaryNames = finalNamesForSummary
            splitStage = .summary
        })
    }

    /// Saves the split files (`plans`, named `names`) and then moves the original to the Trash
    /// if asked. The writing happens in the background behind a progress sheet
    /// (`writeInBackground`), so a large scan no longer freezes the app.
    ///
    /// When one of `names` lands exactly on the original — same folder, same name, as when a
    /// single part's pages were only cut from A3 — the files are written to a temporary folder
    /// first, so the original has been read in full before anything touches it. Then the
    /// original goes to the Trash (“Move original to Trash”) or, after asking, is replaced, and
    /// the new files move into place. Cancelling there saves nothing and leaves the original
    /// alone. `finish` gets whether the original went to the Trash.
    private func saveSplitFiles(names: [String], plans: [SplitFilePlan], into folder: URL,
                                finish: @escaping (Bool) -> Void) {
        guard saveProgress == nil else { return }
        guard let source = pdfManager.sourceURL,
              splitOutputReplacesSource(names: names, folder: folder, source: source) else {
            Task {
                guard let report = await writeInBackground(plans, to: folder) else { return }
                if report.wasCancelled {
                    showNSAlert(title: "Saving Stopped", message: stoppedMessage(report, folder: folder), isError: false)
                    return
                }
                let outcome = PDFManager.splitSaveMessage(report, folder: folder)
                if outcome.isError {
                    showNSAlert(title: outcome.title, message: outcome.message, isError: true)
                    return
                }
                finish(trashSourceFileIfRequested())
            }
            return
        }

        if !deleteSourceAfterSplit {
            guard confirmNSAlert(
                title: "Replace the Original?",
                message: "“\(source.lastPathComponent)” is being saved in the folder it came from, with the same name, so the new version will replace the original.\n\nTo keep the original instead, tick “Move original to Trash” (it stays recoverable there), or give the file a suffix.",
                confirmTitle: "Replace") else { return }
        }

        let fm = FileManager.default
        guard let temp = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                     appropriateFor: folder, create: true) else {
            showNSAlert(title: "Couldn't Save", message: "ScoreSort couldn't make a temporary folder to save into beside \(folder.path).", isError: true)
            return
        }

        Task {
            defer { try? fm.removeItem(at: temp) }
            guard let report = await writeInBackground(plans, to: temp) else { return }
            if report.wasCancelled {
                showNSAlert(title: "Saving Stopped",
                            message: "Nothing was saved, and “\(source.lastPathComponent)” is as it was.",
                            isError: false)
                return
            }
            let outcome = PDFManager.splitSaveMessage(report, folder: folder)
            if outcome.isError {
                showNSAlert(title: outcome.title, message: outcome.message, isError: true)
                return
            }

            var trashed = false
            do {
                if deleteSourceAfterSplit {
                    try fm.trashItem(at: source, resultingItemURL: nil)
                    trashed = true
                }
                for name in names {
                    let from = temp.appendingPathComponent(name)
                    guard fm.fileExists(atPath: from.path) else { continue }
                    let to = folder.appendingPathComponent(name)
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: to.path) {
                        _ = try fm.replaceItemAt(to, withItemAt: from)
                    } else {
                        try fm.moveItem(at: from, to: to)
                    }
                }
            } catch {
                showNSAlert(title: "Couldn't Finish Saving",
                            message: "The split files were made, but couldn't be put in \(folder.path): \(error.localizedDescription)" + (trashed ? "\n\nThe original is in the Trash." : ""),
                            isError: true)
                return
            }
            finish(trashed)
        }
    }

    /// Writes `plans` into `folder` on a background thread, behind the progress sheet, from a
    /// copy of the document (`SplitSaveSource`). Nil if the save couldn't start (the user has
    /// been told why).
    private func writeInBackground(_ plans: [SplitFilePlan], to folder: URL) async -> SplitWriteReport? {
        guard let document = pdfManager.pdfDocument else { return nil }
        let progress = SplitSaveProgress(total: plans.count)
        saveProgress = progress
        // Let the sheet appear before the one step that has to run here: a snapshot of a
        // document rebuilt in memory (an untouched one is reopened from its file instead).
        try? await Task.sleep(for: .milliseconds(80))
        guard let source = SplitSaveSource.of(document, loadedFrom: pdfManager.sourceURL) else {
            saveProgress = nil
            showNSAlert(title: "Couldn't Save",
                        message: "ScoreSort couldn't put the pages together to save them. Try opening the PDF again.",
                        isError: true)
            return nil
        }
        let report = await progress.run(plans, from: source, expectingPageCount: document.pageCount,
                                        to: folder, stampJob: activeStampJob)
        saveProgress = nil
        return report
    }

    /// What a cancelled save did: how many files were written, where, and which weren't.
    private func stoppedMessage(_ report: SplitWriteReport, folder: URL) -> String {
        let total = report.written.count + report.failures.count + report.notWritten.count
        var message = "Saved \(report.written.count) of \(total) files in \(folder.path)."
        let shown = report.notWritten.prefix(8)
        message += "\n\nNot saved:\n" + shown.joined(separator: "\n")
        if report.notWritten.count > shown.count { message += "\n…and \(report.notWritten.count - shown.count) more" }
        if !report.failures.isEmpty {
            message += "\n\nFailed:\n" + report.failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n")
        }
        message += "\n\nSave again to finish: files already saved are replaced."
        return message
    }
}

// MARK: - Booklet Order Sheet

/// Sheet shown by "Fix Booklet Order".  Displays candidate reorderings as thumbnail
/// strips with radio buttons, plus a drag-to-reorder custom option as a fallback.
struct BookletOrderSheet: View {
    let request: BookletFixRequest
    /// Total number of files in the document with the same page count (including this one).
    let matchingFileCount: Int
    let onApply: ([Int]) -> Void
    /// Non-nil when there is more than one matching file; applies the order to all of them.
    let onApplyToAll: (([Int]) -> Void)?
    let onCancel: () -> Void

    // -1 means "custom order" is selected; 0…n-1 indexes into `candidates`.
    @State private var selectedOption: Int = 0
    @State private var customOrder: [Int] = []   // local indices within request.pages

    private let candidates: [(label: String, description: String, order: [Int])]

    init(request: BookletFixRequest,
         matchingFileCount: Int,
         onApply: @escaping ([Int]) -> Void,
         onApplyToAll: (([Int]) -> Void)? = nil,
         onCancel: @escaping () -> Void) {
        self.request           = request
        self.matchingFileCount = matchingFileCount
        self.onApply           = onApply
        self.onApplyToAll      = onApplyToAll
        self.onCancel          = onCancel
        self.candidates = bookletCandidates(n: request.pages.count)
        // Custom order starts as the identity permutation.
        _customOrder = State(initialValue: Array(0..<request.pages.count))
    }

    private var n: Int { request.pages.count }

    /// Returns the page at a given local index in the current option's order.
    private func pageForLocalIdx(_ localIdx: Int, option: Int) -> PDFPage? {
        let order: [Int]
        if option == -1 {
            order = customOrder
        } else {
            guard option < candidates.count else { return nil }
            order = candidates[option].order
        }
        guard localIdx < order.count else { return nil }
        let absIdx = request.pages[order[localIdx]]
        return request.document.page(at: absIdx)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────────
            VStack(spacing: 4) {
                Text("Fix Booklet Order")
                    .font(.title2).fontWeight(.semibold)
                Text("File \(request.fileIndex + 1) · \(n) pages")
                    .font(.subheadline).foregroundColor(.secondary)
                Text("Choose a reordering that matches how the booklet was scanned, then press Apply.")
                    .font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .padding(.top, 2)
            }
            .padding(.top, 28)
            .padding(.bottom, 16)
            .padding(.horizontal, 28)

            Divider()

            // ── Options list ─────────────────────────────────────────────
            // ScrollViewReader lets us programmatically scroll to the custom-order
            // row when the user selects it, avoiding the confusing nested-scroll situation
            // where the inner List absorbs scroll events and hides part of the outer sheet.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        // Automatic candidate options
                        ForEach(candidates.indices, id: \.self) { optIdx in
                            BookletOptionRow(
                                label: candidates[optIdx].label,
                                description: candidates[optIdx].description,
                                isSelected: selectedOption == optIdx,
                                onSelect: { selectedOption = optIdx }
                            ) {
                                // Thumbnail strip for this candidate
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(0..<n, id: \.self) { localIdx in
                                            BookletThumbnailCell(
                                                page: pageForLocalIdx(localIdx, option: optIdx),
                                                label: "\(localIdx + 1)"
                                            )
                                        }
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 4)
                                }
                            }
                        }

                        // Custom drag-to-reorder option
                        BookletOptionRow(
                            label: "Custom order",
                            description: "Drag rows to set the reading order yourself.",
                            isSelected: selectedOption == -1,
                            onSelect: { selectedOption = -1 }
                        ) {
                            if selectedOption == -1 {
                                // Non-scrolling List: scrollDisabled lets the outer ScrollView
                                // handle all scrolling so the inner list never steals events.
                                // Height is exact — no inner scroll bar, no nested scroll confusion.
                                List {
                                    ForEach(customOrder.indices, id: \.self) { pos in
                                        let localIdx = customOrder[pos]
                                        HStack(spacing: 16) {
                                            Text("\(pos + 1).")
                                                .frame(width: 28, alignment: .trailing)
                                                .foregroundColor(.secondary)
                                                .font(.headline)
                                            BookletThumbnailCell(
                                                page: request.document.page(at: request.pages[localIdx]),
                                                label: "Scan \(localIdx + 1)",
                                                thumbWidth: 180, thumbHeight: 254
                                            )
                                            Text("Page in scan position \(localIdx + 1)")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                            Spacer()
                                        }
                                        .padding(.vertical, 8)
                                    }
                                    .onMove { from, to in
                                        customOrder.move(fromOffsets: from, toOffset: to)
                                    }
                                }
                                .listStyle(.plain)
                                .scrollDisabled(true)
                                // Each row: 254pt thumb + 20pt label + 16pt vertical padding = ~290pt
                                .frame(height: CGFloat(n) * 290)
                            } else {
                                // Collapsed preview strip when not selected
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(customOrder.indices, id: \.self) { pos in
                                            BookletThumbnailCell(
                                                page: request.document.page(at: request.pages[customOrder[pos]]),
                                                label: "\(pos + 1)"
                                            )
                                        }
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                        .id("customRow")
                    }
                    .padding(24)
                }
                .onChange(of: selectedOption) { _, newVal in
                    if newVal == -1 {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo("customRow", anchor: .top)
                        }
                    }
                }
            }

            Divider()

            // ── Footer buttons ───────────────────────────────────────────
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let applyAll = onApplyToAll {
                    Button("Apply to All (\(matchingFileCount) files)") {
                        let order = selectedOption == -1 ? customOrder : candidates[selectedOption].order
                        applyAll(order)
                    }
                    .disabled(selectedOption >= candidates.count && selectedOption != -1)
                    .help("Apply this reordering to all \(matchingFileCount) files with \(request.pages.count) pages")
                }
                Button("Apply") {
                    let order = selectedOption == -1 ? customOrder : candidates[selectedOption].order
                    onApply(order)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedOption >= candidates.count && selectedOption != -1)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 580, minHeight: 500)
    }
}

/// A single radio-button row inside `BookletOrderSheet`.
private struct BookletOptionRow<Content: View>: View {
    let label: String
    let description: String
    let isSelected: Bool
    let onSelect: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                        .font(.system(size: 16))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).fontWeight(.medium)
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            content()
                .padding(.leading, 26)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.07)
                      : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15),
                        lineWidth: isSelected ? 1.5 : 1)
        )
    }
}

/// A single thumbnail cell used in the booklet-order sheet.
/// Default size ~90×127 pt for horizontal strips; pass larger values for the
/// drag-to-reorder list where each row shows one page at full readability.
private struct BookletThumbnailCell: View {
    let page: PDFPage?
    let label: String
    var thumbWidth: CGFloat  = 90
    var thumbHeight: CGFloat = 127

    var body: some View {
        VStack(spacing: 4) {
            PDFPageView(page: page, rotation: 0)
                .frame(width: thumbWidth, height: thumbHeight)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Split Controls Section
struct SplitControlsSection: View {
    @Binding var currentPage: Int
    let splitMarkers: Set<Int>
    let fileSizes: [Int]
    let totalPages: Int
    let skippedPages: Set<Int>
    @Binding var skipMode: SkipMode
    let onToggleMarker: () -> Void
    let onSkipCurrentFile: () -> Void
    let onSkipCurrentPage: () -> Void
    let onSwapWithNext: () -> Void
    let onRestride: () -> Void

    /// Returns which file index the current page belongs to, and the size of that file.
    private var currentFileInfo: (fileIndex: Int, fileStart: Int, fileSize: Int)? {
        var pos = 0
        for (i, size) in fileSizes.enumerated() {
            if currentPage >= pos && currentPage < pos + size {
                return (i, pos, size)
            }
            pos += size
        }
        return nil
    }

    /// True if the current page is in skippedPages.
    private var currentPageIsSkipped: Bool { skippedPages.contains(currentPage) }

    /// True if every page in the current file is skipped.
    private var currentFileIsFullySkipped: Bool {
        guard let info = currentFileInfo else { return false }
        let pages = info.fileStart..<(info.fileStart + info.fileSize)
        return pages.allSatisfy { skippedPages.contains($0) }
    }

    /// Label for the skip/unskip button, derived from skip mode and current state.
    private var skipButtonLabel: String {
        switch skipMode {
        case .page:
            return currentPageIsSkipped ? "Un-skip Page" : "Skip Page"
        case .file:
            return currentFileIsFullySkipped ? "Un-skip File" : "Skip File"
        }
    }

    private var skipButtonIcon: String {
        switch skipMode {
        case .page:
            return currentPageIsSkipped ? "arrow.uturn.backward" : "trash"
        case .file:
            return currentFileIsFullySkipped ? "arrow.uturn.backward" : "trash"
        }
    }

    private var skipButtonIsActive: Bool {
        skipMode == .page ? currentPageIsSkipped : currentFileIsFullySkipped
    }

    var body: some View {
        VStack(spacing: 10) {
            // ── Row 1: Navigation ──────────────────────────────────────────
            HStack {
                Button(action: firstPage) {
                    Image(systemName: "chevron.backward.to.line")
                }
                .disabled(currentPage == 0)

                Button(action: previousPage) {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPage == 0)

                Spacer()

                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Page \(currentPage + 1) of \(totalPages)")
                            .font(.headline)
                        if currentPageIsSkipped {
                            Text("SKIPPED")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.15))
                                .foregroundColor(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    // Show which output file this page belongs to
                    if let info = currentFileInfo {
                        let isAtStart = currentPage == info.fileStart
                        let endPage = info.fileStart + info.fileSize - 1
                        let rangeText = info.fileStart == endPage
                            ? "p.\(info.fileStart + 1)"
                            : "pp.\(info.fileStart + 1)–\(endPage + 1)"
                        let skipSuffix = currentFileIsFullySkipped ? " — skipped" : ""
                        Text("File \(info.fileIndex + 1) (\(rangeText), \(info.fileSize) \(info.fileSize == 1 ? "page" : "pages"))\(isAtStart && currentPage > 0 ? " — split marker" : "")\(skipSuffix)")
                            .font(.caption)
                            .foregroundColor(currentFileIsFullySkipped ? .red
                                            : (isAtStart && currentPage > 0) ? .orange
                                            : .secondary)
                    }
                }

                Spacer()

                Button(action: nextPage) {
                    Image(systemName: "chevron.right")
                }
                .disabled(currentPage >= totalPages - 1)

                Button(action: lastPage) {
                    Image(systemName: "chevron.forward.to.line")
                }
                .disabled(currentPage >= totalPages - 1)
            }
            .padding(.horizontal)

            Divider()
                .padding(.horizontal)

            // ── Row 2: Split marker (left) + Re-stride (right) ────────────
            HStack(spacing: 8) {
                Button(action: onToggleMarker) {
                    if splitMarkers.contains(currentPage) {
                        Label("Remove Split (Space)", systemImage: "xmark.circle")
                    } else {
                        Label("Add Split Here (Space)", systemImage: "scissors")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(currentPage == 0)
                .lineLimit(1)

                Spacer()

                Button(action: onRestride) {
                    Label("Re-stride from Here (R)", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(currentPage == 0 || currentPage >= totalPages - 1)
                .help("Re-apply the current stride from this page to the end, keeping all earlier splits intact")
                .lineLimit(1)
            }
            .padding(.horizontal)

            // ── Row 3: Swap (left) · skip toggle + Skip button grouped right ──
            // The toggle is a modifier for the skip button, so they travel together
            // as one right-aligned unit — no orphaned widget in the middle.
            HStack(spacing: 12) {
                Button(action: onSwapWithNext) {
                    Label("Swap with Next (S)", systemImage: "arrow.up.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(currentPage >= totalPages - 1)
                .help("Swap the current page with the one after it")
                .lineLimit(1)

                Spacer()

                // Skip group: mode toggle immediately left of the action button
                HStack(spacing: 10) {
                    VStack(spacing: 2) {
                        Text("Skip")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        HStack(spacing: 4) {
                            Text("Page")
                                .font(.caption)
                                .foregroundColor(skipMode == .page ? .primary : .secondary)
                            Toggle("", isOn: Binding(
                                get: { skipMode == .file },
                                set: { skipMode = $0 ? .file : .page }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.mini)
                            .help("Controls whether Delete / the Skip button targets just this page or the whole output file")
                            Text("File")
                                .font(.caption)
                                .foregroundColor(skipMode == .file ? .primary : .secondary)
                        }
                    }
                    .fixedSize()

                    Button(action: {
                        switch skipMode {
                        case .page: onSkipCurrentPage()
                        case .file: onSkipCurrentFile()
                        }
                    }) {
                        Label(skipButtonLabel, systemImage: skipButtonIcon)
                            .foregroundColor(skipButtonIsActive ? .orange : .red)
                    }
                    .buttonStyle(.bordered)
                    .lineLimit(1)
                    .help(skipMode == .page
                          ? (currentPageIsSkipped ? "Un-skip this page (Delete)" : "Skip this page (Delete)")
                          : (currentFileIsFullySkipped ? "Un-skip this output file (Delete)" : "Skip this output file (Delete)"))
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
    }

    private func firstPage() { currentPage = 0 }
    private func lastPage()  { currentPage = totalPages - 1 }

    private func previousPage() {
        if currentPage > 0 { currentPage -= 1 }
    }

    private func nextPage() {
        if currentPage < totalPages - 1 { currentPage += 1 }
    }
}
