//
//  SplitNaming.swift
//  ScoreSort
//
//  Split PDF tab — Step 2 (naming): the file preview card, the naming stage and
//  the per-file naming row where instrument names are entered/suggested.
//

import SwiftUI
@preconcurrency import PDFKit
import UniformTypeIdentifiers
import Combine

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
    @AppStorage("splitStampEnabled") private var stampEnabled: Bool = false

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
        splitSuggestionOrder(for: prefixEnsembleType)
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

                StampOptionRow(isEnabled: $stampEnabled)

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
        // Escape goes back one step. A focused text field consumes Escape first
        // (cancelling its edit), so this only fires when you're not typing.
        .onExitCommand { onBack() }
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

            // After a lead/solo part ("Solo Alto Sax") the section's numbered parts usually
            // follow, so suggest the plain instrument at part 1 ("Alto Saxophone 1").
            if let afterSolo = splitSuggestionAfterSolo(prev: prev, instrumentNames: instrumentNames, ensemble: ensemble) {
                return afterSolo
            }

            let parts = prev.components(separatedBy: " ")
            if parts.count >= 2, let last = parts.last, let n = Int(last), n > 0 {
                let basePart = parts.dropLast().joined(separator: " ")
                if n < splitSuggestionTypicalPartCount(basePart, ensemble: ensemble) {
                    // Same family, next part — preserve the user's sax style.
                    return "\(basePart) \(n + 1)"
                }
            }
            // Complete instrument (a numbered part at/over its count, or a bare single-part
            // instrument like "Baritone Saxophone") → cross to the next instrument.
            if let cross = splitSuggestionStartingNumberedName(
                prevSuffix: prev, instrumentNames: instrumentNames, ensemble: ensemble) {
                return cross
            }
            break  // only consider the closest non-empty row
        }
        return nil
    }

    /// The closest non-empty part name in the rows above this one.
    private var nearestPreviousSuffix: String? {
        for i in Swift.stride(from: fileIndex - 1, through: 0, by: -1) {
            let prev = (allSuffixes[i] ?? "").trimmingCharacters(in: .whitespaces)
            if !prev.isEmpty { return prev }
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
            // Right after a solo, keep the other solo options visible in the default list
            // (paired with the numbered "Alto Saxophone 1" that numberedSuggestion prepends).
            if nearestPreviousSuffix?.lowercased().hasPrefix("solo") == true {
                result = Array((splitSuggestionExtraOptions(for: ensemble) + deduplicated).prefix(8))
            } else {
                result = Array(deduplicated.prefix(8))
            }
        } else {
            let q = queryText.lowercased()
            // While typing, also offer the "solo" options (jazz) — they're excluded from
            // the empty-field default and the auto-next walk, but surface when searched.
            let pool = deduplicated + splitSuggestionExtraOptions(for: ensemble)
            let prefixMatches   = pool.filter { $0.lowercased().hasPrefix(q) }
            let containsMatches = pool.filter {
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
