//
//  SplitView.swift
//  ScoreSort
//
//  Split PDF tab — Step 1 (SplitView) plus its Step-1 machinery: booklet-reorder
//  UI, A3 split-choice, the booklet-order sheet and the split controls section.
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
        .onAppear { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: appState.selectedTab)     { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: splitStage)               { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: fileSizes)                { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: skippedPages)             { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: pdfManager.pdfDocument)   { DispatchQueue.main.async { syncTabCommands() } }
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
                    StampMenuButton(isEnabled: $stampEnabled, scope: $stampScope)

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
                        case .return:
                            // Advance to naming (same gate as the "Next: Name Files" button).
                            if !(activeFileCount < 1 || (activeFileCount < 2 && skippedPages.isEmpty)) {
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
            let canProceed = loaded && !(activeFileCount < 1 || (activeFileCount < 2 && skippedPages.isEmpty))
            slice.primaryTitle = "Continue to Naming"
            slice.primarySave  = canProceed ? { splitStage = .naming } : nil
            // Always list the actions (disabled until a PDF is loaded) so the menu
            // shows what's possible even in the empty state.
            slice.tabActions = [
                MenuAction(title: "Split as A3\u{2026}", isEnabled: loaded, perform: { showingA3Detection = true }),
                MenuAction(title: "Fix Booklet Order", isEnabled: loaded && canFixBookletOrder, perform: { requestBookletFix() }),
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
                    separator: filenameSeparator,
                    stampJob: activeStampJob
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
            separator: "",
            stampJob: activeStampJob
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
