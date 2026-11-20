//
//  RotateTab.swift
//  ScoreSort
//
//  The Rotate Pages tab: RotateView plus its page-preview section. Uses the shared
//  PDFManager (in the main file) as its @StateObject.
//

import SwiftUI
@preconcurrency import PDFKit
import UniformTypeIdentifiers
import Combine

// MARK: - Rotate View
struct RotateView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var pdfManager = PDFManager()
    @State private var baseRotation: RotationAngle = .none
    @State private var additionalRotationMode: RotationMode = .none
    @State private var additionalRotationAngle: RotationAngle = .rotate180
    @State private var pageRotationOverrides: [Int: Int] = [:]
    @State private var currentPage: Int = 0
    @State private var isShowingSavePanel = false
    @FocusState private var isViewFocused: Bool

    var totalPages: Int { pdfManager.pdfDocument?.pageCount ?? 0 }
    
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
                        Label("Clear File", systemImage: "xmark.circle.fill")
                    }
                    .help("Remove the current file and start over")
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Main content area
            if let document = pdfManager.pdfDocument {
                // PDF loaded - show preview and controls. No stack spacing: the preview's
                // and the controls' own padding already space them either side of the
                // divider, and spacing on top left an empty band the previews can use (#35).
                VStack(spacing: 0) {
                    // Preview area
                    RotatePreviewSection(
                        document: document,
                        currentPage: $currentPage,
                        baseRotation: baseRotation,
                        additionalRotationMode: additionalRotationMode,
                        additionalRotationAngle: additionalRotationAngle,
                        pageRotationOverrides: pageRotationOverrides,
                        onRotateCurrentPageLeft:  rotateCurrentPageLeft,
                        onRotateCurrentPageRight: rotateCurrentPageRight
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
                                // "Rotate all pages:" is the visible label; the picker's own
                                // label squeezed into the 280-pt frame and wrapped (#35).
                                .labelsHidden()
                                .accessibilityLabel("Base rotation")
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
                            
                            HStack(spacing: 0) {
                                // Left half — mode selector
                                Picker("Then also rotate:", selection: $additionalRotationMode) {
                                    Text("No additional rotation").tag(RotationMode.none)
                                    Text("Odd pages (1, 3, 5...)").tag(RotationMode.odd)
                                    Text("Even pages (2, 4, 6...)").tag(RotationMode.even)
                                }
                                .pickerStyle(.radioGroup)
                                .frame(maxWidth: .infinity, alignment: .leading)

                                // Right half — angle selector, left-aligned at window midpoint
                                if additionalRotationMode != .none {
                                    HStack(spacing: 8) {
                                        Text("By:")
                                            .foregroundColor(.secondary)
                                        Picker("Additional rotation angle", selection: $additionalRotationAngle) {
                                            Text("90°").tag(RotationAngle.rotate90)
                                            Text("180°").tag(RotationAngle.rotate180)
                                            Text("270°").tag(RotationAngle.rotate270)
                                        }
                                        .pickerStyle(.segmented)
                                        .labelsHidden()
                                        .frame(width: 200)
                                        Spacer()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Spacer()
                                        .frame(maxWidth: .infinity)
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
                DropZoneView(pdfManager: pdfManager,
                             subtitle: "Correct pages that came out sideways or upside-down after scanning")
            }
        }
        .focusable()
        .focused($isViewFocused)
        // Files opened from Finder or the Dock (#21), handed over by AppState.
        .onAppear { takePendingOpen() }
        .onChange(of: appState.pendingOpen?.id) { takePendingOpen() }
        .onAppear { isViewFocused = true; DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: appState.selectedTab) { DispatchQueue.main.async { syncTabCommands() } }
        .onChange(of: pdfManager.pdfDocument) { _, newValue in
            DispatchQueue.main.async { syncTabCommands() }
            if newValue != nil {
                isViewFocused = true
            } else {
                // PDF cleared — reset all rotation state for the next document.
                baseRotation = .none
                additionalRotationMode = .none
                additionalRotationAngle = .rotate180
                pageRotationOverrides = [:]
                currentPage = 0
            }
        }
        .onKeyPress { press in
            guard appState.selectedTab == 3 else { return .ignored }   // Rotate tab only
            guard pdfManager.pdfDocument != nil else { return .ignored }
            switch press.key {
            case .leftArrow:
                if press.modifiers.contains(.command) { currentPage = 0 }
                else if currentPage > 0 { currentPage -= 1 }
                return .handled
            case .rightArrow:
                if press.modifiers.contains(.command) { currentPage = totalPages - 1 }
                else if currentPage < totalPages - 1 { currentPage += 1 }
                return .handled
            case KeyEquivalent(","):
                rotateCurrentPageLeft()
                return .handled
            case KeyEquivalent("."):
                rotateCurrentPageRight()
                return .handled
            default:
                return .ignored
            }
        }
        .onChange(of: pdfManager.pdfDocument) { _, newValue in
            if newValue == nil { pageRotationOverrides = [:] }
        }
        .onChange(of: isShowingSavePanel) { _, newValue in
            if newValue, let document = pdfManager.pdfDocument {
                saveRotatedPDF(document: document)
            }
        }
    }

    private func openPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.title = "Select PDF"
        beginPanelSheet(panel) { response in
            if response == .OK, let url = panel.url { pdfManager.loadPDF(from: url) }
        }
    }

    /// Publishes Rotate's actions to the menu bridge while Rotate is the active tab.
    /// Loads files opened from Finder or the Dock when they're meant for this tab (#21).
    private func takePendingOpen() {
        guard let urls = appState.takePendingOpen(for: .rotate) else { return }
        if let url = urls.first { pdfManager.loadPDF(from: url) }
    }

    private func syncTabCommands() {
        guard appState.selectedTab == 3 else { return }
        let loaded = pdfManager.pdfDocument != nil
        var slice = TabSlice()
        slice.openTitle    = "Choose PDF\u{2026}"
        slice.open         = { openPDF() }
        slice.primaryTitle = "Save Rotated PDF"
        slice.primarySave  = loaded ? { isShowingSavePanel = true } : nil
        slice.clearTitle   = "Clear File"
        slice.clear        = loaded ? { pdfManager.clearPDF() } : nil
        // Always list the actions (disabled until a PDF is loaded) so the menu shows
        // what's possible rather than collapsing to nothing in the empty state.
        let revealTarget = pdfManager.sourceURL
        slice.tabActions = [
            MenuAction(title: "Rotate Left",  isEnabled: loaded, perform: { rotateCurrentPageLeft() }),
            MenuAction(title: "Rotate Right", isEnabled: loaded, perform: { rotateCurrentPageRight() }),
            MenuAction(title: "Show in Finder", key: KeyEquivalent("f"), modifiers: [.command, .shift],
                       isEnabled: revealTarget != nil, perform: { revealInFinder(revealTarget) }),
        ]
        appState.tabCommands.slice = slice
    }

    private func rotateCurrentPageLeft() {
        let current = pageRotationOverrides[currentPage, default: 0]
        pageRotationOverrides[currentPage] = ((current - 90) % 360 + 360) % 360
    }

    private func rotateCurrentPageRight() {
        let current = pageRotationOverrides[currentPage, default: 0]
        pageRotationOverrides[currentPage] = ((current + 90) % 360 + 360) % 360
    }

    private func saveRotatedPDF(document: PDFDocument) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = (pdfManager.currentFileName ?? "document") + "_rotated.pdf"
        savePanel.title = "Save Rotated PDF"
        savePanel.directoryURL = outputDirectory(forSourceFile: pdfManager.sourceURL)

        beginPanelSheet(savePanel) { response in
            if response == .OK, let url = savePanel.url {
                pdfManager.saveRotatedPDF(
                    to: url,
                    baseRotation: baseRotation,
                    additionalRotationMode: additionalRotationMode,
                    additionalRotationAngle: additionalRotationAngle,
                    pageRotationOverrides: pageRotationOverrides
                ) { title, message, isError in
                    showNSAlert(title: title, message: message, isError: isError)
                }
            }
            isShowingSavePanel = false
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
    let pageRotationOverrides: [Int: Int]
    let onRotateCurrentPageLeft:  () -> Void
    let onRotateCurrentPageRight: () -> Void

    var totalPages: Int { document.pageCount }

    var totalRotationForCurrentPage: Int {
        let pageNumber = currentPage + 1
        var rotation = baseRotation.degrees

        let shouldApplyAdditional: Bool
        switch additionalRotationMode {
        case .odd:  shouldApplyAdditional = pageNumber % 2 == 1
        case .even: shouldApplyAdditional = pageNumber % 2 == 0
        case .none: shouldApplyAdditional = false
        }
        if shouldApplyAdditional { rotation += additionalRotationAngle.degrees }

        rotation += pageRotationOverrides[currentPage, default: 0]

        return ((rotation % 360) + 360) % 360
    }

    var rotationDescription: String {
        if totalRotationForCurrentPage == 0 { return "No rotation" }
        let hasIndividual = pageRotationOverrides[currentPage, default: 0] != 0
        return hasIndividual
            ? "Rotated \(totalRotationForCurrentPage)° (this page)"
            : "Rotated \(totalRotationForCurrentPage)°"
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Page navigation
            HStack {
                Button(action: firstPage) {
                    Image(systemName: "chevron.backward.to.line").accessibilityLabel("First page")
                }
                .disabled(currentPage == 0)

                Button(action: previousPage) {
                    Image(systemName: "chevron.left").accessibilityLabel("Previous page")
                }
                .disabled(currentPage == 0)

                Spacer()

                // Rotate-left button · page info · rotate-right button
                HStack(spacing: 10) {
                    Button(action: onRotateCurrentPageLeft) {
                        Image(systemName: "rotate.left").accessibilityLabel("Rotate this page left")
                    }
                    .buttonStyle(.bordered)
                    .help("Rotate this page 90° counter-clockwise (,)")

                    // The middle is always as wide as its longest possible text, so the
                    // rotate buttons either side stay put as the caption changes from
                    // "No rotation" to the semibold "Rotated 270° (this page)" (#35).
                    VStack(spacing: 4) {
                        ZStack {
                            Text("Page \(totalPages) of \(totalPages)").hidden()
                            Text("Page \(currentPage + 1) of \(totalPages)")
                        }
                        .font(.headline)
                        .monospacedDigit()

                        ZStack {
                            Text("Rotated 270° (this page)").fontWeight(.semibold).hidden()
                            Text(rotationDescription)
                                .foregroundColor(totalRotationForCurrentPage > 0 ? .orange : .secondary)
                                .fontWeight(totalRotationForCurrentPage > 0 ? .semibold : .regular)
                        }
                        .font(.caption)
                    }
                    .lineLimit(1)
                    .fixedSize()

                    Button(action: onRotateCurrentPageRight) {
                        Image(systemName: "rotate.right").accessibilityLabel("Rotate this page right")
                    }
                    .buttonStyle(.bordered)
                    .help("Rotate this page 90° clockwise (.)")
                }

                Spacer()

                Button(action: nextPage) {
                    Image(systemName: "chevron.right").accessibilityLabel("Next page")
                }
                .disabled(currentPage >= totalPages - 1)

                Button(action: lastPage) {
                    Image(systemName: "chevron.forward.to.line").accessibilityLabel("Last page")
                }
                .disabled(currentPage >= totalPages - 1)
            }
            .padding(.horizontal)
            .padding(.top, 10)
            
            // Preview images
            HStack(spacing: 16) {
                // Before
                VStack {
                    Text("Before")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    PDFPageView(
                        page: document.page(at: currentPage),
                        rotation: 0,
                        accessibilityName: "Before"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                Image(systemName: "arrow.right")
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
                
                // After
                VStack {
                    Text(totalRotationForCurrentPage > 0 ? "After (Rotated)" : "After (No Change)")
                        .font(.caption)
                        .foregroundColor(totalRotationForCurrentPage > 0 ? .orange : .secondary)
                        .fontWeight(totalRotationForCurrentPage > 0 ? .semibold : .regular)
                    
                    PDFPageView(
                        page: document.page(at: currentPage),
                        rotation: totalRotationForCurrentPage,
                        accessibilityName: totalRotationForCurrentPage > 0 ? "After, rotated \(totalRotationForCurrentPage) degrees" : "After, not rotated"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            .padding([.horizontal, .bottom])
        }
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
