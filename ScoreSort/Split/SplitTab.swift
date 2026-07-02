//
//  SplitTab.swift
//  ScoreSort
//
//  The entire Split PDF tab: SplitView and its three steps (split → naming →
//  prefix), plus booklet-reorder and A3 UI. Extracted wholesale from the app's
//  main file; pure split maths live in Logic/SplitLogic.swift. (Prefix-order step,
//  rename summary and page-preview views are shared with Bulk Rename.)
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
    @State private var bookmarkNoticeVisible = false
    /// Controls the sheet that asks "which half is page 1?" when an A3 doc is detected.
    @State private var showingA3Detection = false
    /// Set before programmatically loading an A3-split document so onChange skips re-detection.
    @State private var suppressNextA3Detection = false
    /// Set before swapping pages so onChange skips the full state-reset (preserving split markers).
    @State private var suppressDocumentReset = false
    /// True while background A3 splitting is in progress; shows a loading overlay.
    @State private var isProcessingA3 = false
    /// Shows a gentle hint banner when a PDF looks like an A3 scan but didn't trigger auto-detection.
    @State private var a3HintVisible = false
    /// Shows a brief tip banner after an A3 split loads into Step 1.
    @State private var a3SplitNoticeVisible = false
    /// Shows a brief tip banner after the first booklet fix, pointing to the per-card redo icon.
    @State private var bookletRedoNoticeVisible = false
    /// Whether Delete / the Skip button targets the current page or the whole file.
    /// Defaults to `.file`; set to `.page` automatically after an A3 split.
    @State private var skipMode: SkipMode = .file
    /// Non-nil when the "Fix Booklet Order" sheet should be presented.
    @State private var bookletFixRequest: BookletFixRequest? = nil
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
                    stepLabel: "Step 3",
                    initialItems: prefixItems,
                    ensembleType: $prefixEnsembleType,
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
                undoStack = []
                redoStack = []

                // Detect A3 landscape — pause and ask the user which half is page 1,
                // unless this load was triggered by our own A3 processing pipeline.
                if !suppressNextA3Detection && isA3Landscape(doc) {
                    showingA3Detection = true
                    return
                }
                // If the page proportions look A3-like but the strict check didn't fire
                // (e.g. unusual scanner DPI), show a gentle hint banner instead.
                if !suppressNextA3Detection && looksLikeA3Landscape(doc) {
                    withAnimation { a3HintVisible = true }
                }
                suppressNextA3Detection = false
                setupSplitState()
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
                undoStack = []
                redoStack = []
                sourceWasTrashed = false
                lastBookletOrder = nil
                bookletRedoNoticeVisible = false
                a3HintVisible = false
            }
        }
        .sheet(isPresented: $showingA3Detection) {
            A3SplitChoiceView(
                firstPage: pdfManager.pdfDocument?.page(at: 0),
                onChoose: { leftFirst in
                    guard let original = pdfManager.pdfDocument else { return }
                    showingA3Detection = false
                    isProcessingA3 = true
                    // Run the crop-box splitting on a background thread so the
                    // UI stays responsive on large documents.
                    // SAFETY: original is not touched on the main thread again until
                    // the async block completes and posts back via DispatchQueue.main.async.
                    // No mutations inside this block — read-only pass to splitA3Pages.
                    let uncheckedOriginal = Unchecked(original)
                    DispatchQueue.global(qos: .userInitiated).async {
                        let splitDoc = splitA3Pages(uncheckedOriginal.value, leftFirst: leftFirst)
                        DispatchQueue.main.async {
                            isProcessingA3 = false
                            // Switch to page-skip mode so Delete skips individual pages,
                            // which is more useful after an A3 split where blank pages
                            // often need to be removed one at a time.
                            skipMode = .page
                            suppressNextA3Detection = true
                            pdfManager.pdfDocument = splitDoc
                            // onChange fires, skips A3 re-detection, calls setupSplitState().
                            // Show a brief tip so the user knows about Swap.
                            withAnimation(.easeInOut(duration: 0.2)) { a3SplitNoticeVisible = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                                withAnimation(.easeInOut(duration: 0.2)) { a3SplitNoticeVisible = false }
                            }
                        }
                    }
                },
                onKeepAsIs: {
                    showingA3Detection = false
                    setupSplitState()
                }
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
        .overlay {
            if isProcessingA3 {
                ZStack {
                    Color(NSColor.windowBackgroundColor).opacity(0.7)
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(1.3)
                        Text("Splitting A3 pages…")
                            .font(.headline)
                        Text("Cutting each page down the middle.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(32)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .shadow(radius: 20)
                    )
                }
                .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var splitStageBody: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack {
                Text(pdfManager.pdfDocument != nil ? "Split PDF — Step 1: Set Split Points" : "Split PDF")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if pdfManager.pdfDocument != nil {
                    Button { showingA3Detection = true } label: {
                        Label("Split as A3…", systemImage: "rectangle.split.2x1")
                    }
                    .help("Manually trigger A3 splitting — use this if auto-detection didn't fire (e.g. scanner saved landscape pages with a rotation flag)")

                    Button(action: requestBookletFix) {
                        Label("Fix Booklet Order", systemImage: "rectangle.stack")
                    }
                    .disabled(!canFixBookletOrder)
                    .help("Reorder pages in the current file segment to correct booklet scanning order. Set split markers first to define file boundaries.")

                    Button(action: clearAllMarkers) {
                        Label("Clear All Splits", systemImage: "trash")
                    }
                    .disabled(splitMarkers.isEmpty)

                    Button(action: { pdfManager.clearPDF() }) {
                        Label("Clear File", systemImage: "xmark.circle.fill")
                    }
                    .help("Remove the current file and start over")
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if bookmarkNoticeVisible {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark.fill")
                        .foregroundColor(.accentColor)
                    Text("Split points loaded from bookmarks")
                        .font(.callout)
                    Spacer()
                    Button { withAnimation(.easeInOut(duration: 0.2)) { bookmarkNoticeVisible = false } }
                        label: { Image(systemName: "xmark").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if a3HintVisible {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.split.2x1")
                        .foregroundColor(.secondary)
                    Text("This looks like it might be an A3 scan — each page may contain two A4 halves.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    Button("Split as A3…") {
                        withAnimation { a3HintVisible = false }
                        showingA3Detection = true
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
                    Text("A3 pages split in half — use **Swap with Next** (S) to fix page order if needed")
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
                                rotation: 0
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
                                            onNavigate: { pageIndex in currentPage = pageIndex },
                                            onSelect: { isCmd, isShift in
                                                handleFileSelection(fileIndex, isCmd: isCmd, isShift: isShift)
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
                                .disabled(activeFileCount < 1 || (activeFileCount < 2 && skippedPages.isEmpty))
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
        fileSizes = toggleSplit(in: fileSizes, at: page)
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

    func saveSplitPDF() {
        guard let document = pdfManager.pdfDocument,
              activeFileCount >= 1,
              activeFileCount >= 2 || !skippedPages.isEmpty else { return }

        if prefixEnabled {
            // Go straight to Step 3 — folder picker comes after the user confirms order.
            // Only include files that have at least one non-skipped page.
            var items: [PrefixItem] = []
            var pagePos = 0
            for fileIndex in 0..<fileSizes.count {
                let fileSize = fileSizes[fileIndex]
                if !isFileFullySkipped(fileIndex) {
                    let suffix = customFileNames[fileIndex] ?? ""
                    let proposed: String
                    if suffix.isEmpty {
                        proposed = "\(baseFileName)\(filenameSeparator)\(fileIndex + 1).pdf"
                    } else {
                        proposed = "\(baseFileName)\(filenameSeparator)\(suffix).pdf"
                    }
                    let firstPage = document.page(at: pagePos)
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
                pdfManager.saveSplitPDF(
                    to: folderURL,
                    splitMarkers: splitMarkers,
                    baseFileName: baseFileName,
                    customFileNames: customFileNames,
                    pageToFileMapping: pageToFileMapping,
                    skippedPages: skippedPages,
                    separator: filenameSeparator
                ) { title, message, isError in
                    if isError {
                        showNSAlert(title: title, message: message, isError: true)
                    } else {
                        var names: [String] = []
                        for i in 0..<fileSizes.count {
                            guard !isFileFullySkipped(i) else { continue }
                            let sfx = customFileNames[i] ?? ""
                            if sfx.isEmpty {
                                names.append("\(baseFileName)\(filenameSeparator)\(i + 1).pdf")
                            } else {
                                names.append("\(baseFileName)\(filenameSeparator)\(sfx).pdf")
                            }
                        }
                        sourceWasTrashed = trashSourceFileIfRequested()
                        pendingFolderURL = folderURL
                        summaryNames = names
                        splitStage = .summary
                    }
                }
            }
        }
    }

    /// Called by PrefixOrderStepView when the user confirms the prefix ordering.
    /// Shows the folder picker, then writes all split files in one pass.
    private func applyPrefixAndSaveSplit(orderedItems: [PrefixItem]) {
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

    /// Reads bookmarks from the currently loaded document (if any) and initialises
    /// `fileSizes`, `baseFileName`, and `customFileNames`.  Also shows the bookmark
    /// notice banner.  Call this whenever a new (non-A3) document finishes loading.
    private func setupSplitState() {
        let bookmarkData = pdfManager.pdfDocument.flatMap { splitSizesFromBookmarks($0) }
        if let data = bookmarkData {
            fileSizes = data.sizes
            if let names = extractSplitNames(from: data.labels) {
                baseFileName = names.baseName
                for (i, suffix) in names.suffixes.enumerated() {
                    customFileNames[i] = suffix
                }
            } else {
                baseFileName = pdfManager.currentFileName ?? ""
            }
            withAnimation(.easeInOut(duration: 0.2)) { bookmarkNoticeVisible = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                withAnimation(.easeInOut(duration: 0.2)) { bookmarkNoticeVisible = false }
            }
        } else {
            fileSizes = totalPages > 0 ? [totalPages] : []
            baseFileName = pdfManager.currentFileName ?? ""
        }
        if splitStage != .split { splitStage = .split }
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
        suppressDocumentReset   = true
        pdfManager.pdfDocument  = newDoc
        // currentPage stays the same so the preview immediately shows
        // what was just moved down one slot.
    }

    private func applyPrefixToFolder(_ folderURL: URL, orderedItems: [PrefixItem]) {
        let sep = UserDefaults.standard.string(forKey: "prefixSeparator") ?? " - "

        // Build customFileNames keyed by original fileIndex.
        // saveSplitPDF writes: "\(baseFileName)\(separator)\(suffix).pdf"
        // We pass baseFileName="" separator="" so the suffix IS the complete filename (without .pdf).
        // Same numbering the user saw in Step 3 — so the saved names match the preview.
        let numbers = scoreOrderNumbers(forOrderedItems: orderedItems)
        var finalCustomNames: [Int: String] = [:]
        var finalNamesForSummary: [String] = []
        var omittedPages = skippedPages   // Step-1 skips, plus any Step-3 skips below

        for item in orderedItems {
            guard let number = numbers[item.id] else {
                // Skipped in Step 3 → drop this segment's pages so the file isn't written.
                omittedPages.formUnion(pagesForFile(item.id))
                continue
            }
            let fullName = "\(String(format: "%02d", number))\(sep)\(item.proposedName)"  // e.g. "01 - Beethoven - Flute.pdf"
            let nameWithoutPdf = fullName.hasSuffix(".pdf")
                ? String(fullName.dropLast(4))
                : fullName
            finalCustomNames[item.id] = nameWithoutPdf
            finalNamesForSummary.append(fullName)
        }

        pdfManager.saveSplitPDF(
            to: folderURL,
            splitMarkers: splitMarkers,
            baseFileName: "",
            customFileNames: finalCustomNames,
            pageToFileMapping: pageToFileMapping,
            skippedPages: omittedPages,
            separator: ""
        ) { _, _, isError in
            if isError {
                showNSAlert(title: "Save Failed",
                            message: "Could not write one or more files to \(folderURL.path).",
                            isError: true)
            } else {
                sourceWasTrashed = trashSourceFileIfRequested()
                pendingFolderURL = folderURL   // stored here so summary can offer "Show in Finder"
                summaryNames = finalNamesForSummary
                splitStage = .summary
            }
        }
    }
}

// MARK: - A3 Split Choice View

/// Sheet shown when an A3-landscape PDF is detected.  The user picks which half
/// is page 1 (left-first or right-first), or dismisses without splitting.
struct A3SplitChoiceView: View {
    /// The detected A3 page, used to render a real preview behind the left/right markers.
    let firstPage: PDFPage?
    /// Called with `true` for left-first, `false` for right-first.
    let onChoose: (Bool) -> Void
    let onKeepAsIs: () -> Void

    /// Rendered thumbnail of `firstPage` (in its display orientation, so rotation is honoured).
    @State private var pageImage: NSImage?

    /// Aspect ratio of the rendered page; falls back to A3-landscape (√2) before the image loads.
    private var previewAspect: CGFloat {
        guard let img = pageImage, img.size.height > 0 else { return 1.414 }
        return img.size.width / img.size.height
    }

    /// One half-page marker (number badge + caption) on a legible material backing.
    private func halfMarker(symbol: String, text: String, prominent: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title)
                .foregroundColor(prominent ? .accentColor : .secondary)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("A3 Landscape Detected")
                .font(.title2)
                .fontWeight(.semibold)

            Text("This document looks like an A3 sheet with two A4 pages side by side.\nWhich half should become the first page?")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 380)

            // Visual diagram — left/right markers overlaid on a preview of the actual page.
            ZStack {
                if let img = pageImage {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(NSColor.controlBackgroundColor))
                }

                // Left half tinted to signal it's page 1 by default.
                HStack(spacing: 0) {
                    Color.accentColor.opacity(0.18)
                    Color.clear
                }

                HStack(spacing: 0) {
                    halfMarker(symbol: "1.circle.fill", text: "Left half", prominent: true)
                        .frame(maxWidth: .infinity)
                    halfMarker(symbol: "2.circle", text: "Right half", prominent: false)
                        .frame(maxWidth: .infinity)
                }
            }
            .aspectRatio(previewAspect, contentMode: .fit)
            .frame(maxWidth: 300, maxHeight: 200)
            // Centre divider showing where the sheet will be cut.
            .overlay(
                Rectangle()
                    .fill(Color.white.opacity(0.7))
                    .frame(width: 1.5)
                    .shadow(color: .black.opacity(0.4), radius: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            .padding(14)
            .onAppear {
                guard pageImage == nil, let page = firstPage else { return }
                // thumbnail(of:for:) preserves the page's display aspect within the box,
                // so a square bounding size yields a correctly-proportioned image.
                pageImage = page.thumbnail(of: NSSize(width: 600, height: 600), for: .cropBox)
            }

            // Choice buttons
            HStack(spacing: 16) {
                Button {
                    onChoose(true)
                } label: {
                    HStack {
                        Image(systemName: "arrow.left.to.line")
                        Text("Left half first")
                    }
                    .frame(width: 150)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    onChoose(false)
                } label: {
                    HStack {
                        Image(systemName: "arrow.right.to.line")
                        Text("Right half first")
                    }
                    .frame(width: 150)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Text("For saddle-stitch booklets, pages come out in sheet order — use the reorder step to fix the sequence.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Button("Keep as-is — don't split pages") {
                onKeepAsIs()
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .padding(36)
        .frame(minWidth: 480)
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

// MARK: - File Preview Card
struct FilePreviewCard: View {
    let fileIndex: Int
    let pageToFileMapping: [Int: Int]
    let totalPages: Int
    let baseFileName: String
    let customFileNames: [Int: String]
    /// The page currently shown in the left preview — used to highlight the active card.
    let currentPage: Int
    let isFullySkipped: Bool
    let isPartiallySkipped: Bool
    let skippedPages: Set<Int>
    let isSelected: Bool
    let onNavigate: (Int) -> Void
    /// Called when the user clicks the card; provides Cmd and Shift modifier state.
    let onSelect: (_ isCmd: Bool, _ isShift: Bool) -> Void
    /// Non-nil when this file's page count qualifies for booklet reordering (≥ 4, divisible by 4).
    var onFixBookletOrder: (() -> Void)? = nil
    /// Non-nil when a previous booklet order exists and matches this file's page count.
    var onRedoBookletOrder: (() -> Void)? = nil

    var pagesInFile: [Int] {
        pageToFileMapping.filter { $0.value == fileIndex }.keys.sorted()
    }

    /// True when the currently-previewed page belongs to this output file.
    var isActive: Bool {
        pagesInFile.contains(currentPage)
    }

    var fileName: String {
        if let customSuffix = customFileNames[fileIndex], !customSuffix.isEmpty {
            return "\(baseFileName)\(customSuffix).pdf"
        } else {
            return "\(baseFileName)_\(fileIndex + 1).pdf"
        }
    }

    /// Background fill colour reflecting skip / selection / active state.
    private var cardFill: Color {
        if isFullySkipped    { return Color.red.opacity(0.12) }
        if isPartiallySkipped { return Color.orange.opacity(0.12) }
        if isSelected        { return Color.accentColor.opacity(0.15) }
        if isActive          { return Color.accentColor.opacity(0.08) }
        return Color(NSColor.controlBackgroundColor)
    }

    private var cardBorder: Color {
        if isFullySkipped    { return Color.red.opacity(0.4) }
        if isPartiallySkipped { return Color.orange.opacity(0.4) }
        if isSelected        { return Color.accentColor.opacity(0.7) }
        if isActive          { return Color.accentColor.opacity(0.5) }
        return .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: isFullySkipped ? "doc.fill" : "doc.fill")
                    .foregroundColor(isFullySkipped ? .red
                                     : isPartiallySkipped ? .orange
                                     : isActive ? .accentColor : .blue)

                Text(fileName)
                    .font(.headline)
                    .foregroundColor(isFullySkipped ? .secondary : .primary)
                    .strikethrough(isFullySkipped)

                if isFullySkipped {
                    Text("SKIPPED")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if isPartiallySkipped {
                    Text("PARTIAL")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundColor(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Spacer()

                if let fixBooklet = onFixBookletOrder {
                    Button(action: fixBooklet) {
                        Image(systemName: "rectangle.stack")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Fix booklet page order for this file")
                }

                if let redoBooklet = onRedoBookletOrder {
                    Button(action: redoBooklet) {
                        Image(systemName: "rectangle.stack.badge.play")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Repeat the last booklet reordering on this file")
                }

                let activeCount = pagesInFile.filter { !skippedPages.contains($0) }.count
                if isPartiallySkipped {
                    Text("\(activeCount) of \(pagesInFile.count) pages")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(pagesInFile.count) page\(pagesInFile.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 4) {
                ForEach(pagesInFile.prefix(10), id: \.self) { pageIndex in
                    let pageSkipped = skippedPages.contains(pageIndex)
                    Button(action: {
                        onNavigate(pageIndex)
                    }) {
                        Text("\(pageIndex + 1)")
                            .font(.caption2)
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(pageSkipped
                                          ? Color.red.opacity(0.25)
                                          : Color.accentColor.opacity(0.2))
                            )
                            .foregroundColor(pageSkipped ? .red : .primary)
                    }
                    .buttonStyle(.plain)
                }

                if pagesInFile.count > 10 {
                    Text("+ \(pagesInFile.count - 10) more")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(cardBorder, lineWidth: 1.5)
                )
        )
        // Tap selects the card (with modifier support); the selection handler
        // in SplitView also navigates when it's a plain single-click.
        .contentShape(Rectangle())
        .onTapGesture {
            let mods = NSEvent.modifierFlags
            onSelect(mods.contains(.command), mods.contains(.shift))
        }
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Split Naming Stage (Step 2)
/// Full-window Step 2: lets users set the base filename and per-file name suffixes,
/// with a large first-page thumbnail for each output file.
struct SplitNamingStageView: View {
    let pdfDocument: PDFDocument
    let fileSizes: [Int]
    /// Pages omitted from output (passed from SplitView).
    let skippedPages: Set<Int>
    /// File indices whose every page is skipped — hidden from this step.
    let skippedFileIndices: Set<Int>
    @Binding var baseFileName: String
    @Binding var customFileNames: [Int: String]
    @Binding var previewOffset: CGPoint
    let onBack: () -> Void
    let onClear: () -> Void
    let onSave: () -> Void

    @FocusState private var focusedField: Int?
    @AppStorage("filenameSeparator") private var filenameSeparator: String = " - "
    @AppStorage("prefixEnabled") private var prefixEnabled: Bool = true
    /// Sticky across splits and launches (shared by key with SplitView / BulkRenameView).
    @AppStorage("prefixEnsembleType") private var prefixEnsembleType: EnsembleType = .band
    /// Shared by key with SplitView. When on, the original file is moved to the Trash
    /// after the split files are written (handled back in SplitView's save paths).
    @AppStorage("deleteSourceAfterSplit") private var deleteSourceAfterSplit: Bool = false

    /// Set to true once we've auto-inferred the ensemble from a high-confidence signal.
    /// Prevents re-inference (and fighting the user) on subsequent edits this session.
    @State private var hasInferredEnsemble = false

    /// All file indices, excluding fully-skipped ones.
    var visibleFileIndices: [Int] {
        (0..<fileSizes.count).filter { !skippedFileIndices.contains($0) }
    }

    var numberOfFiles: Int { fileSizes.count }

    /// Page index of the first page in a given file.
    private func firstPageIndex(for fileIndex: Int) -> Int {
        fileSizes.prefix(fileIndex).reduce(0, +)
    }

    /// Row subtitle: page range + active page count, noting any partially-skipped pages.
    private func subtitle(for fileIndex: Int) -> String {
        let start = firstPageIndex(for: fileIndex)
        let size  = fileSizes[fileIndex]
        let end   = start + size - 1
        let range = (start == end) ? "Page \(start + 1)" : "Pages \(start + 1)–\(end + 1)"
        let activeCount = (start..<(start + size)).filter { !skippedPages.contains($0) }.count
        if activeCount < size {
            return "\(range) · \(activeCount) active of \(size) pages"
        }
        return "\(range) · \(size) \(size == 1 ? "page" : "pages")"
    }

    /// The selected ensemble's score order, so "next instrument" suggestions follow
    /// that ensemble (e.g. in a band, Horn follows Trumpet; in an orchestra it precedes).
    private var instrumentNames: [String] {
        InstrumentOrders.getOrder(for: prefixEnsembleType).map { $0.capitalized }
    }

    private var baseNameError: String? {
        filenameError(for: baseFileName)
    }

    private var anySuffixError: Bool {
        customFileNames.values.contains { filenameError(for: $0) != nil }
    }

    /// True when two visible files share a non-empty suffix (case-insensitive) — they'd
    /// be written with the same name. Only blocks saving when no prefix will be added
    /// (with the prefix, the score-order number keeps them distinct).
    private var hasDuplicateSuffixes: Bool {
        let names = visibleFileIndices
            .compactMap { customFileNames[$0]?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
        return Set(names).count != names.count
    }

    private var canSave: Bool {
        let count = visibleFileIndices.count
        return (count >= 2 || (count >= 1 && !skippedPages.isEmpty))
            && baseNameError == nil && !anySuffixError
            && !(prefixEnabled == false && hasDuplicateSuffixes)   // would overwrite on direct save
    }

    private func filenameError(for text: String) -> String? { pdfFilenameError(for: text) }

    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar ──────────────────────────────────────────────────
            HStack {
                Spacer()
                Text("Step 2: Name Files")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: onClear) {
                    Label("Clear File", systemImage: "xmark.circle.fill")
                }
                .help("Remove the current file and start over")
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // ── Base filename ─────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Base Filename:")
                        .font(.headline)
                        .fixedSize()

                    TextField("e.g. Symphony No. 5", text: $baseFileName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 380)

                    Text("Example: \(baseFileName.isEmpty ? "basename" : baseFileName)\(filenameSeparator)Flute.pdf  ·  Leave blank for auto-numbering: \(baseFileName.isEmpty ? "basename" : baseFileName)\(filenameSeparator)1.pdf")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()
                }

                if let err = baseNameError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // ── Skipped-pages banner ──────────────────────────────────────
            if !skippedPages.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .foregroundColor(.orange)
                    let rangeStr = formatSkippedPageRanges(skippedPages)
                    let hiddenCount = skippedFileIndices.count
                    if hiddenCount > 0 {
                        Text("Skipping \(rangeStr) from input · \(hiddenCount) file\(hiddenCount == 1 ? "" : "s") hidden above")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Skipping \(rangeStr) from input")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.07))

                Divider()
            }

            // ── File list ─────────────────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(visibleFileIndices, id: \.self) { fileIndex in
                            SplitFileNamingRow(
                                fileIndex: fileIndex,
                                page: pdfDocument.page(at: firstPageIndex(for: fileIndex)),
                                subtitle: subtitle(for: fileIndex),
                                baseFileName: baseFileName,
                                suffix: Binding(
                                    get: { customFileNames[fileIndex] ?? "" },
                                    set: { customFileNames[fileIndex] = $0.isEmpty ? nil : $0 }
                                ),
                                fieldFocus: $focusedField,
                                instrumentNames: instrumentNames,
                                allSuffixes: customFileNames,
                                ensemble: prefixEnsembleType,
                                prefixWillDisambiguate: prefixEnabled,
                                previewOffset: $previewOffset,
                                isLastField: fileIndex == visibleFileIndices.last,
                                onLastTab: { if canSave { onSave() } }
                            )
                            .id(fileIndex)
                            if fileIndex != visibleFileIndices.last { Divider() }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onAppear {
                    proxy.scrollTo(0, anchor: .top)
                    hasInferredEnsemble = false
                    // Auto-focus the first text field so arrow keys immediately
                    // navigate suggestions rather than scrolling the ScrollView.
                    // A short async dispatch lets SwiftUI finish laying out the
                    // new view hierarchy before we request focus.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        focusedField = visibleFileIndices.first
                    }
                }
                .onChange(of: focusedField) { _, newValue in
                    if let field = newValue {
                        withAnimation { proxy.scrollTo(field, anchor: .center) }
                    }
                }
                .onChange(of: customFileNames) { _, newNames in
                    // Auto-switch only on a high-confidence signal (strings → orchestra,
                    // first part a sax → jazz). Fires at most once per naming session so it
                    // doesn't fight manual edits; a charts-with-no-signal list keeps the
                    // sticky choice. Names are passed in file order for the "first part" test.
                    guard !hasInferredEnsemble else { return }
                    let ordered = newNames.sorted { $0.key < $1.key }.map { $0.value }
                    guard let inferred = inferredSplitSuggestionEnsemble(ordered) else { return }
                    prefixEnsembleType = inferred
                    hasInferredEnsemble = true
                }
            }

            Divider()

            // ── Bottom bar ───────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 8) {
                // Prefix option row
                HStack(spacing: 12) {
                    Toggle("Prefix score order", isOn: $prefixEnabled)
                    // Always enabled — the ensemble drives the Step 2 instrument
                    // suggestions (order + per-ensemble part counts), not just prefixing.
                    Picker("", selection: $prefixEnsembleType) {
                        Text("Wind Band").tag(EnsembleType.band)
                        Text("Jazz Band").tag(EnsembleType.jazz)
                        Text("Orchestra").tag(EnsembleType.orchestra)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    Spacer()
                    Toggle("Move original to Trash", isOn: $deleteSourceAfterSplit)
                        .toggleStyle(.checkbox)
                        .help("When the split files are saved, the original PDF is moved to the Trash (recoverable). Off by default.")
                }

                HStack {
                    Button(action: onBack) {
                        Label("Back to Split", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(action: onSave) {
                        Label(prefixEnabled ? "Next: Prefix Order" : "Save Split Files",
                              systemImage: prefixEnabled ? "chevron.right" : "arrow.down.doc.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSave)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

// MARK: - Split File Naming Row
/// One row in the naming stage: large page thumbnail on the left, file info and
/// suffix text field on the right.
/// Used by both SplitNamingStageView (one row per output file from a single PDF)
/// and BulkRenameView (one row per separate PDF file).
struct SplitFileNamingRow: View {
    let fileIndex: Int
    /// The PDF page to display in the thumbnail strip.
    /// SplitNamingStageView passes the first page of each output section;
    /// BulkRenameView passes page 0 of each individual document.
    let page: PDFPage?
    /// Short descriptor shown in the row header, e.g. "Pages 1–4 · 4 pages"
    /// (splitter) or the original filename (bulk rename).
    let subtitle: String
    let baseFileName: String
    @Binding var suffix: String
    /// The parent's FocusState binding — passed directly so that Tab/click
    /// both update the parent (triggering auto-scroll) without a local copy.
    var fieldFocus: FocusState<Int?>.Binding
    let instrumentNames: [String]   // ordered, deduplicated, capitalised
    let allSuffixes: [Int: String]  // snapshot of all rows' current suffixes
    /// Selected ensemble — drives ensemble-specific part counts (e.g. 1 tenor sax in a
    /// band vs 2 in a big band). Defaults to band.
    var ensemble: EnsembleType = .band
    /// True when a score-order prefix will be added afterwards (Step 3), which keeps
    /// same-named files distinct — so a duplicate suffix is only a real collision when
    /// this is false.
    var prefixWillDisambiguate: Bool = false
    @Binding var previewOffset: CGPoint
    /// True for the last visible row — Tab/Return will call onLastTab instead of advancing focus.
    var isLastField: Bool = false
    /// Called when Tab or Return is pressed on the last field. Defaults to a no-op so
    /// BulkRenameView (which doesn't pass this) keeps its existing behaviour.
    var onLastTab: () -> Void = {}

    /// Separator inserted between base name and suffix in output filenames.
    /// Mirrors the setting in Preferences → Renamer.
    @AppStorage("filenameSeparator") private var filenameSeparator: String = " - "

    /// Step sizes in PDF points.
    /// cropH = 100 pt; stepV = 25 pt → 75 % overlap between consecutive positions.
    /// cropW ≈ 200 pt; stepH = 100 pt → 50 % overlap horizontally.
    private let stepV: CGFloat = 25
    private let stepH: CGFloat = 100

    /// Rendered size of the preview strip (captured via GeometryReader) so drag
    /// distances can be converted from screen points to PDF points.
    @State private var stripSize: CGSize = .zero
    /// Running translation of the in-progress strip drag, so we apply incremental deltas.
    @State private var lastStripDrag: CGSize = .zero

    /// (cropW, cropH, pageW, pageH) in PDF points — mirrors PageInstrumentPreview's crop.
    private func cropDims(_ pg: PDFPage) -> (cropW: CGFloat, cropH: CGFloat, pageW: CGFloat, pageH: CGFloat) {
        let mediaBox = pg.bounds(for: .mediaBox)
        let rotation = ((pg.rotation % 360) + 360) % 360
        let pageW = rotation == 90 || rotation == 270 ? mediaBox.height : mediaBox.width
        let pageH = rotation == 90 || rotation == 270 ? mediaBox.width  : mediaBox.height
        return (min(pageW * 0.4, 200), 100, pageW, pageH)
    }

    /// Adds a PDF-point delta to the shared pan offset, clamped to the page's valid range
    /// (x: 0…pageW-cropW, y: -(pageH-cropH)…0) so dragging stops cleanly at the edges.
    private func applyPan(_ delta: CGSize) {
        guard let pg = page else { return }
        let d = cropDims(pg)
        previewOffset.x = min(max(previewOffset.x + delta.width,  0), max(0, d.pageW - d.cropW))
        previewOffset.y = min(max(previewOffset.y + delta.height, -(d.pageH - d.cropH)), 0)
    }

    private var isFieldFocused: Bool { fieldFocus.wrappedValue == fileIndex }

    // Arrow-key selection index into the suggestions list (nil = in the text field)
    @State private var selectedSuggestionIndex: Int? = nil
    /// What the user actually typed before arrowing into a suggestion.
    /// Restored when the user presses Escape or arrows back above the first item.
    @State private var committedTypedText: String = ""

    private var finalFileName: String {
        suffix.isEmpty
            ? "\(baseFileName)\(filenameSeparator)\(fileIndex + 1).pdf"
            : "\(baseFileName)\(filenameSeparator)\(suffix).pdf"
    }

    // ── Pan overlay ─────────────────────────────────────────────────────────
    /// Arrow buttons overlaid on each preview strip; all rows share the same
    /// previewOffset binding so pressing any arrow moves every strip at once.
    ///
    /// Uses Color.clear + .overlay(alignment:) rather than VStack/HStack+Spacer
    /// so button positions are anchored directly — no Spacer needs a concrete
    /// height proposal, so buttons never collapse when the image finishes loading.
    private var panOverlay: some View {
        Color.clear
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { stripSize = geo.size }
                    .onChange(of: geo.size) { _, s in stripSize = s }
            })
            // Drag anywhere on the strip to pan (grab-the-paper direction). Arrow
            // buttons sit on top and still receive their own taps.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        guard let pg = page, stripSize.width > 0, stripSize.height > 0 else { return }
                        let d = cropDims(pg)
                        // `.fill` scales the crop uniformly to cover the strip.
                        let scale = max(stripSize.width / d.cropW, stripSize.height / d.cropH)
                        let dx = (value.translation.width  - lastStripDrag.width)  / scale
                        let dy = (value.translation.height - lastStripDrag.height) / scale
                        lastStripDrag = value.translation
                        applyPan(CGSize(width: -dx, height: dy))   // drag right→see left; drag down→see up
                    }
                    .onEnded { _ in lastStripDrag = .zero }
            )
            .overlay(alignment: .top) {
                panButton("chevron.up")   { previewOffset.y += stepV }
                    .padding(.top, 6)
            }
            .overlay(alignment: .bottom) {
                panButton("chevron.down") { previewOffset.y -= stepV }
                    .padding(.bottom, 6)
            }
            .overlay(alignment: .leading) {
                panButton("chevron.left")  { previewOffset.x -= stepH }
                    .padding(.leading, 6)
            }
            .overlay(alignment: .trailing) {
                panButton("chevron.right") { previewOffset.x += stepH }
                    .padding(.trailing, 6)
            }
            // Reset button — top-right, only visible when panned away from default
            .overlay(alignment: .topTrailing) {
                if previewOffset != .zero {
                    panButton("arrow.uturn.backward") { previewOffset = .zero }
                        .padding(6)
                }
            }
    }

    private func panButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(.ultraThinMaterial)
                .foregroundColor(.secondary)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // ── Validation ──────────────────────────────────────────────────────────
    private var suffixError: String? { pdfFilenameError(for: suffix) }

    /// True when this row's (non-empty) suffix matches another row's — the two files
    /// would be saved with the same name (and overwrite each other). Case-insensitive,
    /// since macOS filenames collide regardless of case.
    private var isDuplicateSuffix: Bool {
        let mine = suffix.trimmingCharacters(in: .whitespaces)
        guard !mine.isEmpty else { return false }
        return allSuffixes.contains { index, other in
            index != fileIndex
                && other.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(mine) == .orderedSame
        }
    }

    // ── Autocomplete ─────────────────────────────────────────────────────────
    /// Index in `instrumentNames` to start suggestions from — the entry just
    /// after the most recently used instrument in the rows above this one.
    /// Uses alias normalisation so "Alto Sax" and "Alto Saxophone" are treated
    /// as the same instrument family.
    private var nextExpectedIndex: Int {
        // Instruments already named in *other* rows (by identity), so we can offer
        // stragglers. Excludes this row so arrowing through its own list doesn't shift it.
        let usedKeys = Set(allSuffixes
            .filter { $0.key != fileIndex }
            .values
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { instrumentIdentityKey($0) })

        for i in Swift.stride(from: fileIndex - 1, through: 0, by: -1) {
            let prev = (allSuffixes[i] ?? "").trimmingCharacters(in: .whitespaces)
            guard !prev.isEmpty else { continue }
            if let idx = nextSuggestionIndex(after: prev, in: instrumentNames, usedKeys: usedKeys) {
                return idx
            }
        }
        return 0
    }

    /// Top-priority numbered suggestion based on the nearest previous suffix:
    /// - If "Flute 1" and typical count for Flute is 2 → suggests "Flute 2"
    /// - If "Flute 2" and typical count for Flute is 2 → cross-boundary: suggests "Oboe 1"
    private var numberedSuggestion: String? {
        for i in Swift.stride(from: fileIndex - 1, through: 0, by: -1) {
            let prev = (allSuffixes[i] ?? "").trimmingCharacters(in: .whitespaces)
            guard !prev.isEmpty else { continue }

            // Clef companion takes priority: "Baritone BC" → "Baritone TC" — but only if
            // that companion clef hasn't been named in *another* row yet (otherwise fall
            // through to the next instrument, so "Baritone BC" then "Baritone TC" rolls on
            // to Tuba). Excludes this row so arrowing onto the companion doesn't make it
            // vanish from its own list.
            if let companion = clefCompanion(for: prev),
               !allSuffixes.contains(where: { index, value in
                   index != fileIndex
                       && preferredInstrumentDisplayName(value.trimmingCharacters(in: .whitespaces)) == companion
               }) {
                return companion
            }

            let parts = prev.components(separatedBy: " ")
            // Must have at least two tokens and last token must be a positive integer
            if parts.count >= 2, let last = parts.last, let n = Int(last), n > 0 {
                let basePart = parts.dropLast().joined(separator: " ")
                let typical = splitSuggestionTypicalPartCount(basePart, ensemble: ensemble)
                if n >= typical {
                    // Cross-boundary: suggest the next instrument family at part 1
                    return splitSuggestionStartingNumberedName(
                        prevSuffix: prev,
                        instrumentNames: instrumentNames,
                        ensemble: ensemble
                    )
                } else {
                    // Same family, next part — preserve the user's sax style
                    let rawNext = "\(basePart) \(n + 1)"
                    return rawNext  // basePart already uses the user's own style
                }
            }
            break  // only consider the closest non-empty row
        }
        return nil
    }

    /// The text to use when filtering suggestions.
    /// While the user is arrowing through the list, the field shows the highlighted
    /// suggestion but suggestions must stay anchored to what was actually typed —
    /// otherwise arrowing to "Flute" collapses the list to a single match.
    private var queryText: String {
        selectedSuggestionIndex != nil ? committedTypedText : suffix
    }

    private var suggestions: [String] {
        // Rotate the base instrument list so "next expected" comes first
        let start = nextExpectedIndex
        let rotated = Array(instrumentNames.suffix(from: start))
                    + Array(instrumentNames.prefix(start))

        // Collapse "Flute 1", "Flute 2" → "Flute" so the list stays compact.
        // When user types a number we show numbered variants (via numberedSuggestion).
        let deduplicated = splitSuggestionDisplayNames(rotated)

        var result: [String]
        if queryText.isEmpty {
            result = Array(deduplicated.prefix(8))
        } else {
            let q = queryText.lowercased()
            let prefixMatches   = deduplicated.filter { $0.lowercased().hasPrefix(q) }
            let containsMatches = deduplicated.filter {
                $0.lowercased().contains(q) && !$0.lowercased().hasPrefix(q)
            }
            result = Array((prefixMatches + containsMatches).prefix(8))
        }

        // Prepend numbered suggestion ("Flute 2" or cross-boundary "Oboe 1") when relevant
        if let numbered = numberedSuggestion {
            let show = queryText.isEmpty || numbered.lowercased().hasPrefix(queryText.lowercased())
            if show {
                result.removeAll { $0.lowercased() == numbered.lowercased() }
                result.insert(numbered, at: 0)
                result = Array(result.prefix(8))
            }
        }

        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── File header ───────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "doc.fill")
                    .foregroundColor(.accentColor)
                Text("File \(fileIndex + 1)")
                    .font(.title3)
                    .fontWeight(.semibold)
                Text("·")
                    .foregroundColor(.secondary)
                Text(subtitle)
                    .foregroundColor(.secondary)
                Spacer()
            }

            // ── Instrument name crop with pan overlay + minimap ──────────
            if let pg = page {
                HStack(alignment: .top, spacing: 8) {
                    // Main crop strip (panning)
                    // panOverlay is applied as .overlay on the FRAMED container rather
                    // than as a ZStack sibling of PageInstrumentPreview.  This guarantees
                    // the overlay always receives the container's fixed 150 pt height as
                    // its layout size, completely independent of whatever
                    // PageInstrumentPreview draws (or redraws) inside.
                    PageInstrumentPreview(page: pg, offset: previewOffset)
                        .allowsHitTesting(false)
                        .frame(maxWidth: .infinity)
                        .frame(height: 150)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
                        .overlay { panOverlay }

                    // Minimap: full-page thumbnail with crop indicator (drag to reposition)
                    PageCropOverview(page: pg, offset: previewOffset, onPanBy: applyPan)
                        .frame(width: 52, height: 70)
                        .padding(.top, (150 - 70) / 2)  // vertically centre against the 150pt strip
                }
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.12))
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
            }

            // ── Name field ────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Custom suffix (optional — leave blank for automatic numbering)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    Text(baseFileName.isEmpty ? "basename" : baseFileName)
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                    TextField("Flute", text: $suffix)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .focused(fieldFocus, equals: fileIndex)
                        // Arrow-key navigation: immediately apply the highlighted suggestion
                        // to the field so Tab/Return can advance without an extra keypress.
                        .onKeyPress(.downArrow) {
                            guard !suggestions.isEmpty else { return .ignored }
                            if selectedSuggestionIndex == nil {
                                committedTypedText = suffix   // remember what was typed
                            }
                            let newIdx = min((selectedSuggestionIndex ?? -1) + 1,
                                            suggestions.count - 1)
                            selectedSuggestionIndex = newIdx
                            suffix = suggestions[newIdx]
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            if let idx = selectedSuggestionIndex, idx > 0 {
                                selectedSuggestionIndex = idx - 1
                                suffix = suggestions[idx - 1]
                            } else {
                                // Arrowed back above the list — restore what the user typed
                                selectedSuggestionIndex = nil
                                suffix = committedTypedText
                            }
                            return .handled
                        }
                        .onKeyPress(.return) {
                            // Suggestion is already in the field; just clear the dropdown.
                            if selectedSuggestionIndex != nil { selectedSuggestionIndex = nil }
                            if isLastField { onLastTab() }
                            else { fieldFocus.wrappedValue = fileIndex + 1 }
                            return .handled
                        }
                        .onKeyPress(.tab) {
                            // For non-last fields: return .ignored so AppKit's natural Tab
                            // traversal moves focus — that's more reliable than a manual
                            // FocusState update in the same event.
                            if selectedSuggestionIndex != nil { selectedSuggestionIndex = nil }
                            guard isLastField else { return .ignored }
                            onLastTab()
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            // Cancel: restore what the user had typed before arrowing
                            selectedSuggestionIndex = nil
                            suffix = committedTypedText
                            return .handled
                        }
                        .onChange(of: suffix) { _, newValue in
                            // If this change was caused by arrow-key selection, don't reset
                            // the selection or the committed text — we set suffix intentionally.
                            if let idx = selectedSuggestionIndex,
                               idx < suggestions.count,
                               suggestions[idx] == newValue { return }
                            // The user typed — reset arrow navigation
                            selectedSuggestionIndex = nil
                            committedTypedText = newValue
                        }
                    Text(".pdf")
                        .foregroundColor(.secondary)
                        .font(.system(.body, design: .monospaced))
                }

                // Validation error
                if let err = suffixError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                // Live filename preview
                if suffixError == nil {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                        Text(finalFileName)
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(isDuplicateSuffix ? .orange : (suffix.isEmpty ? .secondary : .accentColor))
                }

                // Duplicate-name warning — another file has the same name. Only a real
                // collision when no score-order prefix will be added to tell them apart.
                if isDuplicateSuffix {
                    Label(prefixWillDisambiguate
                          ? "Another part has the same name — the score-order prefix will keep the files distinct"
                          : "Another file already uses this name — they'd overwrite each other",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                // ── Autocomplete dropdown ────────────────────────────
                if isFieldFocused && !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.offset) { idx, name in
                            SuggestionButton(
                                label: name,
                                isSelected: selectedSuggestionIndex == idx
                            ) {
                                suffix = name
                                selectedSuggestionIndex = nil
                            }
                            if idx < suggestions.count - 1 {
                                Divider().padding(.leading, 10)
                            }
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                    .frame(maxWidth: 340, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(isFieldFocused ? Color.accentColor.opacity(0.05) : Color.clear)
    }
}

// ── Suggestion button (hover + arrow-key selection highlight) ────────────────
private struct SuggestionButton: View {
    let label: String
    var isSelected: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.20)
                : (isHovered ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Prefix Order Step

/// A single item flowing through the Prefix Order step.
/// For the Splitter, `originalURL` is nil (file not on disk yet).
/// For Bulk Rename, `originalURL` is the current URL of the file to rename.
struct PrefixItem: Identifiable {
    let id: Int              // original zero-based index (stable across reordering)
    let proposedName: String // full filename incl. .pdf, e.g. "Beethoven - Flute.pdf"
    let page: PDFPage?
    var originalURL: URL? = nil
    /// True when the proposed name matched the score (instrument rank 0) — pinned to "00".
    var isScore: Bool = false
    /// Forced number (renamer-style override). Reserved, so auto-numbered items reflow around it.
    var manualNumber: Int? = nil
    /// Excluded from output and from numbering.
    var isSkipped: Bool = false
}

/// One row in PrefixOrderStepView — shows position, thumbnail, proposed name → final name.
private struct PrefixOrderRow: View {
    let item: PrefixItem
    let prefixText: String   // "00"/"01"… or "—" when skipped
    let finalName: String
    let isManual: Bool       // a forced number → orange badge
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    var isUnmatched: Bool = false
    var onToggleSkip: (() -> Void)? = nil
    var onEditPrefix: (() -> Void)? = nil  // called on double-click of the badge

    private var badgeColor: Color {
        item.isSkipped ? .secondary : (isManual ? .orange : .accentColor)
    }

    var body: some View {
        HStack(spacing: 12) {
            // Up / down arrows
            VStack(spacing: 2) {
                Button { onMoveUp?() } label: {
                    Image(systemName: "chevron.up").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(onMoveUp == nil)

                Button { onMoveDown?() } label: {
                    Image(systemName: "chevron.down").font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(onMoveDown == nil)
            }
            .padding(.leading, 8)

            // Number badge — double-click to force a number
            Text(prefixText)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundColor(badgeColor)
                .frame(minWidth: 30, alignment: .center)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isManual ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1)
                )
                .help("Double-click to set a number")
                .gesture(TapGesture(count: 2).onEnded { onEditPrefix?() })

            // Filenames
            VStack(alignment: .leading, spacing: 4) {
                Text(item.proposedName)
                    .font(.body)
                    .lineLimit(1)
                    .strikethrough(item.isSkipped)
                    .foregroundColor(item.isSkipped ? .secondary : .primary)
                if item.isSkipped {
                    Text("Skipped — won't be saved")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(finalName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(isManual ? .orange : .accentColor)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Skip / include toggle
            if let onToggleSkip {
                Button(action: onToggleSkip) {
                    Image(systemName: item.isSkipped ? "arrow.uturn.backward.circle" : "slash.circle")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(item.isSkipped ? "Include this file" : "Skip this file (won't be saved)")
                .padding(.trailing, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isUnmatched && !item.isSkipped ? Color.orange.opacity(0.06) : Color.clear)
    }
}

/// Full-screen step that lets the user set and reorder prefix numbering.
/// Used as Step 3 (Splitter) or Step 2 (Bulk Rename).
struct PrefixOrderStepView: View {
    let stepLabel: String           // "Step 3" or "Step 2"
    let initialItems: [PrefixItem]
    @Binding var ensembleType: EnsembleType
    let onBack: () -> Void
    let onApply: ([PrefixItem]) -> Void  // reordered list; caller handles save

    @State private var items: [PrefixItem]
    /// IDs of items whose proposed name couldn't be matched to the current instrument order.
    @State private var unmatchedIds: Set<Int>
    /// The item whose prefix badge was double-clicked (drives the edit popover).
    @State private var prefixEditTarget: PrefixItem? = nil
    /// The draft prefix text being edited in the popover.
    @State private var prefixEditDraft: String = ""
    @AppStorage("prefixSeparator") private var prefixSeparator: String = " - "

    init(stepLabel: String,
         initialItems: [PrefixItem],
         ensembleType: Binding<EnsembleType>,
         onBack: @escaping () -> Void,
         onApply: @escaping ([PrefixItem]) -> Void) {
        self.stepLabel = stepLabel
        self.initialItems = initialItems
        self._ensembleType = ensembleType
        self.onBack = onBack
        self.onApply = onApply
        let order = InstrumentOrders.getOrder(for: ensembleType.wrappedValue)
        let sorted = Self.autoSorted(initialItems, by: order)
        self._items = State(initialValue: sorted)
        self._unmatchedIds = State(initialValue: Self.computeUnmatchedIds(initialItems, by: order))
    }

    // MARK: Auto-sort helpers

    /// Returns items sorted by instrument order.
    /// Score (rank 0) is pinned first → gets prefix "00".
    /// Other matched items follow in instrument order.
    /// Unmatched items go last (highlighted orange) so they don't displace the score.
    static func autoSorted(_ items: [PrefixItem], by order: [String]) -> [PrefixItem] {
        var score:     [PrefixItem] = []
        var matched:   [(rank: Int, item: PrefixItem)] = []
        var unmatched: [PrefixItem] = []
        for var item in items {
            if let rank = matchInstrumentOrder(in: item.proposedName, order: order) {
                if rank == 0 { item.isScore = true; score.append(item) }
                else { item.isScore = false; matched.append((rank, item)) }
            } else {
                item.isScore = false
                unmatched.append(item)
            }
        }
        return score + matched.sorted { $0.rank < $1.rank }.map(\.item) + unmatched
    }

    /// Returns the set of item IDs whose proposed names don't match any instrument in `order`.
    static func computeUnmatchedIds(_ items: [PrefixItem], by order: [String]) -> Set<Int> {
        Set(items.filter { matchInstrumentOrder(in: $0.proposedName, order: order) == nil }.map(\.id))
    }

    /// id → assigned number for the current ordering (score=0, instruments 1+, skipped omitted).
    private var numbers: [Int: Int] { scoreOrderNumbers(forOrderedItems: items) }

    /// Badge text for an item: "00"/"01"…, or "—" when skipped.
    private func prefixText(for item: PrefixItem) -> String {
        numbers[item.id].map { String(format: "%02d", $0) } ?? "—"
    }

    private func prefixedName(for item: PrefixItem) -> String {
        guard let n = numbers[item.id] else { return item.proposedName }  // skipped — no prefix
        return "\(String(format: "%02d", n))\(prefixSeparator)\(item.proposedName)"
    }

    private func toggleSkip(_ item: PrefixItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isSkipped.toggle()
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar ──────────────────────────────────────────────────
            HStack {
                Spacer()
                Text("\(stepLabel): Prefix Files")
                    .font(.title2).fontWeight(.semibold)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // ── Ensemble type re-sort bar ─────────────────────────────────
            HStack(spacing: 12) {
                Text("Auto-sort by ensemble:")
                    .font(.headline)
                Picker("", selection: $ensembleType) {
                    Text("Wind Band").tag(EnsembleType.band)
                    Text("Jazz Band").tag(EnsembleType.jazz)
                    Text("Orchestra").tag(EnsembleType.orchestra)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .onChange(of: ensembleType) { _, newType in
                    let order = InstrumentOrders.getOrder(for: newType)
                    withAnimation { items = Self.autoSorted(items, by: order) }
                    unmatchedIds = Self.computeUnmatchedIds(items, by: order)
                }
                Button("Re-sort") {
                    let order = InstrumentOrders.getOrder(for: ensembleType)
                    withAnimation { items = Self.autoSorted(items, by: order) }
                    unmatchedIds = Self.computeUnmatchedIds(items, by: order)
                }
                .help("Re-apply instrument order to the current list")
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // ── File list ─────────────────────────────────────────────────
            ScrollView {
                VStack(spacing: 0) {
                    let matchedItems   = items.filter { !unmatchedIds.contains($0.id) }
                    let unmatchedItems = items.filter {  unmatchedIds.contains($0.id) }

                    // ── Matched section (score + auto-detected instruments) ──
                    ForEach(matchedItems, id: \.id) { item in
                        let position   = items.firstIndex(where: { $0.id == item.id })!
                        let sectionIdx = matchedItems.firstIndex(where: { $0.id == item.id })!
                        PrefixOrderRow(
                            item: item,
                            prefixText: prefixText(for: item),
                            finalName: prefixedName(for: item),
                            isManual: item.manualNumber != nil,
                            onMoveUp:   sectionIdx > 0                      ? { items.swapAt(position, position - 1) } : nil,
                            onMoveDown: sectionIdx < matchedItems.count - 1 ? { items.swapAt(position, position + 1) } : nil,
                            onToggleSkip: { toggleSkip(item) },
                            onEditPrefix: { prefixEditTarget = item; prefixEditDraft = item.manualNumber.map(String.init) ?? "\(numbers[item.id] ?? 1)" }
                        )
                        if item.id != matchedItems.last?.id { Divider() }
                    }

                    // ── Unmatched section (instrument not recognised) ──────
                    if !unmatchedItems.isEmpty {
                        if !matchedItems.isEmpty { Divider() }
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("Unmatched — instrument not recognised · double-click the number badge to set a number, or skip the file")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.10))

                        ForEach(unmatchedItems, id: \.id) { item in
                            let position   = items.firstIndex(where: { $0.id == item.id })!
                            let sectionIdx = unmatchedItems.firstIndex(where: { $0.id == item.id })!
                            PrefixOrderRow(
                                item: item,
                                prefixText: prefixText(for: item),
                                finalName: prefixedName(for: item),
                                isManual: item.manualNumber != nil,
                                onMoveUp:   sectionIdx > 0                        ? { items.swapAt(position, position - 1) } : nil,
                                onMoveDown: sectionIdx < unmatchedItems.count - 1 ? { items.swapAt(position, position + 1) } : nil,
                                isUnmatched: true,
                                onToggleSkip: { toggleSkip(item) },
                                onEditPrefix: { prefixEditTarget = item; prefixEditDraft = item.manualNumber.map(String.init) ?? "\(numbers[item.id] ?? 1)" }
                            )
                            if item.id != unmatchedItems.last?.id { Divider() }
                        }
                    }
                }
                .padding(.vertical, 8)
            }

            Divider()

            // ── Bottom bar ────────────────────────────────────────────────
            HStack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button { onApply(items) } label: {
                    Label("Apply & Save", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        // ── Manual number editor (forces a number; others reflow around it) ──
        .sheet(item: $prefixEditTarget) { target in
            PrefixEditSheet(
                fileName: target.proposedName,
                draft: $prefixEditDraft,
                onApply: { value in
                    if let idx = items.firstIndex(where: { $0.id == target.id }) {
                        // A valid integer forces that number; anything else reverts to auto.
                        items[idx].manualNumber = Int(value.trimmingCharacters(in: .whitespaces))
                    }
                    prefixEditTarget = nil
                },
                onClear: {
                    if let idx = items.firstIndex(where: { $0.id == target.id }) {
                        items[idx].manualNumber = nil
                    }
                    prefixEditTarget = nil
                },
                onCancel: { prefixEditTarget = nil }
            )
        }
    }
}

/// Small sheet for forcing a file's score-order number (others reflow around it).
private struct PrefixEditSheet: View {
    let fileName: String
    @Binding var draft: String
    let onApply: (String) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set Number")
                .font(.title2).fontWeight(.semibold)

            Text(fileName)
                .font(.callout)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            VStack(alignment: .leading, spacing: 6) {
                Text("Number (the others reflow around it — leave blank to restore auto-numbering)")
                    .font(.caption).foregroundColor(.secondary)
                TextField("e.g. 1", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { onApply(draft) }
            }

            HStack {
                Button("Clear (use auto)", role: .destructive, action: onClear)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(draft) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { fieldFocused = true }
    }
}

// MARK: - Rename Summary

/// Final screen shown after files are written to disk.
struct RenameSummaryView: View {
    let finalNames: [String]
    /// Non-nil for the Splitter (lets us offer "Show in Finder"). Nil for Bulk Rename.
    let outputFolderURL: URL?
    /// Optional confirmation line shown under the header (e.g. "Original moved to the Trash.").
    var sourceTrashedNote: String? = nil
    let onStartOver: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // ── Success header ────────────────────────────────────────────
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(.green)
                Text("Done!")
                    .font(.title).fontWeight(.bold)
                Text("\(finalNames.count) file\(finalNames.count == 1 ? "" : "s") saved successfully.")
                    .foregroundColor(.secondary)
                if let note = sourceTrashedNote {
                    Label(note, systemImage: "trash")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 36)
            .padding(.bottom, 20)

            Divider()

            // ── File list ─────────────────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(finalNames.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            Image(systemName: "doc.fill")
                                .foregroundColor(.accentColor)
                                .font(.caption)
                            Text(finalNames[i])
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                    }
                }
                .padding()
            }

            Divider()

            // ── Bottom bar ────────────────────────────────────────────────
            HStack {
                if let url = outputFolderURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button(action: onStartOver) {
                    Label("Start Over", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

// MARK: - Page Instrument Preview
struct PageInstrumentPreview: View {
    let page: PDFPage
    /// Pan offset in PDF points from the default top-left position.
    /// Positive y = up the page; negative y = down; positive x = right; negative x = left.
    var offset: CGPoint = .zero

    // Two-phase rendering for performance:
    //   1. Full page rendered ONCE async on appear (expensive PDF draw, background thread).
    //   2. Panning crops from the cached image instantly — no re-render needed.
    @State private var cachedPageImage: NSImage?
    @State private var displayImage: NSImage?

    var body: some View {
        // GeometryReader + top alignment: the crop strip is wider than it is tall, so a
        // plain `.fill` clips the *vertical centre* — cutting the instrument name off the
        // top of the page. Aligning the filled image to the top keeps the page top visible.
        GeometryReader { geo in
            if let img = displayImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    .clipped()
            } else {
                Color.gray.opacity(0.08)
            }
        }
        .task {
            // Render the full page once on a background thread, then extract initial crop.
            let full = await Self.renderFullPageAsync(page: page)
            cachedPageImage = full
            displayImage = Self.cropToStrip(from: full, page: page, offset: .zero)
        }
        .onChange(of: offset) { _, newOffset in
            // Fast path: crop from the cached image — no PDF re-render required.
            displayImage = Self.cropToStrip(from: cachedPageImage, page: page, offset: newOffset)
        }
    }

    // Render the full page at 2× resolution on a background thread.
    // Using thumbnail(of:for:) which correctly respects page rotation.
    private static func renderFullPageAsync(page: PDFPage) async -> NSImage? {
        await withCheckedContinuation { continuation in
            // SAFETY: read-only access only (bounds + thumbnail). Do not mutate p.
            let uncheckedPage = Unchecked(page)
            DispatchQueue.global(qos: .userInitiated).async {
                let p = uncheckedPage.value
                let mediaBox = p.bounds(for: .mediaBox)
                let rotation = ((p.rotation % 360) + 360) % 360
                let scale: CGFloat = 2.0
                let size: NSSize = rotation == 90 || rotation == 270
                    ? NSSize(width: mediaBox.height * scale, height: mediaBox.width * scale)
                    : NSSize(width: mediaBox.width  * scale, height: mediaBox.height * scale)
                continuation.resume(returning: p.thumbnail(of: size, for: .mediaBox))
            }
        }
    }

    // Crop a strip from the cached full-page image.
    // CGImage origin is top-left; PDF origin is bottom-left — Y axis flipped in conversion.
    private static func cropToStrip(from pageImage: NSImage?, page: PDFPage, offset: CGPoint) -> NSImage? {
        guard let pageImage,
              let cg = pageImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let mediaBox = page.bounds(for: .mediaBox)
        let rotation  = ((page.rotation % 360) + 360) % 360
        let pageW = rotation == 90 || rotation == 270 ? mediaBox.height : mediaBox.width
        let pageH = rotation == 90 || rotation == 270 ? mediaBox.width  : mediaBox.height

        let cropH: CGFloat = 100
        let cropW = min(pageW * 0.4, 200)

        // Default anchor: top-left of the page (PDF y = pageH - cropH from the bottom edge).
        let defaultY = pageH - cropH
        let clampedX = min(max(offset.x, 0), pageW - cropW)
        let clampedY = min(max(defaultY + offset.y, 0), defaultY)

        // Convert PDF rect → CGImage pixel rect (flip Y: CGImage y=0 is top of page).
        let sX = CGFloat(cg.width)  / pageW
        let sY = CGFloat(cg.height) / pageH
        let pixRect = CGRect(
            x: (clampedX * sX).rounded(),
            y: ((pageH - clampedY - cropH) * sY).rounded(),
            width:  (cropW * sX).rounded(),
            height: (cropH * sY).rounded()
        )

        guard let cropped = cg.cropping(to: pixRect) else { return nil }
        return NSImage(cgImage: cropped, size: CGSize(width: cropW, height: cropH))
    }
}

// MARK: - Page Crop Overview (minimap)
/// Small thumbnail of the full page with a highlighted rectangle showing where
/// the current crop window sits. Displayed beside the main instrument preview
/// so users can orientate themselves within the page.
struct PageCropOverview: View {
    let page: PDFPage
    var offset: CGPoint = .zero
    /// When set, the minimap is draggable: reports an incremental PDF-point delta to add
    /// to the shared pan offset (direct manipulation — drag the indicator where you want it).
    var onPanBy: ((CGSize) -> Void)? = nil

    /// Fixed display size for the minimap thumbnail.
    private let thumbWidth: CGFloat  = 52
    private let thumbHeight: CGFloat = 70

    @State private var thumbnailImage: NSImage?
    @State private var lastDrag: CGSize = .zero

    /// (pageW, pageH) in PDF points, honouring rotation.
    private var pageDims: (w: CGFloat, h: CGFloat) {
        let mediaBox = page.bounds(for: .mediaBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        return rotation == 90 || rotation == 270
            ? (mediaBox.height, mediaBox.width)
            : (mediaBox.width,  mediaBox.height)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let dims = pageDims
                let dx = (value.translation.width  - lastDrag.width)  * (dims.w / thumbWidth)
                let dy = (value.translation.height - lastDrag.height) * (dims.h / thumbHeight)
                lastDrag = value.translation
                // Drag the indicator: right → window right (+x); down → window down (−y).
                onPanBy?(CGSize(width: dx, height: -dy))
            }
            .onEnded { _ in lastDrag = .zero }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Full-page thumbnail
            Group {
                if let img = thumbnailImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: thumbWidth, height: thumbHeight)
                        .clipped()
                } else {
                    Color.gray.opacity(0.1)
                        .frame(width: thumbWidth, height: thumbHeight)
                }
            }
            .background(Color.white)

            // Crop indicator rectangle overlay
            cropIndicator
        }
        .frame(width: thumbWidth, height: thumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(dragGesture, including: onPanBy == nil ? .subviews : .all)
        .task {
            thumbnailImage = await Self.renderThumbnailAsync(
                page: page,
                width: thumbWidth, height: thumbHeight
            )
        }
    }

    /// Computes the position and size of the highlighted rectangle in the minimap's
    /// coordinate space, mirroring the crop logic in PageInstrumentPreview.
    private var cropIndicator: some View {
        let mediaBox = page.bounds(for: .mediaBox)
        let rotation  = ((page.rotation % 360) + 360) % 360
        let pageW = rotation == 90 || rotation == 270 ? mediaBox.height : mediaBox.width
        let pageH = rotation == 90 || rotation == 270 ? mediaBox.width  : mediaBox.height

        let cropH: CGFloat = 100
        let cropW = min(pageW * 0.4, 200)

        let defaultY = pageH - cropH
        let clampedX = min(max(offset.x, 0), pageW - cropW)
        let clampedY = min(max(defaultY + offset.y, 0), defaultY)

        // Scale from PDF points to thumbnail pixels
        let scaleX = thumbWidth  / pageW
        let scaleY = thumbHeight / pageH

        // PDF y=0 is at page bottom; SwiftUI y=0 is at top — flip
        let rectX = clampedX * scaleX
        let rectY = (pageH - clampedY - cropH) * scaleY
        let rectW = cropW  * scaleX
        let rectH = cropH  * scaleY

        return Rectangle()
            .stroke(Color.accentColor, lineWidth: 1.5)
            .background(Color.accentColor.opacity(0.15))
            .frame(width: max(rectW, 4), height: max(rectH, 4))
            .offset(x: rectX, y: rectY)
    }

    private static func renderThumbnailAsync(
        page: PDFPage, width: CGFloat, height: CGFloat
    ) async -> NSImage? {
        await withCheckedContinuation { continuation in
            // SAFETY: read-only access only (thumbnail). Do not mutate page.
            let uncheckedPage = Unchecked(page)
            DispatchQueue.global(qos: .utility).async {
                let size = NSSize(width: width * 2, height: height * 2)  // 2× for retina
                continuation.resume(returning: uncheckedPage.value.thumbnail(of: size, for: .mediaBox))
            }
        }
    }
}
