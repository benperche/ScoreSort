//
//  SplitPrefixStep.swift
//  ScoreSort
//
//  Split PDF tab — Step 3 (score-order prefixing) plus the rename summary and the
//  shared page-preview views (PageInstrumentPreview, page-crop minimap). The prefix
//  step and these previews are also used by Bulk Rename.
//

import SwiftUI
@preconcurrency import PDFKit
import UniformTypeIdentifiers
import Combine

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
    /// The tool this step belongs to — shown as the header, with `stepLabel` beneath it.
    let toolTitle: String           // "Split PDF" or "Bulk Part Rename"
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

    init(toolTitle: String,
         stepLabel: String,
         initialItems: [PrefixItem],
         ensembleType: Binding<EnsembleType>,
         onBack: @escaping () -> Void,
         onApply: @escaping ([PrefixItem]) -> Void) {
        self.toolTitle = toolTitle
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

    /// Promotes an unrecognised file into the matched section (so it gets a score-order
    /// number), placing it at the bottom of the matched list. Triggered by pressing the
    /// up-arrow on the top unmatched row.
    private func promoteToMatched(_ item: PrefixItem) {
        guard unmatchedIds.contains(item.id),
              let from = items.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation {
            unmatchedIds.remove(item.id)
            let moved = items.remove(at: from)
            let insertAt = (items.lastIndex { !unmatchedIds.contains($0.id) }).map { $0 + 1 } ?? 0
            items.insert(moved, at: insertAt)
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar ──────────────────────────────────────────────────
            HStack {
                // Same header shape as the other steps: the tool, with the step beneath it.
                VStack(alignment: .leading, spacing: 1) {
                    Text(toolTitle)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("\(stepLabel) — prefix files")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .fixedSize()

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
                                // Top unmatched row's up-arrow promotes it into the matched section.
                                onMoveUp:   sectionIdx > 0                        ? { items.swapAt(position, position - 1) } : { promoteToMatched(item) },
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
                .keyboardShortcut(.defaultAction)   // Return applies & moves to the save dialog
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
        // Escape goes back one step (Step 3 → Step 2 for the splitter; back to the
        // base step for Bulk Rename). A focused text field consumes Escape first.
        .onExitCommand { onBack() }
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
