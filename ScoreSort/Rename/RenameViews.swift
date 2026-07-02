//
//  RenameViews.swift
//  ScoreSort
//
//  Rename Files tab — the Score Order Sorter (single- and batch-folder renaming),
//  its summaries and file rows, the manual instrument-assignment sheet, and the
//  Bulk Part Rename flow. View model lives in Rename/RenamerManager.swift; the
//  score-order prefix step it shares with the splitter is in Split/SplitPrefixStep.swift.
//

import SwiftUI
@preconcurrency import PDFKit
import UniformTypeIdentifiers
import Combine

// MARK: - Rename Tab (wrapper)
/// Hosts both panels side-by-side inside the "Rename Files" tab.
struct RenamerView: View {
    @EnvironmentObject private var renamerManager: RenamerManager
    @State private var bulkHasFiles: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Hide the Score Order Sorter (and divider) when Bulk Rename is
            // active — but keep BulkRenameView permanently in the tree so its
            // @State (loadedFiles etc.) survives the layout switch.
            if !bulkHasFiles {
                ScoreOrderSortView()
                if !renamerManager.hasContent {
                    Divider()
                }
            }
            if !renamerManager.hasContent {
                BulkRenameView(hasFiles: $bulkHasFiles)
            }
        }
    }
}

// MARK: - Score Order Sort View
struct ScoreOrderSortView: View {
    @EnvironmentObject private var renamerManager: RenamerManager
    @EnvironmentObject private var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var selectedFileForAssignment: RenameOperation?
    @State private var isFolderTargeted = false
    @State private var isListDropTargeted = false
    @State private var renameResult: (folderURL: URL?, names: [String])? = nil

    // ── Batch state ───────────────────────────────────────────────────────
    /// Ordered folders in the current batch. `count <= 1` means non-batch (single
    /// folder); the batch UI only appears when `count > 1`.
    @State private var batchFolders: [URL] = []
    /// Index of the folder currently loaded for review within `batchFolders`.
    @State private var batchPosition: Int = 0
    /// Per-folder results accumulated as each folder is renamed (for the final summary).
    @State private var batchResults: [(folder: URL?, names: [String])] = []

    // ── Selection state ───────────────────────────────────────────────────
    /// IDs of currently-selected operations (stable across re-scans).
    @State private var selectedIDs: Set<String> = []
    /// Last directly-clicked operation, used as the anchor for shift+click range selection.
    @State private var lastClickedID: String? = nil
    /// NSEvent key-down monitor; installed while the file list is visible.
    @State private var keyEventMonitor: Any? = nil

    /// All operations in display order (undetected → detected → excluded),
    /// used to compute shift+click ranges.
    private var allDisplayedOps: [RenameOperation] {
        let undetected = renamerManager.operations.filter { $0.type == .undetected }
        let rest       = renamerManager.operations.filter { $0.type != .undetected && $0.type != .excluded }
        let excluded   = renamerManager.operations.filter { $0.type == .excluded }
        return undetected + rest + excluded
    }

    private func handleSelect(_ operation: RenameOperation, command: Bool, shift: Bool) {
        if command {
            if selectedIDs.contains(operation.id) {
                selectedIDs.remove(operation.id)
            } else {
                selectedIDs.insert(operation.id)
            }
            lastClickedID = operation.id
        } else if shift, let lastID = lastClickedID,
                  let lastIdx    = allDisplayedOps.firstIndex(where: { $0.id == lastID }),
                  let currentIdx = allDisplayedOps.firstIndex(where: { $0.id == operation.id }) {
            let lo = min(lastIdx, currentIdx)
            let hi = max(lastIdx, currentIdx)
            selectedIDs.formUnion(allDisplayedOps[lo...hi].map { $0.id })
            // Note: lastClickedID intentionally unchanged for shift+click (standard behaviour)
        } else {
            selectedIDs = [operation.id]
            lastClickedID = operation.id
        }
    }

    private func excludeSelected() {
        let names = Set(
            renamerManager.operations
                .filter { selectedIDs.contains($0.id) && $0.type != .excluded }
                .map { $0.originalName }
        )
        guard !names.isEmpty else { return }
        renamerManager.setExcluded(names, excluded: true)
        // Keep IDs selected so the user can see what moved; they'll survive the re-scan
        // because IDs are stable. Clear lastClickedID to avoid stale range anchors.
        lastClickedID = nil
    }

    /// Handles a folder/file drop that (re)starts the rename flow. Used by both the
    /// empty drop zone and the "done" summary screen, so finishing a job and dropping a
    /// new folder restarts immediately without clicking Start Over. `loadFolder`/`loadFiles`
    /// fully reset the manager; clearing `renameResult` leaves the done screen.
    private func handleRestartDrop(_ providers: [NSItemProvider]) -> Bool {
        collectDroppedFileURLs(from: providers) { urls in
            guard !urls.isEmpty else { return }
            startInput(urls)
        }
        return true
    }

    // ── Batch import / queue ──────────────────────────────────────────────
    /// Routes a set of imported URLs: any folders start a batch (one job each); a pure
    /// file selection loads as individual files (current behaviour). A single folder is
    /// just a batch of one, so the flow is identical to before for the common case.
    private func startInput(_ urls: [URL]) {
        renameResult = nil   // leave the done screen if we're on it
        let folders = urls.filter { urlIsDirectory($0) }
        if folders.isEmpty {
            resetBatch()
            renamerManager.loadFiles(urls: urls)
            return
        }
        let jobs = expandToRenameJobFolders(folders)
        if jobs.isEmpty {
            // No renamable files anywhere under the dropped folders — load the first one
            // so the user sees its (empty) state rather than nothing happening.
            resetBatch()
            renamerManager.loadFolder(url: folders[0])
        } else {
            beginBatch(jobs)
        }
    }

    private func beginBatch(_ folders: [URL]) {
        batchFolders = folders
        batchPosition = 0
        batchResults = []
        renameResult = nil
        renamerManager.loadFolder(url: folders[0])
    }

    private func resetBatch() {
        batchFolders = []
        batchPosition = 0
        batchResults = []
    }

    /// True when more than one folder is queued — drives the batch UI.
    private var isBatchActive: Bool { batchFolders.count > 1 }

    /// Advances to the next folder in the batch, or finishes by showing the combined
    /// summary. Called after a rename (`recordResult` carries that folder's outcome) or
    /// from Skip (`recordResult == nil`).
    private func advanceOrFinish(recordResult: (folder: URL?, names: [String])?) {
        if let recordResult { batchResults.append(recordResult) }
        if batchPosition + 1 < batchFolders.count {
            batchPosition += 1
            selectedIDs = []
            lastClickedID = nil
            renamerManager.loadFolder(url: batchFolders[batchPosition])
        } else {
            // Finished — trigger the Done screen. The combined summary renders from
            // batchResults when >1; otherwise we point at the last *renamed* folder
            // (not a trailing skip, which appends nothing) so its files still show.
            renameResult = (folderURL: batchResults.last?.folder,
                            names: batchResults.last?.names ?? [])
        }
    }

    /// Skip the current folder without renaming it, advancing to the next (or finishing).
    private func skipCurrent() {
        advanceOrFinish(recordResult: nil)
    }

    /// Reorders only the *upcoming* tail of the queue (folders after the current one).
    private func moveUpcoming(from source: IndexSet, to destination: Int) {
        let head = Array(batchFolders[...batchPosition])           // done + current (fixed)
        var tail = Array(batchFolders[(batchPosition + 1)...])     // upcoming (reorderable)
        tail.move(fromOffsets: source, toOffset: destination)
        batchFolders = head + tail
    }

    /// Other PDF files in the same folder as the currently-loaded individual files
    /// that haven't been added yet. Nil when irrelevant (folder-mode load, files
    /// span multiple folders, or there are no additional files).
    private var additionalFolderFiles: [URL]? {
        let files = renamerManager.directFiles
        guard !files.isEmpty else { return nil }
        let folders = Set(files.map { $0.deletingLastPathComponent().standardizedFileURL })
        guard folders.count == 1, let folder = folders.first else { return nil }
        let all = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ))?.filter { renamableFileExtensions.contains($0.pathExtension.lowercased()) } ?? []
        let existing = Set(files.map { $0.standardizedFileURL })
        let extra = all.filter { !existing.contains($0.standardizedFileURL) }
        return extra.isEmpty ? nil : extra
    }

    var body: some View {
        content
            .onAppear { DispatchQueue.main.async { syncTabCommands() } }
            .onChange(of: appState.selectedTab)        { DispatchQueue.main.async { syncTabCommands() } }
            .onChange(of: renamerManager.hasContent)   { DispatchQueue.main.async { syncTabCommands() } }
            .onChange(of: renamerManager.renameCount)  { DispatchQueue.main.async { syncTabCommands() } }
            .onChange(of: selectedIDs)                 { DispatchQueue.main.async { syncTabCommands() } }
            .onChange(of: batchFolders)                { DispatchQueue.main.async { syncTabCommands() } }
            .onChange(of: renameResult == nil)         { DispatchQueue.main.async { syncTabCommands() } }
    }

    /// Publishes the Score Order Sorter's actions to the menu bridge while Rename is active.
    private func syncTabCommands() {
        guard appState.selectedTab == 1 else { return }
        let reviewing = renamerManager.hasContent && renameResult == nil
        var slice = TabSlice()
        slice.openTitle    = "Choose Files or Folder\u{2026}"
        slice.open         = { selectFolder() }
        slice.primaryTitle = "Rename Files"
        slice.primarySave  = (reviewing && renamerManager.renameCount > 0) ? {
            renamerManager.executeRename { folderURL, names in
                advanceOrFinish(recordResult: (folder: folderURL, names: names))
            }
        } : nil
        slice.clear = reviewing ? {
            resetBatch(); renamerManager.clearFolder(); selectedIDs = []; lastClickedID = nil
        } : nil

        var actions: [MenuAction] = []
        if reviewing {
            let hasExcludable = renamerManager.operations.contains { selectedIDs.contains($0.id) && $0.type != .excluded }
            actions.append(MenuAction(title: "Don't Rename Selected", isEnabled: hasExcludable, perform: { excludeSelected() }))
            actions.append(MenuAction(title: "Rescan Folder", perform: { renamerManager.scanFolder() }))
            if isBatchActive { actions.append(MenuAction(title: "Skip Folder", perform: { skipCurrent() })) }
        }
        if renameResult != nil {
            actions.append(MenuAction(title: "Start Over", perform: {
                renameResult = nil; resetBatch(); renamerManager.clearFolder()
            }))
        }
        slice.tabActions = actions
        appState.tabCommands.slice = slice
    }

    @ViewBuilder private var content: some View {
        if let result = renameResult {
            // ── Done screen ───────────────────────────────────────────────
            ScoreOrderRenameSummaryView(
                renamedNames: result.names,
                folderURL: result.folderURL,
                perFolder: batchResults.count > 1 ? batchResults : nil,
                onStartOver: {
                    renameResult = nil
                    resetBatch()
                    renamerManager.clearFolder()
                },
                onRescan: {
                    renameResult = nil
                    renamerManager.scanFolder()
                }
            )
            // Drop a new folder/files here to restart without clicking Start Over.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleRestartDrop(providers) }
        } else {
            VStack(spacing: 0) {
                // ── Top toolbar ───────────────────────────────────────────────
                HStack {
                    Text("Score Order Sorter")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    if renamerManager.hasContent {
                        Toggle(isOn: Binding(
                            get: { renamerManager.isRescanMode },
                            set: { renamerManager.setRescanMode($0) }
                        )) {
                            Text("Renumber prefixed files")
                        }
                        .toggleStyle(.checkbox)
                        .help("When on, files that already have a numeric prefix are renumbered along with the rest")
                        // "Don't Rename" — moves the selected files to the excluded section.
                        // Enabled only when at least one non-excluded file is selected.
                        let hasExcludableSelection = renamerManager.operations.contains {
                            selectedIDs.contains($0.id) && $0.type != .excluded
                        }
                        Button {
                            excludeSelected()
                        } label: {
                            Label("Don't Rename", systemImage: "slash.circle")
                        }
                        .disabled(!hasExcludableSelection)
                        .help("Move selected files to the Don't Rename section so they are skipped")
                        Button {
                            UserDefaults.standard.set("renamer", forKey: "preferredPrefsTab")
                            openSettings()
                        } label: {
                            Label("Preferences", systemImage: "gearshape")
                        }
                        Button(action: {
                            resetBatch()
                            renamerManager.clearFolder()
                            selectedIDs = []
                            lastClickedID = nil
                        }) {
                            Label(isBatchActive ? "Cancel Batch" : "Clear Files", systemImage: "xmark.circle.fill")
                        }
                        .help(isBatchActive ? "Stop the batch and clear all folders" : "Remove all files and start over")
                    }
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                if isBatchActive && renamerManager.hasContent {
                    batchQueueBar
                    Divider()
                }

                if renamerManager.hasContent {
                    fileListView
                        .onAppear {
                            // Install a key monitor so ⌫ excludes selected files without
                            // needing SwiftUI focus on the list (which is unreliable for
                            // a non-text ScrollView on macOS).
                            keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                                // Only act on the Rename tab — this app-global monitor stays
                                // installed across tab switches (TabView keeps tabs mounted).
                                guard appState.selectedTab == 1 else { return event }
                                // keyCode 51 = Delete/Backspace
                                if event.keyCode == 51, !selectedIDs.isEmpty {
                                    excludeSelected()
                                    return nil   // consume the event
                                }
                                return event
                            }
                        }
                        .onDisappear {
                            if let m = keyEventMonitor {
                                NSEvent.removeMonitor(m)
                                keyEventMonitor = nil
                            }
                        }
                    Divider()
                    bottomControlsView
                } else {
                    folderSelectionView
                }
            }
            .sheet(item: $selectedFileForAssignment) { operation in
                ManualAssignmentView(
                    operation: operation,
                    existingNumbers: renamerManager.getExistingNumbers(),
                    onAssign: { number in
                        renamerManager.setManualOverride(for: operation.originalName, number: number)
                        selectedFileForAssignment = nil
                    }
                )
            }
        }
    }

    // ── Drop zone (shown when no files loaded) ────────────────────────────
    private var folderSelectionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 64))
                .foregroundColor(isFolderTargeted ? .accentColor : .secondary)
            Text("Select Files or Folder")
                .font(.title2)
                .fontWeight(.medium)
            Text("Drag one or more folders (or PDF / image files) here")
                .font(.callout)
                .foregroundColor(isFolderTargeted ? .accentColor : .secondary)
            Text("or")
                .foregroundColor(.secondary)
            Button(action: selectFolder) {
                Label("Choose Files or Folders", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("Adds sequential prefixes based on detected instrument names. Works with PDFs and image scans (JPG, PNG…). Drop several folders to rename them in a batch.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isFolderTargeted ? Color.accentColor : Color.gray.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [10])
                )
                .padding()
        )
        .onDrop(of: [.fileURL], isTargeted: $isFolderTargeted) { providers in
            handleRestartDrop(providers)
        }
    }

    // ── File list ─────────────────────────────────────────────────────────
    private var fileListView: some View {
        let undetected = renamerManager.operations.filter { $0.type == .undetected }
        let detected   = renamerManager.operations.filter { $0.type != .undetected && $0.type != .excluded }
        let excluded   = renamerManager.operations.filter { $0.type == .excluded }
        return ScrollView {
            LazyVStack(spacing: 0) {
                // Undetected section
                if !undetected.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("Unmatched — instrument not recognised")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.10))

                    ForEach(undetected) { operation in
                        ScoreOrderFileRow(
                            operation: operation,
                            isUnmatched: true,
                            isSelected: selectedIDs.contains(operation.id),
                            onDoubleClick: { selectedFileForAssignment = operation },
                            onSelect: { cmd, shift in handleSelect(operation, command: cmd, shift: shift) }
                        )
                        Divider()
                    }
                }

                // Detected / matched section
                if !detected.isEmpty {
                    if !undetected.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                            Text("Matched")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color(NSColor.controlBackgroundColor))
                    }

                    ForEach(detected) { operation in
                        ScoreOrderFileRow(
                            operation: operation,
                            isSelected: selectedIDs.contains(operation.id),
                            onDoubleClick: { selectedFileForAssignment = operation },
                            onSelect: { cmd, shift in handleSelect(operation, command: cmd, shift: shift) }
                        )
                        Divider()
                    }
                }

                // Don't Rename section — files the user has explicitly excluded.
                if !excluded.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "slash.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                        Text("Won't be renamed")
                            .font(.caption)
                            .foregroundColor(.red)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.08))

                    ForEach(excluded, id: \.excludedSectionID) { operation in
                        ScoreOrderFileRow(
                            operation: operation,
                            isSelected: selectedIDs.contains(operation.id),
                            onDoubleClick: { selectedFileForAssignment = operation },
                            onSelect: { cmd, shift in handleSelect(operation, command: cmd, shift: shift) },
                            onRestore: {
                                renamerManager.setExcluded([operation.originalName], excluded: false)
                                selectedIDs.remove(operation.id)
                            }
                        )
                        Divider()
                    }
                }

                // "Add more from folder" button — only when individual files were
                // loaded and there are unchosen PDFs in the same folder.
                if let extras = additionalFolderFiles {
                    Button {
                        renamerManager.addFiles(urls: extras)
                    } label: {
                        Label(
                            "Add \(extras.count) more file\(extras.count == 1 ? "" : "s") from this folder",
                            systemImage: "plus.circle"
                        )
                    }
                    .buttonStyle(.bordered)
                    .padding()
                    .frame(maxWidth: .infinity)
                }
            }
        }
        // Accept additional file drops onto the file list once files are already loaded.
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isListDropTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                .padding(4)
                .allowsHitTesting(false)
        )
        .onDrop(of: [.fileURL], isTargeted: $isListDropTargeted) { providers in
            collectDroppedFileURLs(from: providers) { urls in
                renamerManager.addFiles(urls: urls)
            }
            return true
        }
    }

    // ── Batch queue bar ───────────────────────────────────────────────────
    private var batchQueueBar: some View {
        let upcoming = batchPosition + 1 < batchFolders.count
            ? Array(batchFolders[(batchPosition + 1)...]) : []
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundColor(.accentColor)
                Text("Folder \(batchPosition + 1) of \(batchFolders.count)")
                    .fontWeight(.semibold)
                Text("·").foregroundColor(.secondary)
                Text(qualifiedFolderName(for: batchFolders[batchPosition], among: batchFolders))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(action: skipCurrent) {
                    Label("Skip Folder", systemImage: "forward.end")
                }
                .help("Skip this folder without renaming it and move to the next")
            }
            if !upcoming.isEmpty {
                Text("Up next — drag to reorder")
                    .font(.caption)
                    .foregroundColor(.secondary)
                List {
                    ForEach(upcoming, id: \.self) { url in
                        HStack(spacing: 6) {
                            Image(systemName: "folder").foregroundColor(.secondary)
                            Text(qualifiedFolderName(for: url, among: batchFolders))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .listRowSeparator(.hidden)
                    }
                    .onMove(perform: moveUpcoming)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: min(CGFloat(upcoming.count) * 26 + 8, 132))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.06))
    }

    // ── Bottom controls ───────────────────────────────────────────────────
    private var bottomControlsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Ensemble:")
                    .font(.headline)
                Picker("", selection: $renamerManager.ensembleType) {
                    Text("Wind Band").tag(EnsembleType.band)
                    Text("Jazz Band").tag(EnsembleType.jazz)
                    Text("Orchestra").tag(EnsembleType.orchestra)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                Spacer()
            }
            HStack {
                Text(renamerManager.statusText)
                    .font(.callout)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    renamerManager.executeRename { folderURL, names in
                        advanceOrFinish(recordResult: (folder: folderURL, names: names))
                    }
                } label: {
                    Label(isBatchActive && batchPosition + 1 < batchFolders.count
                          ? "Rename & Next" : "Rename Files",
                          systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(renamerManager.renameCount == 0)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    // ── Folder picker ─────────────────────────────────────────────────────
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .image, .folder]
        panel.canCreateDirectories = false
        panel.title = "Select Files or Folders"
        panel.message = "Choose one or more folders to rename in a batch, or select individual PDF/image files"
        panel.begin { response in
            guard response == .OK else { return }
            startInput(panel.urls)
        }
    }
}

// MARK: - Score Order Rename Summary

/// Full-screen done screen shown after the Score Order Sorter renames files.
private struct ScoreOrderRenameSummaryView: View {
    let renamedNames: [String]
    let folderURL: URL?
    /// Non-nil with >1 entry → render a combined multi-folder batch summary (Rescan hidden).
    var perFolder: [(folder: URL?, names: [String])]? = nil
    let onStartOver: () -> Void
    let onRescan: () -> Void

    private var isBatch: Bool { (perFolder?.count ?? 0) > 1 }
    private var totalFileCount: Int {
        isBatch ? (perFolder ?? []).reduce(0) { $0 + $1.names.count } : renamedNames.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Success header ────────────────────────────────────────────
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundColor(.green)
                Text("Done!")
                    .font(.title).fontWeight(.bold)
                if isBatch {
                    Text("\(perFolder!.count) folders · \(totalFileCount) file\(totalFileCount == 1 ? "" : "s") renamed successfully.")
                        .foregroundColor(.secondary)
                } else {
                    Text("\(renamedNames.count) file\(renamedNames.count == 1 ? "" : "s") renamed successfully.")
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
                    if isBatch {
                        let allFolders = perFolder!.compactMap { $0.folder }
                        ForEach(perFolder!.indices, id: \.self) { fi in
                            let entry = perFolder![fi]
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill").foregroundColor(.accentColor)
                                Text(entry.folder.map { qualifiedFolderName(for: $0, among: allFolders) } ?? "Folder")
                                    .fontWeight(.semibold)
                                Text("(\(entry.names.count))").foregroundColor(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.top, fi == 0 ? 0 : 8)
                            .padding(.bottom, 2)
                            ForEach(entry.names.indices, id: \.self) { i in
                                fileRow(entry.names[i]).padding(.leading, 16)
                            }
                        }
                    } else {
                        ForEach(renamedNames.indices, id: \.self) { i in
                            fileRow(renamedNames[i])
                        }
                    }
                }
                .padding(.vertical, 12)
            }

            Divider()

            // ── Bottom bar ─────────────────────────────────────────────────
            HStack(spacing: 12) {
                Button(action: onStartOver) {
                    Label("Start Over", systemImage: "arrow.uturn.left")
                }
                .buttonStyle(.bordered)

                // Show in Finder only makes sense for a single folder.
                if !isBatch, let url = folderURL {
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                // Rescan only applies to a single finished folder, not a multi-folder batch.
                if !isBatch {
                    Button(action: onRescan) {
                        Label("Rescan Folder", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Rescan the folder to review or continue renaming")
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    private func fileRow(_ name: String) -> some View {
        // No trailing Spacer: rows stay intrinsic-width so the VStack collapses to the
        // widest row and the vertical ScrollView centres the whole block (matching the
        // original single-folder summary).
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .foregroundColor(.accentColor)
                .font(.caption)
            Text(name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }
}

// MARK: - Score Order File Row
/// One row in the Score Order Sorter list — matches the visual style of PrefixOrderRow.
private struct ScoreOrderFileRow: View {
    let operation: RenameOperation
    var isUnmatched: Bool = false
    var isSelected: Bool = false
    let onDoubleClick: () -> Void
    /// Called on single, cmd, or shift click — passes (isCommandDown, isShiftDown).
    let onSelect: (_ command: Bool, _ shift: Bool) -> Void
    /// If non-nil, a restore button is shown (used for excluded rows).
    var onRestore: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // ── Left column: badge + original filename ────────────────────
            HStack(spacing: 12) {
                // Position badge or status icon
                Group {
                    switch operation.type {
                    case .alreadyPrefixed, .skip:
                        Image(systemName: "checkmark.circle")
                            .foregroundColor(.secondary)
                    case .undetected:
                        Image(systemName: "questionmark.circle.fill")
                            .foregroundColor(.orange)
                    case .excluded:
                        Image(systemName: "slash.circle")
                            .foregroundColor(.red)
                    default:
                        let prefix = String(operation.newName.prefix(2))
                        Text(prefix.isEmpty ? "??" : prefix)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.semibold)
                            .foregroundColor(.accentColor)
                    }
                }
                .frame(width: 30, alignment: .center)

                Text(operation.originalName)
                    .lineLimit(1)
                    .foregroundColor(
                        operation.type == .excluded ? .red
                        : (operation.type == .alreadyPrefixed || operation.type == .skip) ? .secondary
                        : .primary
                    )
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)

            // ── Right column: new filename or hint, status tag ────────────
            HStack(spacing: 8) {
                switch operation.type {
                case .undetected:
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Text("No instrument detected — double-click to assign")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    }
                case .alreadyPrefixed, .skip:
                    Text(operation.type == .alreadyPrefixed ? "Already prefixed — will skip" : "Already correct — will skip")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                case .excluded:
                    Text("Won't be renamed")
                        .font(.caption)
                        .foregroundColor(.red.opacity(0.8))
                        .lineLimit(1)
                default:
                    if !operation.newName.isEmpty {
                        Text(operation.newName)
                            .font(.body)
                            .foregroundColor(operation.color)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                switch operation.type {
                case .manual:
                    statusTag("Manual", color: .blue)
                case .correct:
                    statusTag("Correction", color: .orange)
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // ── Restore button — pinned to trailing edge for excluded rows ─
            if let restore = onRestore {
                Button(action: restore) {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Move back to the rename list")
                .padding(.trailing, 16)
            }
        }
        .padding(.vertical, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.15)
            : isHovered ? Color.accentColor.opacity(0.05)
            : isUnmatched ? Color.orange.opacity(0.06)
            : operation.type == .excluded ? Color.red.opacity(0.04)
            : Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onDoubleClick() }
        .onTapGesture(count: 1) {
            let flags = NSEvent.modifierFlags
            onSelect(flags.contains(.command), flags.contains(.shift))
        }
        .onHover { isHovered = $0 }
    }

    private func statusTag(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

// MARK: - Manual Assignment View
struct ManualAssignmentView: View {
    let operation: RenameOperation
    let existingNumbers: [Int]
    let onAssign: (Int) -> Void
    
    @State private var selectedNumber: Int = 1
    @Environment(\.dismiss) private var dismiss
    
    var willShiftOthers: Bool {
        existingNumbers.contains(selectedNumber)
    }
    
    var shiftDescription: String {
        if willShiftOthers {
            let affectedNumbers = existingNumbers.filter { $0 >= selectedNumber }.sorted()
            guard let first = affectedNumbers.first, let last = affectedNumbers.last else {
                return ""
            }
            if first == last {
                return "File currently numbered \(String(format: "%02d", first)) will become \(String(format: "%02d", first + 1))"
            } else {
                return "Files numbered \(String(format: "%02d", first))-\(String(format: "%02d", last)) will shift to \(String(format: "%02d", first + 1))-\(String(format: "%02d", last + 1))"
            }
        }
        return ""
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            VStack(spacing: 8) {
                Text("Assign Number Manually")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("File: \(operation.originalName)")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                
                Text("This will override any automatic detection")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }
            
            Divider()
            
            // Number input section
            VStack(alignment: .leading, spacing: 12) {
                Text("Assign sequential number:")
                    .font(.headline)
                
                HStack(spacing: 12) {
                    TextField("Number", value: $selectedNumber, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    
                    Stepper("", value: $selectedNumber, in: 0...99)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            
            // Info section
            VStack(alignment: .leading, spacing: 8) {
                Text("The file will be prefixed with \(String(format: "%02d", selectedNumber))")
                    .font(.caption)
                    .foregroundColor(.primary)
                
                if willShiftOthers {
                    Text("⚠️ " + shiftDescription)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Spacer()
                .frame(minHeight: 20)
            
            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Assign") {
                    onAssign(selectedNumber)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500, height: 400)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Bulk Rename View
/// Right panel of the Rename Files tab.
/// Accepts a folder or individual PDFs, lets the user assign a shared base name
/// plus per-file instrument suffixes (with the same autocomplete as the Splitter),
/// then renames all files in place.
private enum BulkStage { case base, prefix, summary }

struct BulkRenameView: View {

    // ── Parent binding so RenamerView can react to file load/clear ────────
    @Binding var hasFiles: Bool

    // ── Loaded files ──────────────────────────────────────────────────────
    @State private var loadedFiles: [(url: URL, document: PDFDocument)] = []

    // ── Naming state ──────────────────────────────────────────────────────
    @State private var baseFileName: String = ""
    @State private var suffixes: [Int: String] = [:]
    @State private var previewOffset: CGPoint = .zero
    @FocusState private var focusedField: Int?

    // ── Drop zone ────────────────────────────────────────────────────────
    @State private var isTargeted = false

    // ── Prefix step ───────────────────────────────────────────────────────
    @State private var bulkStage: BulkStage = .base
    @State private var prefixItems: [PrefixItem] = []
    /// Incremented each time we enter the prefix stage so SwiftUI creates a fresh
    /// PrefixOrderStepView rather than reusing the old one with stale @State.
    @State private var prefixRoundID: Int = 0
    @State private var summaryNames: [String] = []

    // ── Settings ─────────────────────────────────────────────────────────
    @AppStorage("filenameSeparator") private var filenameSeparator: String = " - "
    @AppStorage("prefixEnabled") private var prefixEnabled: Bool = true
    @AppStorage("prefixEnsembleType") private var prefixEnsembleType: EnsembleType = .band

    // ── Instrument names — the selected ensemble's score order (so suggestions
    // follow that ensemble; e.g. in a band, Horn comes right after Trumpet) ──
    private var instrumentNames: [String] {
        InstrumentOrders.getOrder(for: prefixEnsembleType).map { $0.capitalized }
    }

    // ── Validation ────────────────────────────────────────────────────────
    private var baseNameError: String? { pdfFilenameError(for: baseFileName) }

    private var anySuffixError: Bool {
        suffixes.values.contains { pdfFilenameError(for: $0) != nil }
    }

    /// True when two or more output filenames would collide.
    private var hasDuplicateNames: Bool {
        var seen = Set<String>()
        for index in loadedFiles.indices {
            let sfx = suffixes[index] ?? ""
            let name = sfx.isEmpty
                ? "\(baseFileName)\(filenameSeparator)\(index + 1).pdf"
                : "\(baseFileName)\(filenameSeparator)\(sfx).pdf"
            if !seen.insert(name).inserted { return true }
        }
        return false
    }

    private var canRename: Bool {
        !loadedFiles.isEmpty
            && !baseFileName.isEmpty
            && baseNameError == nil
            && !anySuffixError
            // Duplicates only collide on a direct rename; the score-order prefix (Step 3)
            // keeps same-named files distinct.
            && !(prefixEnabled == false && hasDuplicateNames)
    }

    // ── Body ──────────────────────────────────────────────────────────────
    var body: some View {
        switch bulkStage {
        case .summary:
            RenameSummaryView(
                finalNames: summaryNames,
                outputFolderURL: nil,
                onStartOver: {
                    bulkStage = .base
                    clearFiles()
                }
            )
            // Drop a new folder/files here to restart without clicking Start Over.
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in handleRestartDrop(providers) }
        case .prefix:
            PrefixOrderStepView(
                stepLabel: "Step 2",
                initialItems: prefixItems,
                ensembleType: $prefixEnsembleType,
                onBack: { bulkStage = .base },
                onApply: { orderedItems in applyPrefixAndRenameBulk(orderedItems: orderedItems) }
            )
            .id(prefixRoundID)
        case .base:
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Bulk Part Rename")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    if !loadedFiles.isEmpty {
                        Button(action: clearFiles) {
                            Label("Clear Files", systemImage: "xmark.circle.fill")
                        }
                        .help("Remove all files and start over")
                    }
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor))

                Divider()

                if loadedFiles.isEmpty {
                    dropZoneView
                } else {
                    fileListView
                }
            }
        }
    }

    // ── Drop zone ─────────────────────────────────────────────────────────
    private var dropZoneView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 56))
                .foregroundColor(isTargeted ? .accentColor : .secondary)

            Text("Bulk Part Rename")
                .font(.title3)
                .fontWeight(.medium)

            Text("Drag a folder or individual PDF files here")
                .font(.callout)
                .foregroundColor(isTargeted ? .accentColor : .secondary)

            Text("or")
                .foregroundColor(.secondary)

            Button(action: selectFiles) {
                Label("Choose Files or Folder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Rename a set of separate PDF part files with a\nshared base name and instrument suffixes")
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
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleRestartDrop(providers)
        }
    }

    // ── File list (once loaded) ───────────────────────────────────────────
    private var fileListView: some View {
        VStack(spacing: 0) {
            // Base filename bar
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Base Filename:")
                        .font(.headline)
                        .fixedSize()

                    TextField("e.g. Beethoven Symphony 5", text: $baseFileName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)

                    Text("Files will be renamed: \(baseFileName.isEmpty ? "basename" : baseFileName)\(filenameSeparator)Flute.pdf")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()
                }
                if let err = baseNameError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.red)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Per-file naming rows — reuse SplitFileNamingRow directly
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(loadedFiles.indices, id: \.self) { index in
                            SplitFileNamingRow(
                                fileIndex: index,
                                page: loadedFiles[index].document.page(at: 0),
                                subtitle: loadedFiles[index].url.lastPathComponent,
                                baseFileName: baseFileName,
                                suffix: Binding(
                                    get: { suffixes[index] ?? "" },
                                    set: { suffixes[index] = $0.isEmpty ? nil : $0 }
                                ),
                                fieldFocus: $focusedField,
                                instrumentNames: instrumentNames,
                                allSuffixes: suffixes.mapValues { $0 },
                                ensemble: prefixEnsembleType,
                                prefixWillDisambiguate: prefixEnabled,
                                previewOffset: $previewOffset
                            )
                            .id(index)
                            if index < loadedFiles.count - 1 { Divider() }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: focusedField) { _, newValue in
                    if let field = newValue {
                        withAnimation { proxy.scrollTo(field, anchor: .center) }
                    }
                }
            }

            Divider()

            // Bottom bar
            VStack(alignment: .leading, spacing: 6) {
                // Warning
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("This will rename the files in Finder. This cannot be undone.")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Spacer()
                }
                // Duplicate name error (only a real collision without the disambiguating prefix)
                if prefixEnabled == false && hasDuplicateNames {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                        Text("Two or more files would get the same name — check your suffixes.")
                            .font(.caption)
                            .foregroundColor(.red)
                        Spacer()
                    }
                }
                // Prefix option row
                HStack(spacing: 12) {
                    Toggle("Prefix score order", isOn: $prefixEnabled)
                    // Always enabled — the ensemble drives the instrument suggestions
                    // (order + per-ensemble part counts), not just prefixing.
                    Picker("", selection: $prefixEnsembleType) {
                        Text("Wind Band").tag(EnsembleType.band)
                        Text("Jazz Band").tag(EnsembleType.jazz)
                        Text("Orchestra").tag(EnsembleType.orchestra)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)
                    Spacer()
                }
                HStack {
                    Spacer()
                    Button(action: executeRename) {
                        Label(prefixEnabled
                              ? "Next: Prefix Order"
                              : "Rename \(loadedFiles.count) File\(loadedFiles.count == 1 ? "" : "s")",
                              systemImage: prefixEnabled ? "chevron.right" : "pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canRename)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    // ── File loading ──────────────────────────────────────────────────────
    private func selectFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]
        panel.title = "Select PDF Files or Folder"
        panel.message = "Choose a folder containing PDFs, or select individual PDF files"
        panel.begin { response in
            guard response == .OK else { return }
            var isDir: ObjCBool = false
            if panel.urls.count == 1,
               FileManager.default.fileExists(atPath: panel.urls[0].path, isDirectory: &isDir),
               isDir.boolValue {
                loadFromFolder(panel.urls[0])
            } else {
                loadFiles(panel.urls.filter { $0.pathExtension.lowercased() == "pdf" })
            }
        }
    }

    private func loadFromFolder(_ url: URL) {
        let pdfs = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ))?.filter { $0.pathExtension.lowercased() == "pdf" }
          .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        ?? []
        loadFiles(pdfs)
    }

    private func loadFiles(_ urls: [URL]) {
        loadedFiles = urls.compactMap { url in
            guard let doc = PDFDocument(url: url) else { return nil }
            return (url: url, document: doc)
        }
        suffixes = [:]
        previewOffset = .zero
        hasFiles = !loadedFiles.isEmpty
    }

    private func clearFiles() {
        loadedFiles = []
        baseFileName = ""
        suffixes = [:]
        previewOffset = .zero
        hasFiles = false
    }

    /// Handles a folder/file drop that (re)starts the flow. Used by both the empty drop
    /// zone and the "done" summary screen, so finishing a job and dropping new files
    /// restarts immediately without clicking Start Over.
    private func handleRestartDrop(_ providers: [NSItemProvider]) -> Bool {
        collectDroppedFileURLs(from: providers) { collected in
            guard !collected.isEmpty else { return }
            var isDir: ObjCBool = false
            let isFolder = collected.count == 1
                && FileManager.default.fileExists(atPath: collected[0].path, isDirectory: &isDir)
                && isDir.boolValue
            let pdfs = collected.filter { $0.pathExtension.lowercased() == "pdf" }
            if isFolder {
                // Bulk Part Rename works on the PDFs inside a single folder. A folder of
                // subfolders (a batch) belongs to the Score Order Sorter, not here.
                let directPDFs = (try? FileManager.default.contentsOfDirectory(
                    at: collected[0], includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]))?
                    .contains { $0.pathExtension.lowercased() == "pdf" } ?? false
                if !directPDFs {
                    showNSAlert(title: "No PDFs in That Folder",
                                message: "“\(collected[0].lastPathComponent)” doesn’t contain PDF files directly. Bulk Part Rename works on the PDFs inside a single folder. To rename several folders in one go, use the Score Order Sorter on the left side of the Rename Files tab.",
                                isError: true)
                    return
                }
            } else if pdfs.isEmpty {
                showNSAlert(title: "Unsupported File Type",
                            message: "The naming stage only accepts PDF files.",
                            isError: true)
                return
            }
            // Reset to a clean Step 1, leaving the summary screen if we're on it.
            baseFileName = ""
            bulkStage = .base
            if isFolder { loadFromFolder(collected[0]) } else { loadFiles(pdfs) }
        }
        return true
    }

    // ── Rename execution ──────────────────────────────────────────────────
    private func executeRename() {
        let sep = filenameSeparator

        if prefixEnabled {
            // Build PrefixItems (don't touch disk yet) and go to prefix step.
            prefixItems = loadedFiles.enumerated().map { index, item in
                let sfx = suffixes[index] ?? ""
                let proposed = sfx.isEmpty
                    ? "\(baseFileName)\(sep)\(index + 1).pdf"
                    : "\(baseFileName)\(sep)\(sfx).pdf"
                return PrefixItem(id: index,
                                  proposedName: proposed,
                                  page: item.document.page(at: 0),
                                  originalURL: item.url)
            }
            prefixRoundID += 1
            bulkStage = .prefix
        } else {
            // Rename directly to the base name + suffix (no prefix step).
            var errors: [String] = []
            var finalNames: [String] = []
            var sawPermissionError = false

            // Pre-flight: bail with friendly guidance if the location is read-only.
            let unwritable = nonWritableParentDirectories(of: loadedFiles.map { $0.url })
            if !unwritable.isEmpty {
                showNSAlert(
                    title: "Can’t Rename Files Here",
                    message: readOnlyLocationMessage(folderName: unwritable.first?.lastPathComponent),
                    isError: true
                )
                return
            }

            for (index, item) in loadedFiles.enumerated() {
                let sfx = suffixes[index] ?? ""
                let newName = sfx.isEmpty
                    ? "\(baseFileName)\(sep)\(index + 1).pdf"
                    : "\(baseFileName)\(sep)\(sfx).pdf"
                let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
                var coordinatorError: NSError?
                NSFileCoordinator().coordinate(
                    writingItemAt: item.url, options: .forMoving,
                    writingItemAt: newURL,   options: .forReplacing,
                    error: &coordinatorError
                ) { src, dst in
                    do {
                        try FileManager.default.moveItem(at: src, to: dst)
                        finalNames.append(newName)
                    } catch {
                        if isFilePermissionError(error) { sawPermissionError = true }
                        errors.append("\(item.url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                if let e = coordinatorError {
                    if isFilePermissionError(e) { sawPermissionError = true }
                    errors.append("\(item.url.lastPathComponent): \(e.localizedDescription)")
                }
            }

            if errors.isEmpty {
                summaryNames = finalNames
                bulkStage = .summary
            } else if sawPermissionError && finalNames.isEmpty {
                showNSAlert(
                    title: "Can’t Rename Files Here",
                    message: readOnlyLocationMessage(folderName: loadedFiles.first?.url.deletingLastPathComponent().lastPathComponent),
                    isError: true
                )
            } else {
                let failed = errors.prefix(5).joined(separator: "\n")
                var message = "Failed to rename \(errors.count) file\(errors.count == 1 ? "" : "s"):\n\(failed)"
                if sawPermissionError {
                    message += "\n\nSome files are in a read-only location (e.g. Dropbox, Google Drive, iCloud, or a locked folder)."
                }
                showNSAlert(
                    title: "Some Files Could Not Be Renamed",
                    message: message,
                    isError: true
                )
            }
        }
    }

    /// Called by PrefixOrderStepView when the user confirms ordering.
    /// Renames each file from its original URL to the final prefixed name in one pass.
    private func applyPrefixAndRenameBulk(orderedItems: [PrefixItem]) {
        let sep = UserDefaults.standard.string(forKey: "prefixSeparator") ?? " - "
        var errors: [String] = []
        var finalNames: [String] = []
        var sawPermissionError = false

        // Pre-flight: bail with friendly guidance if the location is read-only.
        let sourceURLs = orderedItems.compactMap { $0.originalURL }
        let unwritable = nonWritableParentDirectories(of: sourceURLs)
        if !unwritable.isEmpty {
            showNSAlert(
                title: "Can’t Rename Files Here",
                message: readOnlyLocationMessage(folderName: unwritable.first?.lastPathComponent),
                isError: true
            )
            return
        }

        // Same numbering the user saw in Step 2 — so the renames match the preview.
        let numbers = scoreOrderNumbers(forOrderedItems: orderedItems)
        for item in orderedItems {
            guard let originalURL = item.originalURL else { continue }
            guard let number = numbers[item.id] else { continue }  // skipped → leave unrenamed
            let prefix = String(format: "%02d", number)
            let finalName = "\(prefix)\(sep)\(item.proposedName)"
            let targetURL = originalURL.deletingLastPathComponent()
                                       .appendingPathComponent(finalName)
            var coordinatorError: NSError?
            NSFileCoordinator().coordinate(
                writingItemAt: originalURL, options: .forMoving,
                writingItemAt: targetURL,   options: .forReplacing,
                error: &coordinatorError
            ) { src, dst in
                do {
                    try FileManager.default.moveItem(at: src, to: dst)
                    finalNames.append(finalName)
                } catch {
                    if isFilePermissionError(error) { sawPermissionError = true }
                    errors.append("\(item.proposedName): \(error.localizedDescription)")
                }
            }
            if let e = coordinatorError {
                if isFilePermissionError(e) { sawPermissionError = true }
                errors.append("\(item.proposedName): \(e.localizedDescription)")
            }
        }

        if errors.isEmpty {
            summaryNames = finalNames
            bulkStage = .summary
        } else if sawPermissionError && finalNames.isEmpty {
            showNSAlert(
                title: "Can’t Rename Files Here",
                message: readOnlyLocationMessage(folderName: sourceURLs.first?.deletingLastPathComponent().lastPathComponent),
                isError: true
            )
        } else {
            let failed = errors.prefix(5).joined(separator: "\n")
            var message = "Failed to rename \(errors.count) file\(errors.count == 1 ? "" : "s"):\n\(failed)"
            if sawPermissionError {
                message += "\n\nSome files are in a read-only location (e.g. Dropbox, Google Drive, iCloud, or a locked folder)."
            }
            showNSAlert(
                title: "Some Files Could Not Be Renamed",
                message: message,
                isError: true
            )
        }
    }
}
