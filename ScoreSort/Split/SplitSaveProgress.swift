//
//  SplitSaveProgress.swift
//  ScoreSort
//
//  Saving a split in the background, with a progress sheet.
//
//  Writing the parts of a large scan — copying pages, flattening a stamp onto each part,
//  saving — takes seconds per file, and used to run on the main thread: the app beachballed
//  until the last file was written. Now `writeSplitFiles` runs on a background thread on
//  **its own copy** of the document (PDFKit mustn't be used from two threads at once, and the
//  Split tab is still showing the original), and this sheet shows each part as it's saved,
//  with a Cancel button that stops between files.
//

import SwiftUI
import Combine
@preconcurrency import PDFKit

/// Where a background save reads its pages from — never the document on screen.
nonisolated enum SplitSaveSource: Sendable {
    /// The original file, reopened: the document on screen is still exactly what was loaded.
    case file(URL)
    /// A snapshot of a document rebuilt in memory (Split Double Pages, Swap with Next, Fix
    /// Booklet Order), taken on the main actor.
    case data(Data)

    /// The source for `document`: reopening its file when it is the file as loaded (cheap,
    /// and done off the main thread), otherwise a snapshot of its pages (on this thread).
    @MainActor static func of(_ document: PDFDocument, loadedFrom sourceURL: URL?) -> SplitSaveSource? {
        if let sourceURL, let url = document.documentURL,
           url.standardizedFileURL == sourceURL.standardizedFileURL {
            return .file(sourceURL)
        }
        return document.dataRepresentation().map(SplitSaveSource.data)
    }

    /// Opens the copy. `nil` if it can't be read, or no longer matches what's on screen.
    func open(expectingPageCount pageCount: Int) -> PDFDocument? {
        let document: PDFDocument?
        switch self {
        case .file(let url): document = PDFDocument(url: url)
        case .data(let data): document = PDFDocument(data: data)
        }
        guard let document, !document.isLocked, document.pageCount == pageCount else { return nil }
        return document
    }
}

/// A split save in progress: what the sheet shows, and the way to stop it.
@MainActor
final class SplitSaveProgress: ObservableObject, Identifiable {
    let id = UUID()
    let total: Int
    /// Files finished (written or failed).
    @Published private(set) var done = 0
    /// The file being written now; nil while getting ready, and at the end.
    @Published private(set) var current: String?
    @Published private(set) var isCancelling = false

    private let cancelFlag = CancelFlag()

    init(total: Int) {
        self.total = total
    }

    /// Stops after the file being written now. Files already written stay.
    func cancel() {
        isCancelling = true
        cancelFlag.set()
    }

    /// Writes `plans` into `folder` on a background thread, reading pages from `source` and
    /// publishing progress here as it goes.
    func run(_ plans: [SplitFilePlan], from source: SplitSaveSource, expectingPageCount pageCount: Int,
             to folder: URL, stampJob: StampJob?) async -> SplitWriteReport {
        let flag = cancelFlag
        let owner = self   // held until the save ends, so its progress has somewhere to go
        let report = await Task.detached(priority: .userInitiated) { () -> SplitWriteReport in
            guard let document = source.open(expectingPageCount: pageCount) else {
                var report = SplitWriteReport()
                report.failures = [("The PDF", "ScoreSort couldn't read it again to save the parts. If the file was moved, changed or deleted since you opened it, open it again and redo the split.")]
                return report
            }
            return writeSplitFiles(plans, from: document, to: folder, stampJob: stampJob,
                                   progress: { done, _, next in
                                       Task { @MainActor in owner.update(done: done, current: next) }
                                   },
                                   isCancelled: { flag.isSet })
        }.value
        update(done: report.written.count + report.failures.count, current: nil)
        return report
    }

    private func update(done: Int, current: String?) {
        // Progress hops can arrive late; never let the bar move backwards.
        self.done = max(self.done, done)
        self.current = current
    }
}

/// The sheet shown while a split saves.
struct SplitSaveProgressView: View {
    @ObservedObject var progress: SplitSaveProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saving Split Files")
                .font(.headline)
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .progressViewStyle(.linear)
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button(progress.isCancelling ? "Stopping\u{2026}" : "Cancel") { progress.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(progress.isCancelling)
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }

    private var status: String {
        if progress.isCancelling { return "Stopping after the file being saved now\u{2026}" }
        guard let current = progress.current else {
            return progress.done == 0 ? "Getting ready\u{2026}" : "Finishing\u{2026}"
        }
        return "Saving \(min(progress.done + 1, progress.total)) of \(progress.total): \(current)"
    }
}
