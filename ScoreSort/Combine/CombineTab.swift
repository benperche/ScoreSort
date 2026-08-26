//
//  CombineTab.swift
//  ScoreSort
//
//  The Combine PDFs tab: CombineView and its file/collate-group rows, the preset
//  sidebar and its sheets, and the data layer (CombineFile/CollateGroup, the
//  EnsemblePreset model + store, and CombineManager). The preset model, part row and
//  New Preset sheet are also used by the Combiner preferences pane.
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
    /// Not `@AppStorage`: the answer belongs to the printer, not the app, so it's loaded from
    /// `BookletDuplexDefaults` for whichever printer is currently the default.
    @State private var duplexFlip: BookletDuplexFlip = .longEdge
    @State private var activeSheet: CombineSheet?
    @State private var showBookletLayout = false
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
        .animation(.easeInOut(duration: 0.15), value: showBookletLayout)
        // The ⌫ monitor is app-global, so without this it would still be deleting files from the
        // list behind the overlay. isPanelOpen is the existing flag for "a panel owns the keys".
        .onChange(of: showBookletLayout) { _, shown in menuState.isPanelOpen = shown }
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
                             duplexFlip: duplexFlip)
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
    /// Applies copy counts from the given preset parts to the file list.
    /// Parts are matched against file names via case-insensitive substring search,
    /// longest part name first so "Bass Clarinet" wins over "Clarinet".
    /// Files that don't match any part are highlighted orange.
    /// Arms the preset's stamp, if it has one. A preset belongs to a school or ensemble, so
    /// applying it should set up that organisation's mark — but only ever as a default: the
    /// Stamp button in the toolbar shows what's armed and switches it off in one click.
    /// A preset with no stamp leaves the current choice alone rather than turning it off.
    private func applyPresetStamp(_ stampId: UUID?) {
        guard let stampId, stampStore.stamps.contains(where: { $0.id == stampId }) else { return }
        stampStore.selectedStampId = stampId
        stampEnabled = true
    }

    @discardableResult
    private func applyPreset(parts: [PresetPart], stampId: UUID? = nil) -> (matched: Int, unmatched: Int, unmatchedPartNames: Set<String>) {
        applyPresetStamp(stampId)
        // Sort longest-name-first so "Bass Clarinet" wins over "Clarinet"
        let sortedParts = parts.sorted { $0.name.count > $1.name.count }
        var newUnmatched: Set<UUID> = []
        var matched = 0
        var matchedPartNames: Set<String> = []

        // ── Phase 1: direct match (with roman-numeral normalisation) ──────────
        for file in combineManager.files {
            let filename = normalizeRomanNumerals(file.name.lowercased())
            if let match = sortedParts.first(where: {
                presetPartMatches(part: normalizeRomanNumerals($0.name.lowercased()), in: filename)
            }) {
                combineManager.updateCopies(for: file.id, copies: match.copies, undoManager: undoManager)
                matched += 1
                matchedPartNames.insert(match.name)
            } else {
                newUnmatched.insert(file.id)
            }
        }

        // ── Phase 2: consolidation ────────────────────────────────────────────
        // When ALL numbered siblings of a base name went unmatched AND exactly
        // one file contains that base name, sum their copies and apply to that file.
        // (Any more complex situation — 2 files vs 3 parts etc. — stays orange.)
        let unmatchedParts = parts.filter { !matchedPartNames.contains($0.name) }

        // Group unmatched parts by their (normalised) base name
        var baseGroups: [String: [PresetPart]] = [:]
        for part in unmatchedParts {
            if let base = numberedBase(of: part.name) {
                baseGroups[base, default: []].append(part)
            }
        }

        for (base, group) in baseGroups {
            // All preset parts with this base must be in the unmatched group
            let allWithBase = parts.filter { numberedBase(of: $0.name) == base }
            guard group.count == allWithBase.count else { continue }

            // Find still-unmatched files that contain the base name
            let candidates = newUnmatched.filter { id in
                guard let file = combineManager.files.first(where: { $0.id == id }) else { return false }
                return presetPartMatches(part: base, in: normalizeRomanNumerals(file.name.lowercased()))
            }
            guard candidates.count == 1, let fileId = candidates.first else { continue }

            // Apply summed copies and mark everything resolved
            let total = group.reduce(0) { $0 + $1.copies }
            combineManager.updateCopies(for: fileId, copies: total, undoManager: undoManager)
            newUnmatched.remove(fileId)
            matched += 1
            for part in group { matchedPartNames.insert(part.name) }
        }

        unmatchedFileIds = newUnmatched
        let unmatchedPartNames = Set(parts.map(\.name)).subtracting(matchedPartNames)
        return (matched: matched, unmatched: newUnmatched.count, unmatchedPartNames: unmatchedPartNames)
    }
}

extension Color {
    /// Chrome colour for collate groups — deliberately a fixed hue distinct from the
    /// system accent (which drives row selection) so a group doesn't read as "selected".
    /// Indigo isn't one of macOS's selectable accent colours, so it never collides with
    /// the selection tint whatever accent the user has chosen.
    static let collateGroup = Color.indigo
}

// MARK: - Combine File Row
// MARK: - Two-Sided Setup Wizard

/// The Combine tab's modal sheets, as one value so a single `.sheet(item:)` drives both.
enum CombineSheet: Identifiable {
    case bookletIntro
    /// `startAtCheck` when the test sheet is already on its way to the printer — the first-run
    /// modal does the explaining, so replaying the wizard's own intro would just repeat it.
    case duplexSetup(startAtCheck: Bool)

    var id: String {
        switch self {
        case .bookletIntro:                  return "bookletIntro"
        case .duplexSetup(let startAtCheck): return "duplexSetup-\(startAtCheck)"
        }
    }
}

/// Shown once, when someone first switches the output menu to Booklet.
///
/// This is where the two-sided printing explanation lives rather than the welcome tour, because
/// the tour is only ever shown once per install and existing users would never see it — and they
/// are exactly the people meeting booklets for the first time.
struct BookletIntroView: View {
    let printerName: String
    let onPrint: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Printing Booklets")
                .font(.title2).fontWeight(.semibold)

            Text("""
                 Each part becomes its own fold-and-staple booklet, two pages to a side, so a \
                 whole folder goes out in one print job.
                 """)

            Label("""
                  macOS doesn't let an app choose your two-sided setting, so set **Double-sided** \
                  to *On* in the print dialog yourself.
                  """,
                  systemImage: "printer")
                .foregroundColor(.secondary)

            Label("""
                  Printers also differ in which edge they turn the paper on, so this prints one \
                  sheet to find out. You only do it once per printer.
                  """,
                  systemImage: "arrow.2.squarepath")
                .foregroundColor(.secondary)

            Label("""
                  The preview may show a side upside down — that's normal. Judge it by what comes \
                  out of the printer.
                  """,
                  systemImage: "info.circle")
                .foregroundColor(.secondary)

            if !printerName.isEmpty {
                Text("This setting is remembered for **\(printerName)**.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Not Now", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Print Test Sheet\u{2026}", action: onPrint)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Walks the user through the one thing about booklets that can't be settled in software:
/// which way their printer turns the paper. Prints a single generated sheet, then asks the only
/// question that matters — did it come out readable — and sets the flip from the answer, so
/// nobody has to translate "upside down" into "long edge" themselves.
struct BookletDuplexSetupView: View {
    @Binding var flip: BookletDuplexFlip
    let printerName: String
    /// True when the caller has already explained things and sent a sheet to the printer.
    var startAtCheck: Bool = false
    let onPrint: () -> Void
    let onClose: () -> Void

    private enum Step { case intro, check, switched }
    @State private var step: Step = .intro

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Two-Sided Printing")
                .font(.title2).fontWeight(.semibold)

            switch step {
            case .intro:    intro
            case .check:    check
            case .switched: switched
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { if startAtCheck { step = .check } }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("""
                 Printers differ in which edge they turn the paper on, and macOS doesn't let an \
                 app choose it. This prints one sheet so you can find out — you only need to do \
                 it once per printer.
                 """)
            Label("In the print dialog, make sure Double-sided is set to On.",
                  systemImage: "exclamationmark.circle")
                .foregroundColor(.secondary)
            previewNote
            printerLine

            HStack {
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Print Test Sheet\u{2026}") {
                    step = .check
                    // One runloop turn later: presenting the print sheet from inside the
                    // button's own update pass makes AppKit complain about laying out a view
                    // that's already being laid out.
                    DispatchQueue.main.async { onPrint() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var check: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fold the printed sheet in half.")
                .fontWeight(.medium)
            Text("Do the four pages read **1, 2, 3, 4**, all the right way up?")

            previewNote

            HStack {
                Button("Print Again") { DispatchQueue.main.async { onPrint() } }
                Spacer()
                Button("They\u{2019}re upside down") {
                    flip = (flip == .longEdge) ? .shortEdge : .longEdge
                    step = .switched
                }
                Button("Yes \u{2014} all correct") { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var switched: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Switched to \u{201C}\(flip.label)\u{201D}.", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text("""
                 Print another test sheet to confirm. If it's still wrong, the problem is more \
                 likely that Double-sided wasn't set to On in the print dialog.
                 """)
            printerLine

            HStack {
                Spacer()
                Button("Print Test Sheet\u{2026}") {
                    step = .check
                    DispatchQueue.main.async { onPrint() }
                }
                Button("Done", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// The dialog's preview shows the second side upside down, because that's exactly what has
    /// to be sent for it to come out right. Saying so up front stops it reading as a fault and
    /// stops anyone "correcting" it before the paper has had its say.
    private var previewNote: some View {
        Label("""
              The preview may show a side upside down — that's normal. Judge it by what comes \
              out of the printer.
              """,
              systemImage: "info.circle")
            .foregroundColor(.secondary)
    }

    /// Named because the setting is remembered per printer — worth showing which one is about
    /// to be calibrated, especially for someone who prints at more than one site.
    @ViewBuilder private var printerLine: some View {
        if !printerName.isEmpty {
            Text("This setting is remembered for **\(printerName)**.")
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Output Menu Button

/// The single pull-down holding everything about the *shape* of the output, so the bottom
/// bar's three buttons stay purely about where it goes. Modelled on `StampMenuButton`:
/// inline pickers, so every checkmark in the menu means "this is the one in use".
struct CombineOutputMenuButton: View {
    @Binding var layout: CombineLayout
    @Binding var sheetSize: BookletSheetSize
    @Binding var duplexFlip: BookletDuplexFlip
    @Binding var addBlankPages: Bool
    let onSetUpTwoSided: () -> Void
    let onReviewLayout: () -> Void
    let hasFiles: Bool

    var body: some View {
        Menu {
            Picker("Layout", selection: $layout) {
                ForEach(CombineLayout.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Picker("Sheet size", selection: $sheetSize) {
                ForEach(BookletSheetSize.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
            .disabled(layout != .booklet)      // nothing to lay out two-up on single pages

            Divider()

            Picker("Two-sided flip", selection: $duplexFlip) {
                ForEach(BookletDuplexFlip.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
            .disabled(layout != .booklet)

            Toggle("Blank page after odd-length parts", isOn: $addBlankPages)
                .disabled(layout == .booklet)  // booklets pad to a whole folded sheet anyway

            Divider()

            // Lives in here rather than on the main screen: it's a one-off setup step, not part
            // of the everyday flow. It needs no files — the test sheet is generated — so a new
            // printer can be calibrated before anything has been assembled.
            Button("Page Turns\u{2026}", action: onReviewLayout)
                .disabled(layout != .booklet || !hasFiles)

            Button("Set Up Two-Sided Printing\u{2026}", action: onSetUpTwoSided)
                .disabled(layout != .booklet)
        } label: {
            Label(title, systemImage: layout == .booklet ? "book.closed" : "doc.on.doc")
                .lineLimit(1)
        }
        // Sized to its own label so the row around it stays put instead of the title wrapping.
        .fixedSize()
        .help(helpText)
    }

    private var title: String {
        layout == .booklet ? "Booklet \u{00B7} \(sheetSize.shortLabel)" : "Single pages"
    }

    private var helpText: String {
        switch layout {
        case .singlePages:
            return "Output layout: one page per sheet side, in reading order."
        case .booklet:
            return """
            Each part is imposed as its own saddle-stitch booklet, padded to a whole folded \
            sheet. Set Double-sided to On in the print dialog, then fold and staple.

            First time on a new printer, use Set Up Two-Sided Printing\u{2026} — it prints one \
            numbered sheet and sets the flip from what you see. Remembered per printer.

            When printing, the dialog's preview may show every second side upside down. That's \
            normal — it's how the sheet has to be sent so it comes out right once the printer \
            turns the paper over.

            The flip is applied only when ScoreSort prints, so Create PDF and Open in Preview \
            stay the right way up on screen — an ordinary booklet file you can print later, \
            on any printer.
            """
        }
    }
}

/// "Scale [103]% ⌃⌄" — how big each page is drawn within its half of the booklet sheet.
///
/// A typed field rather than a menu of presets: published music doesn't match A4, and the
/// useful corrections are things like 103%, which a coarse preset list can't express.
struct BookletScaleField: View {
    @Binding var percent: Int
    let range: ClosedRange<Int>

    /// The field edits its own text so a half-typed value ("1" on the way to "105") doesn't
    /// get clamped out from under the cursor. It commits on Return or on losing focus.
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 3) {
            Text("Scale")
                .foregroundColor(.secondary)
            TextField("", text: $text)
                .frame(width: 38)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { text = "\(percent)"; focused = false }
            Text("%")
                .foregroundColor(.secondary)
            Stepper("", value: $percent, in: range)
                .labelsHidden()
        }
        .help("""
              How large each page is drawn within its half of the sheet. 100% fits the half \
              exactly; lower leaves more space around the music, higher fills more of it. \
              Applies to Create PDF, Preview and Print alike.
              """)
        .onAppear { text = "\(percent)" }
        .onChange(of: percent) { _, new in if !focused { text = "\(new)" } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        // Anything unparseable snaps back to the last good value rather than resetting to 100.
        guard let typed = Int(text.trimmingCharacters(in: .whitespaces)) else {
            text = "\(percent)"
            return
        }
        percent = min(max(typed, range.lowerBound), range.upperBound)
        text = "\(percent)"
    }
}

struct CombineFileRow: View {
    let file: CombineFile
    let isSelected: Bool
    let isFocused: Bool
    let isUnmatched: Bool
    /// True when this file belongs to a collate group (indents row, hides copies stepper).
    var isGrouped: Bool = false
    /// True when this is the last member of its collate group (draws the closing border).
    var isLastInGroup: Bool = false
    /// True while a drag is hovering this file's collate group (highlight as merge target).
    var isMergeTarget: Bool = false
    /// Tapping the tick box always adds/removes this file from the selection.
    let onToggleSelect: () -> Void
    /// Tapping anywhere else on the row selects just this file (⌘ toggles, ⇧ extends).
    let onRowTap: () -> Void
    let onCopiesChanged: (Int) -> Void
    let onRemove: () -> Void
    /// True while booklet output is selected — the layout column is meaningless otherwise.
    var showsBookletLayout: Bool = false
    var onBookletLayoutChanged: ((BookletPartLayout) -> Void)? = nil

    @State private var isEditingCopies = false
    @State private var copiesText = ""
    @FocusState private var copiesFieldFocused: Bool

    var body: some View {
        HStack {
            // The tick box is its own hit target: it always toggles membership, so you can
            // build up a multi-selection without holding ⌘.
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .contentShape(Rectangle())
                .onTapGesture { onToggleSelect() }

            Text(file.name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(file.isBlankPage ? .secondary : .primary)
                .italic(file.isBlankPage)
                // Indent grouped files so they visually sit under the group header
                .padding(.leading, isGrouped ? 14 : 0)

            Text("\(file.pageCount)")
                .frame(width: 80, alignment: .center)
                .foregroundColor(.secondary)

            if showsBookletLayout {
                // Labelled by the pages that end up facing each other rather than by the format,
                // because that's what tells a player where they'll have to turn.
                Menu {
                    ForEach(BookletPartLayout.allCases) { option in
                        Button {
                            onBookletLayoutChanged?(option)
                        } label: {
                            if option == file.effectiveBookletLayout {
                                Label("\(option.label) — \(option.spreadDescription(pageCount: file.pageCount))",
                                      systemImage: "checkmark")
                            } else {
                                Text("\(option.label) — \(option.spreadDescription(pageCount: file.pageCount))")
                            }
                        }
                    }
                } label: {
                    Text(file.effectiveBookletLayout.spreadDescription(pageCount: file.pageCount))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 150)
                .disabled(file.isBlankPage)
                .help("Where the page turns fall in this part's booklet")
            }

            // Grouped files don't have their own copy count — the group header owns it
            if isGrouped {
                Spacer().frame(width: 100)
            } else {
                HStack(spacing: 4) {
                    Button(action: {
                        if file.copies > 1 { onCopiesChanged(file.copies - 1) } else { onRemove() }
                    }) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)

                    if isEditingCopies {
                        TextField("", text: $copiesText)
                            .frame(width: 40)
                            .multilineTextAlignment(.center)
                            .font(.system(.body, design: .monospaced))
                            .focused($copiesFieldFocused)
                            .onSubmit { commitCopiesEdit() }
                            .onExitCommand { isEditingCopies = false }
                            .onTapGesture {}
                    } else {
                        Text("\(file.copies)")
                            .frame(width: 40, alignment: .center)
                            .font(.system(.body, design: .monospaced))
                            .onTapGesture(count: 2) {
                                copiesText = "\(file.copies)"
                                isEditingCopies = true
                                copiesFieldFocused = true
                            }
                    }

                    Button(action: { onCopiesChanged(file.copies + 1) }) {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: 100, alignment: .center)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(rowBackground)
        // Continuous collate-colour spine down the left edge of a collate group, plus a
        // closing border under the last member so the group's extent is obvious.
        .overlay(alignment: .leading) {
            if isGrouped {
                Rectangle().fill(Color.collateGroup.opacity(0.55)).frame(width: 3)
            }
        }
        .overlay(alignment: .bottom) {
            if isLastInGroup {
                Rectangle().fill(Color.collateGroup.opacity(0.55)).frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onRowTap() }
        .onChange(of: copiesFieldFocused) { _, focused in
            if !focused && isEditingCopies { commitCopiesEdit() }
        }
    }

    private var rowBackground: Color {
        if isMergeTarget { return Color.collateGroup.opacity(0.22) }   // drag merge highlight
        if isSelected { return Color.accentColor.opacity(isFocused ? 0.18 : 0.1) }
        if isUnmatched { return Color.orange.opacity(0.12) }
        if isGrouped { return Color.collateGroup.opacity(0.08) }   // faint group fill
        if file.isBlankPage { return Color.gray.opacity(0.08) }
        return Color.clear
    }

    private func commitCopiesEdit() {
        if let value = Int(copiesText), value >= 1 { onCopiesChanged(value) }
        isEditingCopies = false
    }
}

// MARK: - Collate Group Header Row
/// The header row displayed above the files in a collate group.
/// Shows the group's total-pages-per-set and the group-level copy count.
struct CollateGroupHeaderRow: View {
    let group: CollateGroup
    let fileCount: Int
    let totalPages: Int
    /// True while a drag is hovering this group (highlight as merge target).
    var isMergeTarget: Bool = false
    var onCopiesChanged: (Int) -> Void
    var onUngroup: () -> Void

    @State private var isEditingCopies = false
    @State private var copiesText = ""
    @FocusState private var copiesFocused: Bool

    var body: some View {
        HStack {
            // Name column ─ icon + label + ungroup button
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundColor(.collateGroup)
                Text("Collate Group")
                    .fontWeight(.semibold)
                Text("(\(fileCount) file\(fileCount == 1 ? "" : "s"))")
                    .foregroundColor(.secondary)
                    .font(.callout)
                Spacer()
                Button(action: onUngroup) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Dissolve group — restore files individually")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Pages column ─ total pages for one complete set
            Text("\(totalPages)")
                .frame(width: 80, alignment: .center)
                .foregroundColor(.secondary)

            // Copies column ─ group-level stepper (double-click to type)
            HStack(spacing: 4) {
                Button { if group.copies > 1 { onCopiesChanged(group.copies - 1) } } label: {
                    Image(systemName: "minus.circle")
                }.buttonStyle(.plain)

                if isEditingCopies {
                    TextField("", text: $copiesText)
                        .frame(width: 40)
                        .multilineTextAlignment(.center)
                        .font(.system(.body, design: .monospaced))
                        .focused($copiesFocused)
                        .onSubmit { commitEdit() }
                        .onExitCommand { isEditingCopies = false }
                        .onTapGesture {}
                } else {
                    Text("\(group.copies)")
                        .frame(width: 40, alignment: .center)
                        .font(.system(.body, design: .monospaced))
                        .onTapGesture(count: 2) {
                            copiesText = "\(group.copies)"
                            isEditingCopies = true
                            copiesFocused = true
                        }
                }

                Button { onCopiesChanged(group.copies + 1) } label: {
                    Image(systemName: "plus.circle")
                }.buttonStyle(.plain)
            }
            .frame(width: 100, alignment: .center)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.collateGroup.opacity(isMergeTarget ? 0.22 : 0.09))
        // Top of the collate-colour spine that runs down the whole collate group.
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.collateGroup.opacity(0.55)).frame(width: 3)
        }
        .onChange(of: copiesFocused) { _, focused in
            if !focused && isEditingCopies { commitEdit() }
        }
    }

    private func commitEdit() {
        if let value = Int(copiesText), value >= 1 { onCopiesChanged(value) }
        isEditingCopies = false
    }
}


// MARK: - Preset Part Row (shared by sidebar and preferences)
/// One row in a parts list. Minus at copies == 1 deletes the part.
/// Double-click the copy count to type a number directly.
struct PresetPartRow: View {
    @Binding var part: PresetPart
    var isUnmatched: Bool = false
    var onMarkDirty: () -> Void
    var onDelete: () -> Void
    /// Pass non-nil to show up/down reorder buttons (preferences panel).
    /// Leave nil to hide them (sidebar).
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil

    // Name editing
    @State private var isEditingName = false
    @State private var nameText = ""
    @FocusState private var nameFocused: Bool

    // Copies editing
    @State private var isEditingCopies = false
    @State private var copiesText = ""
    @FocusState private var copiesFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            // Up / down reorder buttons (preferences only)
            if onMoveUp != nil || onMoveDown != nil {
                VStack(spacing: 1) {
                    Button { onMoveUp?() } label: {
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(onMoveUp == nil)

                    Button { onMoveDown?() } label: {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .disabled(onMoveDown == nil)
                }
                .foregroundColor(.secondary)
                .padding(.trailing, 2)
            }

            // Name — double-click to rename inline
            if isEditingName {
                TextField("", text: $nameText)
                    .frame(maxWidth: .infinity)
                    .font(.callout)
                    .focused($nameFocused)
                    .onSubmit { commitNameEdit() }
                    .onExitCommand { isEditingName = false }
                    .onTapGesture {}
            } else {
                Text(part.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .font(.callout)
                    .onTapGesture(count: 2) {
                        nameText = part.name
                        isEditingName = true
                        nameFocused = true
                    }
            }

            HStack(spacing: 2) {
                Button {
                    if part.copies > 1 {
                        part.copies -= 1
                        onMarkDirty()
                    } else {
                        onDelete()
                    }
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)

                if isEditingCopies {
                    TextField("", text: $copiesText)
                        .frame(width: 32)
                        .multilineTextAlignment(.center)
                        .font(.system(.callout, design: .monospaced))
                        .focused($copiesFocused)
                        .onSubmit { commitCopiesEdit() }
                        .onExitCommand { isEditingCopies = false }
                        .onTapGesture {}
                } else {
                    Text("\(part.copies)")
                        .frame(width: 28, alignment: .center)
                        .font(.system(.callout, design: .monospaced))
                        .onTapGesture(count: 2) {
                            copiesText = "\(part.copies)"
                            isEditingCopies = true
                            copiesFocused = true
                        }
                }

                Button {
                    part.copies += 1
                    onMarkDirty()
                } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 1)
        .background(isUnmatched ? Color.orange.opacity(0.12) : Color.clear)
        .onChange(of: nameFocused) { _, focused in
            if !focused && isEditingName { commitNameEdit() }
        }
        .onChange(of: copiesFocused) { _, focused in
            if !focused && isEditingCopies { commitCopiesEdit() }
        }
    }

    private func commitNameEdit() {
        let trimmed = nameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            part.name = trimmed
            onMarkDirty()
        }
        isEditingName = false
    }

    private func commitCopiesEdit() {
        if let v = Int(copiesText), v >= 1 {
            part.copies = v
            onMarkDirty()
        }
        isEditingCopies = false
    }
}

// MARK: - New Preset Sheet
/// Modal sheet for creating a new preset. Lets the user pick one of three
/// starting templates and give it a custom name before confirming.
struct NewPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (_ name: String, _ parts: [PresetPart]) -> Void

    enum PresetTemplate: String, CaseIterable, Identifiable {
        case windBand   = "Wind Band"
        case jazzBand   = "Jazz Band"
        case orchestra  = "Orchestra"
        var id: Self { self }

        var parts: [PresetPart] {
            switch self {
            case .windBand:  return EnsemblePresetStore.windBandTemplate
            case .jazzBand:  return EnsemblePresetStore.jazzTemplate
            case .orchestra: return EnsemblePresetStore.orchestraTemplate
            }
        }
        var subtitle: String {
            switch self {
            case .windBand:  return "Concert band — woodwinds, brass & percussion"
            case .jazzBand:  return "Big band — saxes, brass & rhythm section"
            case .orchestra: return "Strings, woodwinds, brass & percussion"
            }
        }
    }

    @State private var selected: PresetTemplate = .windBand
    @State private var name: String = PresetTemplate.windBand.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Preset")
                .font(.title2)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Choose a starting template:")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 10) {
                ForEach(PresetTemplate.allCases) { template in
                    TemplateCard(
                        title: template.rawValue,
                        subtitle: template.subtitle,
                        isSelected: selected == template
                    ) {
                        selected = template
                        // Auto-fill name when it still matches a template name
                        if PresetTemplate.allCases.map(\.rawValue).contains(name) {
                            name = template.rawValue
                        }
                    }
                }
            }

            HStack {
                Text("Name:")
                    .fontWeight(.medium)
                TextField("Preset name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create Preset") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    onCreate(n, selected.parts)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 500)
    }
}

private struct TemplateCard: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                Text(title)
                    .fontWeight(.semibold)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preset Sidebar View
struct PresetSidebarView: View {
    @EnvironmentObject var presetStore: EnsemblePresetStore
    let onApply: (_ parts: [PresetPart], _ stampId: UUID?) -> (matched: Int, unmatched: Int, unmatchedPartNames: Set<String>)

    /// Local draft — changes aren't committed to the preset until "Save to Preset"
    @State private var draftParts: [PresetPart] = []
    @State private var isDirty = false
    @State private var showingNewPreset = false
    @State private var applyResult: (matched: Int, unmatched: Int, unmatchedPartNames: Set<String>)? = nil

    private var selectedPreset: EnsemblePreset? { presetStore.selectedPreset }

    var body: some View {
        VStack(spacing: 0) {
            // Header + preset picker (only shown when presets exist)
            if !presetStore.presets.isEmpty {
                VStack(spacing: 6) {
                    HStack {
                        Text("Presets")
                            .font(.headline)
                        Spacer()
                        Button {
                            showingNewPreset = true
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("New Preset")
                    }

                    Picker("", selection: Binding(
                        get: { presetStore.selectedPresetId },
                        set: { switchPreset(to: $0) }
                    )) {
                        ForEach(presetStore.presets) { preset in
                            Text(preset.name).tag(Optional(preset.id))
                        }
                    }
                    .labelsHidden()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

                if let preset = selectedPreset {
                    PresetStampPicker(stampId: Binding(
                        get: { preset.stampId },
                        set: { newValue in
                            var updated = preset
                            updated.stampId = newValue
                            presetStore.updatePreset(updated)
                        }
                    ))
                    .controlSize(.small)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }

                Divider()
            }

            if presetStore.presets.isEmpty {
                // Empty state — prompt to create first preset
                VStack(spacing: 14) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No presets yet")
                        .font(.headline)
                    Text("Create a preset to store copy counts for an ensemble.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("New Preset…") {
                        showingNewPreset = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            } else if !draftParts.isEmpty {
                // Parts list
                List {
                    ForEach($draftParts) { $part in
                        PresetPartRow(
                            part: $part,
                            isUnmatched: applyResult?.unmatchedPartNames.contains(part.name) ?? false,
                            onMarkDirty: { isDirty = true; applyResult = nil },
                            onDelete: {
                                draftParts.removeAll { $0.id == part.id }
                                draftParts = renumberAfterDeletion(draftParts)
                                isDirty = true
                                applyResult = nil
                            }
                        )
                    }
                }
                .listStyle(.plain)

                Divider()

                // Action area
                VStack(spacing: 8) {
                    if isDirty {
                        HStack(spacing: 8) {
                            Button("Revert") {
                                draftParts = selectedPreset?.parts ?? []
                                isDirty = false
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Save to Preset") {
                                if var p = selectedPreset {
                                    p.parts = draftParts
                                    presetStore.updatePreset(p)
                                    isDirty = false
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    Button {
                        applyResult = onApply(draftParts, selectedPreset?.stampId)
                    } label: {
                        Label("Apply to Files", systemImage: "arrow.left.to.line")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    // Apply result summary
                    if let result = applyResult {
                        if result.unmatched == 0 {
                            Label("\(result.matched) file\(result.matched == 1 ? "" : "s") matched", systemImage: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            VStack(spacing: 2) {
                                Label("\(result.matched) matched", systemImage: "checkmark.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.green)
                                Label("\(result.unmatched) not matched — see orange rows", systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear { loadDraft() }
        .onChange(of: presetStore.selectedPresetId) { loadDraft() }
        // Keep the parts list in sync when the selected preset is edited
        // elsewhere (e.g. the Preferences window) — but never clobber unsaved
        // local edits, so we skip the reload while this sidebar is dirty.
        .onChange(of: presetStore.selectedPreset) { _, fresh in
            guard !isDirty, let fresh, fresh.parts != draftParts else { return }
            draftParts = fresh.parts
            applyResult = nil
        }
        .sheet(isPresented: $showingNewPreset) {
            NewPresetSheet { name, parts in
                presetStore.addPreset(name: name, parts: parts)
                loadDraft()
            }
        }
    }

    private func loadDraft() {
        draftParts = selectedPreset?.parts ?? []
        isDirty = false
        applyResult = nil
    }

    private func switchPreset(to newId: UUID?) {
        if isDirty {
            let alert = NSAlert()
            alert.messageText = "Unsaved Changes"
            alert.informativeText = "Discard changes to this preset?"
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        presetStore.selectedPresetId = newId
        isDirty = false
    }
}


// MARK: - Ensemble Preset Model

struct PresetPart: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var copies: Int
}

struct EnsemblePreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var parts: [PresetPart]
    /// A saved stamp this ensemble belongs to — a school or organisation's mark. Applying
    /// the preset arms that stamp for the output. Optional, and an optional property decodes
    /// as nil when absent, so presets saved before this keep working.
    var stampId: UUID?
}

class EnsemblePresetStore: ObservableObject {
    @Published var presets: [EnsemblePreset] = []
    @Published var selectedPresetId: UUID?

    var selectedPreset: EnsemblePreset? {
        presets.first { $0.id == selectedPresetId }
    }

    private var storeURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let folder = dir.appendingPathComponent("ScoreSort", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("ensemble-presets.json")
    }

    init() {
        load()
        if selectedPresetId == nil { selectedPresetId = presets.first?.id }
    }

    func save() {
        guard let url = storeURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(presets) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        guard let url = storeURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([EnsemblePreset].self, from: data)
        else { return }
        presets = decoded
        selectedPresetId = presets.first?.id
    }

    func addPreset(name: String, parts: [PresetPart]) {
        let p = EnsemblePreset(name: name, parts: parts)
        presets.append(p)
        selectedPresetId = p.id
        save()
    }

    func updatePreset(_ preset: EnsemblePreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
            save()
        }
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if selectedPresetId == id {
            selectedPresetId = presets.first?.id
        }
        save()
    }

    func movePresets(from: IndexSet, to: Int) {
        presets.move(fromOffsets: from, toOffset: to)
        save()
    }

    func duplicatePreset(_ id: UUID) {
        guard let original = presets.first(where: { $0.id == id }) else { return }
        let copy = EnsemblePreset(
            id: UUID(),
            name: "Copy of \(original.name)",
            parts: original.parts.map { PresetPart(id: UUID(), name: $0.name, copies: $0.copies) }
        )
        if let idx = presets.firstIndex(where: { $0.id == id }) {
            presets.insert(copy, at: idx + 1)
        } else {
            presets.append(copy)
        }
        selectedPresetId = copy.id
        save()
    }

    func exportCSV() -> String {
        var lines = ["Preset Name,Part Name,Copies"]
        for preset in presets {
            for part in preset.parts {
                func escape(_ s: String) -> String {
                    s.contains(",") || s.contains("\"") ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
                }
                lines.append("\(escape(preset.name)),\(escape(part.name)),\(part.copies)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func importCSV(_ string: String) {
        var partsByPreset: [String: [PresetPart]] = [:]
        var order: [String] = []
        let lines = string.components(separatedBy: .newlines).dropFirst()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let fields = Self.parseCSVLine(trimmed)
            guard fields.count >= 2 else { continue }
            let presetName = fields[0]
            let partName   = fields[1]
            let copies     = fields.count >= 3 ? (Int(fields[2]) ?? 1) : 1
            if partsByPreset[presetName] == nil {
                partsByPreset[presetName] = []
                order.append(presetName)
            }
            partsByPreset[presetName]?.append(PresetPart(name: partName, copies: copies))
        }
        for name in order {
            if let parts = partsByPreset[name], !parts.isEmpty {
                addPreset(name: name, parts: parts)
            }
        }
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                let next = line.index(after: i)
                if inQuotes && next < line.endIndex && line[next] == "\"" {
                    current.append("\"")
                    i = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields
    }

    // MARK: - Built-in templates

    static let windBandTemplate: [PresetPart] = [
        "Score",
        "Piccolo", "Flute 1", "Flute 2",
        "Oboe", "Bassoon",
        "Clarinet 1", "Clarinet 2", "Clarinet 3",
        "Bass Clarinet",
        "Alto Saxophone 1", "Alto Saxophone 2",
        "Tenor Saxophone", "Baritone Saxophone",
        "Trumpet 1", "Trumpet 2", "Trumpet 3",
        "Horn 1", "Horn 2",
        "Trombone 1", "Trombone 2", "Bass Trombone",
        "Euphonium BC", "Tuba",
        "Timpani",
        "Percussion 1", "Percussion 2", "Percussion 3",
    ].map { PresetPart(name: $0, copies: 1) }

    static let jazzTemplate: [PresetPart] = [
        "Score",
        "Alto Saxophone 1", "Alto Saxophone 2",
        "Tenor Saxophone 1", "Tenor Saxophone 2",
        "Baritone Saxophone",
        "Trumpet 1", "Trumpet 2", "Trumpet 3", "Trumpet 4",
        "Trombone 1", "Trombone 2", "Trombone 3", "Bass Trombone",
        "Guitar", "Piano", "Bass", "Drums",
    ].map { PresetPart(name: $0, copies: 1) }

    static let orchestraTemplate: [PresetPart] = [
        "Score",
        "Flute 1", "Flute 2", "Piccolo",
        "Oboe 1", "Oboe 2",
        "Clarinet 1", "Clarinet 2",
        "Bassoon 1", "Bassoon 2",
        "Horn 1", "Horn 2", "Horn 3", "Horn 4",
        "Trumpet 1", "Trumpet 2",
        "Trombone 1", "Trombone 2", "Bass Trombone",
        "Tuba",
        "Timpani", "Percussion",
        "Harp",
        "Violin I", "Violin II",
        "Viola", "Cello", "Double Bass",
    ].map { PresetPart(name: $0, copies: 1) }
}

// MARK: - Combine File Model

/// A named group of files whose pages are interleaved (collated) when combining.
/// e.g. 4 copies of [Perc1, Perc2, Timpani] → Perc1, Perc2, Timp, Perc1, Perc2, Timp, …
struct CollateGroup: Identifiable, Equatable {
    let id: UUID
    var copies: Int
}

struct CombineFile: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let name: String
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
    /// Booklet only — which way the printer turns the paper, so imposition can lay the back
    /// of each sheet out to suit. Not a request to the printer: the print panel resets duplex
    /// from the printer's own preset, so this describes what the printer will do, rather than
    /// telling it what to do.
    var duplexFlip: BookletDuplexFlip = .longEdge
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
                files.append(CombineFile(url: url, name: url.lastPathComponent, pageCount: document.pageCount, copies: 1))
            } else {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { continue }
                let frameCount = CGImageSourceGetCount(src)
                guard frameCount > 0 else { continue }
                files.append(CombineFile(url: url, name: url.lastPathComponent, pageCount: frameCount, copies: 1))
            }
        }
        if files.count != bf.count {
            registerUndo(undoManager: undoManager, actionName: "Add Files",
                         restoringFiles: bf, restoringGroups: bg)
        }
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
    private func buildDocument(options: CombineOutputOptions, stampJob: StampJob?,
                               rotateBackFaces: Bool = false)
        -> (doc: PDFDocument, pageCount: Int, bookmarks: [(label: String, pageIndex: Int)]) {
        var doc = PDFDocument()
        var idx = 0
        var bookmarks: [(label: String, pageIndex: Int)] = []
        var partLayouts: [BookletPartLayout] = []

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
                for page in pdfPages(fromImageAt: file.url) { doc.insert(page, at: idx); idx += 1 }
            } else {
                guard let src = PDFDocument(url: file.url) else { return }
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
        doc = applyingStamp(stampJob, to: doc, partFirstPages: bookmarks.map { $0.pageIndex })

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
                                                    layouts: layouts) {
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

        let root = PDFOutline()
        for (label, pageIndex) in bookmarks {
            if let page = doc.page(at: pageIndex) {
                let item = PDFOutline()
                item.label = label
                item.destination = PDFDestination(page: page, at: .zero)
                root.insertChild(item, at: root.numberOfChildren)
            }
        }
        doc.outlineRoot = root

        return (doc, pageCount, bookmarks)
    }

    func createCombinedPDF(to url: URL, options: CombineOutputOptions,
                           stampJob: StampJob? = nil, completion: PDFAlertHandler) {
        let built = buildDocument(options: options, stampJob: stampJob)
        if built.doc.write(to: url) {
            let unit = options.layout == .booklet ? "booklet sheet sides" : "pages"
            completion("PDF Created Successfully",
                       "Combined PDF with \(built.pageCount) \(unit) saved to:\n\(url.path)", false)
        } else {
            completion("Error", "Failed to create PDF", true)
        }
    }

    func openInPreview(options: CombineOutputOptions, stampJob: StampJob? = nil, onError: PDFAlertHandler) {
        let built = buildDocument(options: options, stampJob: stampJob)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("CombinedForPrint.pdf")
        guard built.doc.write(to: tempURL) else { onError("Error", "Failed to create temporary PDF", true); return }
        NSWorkspace.shared.open(tempURL)
    }

    /// Builds the document and hands it straight to the system print dialog, so a whole
    /// folder of booklets is one print job rather than one per part.
    @MainActor
    func printCombined(options: CombineOutputOptions, stampJob: StampJob? = nil,
                       in window: NSWindow?, onError: PDFAlertHandler) {
        let built = buildDocument(options: options, stampJob: stampJob,
                                  rotateBackFaces: shouldRotateBackFaces(options))
        printPDFDocument(built.doc,
                         jobName: "ScoreSort \u{2014} Combined",
                         wantsTwoSided: options.layout == .booklet,
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
