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
                // PDF loaded - show preview and controls
                VStack(spacing: 16) {
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
        .onAppear { isViewFocused = true }
        .onChange(of: pdfManager.pdfDocument) { _, newValue in
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

        savePanel.begin { response in
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
                    Image(systemName: "chevron.backward.to.line")
                }
                .disabled(currentPage == 0)

                Button(action: previousPage) {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPage == 0)

                Spacer()

                // Rotate-left button · page info · rotate-right button
                HStack(spacing: 10) {
                    Button(action: onRotateCurrentPageLeft) {
                        Image(systemName: "rotate.left")
                    }
                    .buttonStyle(.bordered)
                    .help("Rotate this page 90° counter-clockwise (,)")

                    VStack(spacing: 4) {
                        Text("Page \(currentPage + 1) of \(totalPages)")
                            .font(.headline)

                        Text(rotationDescription)
                            .font(.caption)
                            .foregroundColor(totalRotationForCurrentPage > 0 ? .orange : .secondary)
                            .fontWeight(totalRotationForCurrentPage > 0 ? .semibold : .regular)
                    }

                    Button(action: onRotateCurrentPageRight) {
                        Image(systemName: "rotate.right")
                    }
                    .buttonStyle(.bordered)
                    .help("Rotate this page 90° clockwise (.)")
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
    
    private func firstPage() { currentPage = 0 }
    private func lastPage()  { currentPage = totalPages - 1 }

    private func previousPage() {
        if currentPage > 0 { currentPage -= 1 }
    }

    private func nextPage() {
        if currentPage < totalPages - 1 { currentPage += 1 }
    }
}
