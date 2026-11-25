//
//  PageTextCache.swift
//  ScoreSort
//
//  Reading part names off pages in the app (#17): each page is read once, in the
//  background, and remembered for as long as the page itself is around — so Step 2's
//  previews and Step 1's Suggest Splits share the work, and coming back to a page is free.
//  The recognition is `Logic/PartRecognition.swift`.
//

import Foundation
@preconcurrency import PDFKit

/// The text recognised at the top of each page, remembered per `PDFPage`.
///
/// An entry holds the page weakly and the boxes it was read with, so a page that has gone
/// (another PDF opened) or been cut differently (Split Double Pages) is read again rather than
/// answered from another page's text. Used on the main actor; the reading itself happens on
/// background threads.
@MainActor
final class PageTextCache {
    static let shared = PageTextCache()

    private struct Entry {
        weak var page: PDFPage?
        let cropBox: CGRect
        let rotation: Int
        let lines: [RecognizedLine]
    }
    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Pages read one at a time (the Step 2 previews), a few at once, so a long list of
    /// parts doesn't start dozens of readings together.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "ScoreSort page text"
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        q.qualityOfService = .userInitiated
        return q
    }()

    /// The page's lines if it has been read as it is now.
    func lines(for page: PDFPage) -> [RecognizedLine]? {
        guard let entry = entries[ObjectIdentifier(page)], entry.page === page,
              entry.cropBox == page.bounds(for: .cropBox), entry.rotation == page.rotation else { return nil }
        return entry.lines
    }

    func store(_ lines: [RecognizedLine], for page: PDFPage) {
        if entries.count > 2000 { entries = entries.filter { $0.value.page != nil } }
        entries[ObjectIdentifier(page)] = Entry(page: page, cropBox: page.bounds(for: .cropBox),
                                                rotation: page.rotation, lines: lines)
    }

    /// Reads one page (or answers from what's remembered). Nil when it can't be read: a page
    /// built in memory, or Vision unavailable on this Mac.
    func read(_ page: PDFPage) async -> [RecognizedLine]? {
        if let cached = lines(for: page) { return cached }
        guard let source = page.scanRenderSource else { return nil }
        let queue = self.queue
        let lines: [RecognizedLine]? = await withCheckedContinuation { continuation in
            queue.addOperation { continuation.resume(returning: recognizePageText(source)) }
        }
        if let lines { store(lines, for: page) }
        return lines
    }

    /// Reads many pages, several at once, calling `progress` on the main actor with the
    /// number finished as each one lands. Pages already read count straight away. Nil for a
    /// page that couldn't be read, or wasn't because `cancel` was set.
    func read(_ pages: [PDFPage], cancel: CancelFlag,
              progress: @escaping @MainActor (Int) -> Void) async -> [[RecognizedLine]?] {
        var results: [[RecognizedLine]?] = pages.map { lines(for: $0) }
        let toRead = pages.indices.filter { results[$0] == nil }
        let sources = toRead.map { pages[$0].scanRenderSource }
        let already = pages.count - toRead.count
        progress(already)
        guard !toRead.isEmpty else { return results }

        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var value = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        }
        let counter = Counter()
        let read: [[RecognizedLine]?] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let pages = recognizePages(sources, isCancelled: { cancel.isSet }, progress: { _ in
                    let n = counter.next()
                    DispatchQueue.main.async { MainActor.assumeIsolated { progress(already + n) } }
                })
                continuation.resume(returning: pages)
            }
        }
        for (k, index) in toRead.enumerated() {
            results[index] = read[k]
            if let lines = read[k] { store(lines, for: pages[index]) }
        }
        return results
    }
}
