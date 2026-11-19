//
//  CombineTab.swift
//  ScoreSort
//
//  The Combine PDFs tab's main view, CombineView: the file list, keyboard handling, the
//  menu bridge and applying a preset. The rest of the tab is beside it in Combine/:
//  CombineManager.swift (the data layer), EnsemblePresetStore.swift, PresetViews.swift,
//  CombineRows.swift, BookletSetupViews.swift, BookletLayoutSheet.swift, CombineQuickLook.swift.
//

import SwiftUI
@preconcurrency import PDFKit
import UniformTypeIdentifiers
import Combine

// MARK: - Combine View
struct CombineView: View {
    @Binding var showingKeyboardHelp: Bool
    let menuState: CombineMenuState
    @EnvironmentObject var presetStore: EnsemblePresetStore
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject var stampStore: StampStore
    @StateObject private var combineManager = CombineManager()
    @State private var addBlankPages = false
    @AppStorage("combineLayout") private var layout: CombineLayout = .singlePages
    @AppStorage("combineBookletSheetSize") private var bookletSheetSize: BookletSheetSize = .doubleSize
    /// Stored as whole percent so the stepper and text field agree exactly — a Double would
    /// drift and start showing 102.99999%.
    @AppStorage("combineBookletScalePercent") private var bookletScalePercent = 100
    @AppStorage("combineSingleSided") private var singleSided = false
    /// Not `@AppStorage`: the answer belongs to the printer, not the app, so it's loaded from
    /// `BookletDuplexDefaults` for whichever printer is currently the default.
    @State private var duplexFlip: BookletDuplexFlip = .longEdge
    @State private var activeSheet: CombineSheet?
    @State private var showBookletLayout = false
    /// Index into `quickLookFiles` while the Quick Look overlay is up; nil when it isn't.
    @State private var quickLookIndex: Int?
    /// Shown once, the first time anyone switches to Booklet — which catches people who
    /// upgraded as well as new users, unlike the welcome tour.
    @AppStorage("combineBookletIntroShown") private var bookletIntroShown = false
    @AppStorage("combineStampEnabled") private var stampEnabled = false
    @AppStorage("combineStampScope") private var stampScope: StampScope = .firstPageOfEachPart
    @State private var isTargeted = false
    @State private var selectedFiles: Set<UUID> = []
    @State private var removalNoticeVisible = false
    @State private var removalNoticeCount = 1
    @State private var focusedFileId: UUID?     // keyboard navigation cursor
    @State private var anchorFileId: UUID?      // anchor for shift-range selection
    @State private var showPresetSidebar = false
    @State private var unmatchedFileIds: Set<UUID> = []
    /// Files whose copy count the app divided up rather than read straight off the preset —
    /// tinted so a guessed split is distinguishable from a number the preset actually stated.
    @State private var splitCopyFileIds: Set<UUID> = []
    /// Drag-to-reorder: the (group-snapped) row id an insertion line is shown above,
    /// or `.endOfList` when hovering the trailing drop zone. Nil when not dragging.
    @State private var dropTargetId: UUID?
    @State private var isDropAtEnd = false
    /// Drag-to-reorder: the collate group whose body is hovered (drop = add to group).
    @State private var mergeTargetGroupId: UUID?
    @FocusState private var listFocused: Bool
    /// Local key monitor for delete/backspace (see .onAppear).
    @State private var combineKeyMonitor: Any?
    @Environment(\.undoManager) var undoManager
    
    var body: some View {
        HStack(spacing: 0) {
            mainContent
            if showPresetSidebar {
                Divider()
                PresetSidebarView(onApply: applyPreset)
                    .frame(width: 260)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .overlay {
            if showBookletLayout {
                ZStack {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .onTapGesture { showBookletLayout = false }
                        .transition(.opacity)

                    BookletLayoutReviewView(
                        files: combineManager.files.filter { !$0.isBlankPage },
                        onSet: { id, newLayout in
                            combineManager.setBookletLayout(newLayout, for: [id],
                                                            undoManager: undoManager)
                        },
                        onApplyToAll: { newLayout, current in
                            combineManager.applyBookletLayoutToUndecided(newLayout,
                                                                         including: current,
                                                                         undoManager: undoManager)
                        },
                        onClose: { showBookletLayout = false })
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))

                    Button("") { showBookletLayout = false }
                        .keyboardShortcut(.cancelAction)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                }
            }
        }
        .overlay {
            if let index = quickLookIndex {
                ZStack {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .onTapGesture { quickLookIndex = nil }
                        .transition(.opacity)

                    CombineQuickLookView(
                        files: quickLookFiles,
                        // Reads quickLookIndex, not the `index` unwrapped above: the key monitor
                        // captures this view once, so a binding over a captured constant would
                        // keep computing every step from the index the preview opened on.
                        index: Binding(get: { quickLookIndex ?? index },
                                       set: { quickLookIndex = $0 }),
                        onClose: { quickLookIndex = nil })
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))

                    Button("") { quickLookIndex = nil }
                        .keyboardShortcut(.cancelAction)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                }
            }
        }
        .onChange(of: quickLookIndex) { _, shown in
            menuState.isPanelOpen = shown != nil
            guard shown != nil else { returnFocusToList(); return }
            // Keep the list in step with what's being previewed, the way arrowing through Quick
            // Look moves the selection in Finder. Otherwise closing it drops you back wherever
            // you started, and the arrow keys appear to do nothing.
            guard let shown, quickLookFiles.indices.contains(shown) else { return }
            let id = quickLookFiles[shown].id
            selectedFiles = [id]
            focusedFileId = id
            anchorFileId = id
        }
        .animation(.easeInOut(duration: 0.12), value: quickLookIndex)
        .animation(.easeInOut(duration: 0.15), value: showBookletLayout)
        // The ⌫ monitor is app-global, so without this it would still be deleting files from the
        // list behind the overlay. isPanelOpen is the existing flag for "a panel owns the keys".
        .onChange(of: showBookletLayout) { _, shown in
            menuState.isPanelOpen = shown
            if !shown { returnFocusToList() }
        }
        .animation(.easeInOut(duration: 0.2), value: showPresetSidebar)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
        .onAppear {
            DispatchQueue.main.async { syncMenuClosures(); syncMenuFlags(); syncTabCommands() }
            installKeyMonitor()
            loadDuplexFlipForCurrentPrinter()
        }
        // One sheet(item:) for both — two .sheet modifiers on the same view fight over
        // presentation, and the intro hands straight over to the wizard. item: rather than
        // isPresented: per the blank-sheet gotcha that bit ManualAssignmentView.
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .bookletIntro:
                BookletIntroView(
                    printerName: BookletDuplexDefaults.currentPrinterName,
                    onPrint: {
                        activeSheet = nil
                        // Let each sheet finish dismissing before the next goes up, and print
                        // only once the wizard owns the window — the print dialog is presented
                        // on keyWindow.
                        DispatchQueue.main.async {
                            activeSheet = .duplexSetup(startAtCheck: true)
                            DispatchQueue.main.async { printCalibrationSheet() }
                        }
                    },
                    onClose: { activeSheet = nil })
            case .duplexSetup(let startAtCheck):
                BookletDuplexSetupView(flip: $duplexFlip,
                                       printerName: BookletDuplexDefaults.currentPrinterName,
                                       startAtCheck: startAtCheck,
                                       onPrint: printCalibrationSheet,
                                       onClose: { activeSheet = nil })
            }
        }
        // The first time someone chooses Booklet — before any paper is at stake, and while
        // they're forming the intent rather than halfway through a print job.
        .onChange(of: layout) { _, new in
            guard new == .booklet, !bookletIntroShown else { return }
            bookletIntroShown = true
            activeSheet = .bookletIntro
        }
        .onDisappear {
            if let m = combineKeyMonitor { NSEvent.removeMonitor(m) }
            combineKeyMonitor = nil
        }
        .onChange(of: selectedFiles)          { DispatchQueue.main.async { syncMenuFlags(); syncTabCommands() } }
        .onChange(of: combineManager.files)   { DispatchQueue.main.async { syncMenuFlags(); syncTabCommands() } }
        // Re-publish the moment Combine becomes (or stops being) the active tab.
        .onChange(of: appState.selectedTab)   {
            DispatchQueue.main.async { syncMenuFlags(); syncTabCommands() }
            // Also the cheapest moment to notice the default printer changed since last time —
            // the answer is per-printer, and someone who works at two sites shouldn't have to
            // remember which way this was set.
            loadDuplexFlipForCurrentPrinter()
        }
        .onChange(of: duplexFlip) { _, new in
            BookletDuplexDefaults.setFlip(new, forPrinter: BookletDuplexDefaults.currentPrinterName)
        }
    }

    /// The parts Quick Look can show: blank-page entries are synthetic and have no file behind
    /// them, so they're skipped rather than opening an empty panel.
    private var quickLookFiles: [CombineFile] {
        combineManager.files.filter { !$0.isBlankPage }
    }

    /// Opens Quick Look on the cursor row, or the first selected row, or the first part.
    /// Returns false when there's nothing to show, so the key falls through untouched.
    private func openQuickLook() -> Bool {
        let candidates = quickLookFiles
        guard !candidates.isEmpty else { return false }
        let wanted = focusedFileId ?? selectedFiles.first
        quickLookIndex = wanted.flatMap { id in candidates.firstIndex { $0.id == id } } ?? 0
        return true
    }

    /// Hands the keyboard back to the file list after an overlay closes.
    ///
    /// Both overlays take focus away — Quick Look's preview has to own first responder to scroll
    /// at all — and nothing gives it back on the way out, so the list stops hearing Space and the
    /// arrows until it's clicked. Deferred a runloop turn so the overlay has finished tearing
    /// down before the focus is claimed.
    private func returnFocusToList() {
        DispatchQueue.main.async { listFocused = true }
    }

    private func loadDuplexFlipForCurrentPrinter() {
        duplexFlip = BookletDuplexDefaults.flip(forPrinter: BookletDuplexDefaults.currentPrinterName)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack {
                Text("Combine PDFs")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                // Ahead of the working controls rather than in among them: it's a quiet help
                // affordance, and the only plain-styled thing here — sitting between two
                // bordered buttons it read as a gap in the row.
                Button(action: { showingKeyboardHelp = true }) {
                    Image(systemName: "keyboard")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Keyboard Shortcuts")

                StampMenuButton(isEnabled: $stampEnabled, scope: $stampScope)

                // A Toggle rather than a Button: the sidebar is either showing or not, and the
                // .button style gives it the same bordered chrome as the Stamp menu and Clear
                // Files either side of it, plus a filled state while the panel is open — which
                // the old plain style could only hint at with a tint.
                Toggle(isOn: $showPresetSidebar) {
                    Label("Presets", systemImage: "sidebar.right")
                }
                .toggleStyle(.button)
                // The panel slides, but the button shouldn't fade with it: the `.animation` on
                // the outer HStack covers this whole subtree, so without opting out the accent
                // fill cross-fades over the same 0.2s and lingers after the click.
                .animation(nil, value: showPresetSidebar)
                .help(showPresetSidebar ? "Hide Presets" : "Show Presets")

                if !combineManager.files.isEmpty {
                    Button(action: { combineManager.clearAll(undoManager: undoManager) }) {
                        Label("Clear Files", systemImage: "xmark.circle.fill")
                    }
                    .help("Remove all files and start over")
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Main content area
            if combineManager.files.isEmpty {
                // Empty state - drop zone
                emptyStateView
            } else {
                // File list
                VStack(spacing: 0) {
                    // Control buttons
                    HStack {
                        Button(action: selectFiles) {
                            Label("Add Files", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)

                        Button(action: addBlankPage) {
                            Label("Add Blank Page", systemImage: "doc.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .help("Insert a blank A4 page after the selected file (or at the end)")

                        Button(action: removeSelected) {
                            Label("Remove", systemImage: "minus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedFiles.isEmpty)
                        
                        Divider()
                            .frame(height: 20)
                        
                        Button(action: moveUp) {
                            Label("Move Up", systemImage: "arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canMoveUp)
                        
                        Button(action: moveDown) {
                            Label("Move Down", systemImage: "arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canMoveDown)

                        Divider()
                            .frame(height: 20)

                        Button(action: groupSelected) {
                            Label("Collate", systemImage: "rectangle.stack")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canGroup)
                        .help("Group selected files into a collate set — copies of the whole set are printed interleaved (C)")

                        Divider()
                            .frame(height: 20)

                        Button(action: selectAll) {
                            Text("Select All")
                        }
                        .buttonStyle(.bordered)
                        
                        Button(action: selectNone) {
                            Text("Select None")
                        }
                        .buttonStyle(.bordered)
                        
                        Spacer()
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    
                    Divider()
                    
                    // Column headers
                    HStack {
                        Text("Name")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .font(.headline)
                        
                        Text("Pages")
                            .frame(width: 80, alignment: .center)
                            .font(.headline)

                        if layout == .booklet {
                            Text("Opens to")
                                .frame(width: 150, alignment: .center)
                                .font(.headline)
                        }
                        
                        Text("# Copies")
                            .frame(width: 100, alignment: .center)
                            .font(.headline)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.controlBackgroundColor))
                    
                    Divider()
                    
                    // File list — focusable so arrow-key navigation works after a click
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(combineManager.files) { file in
                                let isGroupFirst = file.collateGroupId.map { gid in
                                    combineManager.files.first(where: { $0.collateGroupId == gid })?.id == file.id
                                } ?? false
                                VStack(spacing: 0) {
                                    // If this file is the first member of a collate group,
                                    // emit a group header row before it. The header is a
                                    // *reorder* drop target (lands above the group), while
                                    // the member rows below merge dropped files into it.
                                    if isGroupFirst, let gid = file.collateGroupId,
                                       let group = combineManager.collateGroups[gid] {
                                        let groupFiles = combineManager.files.filter { $0.collateGroupId == gid }
                                        CollateGroupHeaderRow(
                                            group: group,
                                            fileCount: groupFiles.count,
                                            totalPages: groupFiles.reduce(0) { $0 + $1.pageCount },
                                            isMergeTarget: mergeTargetGroupId == gid,
                                            onCopiesChanged: { newValue in
                                                combineManager.updateGroupCopies(id: gid, copies: newValue, undoManager: undoManager)
                                            },
                                            onUngroup: {
                                                combineManager.dissolveGroup(id: gid, undoManager: undoManager)
                                            }
                                        )
                                        .draggable(file.id.uuidString) { dragPreview(for: file) }
                                        .overlay(alignment: .top) { insertionLine(visible: dropTargetId == file.id) }
                                        .dropDestination(for: String.self) { items, _ in
                                            handleReorderDrop(items, onto: file.id)
                                        } isTargeted: { setReorderTarget(file.id, $0) }
                                        Divider()
                                    }
                                    CombineFileRow(
                                        file: file,
                                        isSelected: selectedFiles.contains(file.id),
                                        isFocused: focusedFileId == file.id,
                                        isUnmatched: unmatchedFileIds.contains(file.id),
                                        hasSplitCopies: splitCopyFileIds.contains(file.id),
                                        isGrouped: file.collateGroupId != nil,
                                        isLastInGroup: isLastInGroup(file),
                                        isMergeTarget: file.collateGroupId != nil && mergeTargetGroupId == file.collateGroupId,
                                        onToggleSelect: { toggleSelection(file.id) },
                                        onRowTap: { selectFile(file.id) },
                                        onCopiesChanged: { newValue in
                                            combineManager.updateCopies(for: file.id, copies: newValue, undoManager: undoManager)
                                        },
                                        onRemove: {
                                            selectedFiles.remove(file.id)
                                            unmatchedFileIds.remove(file.id)
                                            splitCopyFileIds.remove(file.id)
                                            combineManager.removeFiles(ids: [file.id], undoManager: undoManager)
                                            showRemovalNotice(undoManager: undoManager)
                                        },
                                        showsBookletLayout: layout == .booklet,
                                        onBookletLayoutChanged: { newLayout in
                                            // Applies to the whole selection when this row is part
                                            // of it, so a whole chart can be set in one go.
                                            let targets = selectedFiles.contains(file.id)
                                                ? selectedFiles : [file.id]
                                            combineManager.setBookletLayout(newLayout, for: targets,
                                                                            undoManager: undoManager)
                                        }
                                    )
                                    .draggable(file.id.uuidString) { dragPreview(for: file) }
                                    .overlay(alignment: .top) {
                                        // Ungrouped rows show a reorder insertion line; grouped
                                        // member rows use the whole-group merge highlight instead.
                                        insertionLine(visible: file.collateGroupId == nil && dropTargetId == file.id)
                                    }
                                    .dropDestination(for: String.self) { items, _ in
                                        if let gid = file.collateGroupId {
                                            return handleAddToGroup(items, groupId: gid)
                                        }
                                        return handleReorderDrop(items, onto: file.id)
                                    } isTargeted: { targeted in
                                        if let gid = file.collateGroupId {
                                            if targeted { mergeTargetGroupId = gid; dropTargetId = nil }
                                            else if mergeTargetGroupId == gid { mergeTargetGroupId = nil }
                                        } else {
                                            setReorderTarget(file.id, targeted)
                                        }
                                    }
                                    Divider()
                                }
                            }

                            // Trailing zone: drop here to move the block to the very end.
                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: 32)
                                .contentShape(Rectangle())
                                .overlay(alignment: .top) { insertionLine(visible: isDropAtEnd) }
                                .dropDestination(for: String.self) { items, _ in
                                    handleReorderDropAtEnd(items)
                                } isTargeted: { isDropAtEnd = $0 }
                        }
                    }
                    // Clicking the empty space below/around the rows clears the selection.
                    // Row taps are handled by the rows themselves, so this only fires on
                    // genuinely blank areas.
                    .contentShape(Rectangle())
                    .onTapGesture { selectNone() }
                    .focusable()
                    .focused($listFocused)
                    // The list is focusable so it can catch the bare keys below, but it doesn't
                    // need to advertise it: there's nothing else here to compete for focus except
                    // text fields, which show their own cursor. Drawing a ring round the middle of
                    // the layout marked the one state nobody wonders about. Where the arrow keys
                    // will move from is the useful thing, and that's on the cursor row instead.
                    .focusEffectDisabled()
                    .onKeyPress { press in
                        guard appState.selectedTab == 0 else { return .ignored }   // Combine tab only
                        guard !menuState.isPanelOpen else { return .ignored }
                        let isShift = press.modifiers.contains(.shift)
                        switch press.key {
                        case .upArrow:
                            navigateSelection(direction: -1, extending: isShift)
                            return .handled
                        case .downArrow:
                            navigateSelection(direction: 1, extending: isShift)
                            return .handled
                        case KeyEquivalent("a") where press.modifiers == .command:
                            selectAll()
                            return .handled
                        case KeyEquivalent("c") where press.modifiers == []:
                            if canGroup { groupSelected(); return .handled }
                            return .ignored
                        case KeyEquivalent(" ") where press.modifiers == []:
                            return openQuickLook() ? .handled : .ignored
                        default:
                            return .ignored
                        }
                    }
                    
                    Divider()
                    
                    // Bottom controls
                    VStack(spacing: 12) {
                        // Removal notice (shown briefly when minus removes a file)
                        if removalNoticeVisible {
                            HStack(spacing: 8) {
                                Image(systemName: "trash")
                                    .foregroundColor(.secondary)
                                Text(removalNoticeCount == 1 ? "File removed" : "\(removalNoticeCount) files removed")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Undo") {
                                    undoManager?.undo()
                                    removalNoticeVisible = false
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(NSColor.controlBackgroundColor))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(Color.secondary.opacity(0.2))
                                    )
                            )
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }

                        HStack {
                            CombineOutputMenuButton(layout: $layout,
                                                    sheetSize: $bookletSheetSize,
                                                    duplexFlip: $duplexFlip,
                                                    addBlankPages: $addBlankPages,
                                                    singleSided: $singleSided,
                                                    canGoSingleSided: canGoSingleSided,
                                                    onSetUpTwoSided: { activeSheet = .duplexSetup(startAtCheck: false) },
                                                    onReviewLayout: { showBookletLayout = true },
                                                    hasFiles: !combineManager.files.isEmpty)

                            // Only meaningful once pages are being placed two-up; in single-page
                            // output the print dialog's own scaling is the right tool.
                            if layout == .booklet {
                                BookletScaleField(percent: scalePercentBinding,
                                                  range: minScalePercent...maxScalePercent)

                                // On the bar rather than only in the output menu: deciding where
                                // page turns fall is part of setting a booklet up, not a setting
                                // you'd go hunting for.
                                Button {
                                    showBookletLayout = true
                                } label: {
                                    Label("Page Turns\u{2026}", systemImage: "book")
                                }
                                .disabled(combineManager.files.isEmpty)
                                .help("Choose where each part's page turns fall")
                            }

                            Text(outputSummary)
                                .font(.callout)
                                .foregroundColor(.secondary)

                            Spacer()

                            Button(action: openInPreview) {
                                Label("Open in Preview", systemImage: "doc.text.magnifyingglass")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Button(action: printCombined) {
                                Label("Print\u{2026}", systemImage: "printer")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(combineManager.files.isEmpty)

                            Button(action: createPDF) {
                                Label("Create PDF", systemImage: "arrow.down.doc")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 64))
                .foregroundColor(isTargeted ? .accentColor : .secondary)
            
            Text("Drop PDF files here to combine")
                .font(.title2)
                .fontWeight(.medium)

            Text("or")
                .foregroundColor(.secondary)

            Button(action: selectFiles) {
                Label("Choose Files", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Merge multiple PDFs or images into a single document ready to print in one go")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.gray.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [10])
                )
                .padding()
        )
    }
    
    // Expand the selection to include all group-mates of any selected grouped file,
    // so that move-up/down always treats a collate group as an indivisible block.
    private func expandForGroups(_ ids: Set<UUID>) -> Set<UUID> {
        var expanded = ids
        for id in ids {
            if let gid = combineManager.files.first(where: { $0.id == id })?.collateGroupId {
                combineManager.files.filter { $0.collateGroupId == gid }.forEach { expanded.insert($0.id) }
            }
        }
        return expanded
    }

    // True when `file` is the last member of its collate group (used to draw the
    // closing border so a group's extent is obvious).
    private func isLastInGroup(_ file: CombineFile) -> Bool {
        guard let gid = file.collateGroupId,
              let idx = combineManager.files.firstIndex(where: { $0.id == file.id })
        else { return false }
        let next = idx + 1
        return next >= combineManager.files.count || combineManager.files[next].collateGroupId != gid
    }

    // Snap a drop target to its collate group's first member, so an insert never
    // lands inside a group (which would split it). Ungrouped ids are returned as-is.
    private func groupSnappedTarget(_ targetId: UUID) -> UUID {
        guard let gid = combineManager.files.first(where: { $0.id == targetId })?.collateGroupId
        else { return targetId }
        return combineManager.files.first(where: { $0.collateGroupId == gid })?.id ?? targetId
    }

    // The set of files a drag should move: the whole selection if the dragged row is
    // part of it, otherwise just the dragged row — then group-expanded either way.
    private func draggedSet(for draggedId: UUID) -> Set<UUID> {
        let base: Set<UUID> = selectedFiles.contains(draggedId) ? selectedFiles : [draggedId]
        return expandForGroups(base)
    }

    /// Handle a reorder drop onto `rowId`. Returns true if the order changed.
    private func handleReorderDrop(_ items: [String], onto rowId: UUID) -> Bool {
        dropTargetId = nil
        mergeTargetGroupId = nil
        guard let first = items.first, let draggedId = UUID(uuidString: first) else { return false }
        let moving = draggedSet(for: draggedId)
        let target = groupSnappedTarget(rowId)
        guard !moving.contains(target) else { return false }   // dropped onto its own block
        combineManager.move(ids: moving, before: target, undoManager: undoManager)
        return true
    }

    /// Handle a drop onto a collate group's body — merge the dragged file(s) into it.
    private func handleAddToGroup(_ items: [String], groupId: UUID) -> Bool {
        dropTargetId = nil
        mergeTargetGroupId = nil
        guard let first = items.first, let draggedId = UUID(uuidString: first) else { return false }
        combineManager.addToGroup(ids: draggedSet(for: draggedId), groupId: groupId, undoManager: undoManager)
        return true
    }

    // Track which row's insertion line is shown while reordering.
    private func setReorderTarget(_ id: UUID, _ targeted: Bool) {
        if targeted { dropTargetId = id; mergeTargetGroupId = nil }
        else if dropTargetId == id { dropTargetId = nil }
    }

    /// Handle a drop onto the trailing zone — move the dragged block to the end.
    private func handleReorderDropAtEnd(_ items: [String]) -> Bool {
        isDropAtEnd = false
        guard let first = items.first, let draggedId = UUID(uuidString: first) else { return false }
        combineManager.move(ids: draggedSet(for: draggedId), before: nil, undoManager: undoManager)
        return true
    }

    /// Drag preview, reflecting what's actually being moved: "Collate Group" when the
    /// drag is exactly one collate group, "N items" for a multi-file selection, else
    /// the single file's name.
    @ViewBuilder private func dragPreview(for file: CombineFile) -> some View {
        let moving = draggedSet(for: file.id)
        if let gid = file.collateGroupId,
           moving == Set(combineManager.files.filter { $0.collateGroupId == gid }.map(\.id)) {
            dragPreviewLabel("Collate Group", systemImage: "rectangle.stack.fill")
        } else if moving.count > 1 {
            dragPreviewLabel("\(moving.count) items", systemImage: "doc.on.doc")
        } else {
            dragPreviewLabel(file.name, systemImage: "doc.on.doc")
        }
    }

    private func dragPreviewLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .lineLimit(1)
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    /// A thin accent insertion line shown where a dragged block will land.
    @ViewBuilder private func insertionLine(visible: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 8)
            .opacity(visible ? 1 : 0)
    }

    private var canMoveUp: Bool {
        guard !selectedFiles.isEmpty else { return false }
        let effective = expandForGroups(selectedFiles)
        // Enabled if at least one item in the effective set can actually shift up.
        return combineManager.files.indices.contains { index in
            guard effective.contains(combineManager.files[index].id) else { return false }
            guard index > 0 else { return false }
            return !effective.contains(combineManager.files[index - 1].id)
        }
    }

    private var canMoveDown: Bool {
        guard !selectedFiles.isEmpty else { return false }
        let effective = expandForGroups(selectedFiles)
        return combineManager.files.indices.contains { index in
            guard effective.contains(combineManager.files[index].id) else { return false }
            guard index < combineManager.files.count - 1 else { return false }
            return !effective.contains(combineManager.files[index + 1].id)
        }
    }

    /// True when 2+ selected files are all ungrouped — they can be collated together.
    private var canGroup: Bool {
        guard selectedFiles.count >= 2 else { return false }
        return selectedFiles.allSatisfy { id in
            combineManager.files.first(where: { $0.id == id })?.collateGroupId == nil
        }
    }
    
    private func selectFiles() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        menuState.isPanelOpen = true
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .jpeg, .png, .tiff, .bmp, .gif, .heic]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.title = "Select PDF or Image Files"
        panel.message = "Select PDF or image files, or select a folder to add all supported files inside it"

        panel.beginSheetModal(for: window) { response in
            self.menuState.isPanelOpen = false
            if response == .OK {
                let expanded = Self.expandToSupportedFiles(panel.urls)
                self.combineManager.addFiles(urls: expanded, undoManager: self.undoManager)
            }
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) {
        var collected: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url { collected.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !collected.isEmpty else { return }
            let expanded = Self.expandToSupportedFiles(collected)
            if expanded.isEmpty {
                showNSAlert(title: "Unsupported File Type",
                            message: "ScoreSort can combine PDFs and images (JPEG, PNG, TIFF, HEIC, BMP, GIF). The dropped item(s) were not recognised.",
                            isError: true)
            } else {
                self.combineManager.addFiles(urls: expanded, undoManager: self.undoManager)
            }
        }
    }

    /// PDFs plus every image ScoreSort can page — shared with the Stamp tab.
    static let supportedExtensions: Set<String> = pageableFileExtensions

    /// Expands a mixed list of file and folder URLs into a flat, sorted list of supported file
    /// URLs. Folders are enumerated recursively; unsupported files are ignored.
    static func expandToSupportedFiles(_ urls: [URL]) -> [URL] {
        expandToFiles(urls, extensions: supportedExtensions)
    }
    
    /// A click on the row body. Standard macOS list behaviour:
    ///   • plain click  → select just this file (replacing the selection)
    ///   • ⌘ click      → add/remove this file from the selection
    ///   • ⇧ click      → extend the range from the anchor
    private func selectFile(_ id: UUID) {
        let modifiers = NSEvent.modifierFlags

        if modifiers.contains(.shift),
           let anchor = anchorFileId,
           let anchorIndex = combineManager.files.firstIndex(where: { $0.id == anchor }),
           let clickedIndex = combineManager.files.firstIndex(where: { $0.id == id }) {
            // Range selection: everything from the anchor to the clicked item. The anchor
            // stays fixed so further shift-clicks extend/shrink the same range.
            let lo = min(anchorIndex, clickedIndex)
            let hi = max(anchorIndex, clickedIndex)
            selectedFiles = Set(combineManager.files[lo...hi].map { $0.id })
            focusedFileId = id
        } else if modifiers.contains(.command) {
            toggleSelection(id)
            return   // toggleSelection already pulls list focus
        } else {
            // Plain click replaces the selection with just this file.
            selectedFiles = [id]
            focusedFileId = id
            anchorFileId = id
        }
        listFocused = true  // pull keyboard focus to the list after a click
    }

    /// Adds/removes a file from the selection — used by the tick box and ⌘-click.
    private func toggleSelection(_ id: UUID) {
        if selectedFiles.contains(id) {
            selectedFiles.remove(id)
            if focusedFileId == id { focusedFileId = nil; anchorFileId = nil }
        } else {
            selectedFiles.insert(id)
            focusedFileId = id
            anchorFileId = id
        }
        listFocused = true  // pull keyboard focus to the list after a click
    }

    private func selectAll() {
        selectedFiles = Set(combineManager.files.map { $0.id })
        anchorFileId = combineManager.files.first?.id
        focusedFileId = combineManager.files.last?.id
    }

    private func selectNone() {
        selectedFiles.removeAll()
        focusedFileId = nil
        anchorFileId = nil
    }

    private func addBlankPage() {
        combineManager.addBlankPage(after: selectedFiles, undoManager: undoManager)
    }

    private func removeSelected() {
        guard !selectedFiles.isEmpty else { return }
        let count = selectedFiles.count
        unmatchedFileIds.subtract(selectedFiles)
        splitCopyFileIds.subtract(selectedFiles)
        combineManager.removeFiles(ids: selectedFiles, undoManager: undoManager)
        selectedFiles.removeAll()
        focusedFileId = nil
        anchorFileId = nil
        showRemovalNotice(count: count, undoManager: undoManager)
    }

    /// Keyboard navigation: moves the cursor by `direction` (±1), extending the
    /// selection from the anchor when `extending` is true (Shift held).
    private func navigateSelection(direction: Int, extending: Bool) {
        let files = combineManager.files
        guard !files.isEmpty else { return }

        let currentIndex: Int
        if let id = focusedFileId, let idx = files.firstIndex(where: { $0.id == id }) {
            currentIndex = idx
        } else {
            // No cursor yet — start from the logical edge
            currentIndex = direction > 0 ? -1 : files.count
        }

        let newIndex = max(0, min(files.count - 1, currentIndex + direction))
        let newId = files[newIndex].id
        focusedFileId = newId

        if extending {
            // Extend selection from anchor to cursor
            let anchorIndex = anchorFileId.flatMap { id in
                files.firstIndex(where: { $0.id == id })
            } ?? newIndex
            let lo = min(anchorIndex, newIndex)
            let hi = max(anchorIndex, newIndex)
            selectedFiles = Set(files[lo...hi].map { $0.id })
        } else {
            anchorFileId = newId
            selectedFiles = [newId]
        }
    }

    private func moveUp() {
        // Expand so entire collate groups always move as one block
        combineManager.moveUp(ids: expandForGroups(selectedFiles), undoManager: undoManager)
    }

    private func moveDown() {
        combineManager.moveDown(ids: expandForGroups(selectedFiles), undoManager: undoManager)
    }

    private func groupSelected() {
        guard canGroup else { return }
        combineManager.createCollateGroup(fileIds: selectedFiles, undoManager: undoManager)
        selectedFiles = []
        focusedFileId = nil
        anchorFileId = nil
    }

    private func showRemovalNotice(count: Int = 1, undoManager: UndoManager?) {
        removalNoticeCount = count
        withAnimation(.easeInOut(duration: 0.2)) { removalNoticeVisible = true }
        // Auto-dismiss after 5 s; pressing Undo dismisses it immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            withAnimation(.easeInOut(duration: 0.2)) { removalNoticeVisible = false }
        }
    }
    
    private func createPDF() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        menuState.isPanelOpen = true
        // Find moved files first, so the panel opens where the first file is now.
        combineManager.refreshFileLocations()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Combined.pdf"
        panel.title = "Save Combined PDF"
        // Default to the folder of the first real input file.
        if let firstSource = combineManager.files.first(where: { !$0.isBlankPage })?.url {
            panel.directoryURL = outputDirectory(forSourceFile: firstSource)
        }

        panel.beginSheetModal(for: window) { response in
            menuState.isPanelOpen = false
            if response == .OK, let url = panel.url {
                combineManager.createCombinedPDF(to: url, options: outputOptions, stampJob: activeStampJob) { title, message, isError in
                    if isError {
                        showNSAlert(title: title, message: message, isError: true)
                    } else {
                        let alert = NSAlert()
                        alert.messageText = title
                        alert.informativeText = message
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        alert.addButton(withTitle: "Open in Preview")
                        if alert.runModal() == .alertSecondButtonReturn {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }
    
    private func openInPreview() {
        combineManager.openInPreview(options: outputOptions, stampJob: activeStampJob) { title, message, isError in
            showNSAlert(title: title, message: message, isError: isError)
        }
    }

    /// Prints the generated calibration sheet. Presented on `keyWindow`, which while the wizard
    /// is up is the wizard's own sheet window — a second sheet on the *main* window would queue
    /// behind the wizard instead of appearing.
    private func printCalibrationSheet() {
        guard let sheet = bookletCalibrationSheet(sheetSize: bookletSheetSize,
                                                  pageScale: Double(bookletScalePercent) / 100,
                                                  rotateBackFaces: duplexFlip.rotatesBackFaces) else {
            showNSAlert(title: "Error", message: "Could not build the test sheet.", isError: true)
            return
        }
        printPDFDocument(sheet,
                         jobName: "ScoreSort \u{2014} Two-Sided Test Sheet",
                         wantsTwoSided: true,
                         in: NSApp.keyWindow ?? NSApp.mainWindow) { title, message, isError in
            showNSAlert(title: title, message: message, isError: isError)
        }
    }

    private func printCombined() {
        combineManager.printCombined(options: outputOptions,
                                     stampJob: activeStampJob,
                                     in: NSApp.keyWindow ?? NSApp.mainWindow) { title, message, isError in
            showNSAlert(title: title, message: message, isError: isError)
        }
    }

    /// The output shape the buttons will produce, gathered from the menu's bindings.
    private var outputOptions: CombineOutputOptions {
        CombineOutputOptions(layout: layout,
                             sheetSize: bookletSheetSize,
                             bookletPageScale: Double(bookletScalePercent) / 100,
                             addBlankPages: addBlankPages,
                             singleSided: singleSided && canGoSingleSided,
                             duplexFlip: duplexFlip)
    }

    /// True when no part needs the back of its sheet, so the blank backs can be left out without
    /// stranding a folded part away from the half it pairs with.
    private var canGoSingleSided: Bool {
        let parts = combineManager.files.filter { !$0.isBlankPage }
        return !parts.isEmpty && parts.allSatisfy {
            bookletFitsOneSheetFace(pageCount: $0.pageCount, layout: $0.effectiveBookletLayout)
        }
    }

    /// Clamped to the same range the imposition enforces, so what the field shows is what
    /// the output uses — typing 400 lands on 150, not silently on something else.
    private var scalePercentBinding: Binding<Int> {
        Binding(
            get: { bookletScalePercent },
            set: { bookletScalePercent = min(max($0, minScalePercent), maxScalePercent) }
        )
    }

    private var minScalePercent: Int { Int(bookletPageScaleRange.lowerBound * 100) }
    private var maxScalePercent: Int { Int(bookletPageScaleRange.upperBound * 100) }

    /// The counts line beside the output menu. Booklet mode adds the paper count, which is
    /// what actually matters when loading a tray.
    private var outputSummary: String {
        let base = "\(combineManager.totalFiles) file(s) \u{2022} \(combineManager.totalPages) total page(s)"
        guard layout == .booklet else { return base }
        let sheets = combineManager.totalBookletSheets
        return base + " \u{2022} \(sheets) sheet(s) of paper"
    }

    /// The stamp job to apply to output, or nil when stamping is switched off.
    private var activeStampJob: StampJob? {
        guard stampEnabled, let stamp = stampStore.selectedStamp else { return nil }
        return StampJob(stamp: stamp, scope: stampScope)
    }

    // MARK: - Menu state sync
    private func syncMenuClosures() {
        menuState.removeSelected          = removeSelected
        menuState.moveUp                  = moveUp
        menuState.moveDown                = moveDown
        menuState.selectAll               = selectAll
        menuState.group                   = groupSelected
        menuState.selectPrevious          = { navigateSelection(direction: -1, extending: false) }
        menuState.selectNext              = { navigateSelection(direction:  1, extending: false) }
        menuState.selectPreviousExtending = { navigateSelection(direction: -1, extending: true)  }
        menuState.selectNextExtending     = { navigateSelection(direction:  1, extending: true)  }
        menuState.togglePresetSidebar     = { showPresetSidebar.toggle() }
        syncMenuFlags()
    }

    /// ⌫ / ⌦ — remove the selected files.
    ///
    /// Deliberately *not* a menu `.keyboardShortcut(.delete)`: a CommandMenu key
    /// equivalent fires app-wide even when the item is `.disabled()`, which would steal
    /// backspace from every text field (preset names, the copies field, stamp designer).
    /// SwiftUI's `onKeyPress` doesn't reliably see delete on macOS either, so — as in the
    /// Rename and Split tabs — a local NSEvent monitor catches it at the app level.
    private func installKeyMonitor() {
        guard combineKeyMonitor == nil else { return }
        combineKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // This monitor is app-global and stays installed while Combine is mounted
            // (TabView keeps hidden tabs mounted), so gate it the same way the tab's
            // onKeyPress is gated.
            guard appState.selectedTab == 0 else { return event }
            guard !menuState.isPanelOpen else { return event }
            guard event.keyCode == 51 || event.keyCode == 117 else { return event }
            // Never steal the key from text editing, or from a sheet on top of us
            // (New Preset, stamp designer) where ⌫ must not touch the file list.
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }
            if NSApp.keyWindow?.isSheet == true { return event }
            // Nothing selected — let the system have it rather than silently swallowing.
            guard !selectedFiles.isEmpty else { return event }
            DispatchQueue.main.async { self.removeSelected() }
            return nil  // consume — prevents the system bonk
        }
    }

    private func syncMenuFlags() {
        menuState.canRemove   = !selectedFiles.isEmpty
        menuState.canMoveUp   = canMoveUp
        menuState.canMoveDown = canMoveDown
        menuState.canGroup    = canGroup
        menuState.hasFiles    = !combineManager.files.isEmpty
        menuState.isActiveTab = appState.selectedTab == 0
    }

    /// Publishes Combine's actions to the app-level menu bridge — but only while Combine
    /// is the active tab, so the File/View/Actions menus reflect whatever tab is on screen.
    private func syncTabCommands() {
        guard appState.selectedTab == 0 else { return }
        let hasFiles = !combineManager.files.isEmpty
        var slice = TabSlice()
        slice.openTitle     = "Add Files\u{2026}"
        slice.open          = { selectFiles() }
        slice.primaryTitle  = "Create PDF\u{2026}"
        slice.primarySave   = hasFiles ? { createPDF() } : nil
        slice.openInPreview = hasFiles ? { openInPreview() } : nil
        slice.print         = hasFiles ? { printCombined() } : nil
        slice.clearTitle    = "Clear Files"
        slice.clear         = hasFiles ? { combineManager.clearAll(undoManager: undoManager) } : nil
        slice.togglePresets = { showPresetSidebar.toggle() }
        let revealTarget = combineManager.files.first?.url
        slice.tabActions = [
            MenuAction(title: "Move Up", key: KeyEquivalent.upArrow, isEnabled: canMoveUp, perform: { moveUp() }),
            MenuAction(title: "Move Down", key: KeyEquivalent.downArrow, isEnabled: canMoveDown, perform: { moveDown() }),
            MenuAction(title: "Collate", isEnabled: canGroup, perform: { groupSelected() }),
            MenuAction(title: "Add Blank Page", perform: { addBlankPage() }),
            MenuAction(title: "Remove Selected", isEnabled: !selectedFiles.isEmpty, perform: { removeSelected() }),
            MenuAction(title: "Select All", isEnabled: hasFiles, perform: { selectAll() }),
            MenuAction(title: "Select None", isEnabled: hasFiles, perform: { selectNone() }),
            // Present but disabled outside booklet output, so it teaches that booklets have this
            // rather than appearing from nowhere. ⌘T is safe to bind: a CommandMenu shortcut fires
            // even while disabled, but nothing else here wants it — the app has no tabbed windows
            // and no font panel, and NSTextView doesn't claim it.
            MenuAction(title: "Booklet Page Turns\u{2026}", key: KeyEquivalent("t"),
                       isEnabled: layout == .booklet && hasFiles,
                       perform: { showBookletLayout = true }),
            MenuAction(title: "Show in Finder", key: KeyEquivalent("f"), modifiers: [.command, .shift],
                       isEnabled: revealTarget != nil, perform: { revealInFinder(revealTarget) }),
        ]
        appState.tabCommands.slice = slice
    }

    // MARK: - Apply Preset

    /// Arms the preset's stamp, if it has one. A preset belongs to a school or ensemble, so
    /// applying it should set up that organisation's mark — but only ever as a default: the
    /// Stamp button in the toolbar shows what's armed and switches it off in one click.
    /// A preset with no stamp leaves the current choice alone rather than turning it off.
    private func applyPresetStamp(_ stampId: UUID?) {
        guard let stampId, stampStore.stamps.contains(where: { $0.id == stampId }) else { return }
        stampStore.selectedStampId = stampId
        stampEnabled = true
    }

    /// Applies a preset's copy counts to the file list (`CombineManager.applyPreset`) and arms
    /// its stamp. Files that match no part are highlighted orange; copies the app divided
    /// between numbered parts are tinted blue.
    @discardableResult
    private func applyPreset(parts: [PresetPart], stampId: UUID? = nil) -> (matched: Int, unmatched: Int, unmatchedPartNames: Set<String>) {
        applyPresetStamp(stampId)
        let result = combineManager.applyPreset(parts: parts, undoManager: undoManager)
        unmatchedFileIds = result.unmatchedFileIds
        splitCopyFileIds = result.splitFileIds
        return (matched: result.matchedCount, unmatched: result.unmatchedFileIds.count,
                unmatchedPartNames: result.unmatchedPartNames)
    }
}
