//
//  ScanSplitSheet.swift
//  ScoreSort
//
//  "Split Double Pages" — the sheet that turns a scan into pages. Every scan is shown
//  with ScoreSort's suggestion: kept whole, or cut in two at the gutter (or at the edge
//  of the black scanner bed), with empty or black pieces marked to skip. The user drags
//  a cut, flips a scan between one page and two, or clicks a piece to skip or keep it.
//
//  Detection lives in Logic/ScanSplitLogic.swift; this file is the review UI and the
//  model that runs the detection off the main actor.
//

import SwiftUI
@preconcurrency import PDFKit
import AppKit
import Combine

/// A pending "split this document's double pages" review.
struct ScanSplitRequest: Identifiable {
    let id = UUID()
    let document: PDFDocument
    /// True when offered automatically on opening the PDF (so "Don't Split" moves on to
    /// the next prompt), false when chosen from the menu.
    let fromLoad: Bool
}

/// What the sheet hands back: how to cut each scan, and which pages of the result to skip.
struct ScanSplitChoice {
    let layouts: [ScanLayout]
    let leftFirst: Bool
    /// Page indices in the split document.
    let skippedPages: Set<Int>
}

// MARK: - Model

@MainActor
final class ScanSplitModel: ObservableObject {
    struct Scan: Identifiable {
        /// Page index in the source document.
        let id: Int
        /// Width ÷ height as the reader sees it; known before the scan is rendered.
        let aspect: CGFloat
        var image: CGImage?
        /// Greyscale copy of `image`, kept to re-check pieces for blanks when a cut moves.
        var gray: GrayImage?
        /// What detection chose.
        var suggested: ScanLayout = .single
        var layout: ScanLayout = .single
        /// Per piece, left to right.
        var skip: [Bool] = [false]
        /// Set once the user clicks a piece; from then on moving the cut leaves the skips alone.
        var skipEdited = false
        var analysed = false
    }

    @Published var scans: [Scan]
    @Published private(set) var analysedCount = 0
    @Published var leftFirst = true
    /// Every scan cut in two at `sharedCut`; dragging any cut moves them all. On by default
    /// for uniform sheets (a flatbed A3 scan), where each page should be split the same way.
    @Published private(set) var sameCutForAll: Bool
    @Published private(set) var sharedCut: Double = 0.5

    private let document: PDFDocument
    private let cancelled = CancelFlag()

    var isAnalysing: Bool { analysedCount < scans.count }

    init(document: PDFDocument) {
        self.document = document
        scans = (0..<document.pageCount).map { i in
            var aspect: CGFloat = 0.7
            if let page = document.page(at: i) {
                let b = page.bounds(for: .cropBox)
                let size = page.rotation % 180 == 0 ? b.size : CGSize(width: b.height, height: b.width)
                if size.height > 0 { aspect = size.width / size.height }
            }
            return Scan(id: i, aspect: aspect)
        }
        sameCutForAll = isUniformSheetScan(document)
        if sameCutForAll {
            for i in scans.indices {
                scans[i].layout = .split(at: sharedCut)
                scans[i].skip = [false, false]
            }
        }
    }

    // MARK: Analysis

    /// One scan's render and detection result, carried back to the main actor.
    private struct Result: @unchecked Sendable {
        let index: Int
        let image: CGImage
        let gray: GrayImage
        let analysis: ScanAnalysis
        let blanks: [BlankKind?]
    }

    /// Thumbnail width in pixels: two points per pixel for cards about 220 points wide.
    nonisolated private static func renderWidth(aspect: CGFloat) -> Int {
        scanAnalysisWidth(aspect: aspect)
    }

    nonisolated private static func analyse(index: Int, source: ScanRenderSource) -> Result? {
        guard let scan = analyseScanSource(source) else { return nil }
        return Result(index: index, image: scan.image, gray: scan.gray, analysis: scan.analysis, blanks: scan.blanks)
    }

    nonisolated private static func analyse(index: Int, image: CGImage, gray: GrayImage) -> Result {
        let scan = analyseScanImage(image, gray: gray)
        return Result(index: index, image: scan.image, gray: scan.gray, analysis: scan.analysis, blanks: scan.blanks)
    }

    /// Renders and analyses every scan, several at once, publishing each as it finishes.
    func start() {
        guard analysedCount == 0 else { return }
        var sources: [(Int, ScanRenderSource)] = []
        var inMemoryPages: [Int] = []
        for i in 0..<document.pageCount {
            if let source = document.page(at: i)?.scanRenderSource {
                sources.append((i, source))
            } else {
                inMemoryPages.append(i)
            }
        }

        let flag = cancelled
        let jobs = sources
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            DispatchQueue.concurrentPerform(iterations: jobs.count) { k in
                guard !flag.isSet else { return }
                let (index, source) = jobs[k]
                let result = Self.analyse(index: index, source: source)
                DispatchQueue.main.async { self?.receive(result, for: index) }
            }
        }

        // Pages built in memory have no Core Graphics page; render those through PDFKit,
        // here, one at a time. (Not the case for anything read from a file.)
        if !inMemoryPages.isEmpty {
            Task { @MainActor [weak self] in
                for index in inMemoryPages {
                    guard let self, !flag.isSet else { return }
                    var result: Result? = nil
                    if let page = self.document.page(at: index) {
                        let w = Self.renderWidth(aspect: self.scans[index].aspect)
                        let thumb = page.thumbnail(of: NSSize(width: w, height: w), for: .cropBox)
                        if let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil),
                           let gray = GrayImage(cg) {
                            result = Self.analyse(index: index, image: cg, gray: gray)
                        }
                    }
                    self.receive(result, for: index)
                    await Task.yield()
                }
            }
        }
    }

    func cancel() { cancelled.set() }

    private func receive(_ result: Result?, for index: Int) {
        guard scans.indices.contains(index), !scans[index].analysed else { return }
        if let result {
            scans[index].image = result.image
            scans[index].gray = result.gray
            scans[index].suggested = result.analysis.layout
            if sameCutForAll {
                // Keep the shared cut; only the blank check comes from the analysis.
                scans[index].layout = .split(at: sharedCut)
                refreshSkips(scan: index)
            } else {
                scans[index].layout = result.analysis.layout
                scans[index].skip = result.blanks.map { $0 != nil }
            }
        }
        // A scan that couldn't be rendered stays whole and unskipped.
        scans[index].analysed = true
        analysedCount += 1
    }

    // MARK: Editing

    /// Switches between one cut shared by every scan and each scan's own suggestion.
    /// Skips are re-suggested either way, since every piece may have changed.
    func setSameCutForAll(_ on: Bool) {
        guard on != sameCutForAll else { return }
        sameCutForAll = on
        for i in scans.indices {
            scans[i].layout = on ? .split(at: sharedCut) : scans[i].suggested
            scans[i].skipEdited = false
            refreshSkips(scan: i)
        }
    }

    /// Keep a scan whole, or cut it in two (where detection suggested, else down the middle).
    /// Not available while every scan shares one cut.
    func setTwoPages(_ two: Bool, scan id: Int) {
        guard scans.indices.contains(id), !sameCutForAll else { return }
        if two {
            if case .split = scans[id].layout { return }
            if case .split = scans[id].suggested {
                scans[id].layout = scans[id].suggested
            } else {
                scans[id].layout = .split(at: 0.5)
            }
        } else {
            scans[id].layout = .single
        }
        scans[id].skipEdited = false
        refreshSkips(scan: id)
    }

    /// Moves a scan's cut. Pass `final: true` when the drag ends, to re-check for blanks.
    /// With the same cut for all, moving any scan's cut moves every one.
    func moveCut(to fraction: Double, scan id: Int, final: Bool) {
        guard scans.indices.contains(id) else { return }
        let f = min(max(fraction, 0.03), 0.97)
        if sameCutForAll {
            sharedCut = f
            for i in scans.indices {
                scans[i].layout = .split(at: f)
                if final { refreshSkips(scan: i) }
            }
        } else {
            scans[id].layout = .split(at: f)
            if final { refreshSkips(scan: id) }
        }
    }

    func toggleSkip(piece: Int, scan id: Int) {
        guard scans.indices.contains(id), scans[id].skip.indices.contains(piece) else { return }
        scans[id].skip[piece].toggle()
        scans[id].skipEdited = true
    }

    /// Re-suggests skips after the pieces change, unless the user has chosen them.
    private func refreshSkips(scan id: Int) {
        let pieces = scans[id].layout.pieceCount
        guard !scans[id].skipEdited, let gray = scans[id].gray else {
            if scans[id].skip.count != pieces { scans[id].skip = Array(repeating: false, count: pieces) }
            return
        }
        scans[id].skip = blankPieces(gray, layout: scans[id].layout).map { $0 != nil }
    }

    // MARK: Result

    var layouts: [ScanLayout] { scans.map(\.layout) }

    /// The page number (1-based) each piece will have, scan by scan, left to right.
    var pageNumbers: [[Int]] {
        scanPieceOutputIndices(layouts: layouts, leftFirst: leftFirst).map { $0.map { $0 + 1 } }
    }

    var pageCount: Int { scans.reduce(0) { $0 + $1.layout.pieceCount } }
    var skippedCount: Int { scans.reduce(0) { $0 + $1.skip.filter { $0 }.count } }
    var splitCount: Int { scans.filter { $0.layout.pieceCount == 2 }.count }

    var choice: ScanSplitChoice {
        let indices = scanPieceOutputIndices(layouts: layouts, leftFirst: leftFirst)
        var skipped = Set<Int>()
        for (scan, pieces) in zip(scans, indices) {
            for (k, page) in pieces.enumerated() where k < scan.skip.count && scan.skip[k] {
                skipped.insert(page)
            }
        }
        return ScanSplitChoice(layouts: layouts, leftFirst: leftFirst, skippedPages: skipped)
    }
}

/// A thread-safe "stop" flag for the background analysis.
nonisolated final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

// MARK: - Sheet

struct ScanSplitSheet: View {
    let request: ScanSplitRequest
    let onSplit: (ScanSplitChoice) -> Void
    let onCancel: () -> Void

    @StateObject private var model: ScanSplitModel

    init(request: ScanSplitRequest,
         onSplit: @escaping (ScanSplitChoice) -> Void,
         onCancel: @escaping () -> Void) {
        self.request = request
        self.onSplit = onSplit
        self.onCancel = onCancel
        _model = StateObject(wrappedValue: ScanSplitModel(document: request.document))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 14)],
                          spacing: 14) {
                    ForEach(model.scans) { scan in
                        ScanSplitCard(scan: scan,
                                      pageNumbers: model.pageNumbers[scan.id],
                                      model: model)
                    }
                }
                .padding(16)
            }
            .background(Color(NSColor.underPageBackgroundColor))
            Divider()
            footer
        }
        .frame(width: 960, height: 700)
        .onAppear { model.start() }
        .onDisappear { model.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Split Double Pages")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Toggle("Same cut on every page", isOn: Binding(
                    get: { model.sameCutForAll },
                    set: { model.setSameCutForAll($0) }))
                    .toggleStyle(.checkbox)
                    .help("Cut every scan in two at the same place — for scans of identical sheets, such as A3 or tabloid")
                    .padding(.trailing, 12)
                Picker("First page:", selection: $model.leftFirst) {
                    Text("Left").tag(true)
                    Text("Right").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Which side of a two-page scan comes first")
            }
            Text(model.sameCutForAll
                 ? "Every scan is cut in two at the same place — down the middle unless you drag a cut line, which moves them all. Black or empty pages are marked to skip; click a page to skip or keep it. Skipped pages stay in Step 1, greyed out, in case you need one back."
                 : "ScoreSort has cut each two-page scan at the gap between its pages, and marked black or empty pages to skip. Drag a cut line to move it, or click a page to skip or keep it. Skipped pages stay in Step 1, greyed out, in case you need one back.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isAnalysing {
                ProgressView(value: Double(model.analysedCount), total: Double(max(1, model.scans.count)))
                    .frame(width: 120)
                Text("Checking scan \(min(model.analysedCount + 1, model.scans.count)) of \(model.scans.count)…")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            } else {
                Text(summary)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Don't Split") { onCancel() }
                .keyboardShortcut(.cancelAction)
                .help("Leave every scan as it is")
            Button("Split Pages") { onSplit(model.choice) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isAnalysing)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var summary: String {
        let scans = model.scans.count
        var text = "\(scans) \(scans == 1 ? "scan" : "scans") → \(model.pageCount) pages"
        if model.skippedCount > 0 { text += ", \(model.skippedCount) skipped" }
        return text
    }
}

// MARK: - Card

/// One scan: its preview with the cut and skipped pieces drawn on, and a One/Two Pages switch.
private struct ScanSplitCard: View {
    let scan: ScanSplitModel.Scan
    let pageNumbers: [Int]
    @ObservedObject var model: ScanSplitModel

    private var isTwoPages: Bool { scan.layout.pieceCount == 2 }

    private func layoutButton(two: Bool, symbol: String, help: String) -> some View {
        let selected = isTwoPages == two
        return Button {
            model.setTwoPages(two, scan: scan.id)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 18)
                .foregroundColor(selected ? .primary : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected ? Color(NSColor.controlColor) : Color.clear)
                        .shadow(color: .black.opacity(selected ? 0.18 : 0), radius: 0.5, y: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(two ? "Two pages" : "One page")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var body: some View {
        VStack(spacing: 8) {
            ScanSplitPreview(scan: scan, pageNumbers: pageNumbers, model: model)
                .frame(height: 170)
                .frame(maxWidth: .infinity)

            HStack {
                Text("Scan \(scan.id + 1)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                Spacer()
                // Two plain buttons drawn as a segmented switch. Not a segmented Picker: an
                // NSSegmentedControl in every card of this lazy grid crashed inside AppKit
                // (-[NSSegmentedCell _segmentsDeselectedBySegment:]) as the grid recycled cards.
                let locked = !scan.analysed || model.sameCutForAll
                HStack(spacing: 1) {
                    layoutButton(two: false, symbol: "rectangle.portrait",
                                 help: "One page — keep this scan whole")
                    layoutButton(two: true, symbol: "rectangle.split.2x1",
                                 help: "Two pages — cut this scan in two")
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.14)))
                .disabled(locked)
                .opacity(locked ? 0.5 : 1)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
    }
}

/// The scan itself. Drag near the cut to move it; click a piece to skip or keep it.
private struct ScanSplitPreview: View {
    let scan: ScanSplitModel.Scan
    let pageNumbers: [Int]
    @ObservedObject var model: ScanSplitModel

    /// Set while the cut is being dragged.
    @State private var draggingCut = false
    @State private var cursorPushed = false

    /// How close (points) to the cut a press has to be to grab it.
    private let grabDistance: CGFloat = 10

    var body: some View {
        Group {
            if let image = scan.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay { GeometryReader { geo in overlays(in: geo.size) } }
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .aspectRatio(scan.aspect, contentMode: .fit)
                    .overlay {
                        if scan.analysed {
                            Image(systemName: "exclamationmark.triangle").foregroundColor(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
    }

    private var cutFraction: Double? {
        if case .split(let f) = scan.layout { return f }
        return nil
    }

    @ViewBuilder
    private func overlays(in size: CGSize) -> some View {
        let ranges = scan.layout.pieceRanges
        ZStack(alignment: .topLeading) {
            ForEach(Array(ranges.enumerated()), id: \.offset) { k, range in
                let x0 = CGFloat(range.lowerBound) * size.width
                let w = CGFloat(range.upperBound - range.lowerBound) * size.width
                let skipped = k < scan.skip.count && scan.skip[k]
                pieceOverlay(skipped: skipped, number: k < pageNumbers.count ? pageNumbers[k] : nil)
                    .frame(width: w, height: size.height)
                    .offset(x: x0)
            }
            if let f = cutFraction {
                cutLine(height: size.height)
                    .offset(x: CGFloat(f) * size.width - 7)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(dragOrClick(in: size))
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                setResizeCursor(near(point.x, width: size.width) || draggingCut)
            case .ended:
                if !draggingCut { setResizeCursor(false) }
            }
        }
        .onDisappear { setResizeCursor(false) }
    }

    private func pieceOverlay(skipped: Bool, number: Int?) -> some View {
        ZStack {
            if skipped {
                Rectangle().fill(Color.red.opacity(0.28))
                // Just the icon on a piece too narrow for the word.
                ViewThatFits(in: .horizontal) {
                    Label("Skip", systemImage: "eye.slash")
                        .fixedSize()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.horizontal, 4)
                    Image(systemName: "eye.slash")
                        .padding(4)
                        .background(.regularMaterial, in: Circle())
                }
                .font(.caption.weight(.semibold))
            }
            if let number {
                VStack {
                    Spacer()
                    Text("\(number)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 4)
                }
            }
        }
    }

    private func cutLine(height: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2, height: height)
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 8, height: 26)
                .overlay(Capsule().stroke(Color.white, lineWidth: 1.5))
        }
        .frame(width: 14, height: height)
        .allowsHitTesting(false)
    }

    private func near(_ x: CGFloat, width: CGFloat) -> Bool {
        guard let f = cutFraction else { return false }
        return abs(x - CGFloat(f) * width) <= grabDistance
    }

    /// One gesture for both: a press on the cut drags it; a click anywhere else toggles
    /// the piece under it. (Two separate gestures fight over the same clicks.)
    private func dragOrClick(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !draggingCut && near(value.startLocation.x, width: size.width) {
                    draggingCut = true
                }
                if draggingCut, size.width > 0 {
                    model.moveCut(to: Double(value.location.x / size.width), scan: scan.id, final: false)
                }
            }
            .onEnded { value in
                defer { draggingCut = false }
                if draggingCut {
                    if size.width > 0 {
                        model.moveCut(to: Double(value.location.x / size.width), scan: scan.id, final: true)
                    }
                    return
                }
                let moved = hypot(value.translation.width, value.translation.height)
                guard moved < 4, size.width > 0 else { return }
                let f = Double(value.location.x / size.width)
                let piece = scan.layout.pieceRanges.firstIndex { $0.contains(f) } ?? 0
                model.toggleSkip(piece: piece, scan: scan.id)
            }
    }

    private func setResizeCursor(_ on: Bool) {
        if on && !cursorPushed {
            NSCursor.resizeLeftRight.push()
            cursorPushed = true
        } else if !on && cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}
