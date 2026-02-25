//
//  MusicPDFManager.swift
//  Music PDF Manager
//
//  A macOS app for managing music PDFs:
//  - Renaming sheet music files with sequential prefixes
//  - Splitting PDFs into separate files
//  - Rotating odd or even pages in PDF files
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import Combine

// MARK: - Main App
@main
struct MusicPDFManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

// MARK: - App Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            RenamerView()
                .tabItem {
                    Label("Rename Files", systemImage: "folder.badge.gearshape")
                }
                .tag(0)
            
            SplitView()
                .tabItem {
                    Label("Split PDF", systemImage: "scissors")
                }
                .tag(1)
            
            RotateView()
                .tabItem {
                    Label("Rotate Pages", systemImage: "rotate.right")
                }
                .tag(2)
        }
        .frame(minWidth: 900, minHeight: 700)
    }
}

// MARK: - Renamer View
struct RenamerView: View {
    @StateObject private var renamerManager = RenamerManager()
    @State private var showingPreferences = false
    @State private var selectedFileForAssignment: RenameOperation?
    @State private var isFolderTargeted = false
    @State private var sortColumn: SortColumn = .newName
    @State private var sortAscending = true
    
    enum SortColumn {
        case originalName
        case newName
        case status
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack {
                Text("Sheet Music Renamer")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if renamerManager.folderURL != nil {
                    Button(action: { renamerManager.rescanFolder() }) {
                        Label("Check for Errors", systemImage: "checkmark.circle")
                    }
                    .help("Rescan all files and suggest corrections")
                    
                    Button(action: { showingPreferences = true }) {
                        Label("Preferences", systemImage: "gearshape")
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    
                    Button(action: { renamerManager.clearFolder() }) {
                        Label("Clear", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Main content area
            if renamerManager.folderURL != nil {
                VStack(spacing: 0) {
                    // File list
                    fileListView
                    
                    Divider()
                    
                    // Bottom controls
                    bottomControlsView
                }
            } else {
                // Folder selection
                folderSelectionView
            }
        }
        .sheet(isPresented: $showingPreferences) {
            PreferencesView(
                ensembleType: $renamerManager.ensembleType,
                instrumentOrder: $renamerManager.customInstrumentOrder
            )
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
        .onAppear {
            // Workaround for SwiftUI sheet initialization bug
            // This "warms up" the sheet system so the first popup renders correctly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Just accessing the sheet system is enough
                _ = showingPreferences
            }
        }
    }
    
    private var folderSelectionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 64))
                .foregroundColor(isFolderTargeted ? .accentColor : .secondary)
            
            Text("Select a Folder with PDF Files")
                .font(.title2)
                .fontWeight(.medium)
            
            Text("This tool will add sequential prefixes to your sheet music files\nbased on detected instrument names")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Text("Drag a folder here")
                .font(.callout)
                .foregroundColor(isFolderTargeted ? .accentColor : .secondary)
            
            Text("or")
                .foregroundColor(.secondary)
            
            Button(action: selectFolder) {
                Label("Choose Folder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            // Ensemble type selector
            VStack(alignment: .leading, spacing: 8) {
                Text("Ensemble Type:")
                    .font(.headline)
                
                Picker("Ensemble Type", selection: $renamerManager.ensembleType) {
                    Text("Wind Band").tag(EnsembleType.band)
                    Text("Jazz Band").tag(EnsembleType.jazz)
                    Text("Orchestra").tag(EnsembleType.orchestra)
                }
                .pickerStyle(.segmented)
                .frame(width: 400)
            }
            .padding(.top, 20)
        }
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
            guard let provider = providers.first else { return false }
            
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                       isDirectory.boolValue {
                        DispatchQueue.main.async {
                            renamerManager.loadFolder(url: url)
                        }
                    }
                }
            }
            
            return true
        }
    }
    
    private var fileListView: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { sortBy(.originalName) }) {
                    HStack(spacing: 4) {
                        Text("Original Filename")
                            .font(.headline)
                        if sortColumn == .originalName {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                
                Button(action: { sortBy(.newName) }) {
                    HStack(spacing: 4) {
                        Text("New Filename")
                            .font(.headline)
                        if sortColumn == .newName {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                
                Button(action: { sortBy(.status) }) {
                    HStack(spacing: 4) {
                        Text("Status")
                            .font(.headline)
                        if sortColumn == .status {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.caption)
                        }
                    }
                    .frame(width: 200, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // File list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sortedOperations) { operation in
                        FileRowView(operation: operation) {
                            selectedFileForAssignment = operation
                        }
                        Divider()
                    }
                }
            }
        }
    }
    
    private var sortedOperations: [RenameOperation] {
        renamerManager.operations.sorted { op1, op2 in
            let result: Bool
            switch sortColumn {
            case .originalName:
                result = op1.originalName.localizedCaseInsensitiveCompare(op2.originalName) == .orderedAscending
            case .newName:
                // Empty new names go to the end
                if op1.newName.isEmpty && !op2.newName.isEmpty {
                    result = false
                } else if !op1.newName.isEmpty && op2.newName.isEmpty {
                    result = true
                } else if op1.newName.isEmpty && op2.newName.isEmpty {
                    result = op1.originalName.localizedCaseInsensitiveCompare(op2.originalName) == .orderedAscending
                } else {
                    result = op1.newName.localizedCaseInsensitiveCompare(op2.newName) == .orderedAscending
                }
            case .status:
                result = op1.statusText.localizedCaseInsensitiveCompare(op2.statusText) == .orderedAscending
            }
            return sortAscending ? result : !result
        }
    }
    
    private func sortBy(_ column: SortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = true
        }
    }
    
    private var bottomControlsView: some View {
        VStack(spacing: 12) {
            // Status text
            Text(renamerManager.statusText)
                .font(.callout)
                .foregroundColor(.secondary)
            
            // Action button
            HStack {
                Spacer()
                
                Button(action: { renamerManager.executeRename() }) {
                    Label("Rename Files", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(renamerManager.renameCount == 0)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Select Folder with PDF Files"
        panel.message = "Choose a folder containing sheet music PDF files to rename"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                renamerManager.loadFolder(url: url)
            }
        }
    }
}

// MARK: - File Row View
struct FileRowView: View {
    let operation: RenameOperation
    let onDoubleClick: () -> Void
    
    var body: some View {
        HStack {
            Text(operation.originalName)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(operation.color)
            
            Text(operation.newName)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(operation.color)
            
            Text(operation.statusText)
                .frame(width: 200, alignment: .leading)
                .foregroundColor(operation.color)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Allow manual override on any file
            onDoubleClick()
        }
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
            if affectedNumbers.isEmpty {
                return ""
            }
            let first = affectedNumbers.first!
            let last = affectedNumbers.last!
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

// MARK: - Preferences View
struct PreferencesView: View {
    @Binding var ensembleType: EnsembleType
    @Binding var instrumentOrder: [String]
    
    @State private var editableOrder: [String]
    @State private var newInstrument: String = ""
    @Environment(\.dismiss) private var dismiss
    
    init(ensembleType: Binding<EnsembleType>, instrumentOrder: Binding<[String]>) {
        self._ensembleType = ensembleType
        self._instrumentOrder = instrumentOrder
        self._editableOrder = State(initialValue: instrumentOrder.wrappedValue)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Instrument Order Preferences")
                .font(.title2)
                .fontWeight(.semibold)
            
            // Ensemble type selector
            VStack(alignment: .leading, spacing: 8) {
                Text("Ensemble Type:")
                    .font(.headline)
                
                Picker("Ensemble Type", selection: $ensembleType) {
                    Text("Wind Band").tag(EnsembleType.band)
                    Text("Jazz Band").tag(EnsembleType.jazz)
                    Text("Orchestra").tag(EnsembleType.orchestra)
                }
                .pickerStyle(.segmented)
                .onChange(of: ensembleType) { newType in
                    editableOrder = InstrumentOrders.getOrder(for: newType)
                }
            }
            
            Divider()
            
            // Instrument list
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Instruments (in order):")
                        .font(.headline)
                    
                    Spacer()
                    
                    Button("Reset to Default") {
                        editableOrder = InstrumentOrders.getOrder(for: ensembleType)
                    }
                    .font(.caption)
                }
                
                Text("Files are numbered sequentially based on this order. Drag to reorder.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(editableOrder.enumerated()), id: \.offset) { index, instrument in
                            HStack {
                                Text("\(index + 1).")
                                    .foregroundColor(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                                
                                Text(instrument)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color(NSColor.controlBackgroundColor))
                                    )
                                
                                Button(action: {
                                    editableOrder.remove(at: index)
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                                
                                VStack(spacing: 2) {
                                    Button(action: {
                                        if index > 0 {
                                            editableOrder.swapAt(index, index - 1)
                                        }
                                    }) {
                                        Image(systemName: "chevron.up")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(index == 0)
                                    
                                    Button(action: {
                                        if index < editableOrder.count - 1 {
                                            editableOrder.swapAt(index, index + 1)
                                        }
                                    }) {
                                        Image(systemName: "chevron.down")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(index == editableOrder.count - 1)
                                }
                            }
                        }
                    }
                }
                .frame(height: 300)
                .border(Color.gray.opacity(0.2))
                
                // Add new instrument
                HStack {
                    TextField("Add new instrument...", text: $newInstrument)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            addInstrument()
                        }
                    
                    Button(action: addInstrument) {
                        Image(systemName: "plus.circle.fill")
                    }
                    .disabled(newInstrument.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            
            Spacer()
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Save") {
                    instrumentOrder = editableOrder
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 650, height: 600)
    }
    
    private func addInstrument() {
        let trimmed = newInstrument.trimmingCharacters(in: .whitespaces).lowercased()
        if !trimmed.isEmpty && !editableOrder.contains(trimmed) {
            editableOrder.append(trimmed)
            newInstrument = ""
        }
    }
}

// MARK: - Renamer Manager
class RenamerManager: ObservableObject {
    @Published var folderURL: URL?
    @Published var operations: [RenameOperation] = []
    @Published var ensembleType: EnsembleType = .band {
        didSet {
            if !hasCustomOrder {
                customInstrumentOrder = InstrumentOrders.getOrder(for: ensembleType)
            }
            if folderURL != nil {
                scanFolder()
            }
        }
    }
    @Published var customInstrumentOrder: [String] = InstrumentOrders.getOrder(for: .band) {
        didSet {
            hasCustomOrder = true
            if folderURL != nil {
                scanFolder()
            }
        }
    }
    
    private var hasCustomOrder = false
    private var manualOverrides: [String: Int] = [:]
    private var isRescanMode = false
    
    var statusText: String {
        let total = operations.count
        let willRename = renameCount
        let willSkip = operations.filter { $0.type == .skip || $0.type == .alreadyPrefixed }.count
        let corrections = operations.filter { $0.type == .correct }.count
        
        if isRescanMode && corrections > 0 {
            return "Found \(total) PDFs: \(corrections) need correction, \(willRename - corrections) will be renamed, \(willSkip) are correct/will be skipped"
        } else {
            return "Found \(total) PDFs: \(willRename) will be renamed, \(willSkip) will be skipped"
        }
    }
    
    var renameCount: Int {
        operations.filter { $0.type == .rename || $0.type == .correct || $0.type == .manual }.count
    }
    
    func loadFolder(url: URL) {
        self.folderURL = url
        self.manualOverrides = [:]
        self.isRescanMode = false
        scanFolder()
    }
    
    func clearFolder() {
        self.folderURL = nil
        self.operations = []
        self.manualOverrides = [:]
        self.isRescanMode = false
    }
    
    func rescanFolder() {
        let alert = NSAlert()
        alert.messageText = "Check for Errors"
        alert.informativeText = "This will check all files (including already numbered ones) and suggest corrections.\n\nFiles will be renumbered sequentially based on instrument detection.\n\nContinue?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            isRescanMode = true
            manualOverrides = [:]
            scanFolder()
        }
    }
    
    func setManualOverride(for filename: String, number: Int) {
        // Check if this number conflicts with existing assignments
        let existingAtThisNumber = manualOverrides.filter { $0.value == number && $0.key != filename }
        
        if !existingAtThisNumber.isEmpty {
            // Shift all manual overrides >= number up by 1
            var updatedOverrides: [String: Int] = [:]
            for (key, value) in manualOverrides {
                if key == filename {
                    // Skip, we'll add this at the end
                    continue
                }
                if value >= number {
                    updatedOverrides[key] = value + 1
                } else {
                    updatedOverrides[key] = value
                }
            }
            manualOverrides = updatedOverrides
        }
        
        manualOverrides[filename] = number
        scanFolder()
    }
    
    func getExistingNumbers() -> [Int] {
        var numbers: [Int] = []
        
        // Add manual override numbers
        numbers.append(contentsOf: manualOverrides.values)
        
        // Add auto-detected numbers by scanning current operations
        for operation in operations {
            if operation.type == .rename || operation.type == .correct {
                // Extract the number prefix from the new name
                if let match = operation.newName.range(of: "^(\\d{2})", options: .regularExpression),
                   let number = Int(operation.newName[match]) {
                    numbers.append(number)
                }
            }
        }
        
        return Array(Set(numbers)).sorted()
    }
    
    private func scanFolder() {
        guard let folderURL = folderURL else { return }
        
        operations = []
        
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return
        }
        
        var pdfFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "pdf" {
                pdfFiles.append(fileURL)
            }
        }
        
        pdfFiles.sort { $0.lastPathComponent < $1.lastPathComponent }
        
        // Group files
        var detectedFiles: [(order: Int, url: URL, originalName: String, instrument: String)] = []
        var scoreFiles: [(url: URL, originalName: String, instrument: String)] = []
        var undetectedFiles: [(url: URL, originalName: String)] = []
        var manuallyAssigned: [(number: Int, url: URL, originalName: String)] = []
        
        for fileURL in pdfFiles {
            let filename = fileURL.lastPathComponent
            let originalFilename = filename
            
            // Strip existing prefix for rescan mode
            let filenameWithoutPrefix: String
            if isRescanMode, let match = filename.range(of: "^\\d{2}[-_\\s]", options: .regularExpression) {
                filenameWithoutPrefix = String(filename[match.upperBound...])
            } else {
                filenameWithoutPrefix = filename
            }
            
            // Skip already prefixed in normal mode
            if !isRescanMode, filename.range(of: "^\\d{2}[-_\\s]", options: .regularExpression) != nil {
                let op = RenameOperation(
                    originalURL: fileURL,
                    originalName: filename,
                    newName: "",
                    type: .alreadyPrefixed
                )
                operations.append(op)
                continue
            }
            
            // Check manual override
            if let manualNumber = manualOverrides[originalFilename] {
                manuallyAssigned.append((manualNumber, fileURL, originalFilename))
                continue
            }
            
            // Detect instrument
            if let (order, instrument) = detectInstrument(in: filenameWithoutPrefix) {
                if instrument == "score" {
                    scoreFiles.append((fileURL, originalFilename, instrument))
                } else {
                    detectedFiles.append((order, fileURL, originalFilename, instrument))
                }
            } else {
                undetectedFiles.append((fileURL, originalFilename))
            }
        }
        
        // Sort and assign numbers
        detectedFiles.sort { $0.order < $1.order }
        
        // Process score files (all get 00)
        for (url, originalName, _) in scoreFiles {
            let prefix = "00"
            let cleanName: String
            let oldPrefix: String?
            
            if isRescanMode, let match = originalName.range(of: "^(\\d{2})", options: .regularExpression) {
                oldPrefix = String(originalName[match])
                cleanName = String(originalName[originalName.index(match.upperBound, offsetBy: 0)...])
                    .replacingOccurrences(of: "^[-_\\s]+", with: "", options: .regularExpression)
            } else {
                oldPrefix = nil
                cleanName = originalName
            }
            
            let newFilename = "\(prefix) - \(cleanName)"
            let newURL = folderURL.appendingPathComponent(newFilename)
            
            if oldPrefix == prefix {
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: "",
                    type: .skip
                )
                operations.append(op)
            } else if fileManager.fileExists(atPath: newURL.path) && newURL != url {
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: newFilename,
                    type: .skip,
                    statusOverride: "Target exists"
                )
                operations.append(op)
            } else {
                let type: RenameOperationType = oldPrefix != nil ? .correct : .rename
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: newFilename,
                    newURL: newURL,
                    type: type,
                    oldPrefix: oldPrefix
                )
                operations.append(op)
            }
        }
        
        // Process detected files (start from 01)
        for (index, (_, url, originalName, _)) in detectedFiles.enumerated() {
            let prefix = String(format: "%02d", index + 1)
            let cleanName: String
            let oldPrefix: String?
            
            if isRescanMode, let match = originalName.range(of: "^(\\d{2})", options: .regularExpression) {
                oldPrefix = String(originalName[match])
                cleanName = String(originalName[originalName.index(match.upperBound, offsetBy: 0)...])
                    .replacingOccurrences(of: "^[-_\\s]+", with: "", options: .regularExpression)
            } else {
                oldPrefix = nil
                cleanName = originalName
            }
            
            let newFilename = "\(prefix) - \(cleanName)"
            let newURL = folderURL.appendingPathComponent(newFilename)
            
            if oldPrefix == prefix {
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: "",
                    type: .skip
                )
                operations.append(op)
            } else if fileManager.fileExists(atPath: newURL.path) && newURL != url {
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: newFilename,
                    type: .skip,
                    statusOverride: "Target exists"
                )
                operations.append(op)
            } else {
                let type: RenameOperationType = oldPrefix != nil ? .correct : .rename
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: newFilename,
                    newURL: newURL,
                    type: type,
                    oldPrefix: oldPrefix
                )
                operations.append(op)
            }
        }
        
        // Process manually assigned
        manuallyAssigned.sort { $0.number < $1.number }
        for (number, url, originalName) in manuallyAssigned {
            let prefix = String(format: "%02d", number)
            let cleanName: String
            
            if isRescanMode, let match = originalName.range(of: "^\\d{2}[-_\\s]", options: .regularExpression) {
                cleanName = String(originalName[match.upperBound...])
            } else {
                cleanName = originalName
            }
            
            let newFilename = "\(prefix) - \(cleanName)"
            let newURL = folderURL.appendingPathComponent(newFilename)
            
            if fileManager.fileExists(atPath: newURL.path) && newURL != url {
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: newFilename,
                    type: .skip,
                    statusOverride: "Target exists"
                )
                operations.append(op)
            } else {
                let op = RenameOperation(
                    originalURL: url,
                    originalName: originalName,
                    newName: newFilename,
                    newURL: newURL,
                    type: .manual
                )
                operations.append(op)
            }
        }
        
        // Add undetected files
        for (url, originalName) in undetectedFiles {
            let op = RenameOperation(
                originalURL: url,
                originalName: originalName,
                newName: "",
                type: .undetected
            )
            operations.append(op)
        }
        
        // Sort by new filename
        operations.sort { op1, op2 in
            if op1.newName.isEmpty && !op2.newName.isEmpty {
                return false
            } else if !op1.newName.isEmpty && op2.newName.isEmpty {
                return true
            } else if op1.newName.isEmpty && op2.newName.isEmpty {
                return op1.originalName < op2.originalName
            } else {
                return op1.newName < op2.newName
            }
        }
    }
    
    private func detectInstrument(in filename: String) -> (Int, String)? {
        let lowerFilename = filename.lowercased()
        
        // Create array of (originalIndex, instrument) and sort by length (longest first)
        // This ensures "bass clarinet" matches before "clarinet"
        let sortedInstruments = customInstrumentOrder.enumerated().map { ($0.offset, $0.element) }
            .sorted { $0.1.count > $1.1.count }
        
        // Find all matches with their position in the filename
        var matches: [(index: Int, instrument: String, position: Int)] = []
        for (originalIndex, instrument) in sortedInstruments {
            if let range = lowerFilename.range(of: instrument.lowercased()) {
                let position = lowerFilename.distance(from: lowerFilename.startIndex, to: range.lowerBound)
                matches.append((originalIndex, instrument, position))
            }
        }
        
        // Return the match that appears FIRST in the filename (leftmost position)
        // This handles cases like "Baritone BC Bassoon" -> should use "baritone" not "bassoon"
        if let firstMatch = matches.min(by: { $0.position < $1.position }) {
            return (firstMatch.index, firstMatch.instrument)
        }
        
        return nil
    }
    
    func executeRename() {
        let toRename = operations.filter { $0.type == .rename || $0.type == .correct || $0.type == .manual }
        
        guard !toRename.isEmpty else { return }
        
        var successCount = 0
        var errors: [String] = []
        
        for operation in toRename {
            guard let newURL = operation.newURL else { continue }
            
            do {
                try FileManager.default.moveItem(at: operation.originalURL, to: newURL)
                successCount += 1
            } catch {
                errors.append("\(operation.originalName): \(error.localizedDescription)")
            }
        }
        
        if !errors.isEmpty {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Partial Success"
            let errorList = errors.prefix(5).joined(separator: "\n")
            var message = "Renamed \(successCount) file(s), but \(errors.count) failed:\n\n\(errorList)"
            if errors.count > 5 {
                message += "\n... and \(errors.count - 5) more"
            }
            errorAlert.informativeText = message
            errorAlert.alertStyle = .warning
            errorAlert.runModal()
        }
        
        scanFolder()
    }
}

// MARK: - Supporting Types for Renamer
enum EnsembleType: String, CaseIterable {
    case band = "Band"
    case jazz = "Jazz"
    case orchestra = "Orchestra"
}

struct InstrumentOrders {
    static let band = [
        "score",
        "instrumentation",
        "piccolo",
        "flute",
        "oboe",
        "cor anglais",
        "english horn",
        "bassoon",
        "contrabassoon",
        "eb clarinet",
        "eflat clarinet",
        "clarinet",
        "alto clarinet",
        "bass clarinet",
        "contrabass clarinet",
        "soprano sax",
        "sop sax",
        "sop saxophone",
        "soprano saxophone",
        "alto saxophone",
        "alto sax",
        "sax alto",
        "tenor sax",
        "tenor saxophone",
        "sax tenor",
        "bari sax",
        "baritone sax",
        "baritone saxophone",
        "bari saxophone",
        "sax bari",
        "saxophone bari",
        "sax baritone",
        "bass sax",
        "bass saxophone",
        "cornet",
        "trumpet",
        "horn",
        "trombone",
        "bass trombone",
        "trombone bass",
        "euphonium",
        "eupho",
        "baritone",
        "tuba",
        "guitar",
        "keyboard",
        "piano",
        "harp",
        "string bass",
        "bass",
        "timpani",
        "mallet",
        "mallets",
        "mallet percussion",
        "bells",
        "chimes",
        "glockenspiel",
        "xylophone",
        "vibraphone",
        "marimba",
        "drums",
        "drum set",
        "percussion",
        "violin",
        "viola",
        "cello",
        "double bass",
    ]
    
    static let jazz = [
        "score",
        "instrumentation",
        "voice",
        "vocal",
        "vocals",
        "solo alto sax",
        "solo alto saxophone",
        "solo eb",
        "solo eflat",
        "solo e flat",
        "solo tenor sax",
        "solo tenor saxophone",
        "solo bari sax",
        "solo baritone sax",
        "solo trumpet",
        "solo trombone",
        "solo",
        "soli",
        "alto saxophone",
        "alto sax",
        "sax alto",
        "alto",
        "tenor sax",
        "sax tenor",
        "tenor saxophone",
        "tenor",
        "bari sax",
        "baritone sax",
        "bari saxophone",
        "sax bari",
        "saxophone bari",
        "sax baritone",
        "baritone saxophone",
        "baritone",
        "bari",
        "trumpet",
        "cornet",
        "flugelhorn",
        "trombone",
        "bass trombone",
        "trombone bass",
        "guitar",
        "guitar chords",
        "guitar chord",
        "chords",
        "piano",
        "keyboard",
        "bass",
        "string bass",
        "electric bass",
        "double bass",
        "drums",
        "drum set",
        "aux percussion",
        "auxiliary percussion",
        "congas",
        "bongos",
        "percussion",
        "mallets",
        "vibraphone",
        "vibes",
        "flute",
        "clarinet",
        "horn",
        "baritone horn",
        "eupho",
        "euphonium",
        "tuba",
    ]
    
    static let orchestra = [
        "score",
        "instrumentation",
        "piccolo",
        "flute",
        "oboe",
        "cor anglais",
        "english horn",
        "clarinet",
        "eb clarinet",
        "eflat clarinet",
        "alto clarinet",
        "bass clarinet",
        "contrabass clarinet",
        "bassoon",
        "contrabassoon",
        "soprano sax",
        "sop sax",
        "sop saxophone",
        "soprano saxophone",
        "alto saxophone",
        "alto sax",
        "sax alto",
        "tenor sax",
        "tenor saxophone",
        "sax tenor",
        "bari sax",
        "baritone sax",
        "bari saxophone",
        "sax bari",
        "saxophone bari",
        "sax baritone",
        "bass sax",
        "bass saxophone",
        "horn",
        "trumpet",
        "cornet",
        "trombone",
        "bass trombone",
        "trombone bass",
        "euphonium",
        "eupho",
        "baritone",
        "tuba",
        "timpani",
        "mallet",
        "mallets",
        "mallet percussion",
        "percussion",
        "drums",
        "guitar",
        "keyboard",
        "piano",
        "harp",
        "violin",
        "viola",
        "cello",
        "double bass",
        "string bass",
        "bass",
    ]
    
    static func getOrder(for type: EnsembleType) -> [String] {
        switch type {
        case .band: return band
        case .jazz: return jazz
        case .orchestra: return orchestra
        }
    }
}

enum RenameOperationType {
    case rename
    case skip
    case alreadyPrefixed
    case undetected
    case correct
    case manual
}

struct RenameOperation: Identifiable {
    let id = UUID()
    let originalURL: URL
    let originalName: String
    let newName: String
    var newURL: URL?
    let type: RenameOperationType
    var statusOverride: String?
    var oldPrefix: String?
    
    init(originalURL: URL, originalName: String, newName: String, newURL: URL? = nil,
         type: RenameOperationType, statusOverride: String? = nil, oldPrefix: String? = nil) {
        self.originalURL = originalURL
        self.originalName = originalName
        self.newName = newName
        self.newURL = newURL
        self.type = type
        self.statusOverride = statusOverride
        self.oldPrefix = oldPrefix
    }
    
    var statusText: String {
        if let override = statusOverride {
            return override
        }
        
        switch type {
        case .rename:
            return "Will rename"
        case .skip:
            return "Already correct"
        case .alreadyPrefixed:
            return "Already prefixed"
        case .undetected:
            return "No instrument found (double-click to assign)"
        case .correct:
            if let old = oldPrefix {
                let new = String(newName.prefix(2))
                return "Will correct (\(old) → \(new))"
            }
            return "Will correct"
        case .manual:
            return "Will rename (manual)"
        }
    }
    
    var color: Color {
        switch type {
        case .rename:
            return Color.green
        case .skip, .alreadyPrefixed:
            return Color.secondary
        case .undetected:
            return Color.secondary
        case .correct:
            return Color.orange
        case .manual:
            return Color.blue
        }
    }
}

// MARK: - Rotate View
struct RotateView: View {
    @StateObject private var pdfManager = PDFManager()
    @State private var baseRotation: RotationAngle = .none
    @State private var additionalRotationMode: RotationMode = .none
    @State private var additionalRotationAngle: RotationAngle = .rotate180
    @State private var currentPage: Int = 0
    @State private var isShowingSavePanel = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack {
                Text("Rotate Pages")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if pdfManager.pdfDocument != nil {
                    Button(action: { pdfManager.clearPDF() }) {
                        Label("Clear", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Main content area
            if let document = pdfManager.pdfDocument {
                // PDF loaded - show preview and controls
                VStack(spacing: 16) {
                    // Preview area
                    RotatePreviewSection(
                        document: document,
                        currentPage: $currentPage,
                        baseRotation: baseRotation,
                        additionalRotationMode: additionalRotationMode,
                        additionalRotationAngle: additionalRotationAngle
                    )
                    
                    Divider()
                    
                    // Controls
                    VStack(spacing: 16) {
                        // Base rotation options
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Step 1: Base Rotation (All Pages)")
                                .font(.headline)
                            
                            HStack {
                                Text("Rotate all pages:")
                                Picker("Base rotation", selection: $baseRotation) {
                                    Text("None").tag(RotationAngle.none)
                                    Text("90°").tag(RotationAngle.rotate90)
                                    Text("180°").tag(RotationAngle.rotate180)
                                    Text("270°").tag(RotationAngle.rotate270)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 280)
                                
                                Spacer()
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                        
                        // Additional rotation options
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Step 2: Additional Rotation (Optional)")
                                .font(.headline)
                            
                            HStack(spacing: 20) {
                                Picker("Then also rotate:", selection: $additionalRotationMode) {
                                    Text("No additional rotation").tag(RotationMode.none)
                                    Text("Odd pages (1, 3, 5...)").tag(RotationMode.odd)
                                    Text("Even pages (2, 4, 6...)").tag(RotationMode.even)
                                }
                                .pickerStyle(.radioGroup)
                                
                                Spacer()
                                
                                if additionalRotationMode != .none {
                                    HStack {
                                        Text("by:")
                                        Picker("Additional rotation angle", selection: $additionalRotationAngle) {
                                            Text("90°").tag(RotationAngle.rotate90)
                                            Text("180°").tag(RotationAngle.rotate180)
                                            Text("270°").tag(RotationAngle.rotate270)
                                        }
                                        .pickerStyle(.segmented)
                                        .frame(width: 200)
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                        
                        // Action buttons
                        HStack {
                            Spacer()
                            
                            Button(action: { isShowingSavePanel = true }) {
                                Label("Save Rotated PDF", systemImage: "arrow.down.doc.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                    .padding()
                }
            } else {
                // No PDF loaded - show drop zone
                DropZoneView(pdfManager: pdfManager)
            }
        }
        .onChange(of: isShowingSavePanel) { newValue in
            if newValue, let document = pdfManager.pdfDocument {
                saveRotatedPDF(document: document)
            }
        }
    }
    
    private func saveRotatedPDF(document: PDFDocument) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = (pdfManager.currentFileName ?? "document") + "_rotated.pdf"
        savePanel.title = "Save Rotated PDF"
        
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                pdfManager.saveRotatedPDF(
                    to: url,
                    baseRotation: baseRotation,
                    additionalRotationMode: additionalRotationMode,
                    additionalRotationAngle: additionalRotationAngle
                )
            }
            isShowingSavePanel = false
        }
    }
}

// MARK: - Split View
struct SplitView: View {
    @StateObject private var pdfManager = PDFManager()
    @State private var splitMarkers: Set<Int> = []
    @State private var currentPage: Int = 0
    @State private var autoSplitPages: Int = 2
    @State private var isShowingFolderPicker = false
    @State private var showingAutoSplitSheet = false
    @State private var showingBaseNameSheet = false
    @State private var baseFileName: String = ""
    @State private var editingBaseFileName: String = ""
    @State private var customFileNames: [Int: String] = [:]
    @State private var showingFileNamesSheet = false
    @FocusState private var isViewFocused: Bool
    
    var totalPages: Int {
        pdfManager.pdfDocument?.pageCount ?? 0
    }
    
    var pageToFileMapping: [Int: Int] {
        guard totalPages > 0 else { return [:] }
        
        let sortedMarkers = splitMarkers.sorted()
        var mapping: [Int: Int] = [:]
        var currentFileIndex = 0
        
        for pageIndex in 0..<totalPages {
            if sortedMarkers.contains(pageIndex) && pageIndex > 0 {
                currentFileIndex += 1
            }
            mapping[pageIndex] = currentFileIndex
        }
        
        return mapping
    }
    
    var numberOfFiles: Int {
        return (pageToFileMapping.values.max() ?? 0) + 1
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top toolbar
            HStack {
                Text("Split PDF")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if pdfManager.pdfDocument != nil {
                    Button(action: { showingAutoSplitSheet = true }) {
                        Label("Auto-Split Every N Pages", systemImage: "rectangle.split.3x1")
                    }
                    
                    Button(action: clearAllMarkers) {
                        Label("Clear All Markers", systemImage: "trash")
                    }
                    .disabled(splitMarkers.isEmpty)
                    
                    Button(action: { pdfManager.clearPDF() }) {
                        Label("Clear", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Main content area
            if let document = pdfManager.pdfDocument {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        // Left: Page preview and controls
                        VStack(spacing: 16) {
                            // Page navigation and controls
                            SplitControlsSection(
                                document: document,
                                currentPage: $currentPage,
                                splitMarkers: $splitMarkers,
                                totalPages: totalPages
                            )
                            
                            Divider()
                            
                            // Preview
                            VStack {
                                Text("Page \(currentPage + 1) of \(totalPages)")
                                    .font(.headline)
                                
                                if splitMarkers.contains(currentPage) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "scissors")
                                            .foregroundColor(.orange)
                                        Text("Split marker on this page")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                } else {
                                    if let fileIndex = pageToFileMapping[currentPage] {
                                        Text("Will be in file \(fileIndex + 1)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                
                                PDFPageView(
                                    page: document.page(at: currentPage),
                                    rotation: 0
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    isViewFocused = true
                                }
                            }
                            .padding()
                        }
                        .frame(width: geometry.size.width * 0.5)
                        .focusable()
                        .focused($isViewFocused)
                        
                        Divider()
                        
                        // Right: File breakdown
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("Output Files (\(numberOfFiles))")
                                    .font(.headline)
                                
                                Spacer()
                                
                                Button(action: { showingFileNamesSheet = true }) {
                                    Label("Customise Names", systemImage: "pencil")
                                        .font(.caption)
                                }
                            }
                            
                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(0..<numberOfFiles, id: \.self) { fileIndex in
                                        FilePreviewCard(
                                            fileIndex: fileIndex,
                                            pageToFileMapping: pageToFileMapping,
                                            totalPages: totalPages,
                                            baseFileName: baseFileName,
                                            customFileNames: customFileNames,
                                            onNavigate: { pageIndex in
                                                currentPage = pageIndex
                                            }
                                        )
                                    }
                                }
                            }
                            
                            Divider()
                            
                            // Base filename display
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Base Filename:")
                                        .font(.headline)
                                    
                                    Spacer()
                                    
                                    Button(action: {
                                        editingBaseFileName = baseFileName
                                        showingBaseNameSheet = true
                                    }) {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                                
                                Text(baseFileName.isEmpty ? "(no name set)" : baseFileName)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(baseFileName.isEmpty ? .secondary : .primary)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color(NSColor.textBackgroundColor))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                    )
                                
                                Text("Files will be named: \(baseFileName)_1.pdf, \(baseFileName)_2.pdf, etc.\nAdd suffixes in 'Customise Names' for: \(baseFileName)Flute.pdf (no automatic numbering)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.controlBackgroundColor))
                            )
                            
                            // Action button
                            HStack {
                                Spacer()
                                
                                Button(action: { isShowingFolderPicker = true }) {
                                    Label("Split and Save", systemImage: "arrow.down.doc.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                .disabled(numberOfFiles < 2)
                            }
                        }
                        .padding()
                        .frame(width: geometry.size.width * 0.5)
                    }
                    .onKeyPress(.space) {
                        if currentPage > 0 {
                            if splitMarkers.contains(currentPage) {
                                splitMarkers.remove(currentPage)
                            } else {
                                splitMarkers.insert(currentPage)
                            }
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.leftArrow) {
                        if currentPage > 0 {
                            currentPage -= 1
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.rightArrow) {
                        if currentPage < totalPages - 1 {
                            currentPage += 1
                            return .handled
                        }
                        return .ignored
                    }
                }
            } else {
                // No PDF loaded - show drop zone
                DropZoneView(pdfManager: pdfManager)
            }
        }
        .focused($isViewFocused)
        .onAppear {
            isViewFocused = true
        }
        .onChange(of: pdfManager.pdfDocument) { newValue in
            if newValue != nil {
                baseFileName = pdfManager.currentFileName ?? ""
                isViewFocused = true
            } else {
                splitMarkers.removeAll()
                currentPage = 0
                customFileNames.removeAll()
            }
        }
        .onChange(of: isShowingFolderPicker) { newValue in
            if newValue {
                saveSplitPDF()
            }
        }
        .sheet(isPresented: $showingBaseNameSheet) {
            BaseNameEditSheet(
                baseFileName: $editingBaseFileName,
                onSave: {
                    baseFileName = editingBaseFileName
                    showingBaseNameSheet = false
                }
            )
        }
        .sheet(isPresented: $showingAutoSplitSheet) {
            AutoSplitSheet(
                autoSplitPages: $autoSplitPages,
                onApply: {
                    applyAutoSplit()
                    showingAutoSplitSheet = false
                }
            )
        }
        .sheet(isPresented: $showingFileNamesSheet) {
            CustomFileNamesSheet(
                numberOfFiles: numberOfFiles,
                baseFileName: baseFileName,
                customFileNames: $customFileNames,
                pageToFileMapping: pageToFileMapping,
                pdfDocument: pdfManager.pdfDocument
            )
        }
    }
    
    private func clearAllMarkers() {
        splitMarkers.removeAll()
    }
    
    private func applyAutoSplit() {
        splitMarkers.removeAll()
        
        var pageIndex = autoSplitPages
        while pageIndex < totalPages {
            splitMarkers.insert(pageIndex)
            pageIndex += autoSplitPages
        }
    }
    
    private func saveSplitPDF() {
        guard let document = pdfManager.pdfDocument, numberOfFiles >= 2 else {
            isShowingFolderPicker = false
            return
        }
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "Select Output Folder"
        panel.message = "Choose where to save the split PDF files"
        
        panel.begin { response in
            if response == .OK, let folderURL = panel.url {
                pdfManager.saveSplitPDF(
                    to: folderURL,
                    splitMarkers: splitMarkers,
                    baseFileName: baseFileName,
                    customFileNames: customFileNames,
                    pageToFileMapping: pageToFileMapping
                )
            }
            isShowingFolderPicker = false
        }
    }
}

// MARK: - Split Controls Section
struct SplitControlsSection: View {
    let document: PDFDocument
    @Binding var currentPage: Int
    @Binding var splitMarkers: Set<Int>
    let totalPages: Int
    
    var body: some View {
        VStack(spacing: 12) {
            // Navigation controls
            HStack {
                Button(action: previousPage) {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPage == 0)
                
                Spacer()
                
                VStack(spacing: 4) {
                    Text("Page \(currentPage + 1) of \(totalPages)")
                        .font(.headline)
                }
                
                Spacer()
                
                Button(action: nextPage) {
                    Image(systemName: "chevron.right")
                }
                .disabled(currentPage >= totalPages - 1)
            }
            .padding(.horizontal)
            
            // Split marker controls
            HStack(spacing: 12) {
                Button(action: toggleMarker) {
                    if splitMarkers.contains(currentPage) {
                        Label("Remove Split Marker", systemImage: "xmark.circle")
                    } else {
                        Label("Add Split Marker", systemImage: "plus.circle")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(currentPage == 0)
                
                Text("Press Space to toggle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }
    
    private func toggleMarker() {
        if splitMarkers.contains(currentPage) {
            splitMarkers.remove(currentPage)
        } else {
            splitMarkers.insert(currentPage)
        }
    }
    
    private func previousPage() {
        if currentPage > 0 {
            currentPage -= 1
        }
    }
    
    private func nextPage() {
        if currentPage < totalPages - 1 {
            currentPage += 1
        }
    }
}

// MARK: - File Preview Card
struct FilePreviewCard: View {
    let fileIndex: Int
    let pageToFileMapping: [Int: Int]
    let totalPages: Int
    let baseFileName: String
    let customFileNames: [Int: String]
    let onNavigate: (Int) -> Void
    
    var pagesInFile: [Int] {
        pageToFileMapping.filter { $0.value == fileIndex }.keys.sorted()
    }
    
    var fileName: String {
        if let customSuffix = customFileNames[fileIndex], !customSuffix.isEmpty {
            return "\(baseFileName)\(customSuffix).pdf"
        } else {
            return "\(baseFileName)_\(fileIndex + 1).pdf"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.fill")
                    .foregroundColor(.blue)
                
                Text(fileName)
                    .font(.headline)
                
                Spacer()
                
                Text("\(pagesInFile.count) page\(pagesInFile.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 4) {
                ForEach(pagesInFile.prefix(10), id: \.self) { pageIndex in
                    Button(action: {
                        onNavigate(pageIndex)
                    }) {
                        Text("\(pageIndex + 1)")
                            .font(.caption2)
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor.opacity(0.2))
                            )
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
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }
}

// MARK: - Base Name Edit Sheet
struct BaseNameEditSheet: View {
    @Binding var baseFileName: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Base Filename")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("This name will be used for all split files")
                .font(.callout)
                .foregroundColor(.secondary)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Base Filename:")
                    .font(.headline)
                
                TextField("Enter base filename", text: $baseFileName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                
                Text("Example: \(baseFileName.isEmpty ? "filename" : baseFileName)_1.pdf, \(baseFileName.isEmpty ? "filename" : baseFileName)_2.pdf, etc.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            
            Spacer()
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Save") {
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 450, height: 280)
    }
}

// MARK: - Auto Split Sheet
struct AutoSplitSheet: View {
    @Binding var autoSplitPages: Int
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Auto-Split Every N Pages")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("This will automatically add split markers every N pages")
                .font(.callout)
                .foregroundColor(.secondary)
            
            Divider()
            
            HStack {
                Text("Split every:")
                
                TextField("Pages", value: $autoSplitPages, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                
                Stepper("", value: $autoSplitPages, in: 1...100)
                
                Text("pages")
                
                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            
            Spacer()
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Apply") {
                    onApply()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 400, height: 250)
    }
}

// MARK: - Custom File Names Sheet
struct CustomFileNamesSheet: View {
    let numberOfFiles: Int
    let baseFileName: String
    @Binding var customFileNames: [Int: String]
    let pageToFileMapping: [Int: Int]
    let pdfDocument: PDFDocument?
    @Environment(\.dismiss) private var dismiss
    
    @State private var editableNames: [Int: String] = [:]
    @FocusState private var focusedField: Int?
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Customise File Names")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Names will be added as suffixes to the base name (no automatic numbering)")
                .font(.callout)
                .foregroundColor(.secondary)
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(0..<numberOfFiles, id: \.self) { fileIndex in
                            HStack(alignment: .top, spacing: 12) {
                                // Preview of first page in this file
                                if let document = pdfDocument,
                                   let firstPageIndex = pagesInFile(fileIndex).first,
                                   let page = document.page(at: firstPageIndex) {
                                    PageInstrumentPreview(page: page)
                                        .frame(width: 80, height: 100)
                                } else {
                                    Rectangle()
                                        .fill(Color.gray.opacity(0.2))
                                        .frame(width: 80, height: 100)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("File \(fileIndex + 1)")
                                        .font(.headline)
                                    
                                    if let pageRange = pagesInFile(fileIndex).first.map({ first in
                                        let last = pagesInFile(fileIndex).last ?? first
                                        return first == last ? "Page \(first + 1)" : "Pages \(first + 1)-\(last + 1)"
                                    }) {
                                        Text(pageRange)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    HStack(spacing: 4) {
                                        Text(baseFileName)
                                            .foregroundColor(.secondary)
                                        
                                        TextField("suffix (optional)", text: Binding(
                                            get: { editableNames[fileIndex] ?? "" },
                                            set: { editableNames[fileIndex] = $0.isEmpty ? nil : $0 }
                                        ))
                                        .textFieldStyle(.roundedBorder)
                                        .focused($focusedField, equals: fileIndex)
                                        .onSubmit {
                                            // Move to next field on Return
                                            if fileIndex < numberOfFiles - 1 {
                                                focusedField = fileIndex + 1
                                            }
                                        }
                                        
                                        Text(".pdf")
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    // Preview of final name
                                    if let suffix = editableNames[fileIndex], !suffix.isEmpty {
                                        Text("→ \(baseFileName)\(suffix).pdf")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                    } else {
                                        Text("→ (no custom name, will use default: \(baseFileName)_\(fileIndex + 1).pdf)")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.controlBackgroundColor))
                            )
                            .id(fileIndex)
                        }
                    }
                    .onChange(of: focusedField) { newValue in
                        if let field = newValue {
                            withAnimation {
                                proxy.scrollTo(field, anchor: .center)
                            }
                        }
                    }
                }
                .frame(height: 400)
            }
            
            HStack {
                Button("Clear All") {
                    editableNames.removeAll()
                }
                
                Spacer()
                
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Save") {
                    customFileNames = editableNames
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 600, height: 600)
        .onAppear {
            editableNames = customFileNames
        }
    }
    
    private func pagesInFile(_ fileIndex: Int) -> [Int] {
        pageToFileMapping.filter { $0.value == fileIndex }.keys.sorted()
    }
}

// MARK: - Page Instrument Preview
struct PageInstrumentPreview: View {
    let page: PDFPage
    
    var body: some View {
        if let image = renderInstrumentNameArea(from: page) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
        }
    }
    
    // Render just the top-left portion where instrument names typically appear
    private func renderInstrumentNameArea(from page: PDFPage) -> NSImage? {
        let pageBounds = page.bounds(for: .mediaBox)
        
        // Calculate the crop area - top 1 inch (72 points) of the left side
        let cropHeight: CGFloat = 72 // 1 inch
        let cropWidth: CGFloat = min(pageBounds.width * 0.4, 200) // Left 40% of page, max 200pt
        
        // Account for page rotation
        let rotation = page.rotation
        var actualBounds = pageBounds
        if rotation == 90 || rotation == 270 {
            actualBounds = CGRect(x: pageBounds.origin.x, y: pageBounds.origin.y,
                                width: pageBounds.height, height: pageBounds.width)
        }
        
        let cropRect = CGRect(
            x: actualBounds.origin.x,
            y: actualBounds.origin.y + actualBounds.height - cropHeight,
            width: cropWidth,
            height: cropHeight
        )
        
        // Create image
        let scale: CGFloat = 2.0 // Retina resolution
        let imageSize = NSSize(width: cropRect.width * scale, height: cropRect.height * scale)
        
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(imageSize.width),
            pixelsHigh: Int(imageSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            return nil
        }
        NSGraphicsContext.current = context
        
        let cgContext = context.cgContext
        
        // Fill white background
        cgContext.setFillColor(NSColor.white.cgColor)
        cgContext.fill(CGRect(origin: .zero, size: imageSize))
        
        // Set up transform for cropped area
        cgContext.scaleBy(x: scale, y: scale)
        cgContext.translateBy(x: -cropRect.origin.x, y: -cropRect.origin.y)
        
        // Draw the page
        page.draw(with: .mediaBox, to: cgContext)
        
        NSGraphicsContext.restoreGraphicsState()
        
        let image = NSImage(size: cropRect.size)
        image.addRepresentation(bitmapRep)
        return image
    }
}

// MARK: - Drop Zone View (Shared)
struct DropZoneView: View {
    @ObservedObject var pdfManager: PDFManager
    @State private var isTargeted = false
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.viewfinder")
                .font(.system(size: 64))
                .foregroundColor(isTargeted ? .accentColor : .secondary)
            
            Text("Drop a PDF here")
                .font(.title2)
                .fontWeight(.medium)
            
            Text("or")
                .foregroundColor(.secondary)
            
            Button(action: selectPDF) {
                Label("Choose PDF", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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
            guard let provider = providers.first else { return false }
            
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url, url.pathExtension.lowercased() == "pdf" {
                    DispatchQueue.main.async {
                        pdfManager.loadPDF(from: url)
                    }
                }
            }
            
            return true
        }
    }
    
    private func selectPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.title = "Select PDF"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                pdfManager.loadPDF(from: url)
            }
        }
    }
}

// MARK: - Rotate Preview Section
struct RotatePreviewSection: View {
    let document: PDFDocument
    @Binding var currentPage: Int
    let baseRotation: RotationAngle
    let additionalRotationMode: RotationMode
    let additionalRotationAngle: RotationAngle
    
    var totalPages: Int {
        document.pageCount
    }
    
    var totalRotationForCurrentPage: Int {
        let pageNumber = currentPage + 1
        var rotation = baseRotation.degrees
        
        let shouldApplyAdditional: Bool
        switch additionalRotationMode {
        case .odd:
            shouldApplyAdditional = pageNumber % 2 == 1
        case .even:
            shouldApplyAdditional = pageNumber % 2 == 0
        case .none, .all:
            shouldApplyAdditional = false
        }
        
        if shouldApplyAdditional {
            rotation += additionalRotationAngle.degrees
        }
        
        return rotation % 360
    }
    
    var rotationDescription: String {
        if totalRotationForCurrentPage == 0 {
            return "No rotation"
        } else if baseRotation.degrees == 0 {
            return "Rotated \(additionalRotationAngle.degrees)°"
        } else if additionalRotationMode == .none {
            return "Rotated \(baseRotation.degrees)°"
        } else {
            return "Rotated \(additionalRotationAngle.degrees)°"
        }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Page navigation
            HStack {
                Button(action: previousPage) {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPage == 0)
                
                Spacer()
                
                VStack(spacing: 4) {
                    Text("Page \(currentPage + 1) of \(totalPages)")
                        .font(.headline)
                    
                    Text(rotationDescription)
                        .font(.caption)
                        .foregroundColor(totalRotationForCurrentPage > 0 ? .orange : .secondary)
                        .fontWeight(totalRotationForCurrentPage > 0 ? .semibold : .regular)
                }
                
                Spacer()
                
                Button(action: nextPage) {
                    Image(systemName: "chevron.right")
                }
                .disabled(currentPage >= totalPages - 1)
            }
            .padding(.horizontal)
            
            // Preview images
            HStack(spacing: 16) {
                // Before
                VStack {
                    Text("Before")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    PDFPageView(
                        page: document.page(at: currentPage),
                        rotation: 0
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                Image(systemName: "arrow.right")
                    .font(.title2)
                    .foregroundColor(.secondary)
                
                // After
                VStack {
                    Text(totalRotationForCurrentPage > 0 ? "After (Rotated)" : "After (No Change)")
                        .font(.caption)
                        .foregroundColor(totalRotationForCurrentPage > 0 ? .orange : .secondary)
                        .fontWeight(totalRotationForCurrentPage > 0 ? .semibold : .regular)
                    
                    PDFPageView(
                        page: document.page(at: currentPage),
                        rotation: totalRotationForCurrentPage
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .padding()
        }
    }
    
    private func previousPage() {
        if currentPage > 0 {
            currentPage -= 1
        }
    }
    
    private func nextPage() {
        if currentPage < totalPages - 1 {
            currentPage += 1
        }
    }
}

// MARK: - PDF Page View using native PDFView
struct PDFPageView: NSViewRepresentable {
    let page: PDFPage?
    let rotation: Int
    
    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePage
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = NSColor.white
        return pdfView
    }
    
    func updateNSView(_ pdfView: PDFView, context: Context) {
        guard let page = page else {
            pdfView.document = nil
            return
        }
        
        let document = PDFDocument()
        if let image = renderFullImage(from: page), let clonedPage = PDFPage(image: image) {
            clonedPage.rotation = rotation
            document.insert(clonedPage, at: 0)
        } else {
            // Fallback: insert original page without rotation to avoid mutating shared state
            document.insert(page, at: 0)
        }
        pdfView.document = document
        if let first = document.page(at: 0) {
            pdfView.go(to: first)
        }
    }
    
    // Render the full PDF page into an NSImage for safe preview cloning
    private func renderFullImage(from page: PDFPage) -> NSImage? {
        let bounds = page.bounds(for: .mediaBox)
        let size = NSSize(width: bounds.width, height: bounds.height)
        let image = NSImage(size: size)
        image.lockFocus()
        
        NSGraphicsContext.current?.imageInterpolation = .high
        
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            // Draw the page directly without flipping - PDFKit handles orientation
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()
        }
        
        image.unlockFocus()
        return image
    }
}

// MARK: - PDF Manager
class PDFManager: ObservableObject {
    @Published var pdfDocument: PDFDocument?
    @Published var currentFileName: String?
    
    func loadPDF(from url: URL) {
        guard let document = PDFDocument(url: url) else {
            print("Failed to load PDF")
            return
        }
        
        self.pdfDocument = document
        self.currentFileName = url.deletingPathExtension().lastPathComponent
    }
    
    func clearPDF() {
        pdfDocument = nil
        currentFileName = nil
    }
    
    func saveRotatedPDF(to url: URL, baseRotation: RotationAngle, additionalRotationMode: RotationMode, additionalRotationAngle: RotationAngle) {
        guard let document = pdfDocument else { return }
        
        let newDocument = PDFDocument()
        
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            
            let pageNumber = pageIndex + 1
            
            if baseRotation.degrees != 0 {
                page.rotation += baseRotation.degrees
            }
            
            let shouldApplyAdditional: Bool
            switch additionalRotationMode {
            case .odd:
                shouldApplyAdditional = pageNumber % 2 == 1
            case .even:
                shouldApplyAdditional = pageNumber % 2 == 0
            case .none, .all:
                shouldApplyAdditional = false
            }
            
            if shouldApplyAdditional {
                page.rotation += additionalRotationAngle.degrees
            }
            
            newDocument.insert(page, at: pageIndex)
        }
        
        newDocument.write(to: url)
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "PDF Saved Successfully"
            alert.informativeText = "Your rotated PDF has been saved to:\n\(url.path)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
    
    func saveSplitPDF(to folderURL: URL, splitMarkers: Set<Int>, baseFileName: String, customFileNames: [Int: String], pageToFileMapping: [Int: Int]) {
        guard let document = pdfDocument else { return }
        
        let numberOfFiles = (pageToFileMapping.values.max() ?? 0) + 1
        var fileDocuments: [Int: PDFDocument] = [:]
        
        // Initialize PDF documents for each file
        for fileIndex in 0..<numberOfFiles {
            fileDocuments[fileIndex] = PDFDocument()
        }
        
        // Distribute pages to files
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let fileIndex = pageToFileMapping[pageIndex],
                  let targetDoc = fileDocuments[fileIndex] else {
                continue
            }
            
            targetDoc.insert(page, at: targetDoc.pageCount)
        }
        
        // Save each file
        var savedFiles: [String] = []
        var errors: [String] = []
        
        for fileIndex in 0..<numberOfFiles {
            guard let doc = fileDocuments[fileIndex] else { continue }
            
            let fileName: String
            if let customSuffix = customFileNames[fileIndex], !customSuffix.isEmpty {
                fileName = "\(baseFileName)\(customSuffix).pdf"
            } else {
                fileName = "\(baseFileName)_\(fileIndex + 1).pdf"
            }
            
            let fileURL = folderURL.appendingPathComponent(fileName)
            
            if doc.write(to: fileURL) {
                savedFiles.append(fileName)
            } else {
                errors.append(fileName)
            }
        }
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            if errors.isEmpty {
                alert.messageText = "PDF Split Successfully"
                alert.informativeText = "Created \(savedFiles.count) file(s) in:\n\(folderURL.path)"
                alert.alertStyle = .informational
            } else {
                alert.messageText = "Partial Success"
                alert.informativeText = "Created \(savedFiles.count) file(s), but \(errors.count) failed:\n\(errors.joined(separator: ", "))"
                alert.alertStyle = .warning
            }
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

// MARK: - Supporting Types
enum RotationMode {
    case odd
    case even
    case all
    case none
}

enum RotationAngle: Int {
    case none = 0
    case rotate90 = 90
    case rotate180 = 180
    case rotate270 = 270
    
    var degrees: Int {
        self.rawValue
    }
}
