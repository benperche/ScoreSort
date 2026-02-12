//
//  ScanReorienterApp.swift
//  Scan Reorienter
//
//  A macOS app for rotating odd or even pages in PDF files
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import Combine

// MARK: - Main App
@main
struct ScanReorienterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            RotateView()
                .tabItem {
                    Label("Rotate Pages", systemImage: "rotate.right")
                }
                .tag(0)
            
            SplitView()
                .tabItem {
                    Label("Split PDF", systemImage: "scissors")
                }
                .tag(1)
        }
        .frame(minWidth: 800, minHeight: 600)
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
    @State private var splitMarkers: Set<Int> = [] // Page indices where splits occur (start of new file)
    @State private var currentPage: Int = 0
    @State private var autoSplitPages: Int = 2
    @State private var isShowingFolderPicker = false
    @State private var showingAutoSplitSheet = false
    
    var totalPages: Int {
        pdfManager.pdfDocument?.pageCount ?? 0
    }
    
    // Calculate which file each page belongs to
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
    
    var numberOfOutputFiles: Int {
        guard totalPages > 0 else { return 0 }
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
                    Button(action: {
                        pdfManager.clearPDF()
                        splitMarkers.removeAll()
                        currentPage = 0
                    }) {
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
                VStack(spacing: 16) {
                    // Preview and controls
                    HStack(spacing: 16) {
                        // Left side - Preview
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
                                    
                                    if let fileNum = pageToFileMapping[currentPage] {
                                        Text("Will be in file \(fileNum + 1)")
                                            .font(.caption)
                                            .foregroundColor(.blue)
                                    }
                                    
                                    if splitMarkers.contains(currentPage) {
                                        Text("⚑ SPLIT MARKER - Starts new file")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                            .fontWeight(.semibold)
                                    }
                                }
                                
                                Spacer()
                                
                                Button(action: nextPage) {
                                    Image(systemName: "chevron.right")
                                }
                                .disabled(currentPage >= totalPages - 1)
                            }
                            
                            // PDF Preview
                            PDFPageView(
                                page: document.page(at: currentPage),
                                rotation: 0
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(
                                Group {
                                    if splitMarkers.contains(currentPage) {
                                        VStack {
                                            HStack {
                                                Image(systemName: "flag.fill")
                                                    .foregroundColor(.orange)
                                                    .font(.title)
                                                Spacer()
                                            }
                                            Spacer()
                                        }
                                        .padding(8)
                                    }
                                }
                            )
                            
                            // Toggle split marker button
                            Button(action: toggleSplitMarker) {
                                Label(
                                    splitMarkers.contains(currentPage) ? "Remove Split Marker" : "Add Split Marker (Start New File Here)",
                                    systemImage: splitMarkers.contains(currentPage) ? "flag.slash.fill" : "flag.fill"
                                )
                            }
                            .buttonStyle(.bordered)
                            .disabled(currentPage == 0) // Can't split before first page
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        
                        Divider()
                        
                        // Right side - Split overview and controls
                        VStack(alignment: .leading, spacing: 16) {
                            // Split summary
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Split Summary")
                                    .font(.headline)
                                
                                Text("\(numberOfOutputFiles) output files will be created")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                
                                if splitMarkers.isEmpty {
                                    Text("No split markers set")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                } else {
                                    Text("\(splitMarkers.count) split markers")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.controlBackgroundColor))
                            )
                            
                            // Auto-split options
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Quick Auto-Split")
                                    .font(.headline)
                                
                                HStack {
                                    Text("Every")
                                    
                                    Stepper("\(autoSplitPages)", value: $autoSplitPages, in: 1...20)
                                        .frame(width: 100)
                                    
                                    Text("pages")
                                }
                                
                                Button(action: autoSplit) {
                                    Label("Apply Auto-Split", systemImage: "wand.and.stars")
                                }
                                .buttonStyle(.bordered)
                                
                                Button(action: { showingAutoSplitSheet = true }) {
                                    Label("Advanced Auto-Split", systemImage: "slider.horizontal.3")
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.controlBackgroundColor))
                            )
                            
                            // Split markers list
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Split Markers")
                                        .font(.headline)
                                    
                                    Spacer()
                                    
                                    if !splitMarkers.isEmpty {
                                        Button("Clear All") {
                                            splitMarkers.removeAll()
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(.red)
                                        .font(.caption)
                                    }
                                }
                                
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 4) {
                                        if splitMarkers.isEmpty {
                                            Text("Click 'Add Split Marker' on pages where you want to start a new file")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .padding(8)
                                        } else {
                                            ForEach(splitMarkers.sorted(), id: \.self) { pageIndex in
                                                HStack {
                                                    Image(systemName: "flag.fill")
                                                        .foregroundColor(.orange)
                                                        .font(.caption)
                                                    
                                                    Text("Page \(pageIndex + 1)")
                                                        .font(.caption)
                                                    
                                                    Spacer()
                                                    
                                                    Button(action: {
                                                        splitMarkers.remove(pageIndex)
                                                    }) {
                                                        Image(systemName: "xmark.circle.fill")
                                                            .foregroundColor(.secondary)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                                .padding(.vertical, 4)
                                                .padding(.horizontal, 8)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .fill(currentPage == pageIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                                                )
                                                .onTapGesture {
                                                    currentPage = pageIndex
                                                }
                                            }
                                        }
                                    }
                                }
                                .frame(maxHeight: 200)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.controlBackgroundColor))
                            )
                            
                            Spacer()
                            
                            // Action button
                            Button(action: { isShowingFolderPicker = true }) {
                                Label("Split PDF and Save Files", systemImage: "scissors")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(numberOfOutputFiles <= 1)
                        }
                        .frame(width: 300)
                        .padding()
                    }
                }
            } else {
                // No PDF loaded - show drop zone
                DropZoneView(pdfManager: pdfManager)
            }
        }
        .onChange(of: isShowingFolderPicker) { newValue in
            if newValue {
                selectOutputFolder()
            }
        }
        .sheet(isPresented: $showingAutoSplitSheet) {
            AdvancedAutoSplitSheet(
                totalPages: totalPages,
                splitMarkers: $splitMarkers,
                isPresented: $showingAutoSplitSheet
            )
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
    
    private func toggleSplitMarker() {
        if currentPage == 0 { return } // Can't split before first page
        
        if splitMarkers.contains(currentPage) {
            splitMarkers.remove(currentPage)
        } else {
            splitMarkers.insert(currentPage)
        }
    }
    
    private func autoSplit() {
        splitMarkers.removeAll()
        
        // Add markers at every N pages
        for pageIndex in stride(from: autoSplitPages, to: totalPages, by: autoSplitPages) {
            splitMarkers.insert(pageIndex)
        }
    }
    
    private func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Output Folder"
        panel.message = "Choose where to save the split PDF files"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                performSplit(outputFolder: url)
            }
            isShowingFolderPicker = false
        }
    }
    
    private func performSplit(outputFolder: URL) {
        guard let document = pdfManager.pdfDocument else { return }
        guard numberOfOutputFiles > 1 else { return }
        
        let baseFileName = pdfManager.currentFileName ?? "document"
        let mapping = pageToFileMapping
        
        // Group pages by file index
        var fileGroups: [Int: [Int]] = [:]
        for pageIndex in 0..<totalPages {
            let fileIndex = mapping[pageIndex] ?? 0
            fileGroups[fileIndex, default: []].append(pageIndex)
        }
        
        var savedFiles: [URL] = []
        
        // Create each split PDF
        for fileIndex in 0..<numberOfOutputFiles {
            guard let pageIndices = fileGroups[fileIndex] else { continue }
            
            let newDocument = PDFDocument()
            
            for (newIndex, originalIndex) in pageIndices.enumerated() {
                if let page = document.page(at: originalIndex) {
                    newDocument.insert(page, at: newIndex)
                }
            }
            
            // Determine filename
            let fileName: String
            if numberOfOutputFiles == 1 {
                fileName = "\(baseFileName).pdf"
            } else {
                let startPage = pageIndices.first! + 1
                let endPage = pageIndices.last! + 1
                fileName = "\(baseFileName)_part\(fileIndex + 1)_pages\(startPage)-\(endPage).pdf"
            }
            
            let outputURL = outputFolder.appendingPathComponent(fileName)
            newDocument.write(to: outputURL)
            savedFiles.append(outputURL)
        }
        
        // Show success alert
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "PDF Split Successfully"
            alert.informativeText = "Created \(savedFiles.count) files in:\n\(outputFolder.path)"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "OK")
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.selectFile(savedFiles.first?.path, inFileViewerRootedAtPath: outputFolder.path)
            }
        }
    }
}

// MARK: - Advanced Auto-Split Sheet
struct AdvancedAutoSplitSheet: View {
    let totalPages: Int
    @Binding var splitMarkers: Set<Int>
    @Binding var isPresented: Bool
    
    @State private var sections: [SplitSection] = [SplitSection(pagesPerPart: 2, numberOfParts: 1)]
    
    var estimatedTotalPages: Int {
        sections.reduce(0) { $0 + ($1.pagesPerPart * $1.numberOfParts) }
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Advanced Auto-Split")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Define sections with different page counts")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Divider()
            
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(sections.indices, id: \.self) { index in
                        HStack {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Section \(index + 1)")
                                    .font(.headline)
                                
                                HStack {
                                    Stepper("Pages per part: \(sections[index].pagesPerPart)",
                                           value: $sections[index].pagesPerPart, in: 1...20)
                                    
                                    Spacer()
                                    
                                    Stepper("× \(sections[index].numberOfParts) parts",
                                           value: $sections[index].numberOfParts, in: 1...50)
                                }
                                
                                Text("= \(sections[index].pagesPerPart * sections[index].numberOfParts) pages total")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Button(action: { sections.remove(at: index) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .disabled(sections.count == 1)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                    }
                }
            }
            .frame(maxHeight: 300)
            
            Button(action: { sections.append(SplitSection(pagesPerPart: 2, numberOfParts: 1)) }) {
                Label("Add Section", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.bordered)
            
            Divider()
            
            HStack {
                VStack(alignment: .leading) {
                    Text("Estimated total: \(estimatedTotalPages) pages")
                        .font(.subheadline)
                    
                    if estimatedTotalPages != totalPages {
                        Text("PDF has \(totalPages) pages - adjust sections to match")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                
                Spacer()
                
                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(.bordered)
                
                Button("Apply") {
                    applySections()
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 600)
    }
    
    private func applySections() {
        splitMarkers.removeAll()
        
        var currentPage = 0
        
        for section in sections {
            for _ in 0..<section.numberOfParts {
                currentPage += section.pagesPerPart
                if currentPage < totalPages {
                    splitMarkers.insert(currentPage)
                }
            }
        }
    }
}

struct SplitSection {
    var pagesPerPart: Int
    var numberOfParts: Int
}

// MARK: - Drop Zone View
struct DropZoneView: View {
    @ObservedObject var pdfManager: PDFManager
    @State private var isTargeted = false
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.fill")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("Drop PDF Here")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("or click to browse")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Button("Choose PDF File") {
                selectPDF()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [10]))
                .foregroundColor(isTargeted ? .accentColor : .secondary)
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .padding(40)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }
    
    private func selectPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                pdfManager.loadPDF(from: url)
            }
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.pathExtension.lowercased() == "pdf" else {
                return
            }
            
            DispatchQueue.main.async {
                pdfManager.loadPDF(from: url)
            }
        }
        
        return true
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
        var total = baseRotation.degrees
        
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
            total += additionalRotationAngle.degrees
        }
        
        return total
    }
    
    var rotationDescription: String {
        let pageNumber = currentPage + 1
        let base = baseRotation.degrees
        let shouldApplyAdditional: Bool
        
        switch additionalRotationMode {
        case .odd:
            shouldApplyAdditional = pageNumber % 2 == 1
        case .even:
            shouldApplyAdditional = pageNumber % 2 == 0
        case .none, .all:
            shouldApplyAdditional = false
        }
        
        if base == 0 && !shouldApplyAdditional {
            return "No rotation"
        } else if base != 0 && shouldApplyAdditional {
            let additional = additionalRotationAngle.degrees
            let total = base + additional
            return "Rotated \(total)° (\(base)° + \(additional)°)"
        } else if base != 0 {
            return "Rotated \(base)°"
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

// MARK: - PDF Page View
struct PDFPageView: View {
    let page: PDFPage?
    let rotation: Int
    
    var body: some View {
        GeometryReader { geometry in
            if let page = page {
                Image(nsImage: renderPage(page, in: geometry.size))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .background(Color.white)
        .cornerRadius(4)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
    
    private func renderPage(_ page: PDFPage, in size: CGSize) -> NSImage {
        let originalBounds = page.bounds(for: .mediaBox)
        
        // Calculate scale to fit in view
        let scale = min(
            size.width / originalBounds.width,
            size.height / originalBounds.height
        )
        
        // Adjust for rotation
        var renderBounds = originalBounds
        if rotation == 90 || rotation == 270 {
            renderBounds = CGRect(
                x: 0,
                y: 0,
                width: originalBounds.height,
                height: originalBounds.width
            )
        }
        
        let scaledSize = CGSize(
            width: renderBounds.width * scale,
            height: renderBounds.height * scale
        )
        
        let image = NSImage(size: scaledSize)
        image.lockFocus()
        
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            
            // Fill background
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: scaledSize))
            
            // Apply rotation
            context.translateBy(x: scaledSize.width / 2, y: scaledSize.height / 2)
            context.rotate(by: CGFloat(rotation) * .pi / 180)
            context.translateBy(x: -renderBounds.width * scale / 2, y: -renderBounds.height * scale / 2)
            
            // Scale to fit
            context.scaleBy(x: scale, y: scale)
            
            // Draw PDF page
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
            
            // Apply base rotation to all pages
            if baseRotation.degrees != 0 {
                page.rotation += baseRotation.degrees
            }
            
            // Apply additional rotation to odd/even pages if specified
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
        
        // Show success alert
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "PDF Saved Successfully"
            alert.informativeText = "Your rotated PDF has been saved to:\n\(url.path)"
            alert.alertStyle = .informational
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
