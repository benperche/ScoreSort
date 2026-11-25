//
//  SuggestSplitsSheet.swift
//  ScoreSort
//
//  Step 1's Suggest Splits (#17): read the tops of the pages on this Mac, work out where the
//  parts start and what they're called, and offer that — never applied without the person
//  saying so. The reading is `Logic/PartRecognition.swift`, through `PageTextCache`.
//

import SwiftUI
import Combine
@preconcurrency import PDFKit

/// A Suggest Splits run: the pages being read, how far it's got, and what it found.
@MainActor
final class SplitSuggestion: ObservableObject, Identifiable {
    let id = UUID()
    let total: Int
    /// Pages read so far (cached ones count at once).
    @Published private(set) var read = 0
    /// What reading found; nil while reading.
    @Published private(set) var reading: PartReading?

    private let pages: [PDFPage]
    private let order: [String]
    private let cancelFlag = CancelFlag()

    init(document: PDFDocument, ensemble: EnsembleType) {
        pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        total = pages.count
        order = InstrumentOrders.getOrder(for: ensemble)
    }

    /// A finished run, as the sheet shows it (previews and tests).
    init(total: Int, reading: PartReading) {
        pages = []
        self.total = total
        order = []
        read = total
        self.reading = reading
    }

    /// Reads every page in the background, then works out the parts.
    func start() async {
        guard reading == nil else { return }
        let lines = await PageTextCache.shared.read(pages, cancel: cancelFlag) { [weak self] n in
            guard let self else { return }
            self.read = max(self.read, n)
        }
        guard !cancelFlag.isSet else { return }
        let order = self.order
        reading = await Task.detached(priority: .userInitiated) { readParts(lines, order: order) }.value
    }

    /// Stops reading; pages already read stay remembered.
    func cancel() { cancelFlag.set() }

    /// The suggestion worth applying: two or more parts.
    var parts: [SuggestedPart]? {
        guard let parts = reading?.parts, parts.count >= 2 else { return nil }
        return parts
    }
}

/// The sheet: progress and Cancel while reading, then the parts found with Apply and
/// Dismiss — or why there's nothing to suggest.
struct SuggestSplitsSheet: View {
    @ObservedObject var suggestion: SplitSuggestion
    let onApply: ([SuggestedPart]) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Suggest Splits")
                .font(.headline)
            if let reading = suggestion.reading {
                result(reading)
            } else {
                ProgressView(value: Double(suggestion.read), total: Double(max(suggestion.total, 1)))
                    .progressViewStyle(.linear)
                Text("Reading the tops of the pages\u{2026} \(suggestion.read) of \(suggestion.total)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("This happens on your Mac; nothing is sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") {
                        suggestion.cancel()
                        onClose()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled()
        .task { await suggestion.start() }
    }

    @ViewBuilder
    private func result(_ reading: PartReading) -> some View {
        if let parts = suggestion.parts {
            Text("ScoreSort found \(parts.count) parts. Names are read off the page and can be wrong: check them when you name the files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                        let end = i + 1 < parts.count ? parts[i + 1].startPage : suggestion.total
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(end - part.startPage == 1 ? "Page \(part.startPage + 1)" : "Pages \(part.startPage + 1)–\(end)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                            if part.name.isEmpty {
                                Text("Name not read").italic().foregroundStyle(.secondary)
                            } else {
                                Text(part.name)
                            }
                            Spacer()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
            Text("Applying replaces the current split points and names. ⌘Z undoes it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Dismiss") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(parts) }
                    .keyboardShortcut(.defaultAction)
            }
        } else {
            Text(message(reading))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("OK") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Why there's nothing to apply.
    private func message(_ reading: PartReading) -> String {
        if let problem = reading.problem { return problem + " Set the split points by hand." }
        if let only = reading.parts.first {
            return only.name.isEmpty
                ? "This looks like a single part, so there's nothing to split."
                : "This looks like a single part (\(only.name)), so there's nothing to split."
        }
        return "ScoreSort couldn't tell where the parts start. Set the split points by hand."
    }
}
