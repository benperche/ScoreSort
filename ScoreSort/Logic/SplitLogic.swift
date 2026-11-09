//
//  SplitLogic.swift
//  ScoreSort
//
//  Pure functions behind the Split PDF tab — split-point maths, A3 detection/
//  splitting, bookmark parsing, and saddle-stitch booklet deimposition.
//  No view state; unit-tested directly.
//

import Foundation
import PDFKit

// MARK: - Split maths, A3 & bookmarks

/// Returns a new sizes array with a split toggled at `page` (0-based).
/// If `page` is the start of an existing file, that file merges with the one before it.
/// If `page` is mid-file, the file containing it is split at that position.
func toggleSplit(in sizes: [Int], at page: Int) -> [Int] {
    guard page > 0, !sizes.isEmpty else { return sizes }
    var result = sizes
    var pos = 0
    for (i, size) in result.enumerated() {
        if page >= pos && page < pos + size {
            let localPos = page - pos
            if localPos == 0 {
                if i > 0 {
                    result[i - 1] += result[i]
                    result.remove(at: i)
                }
            } else {
                let firstPart = localPos
                let secondPart = size - localPos
                result[i] = firstPart
                result.insert(secondPart, at: i + 1)
            }
            return result
        }
        pos += size
    }
    return result
}

/// Returns a sizes array that evenly divides `totalPages` into chunks of `stride`,
/// with the last chunk taking any remainder.
func splitSizes(totalPages: Int, stride: Int) -> [Int] {
    guard totalPages > 0, stride > 0 else { return [] }
    var sizes: [Int] = []
    var remaining = totalPages
    while remaining > 0 {
        let chunk = min(stride, remaining)
        sizes.append(chunk)
        remaining -= chunk
    }
    return sizes
}

/// One output file a document's bookmarks would produce: where it starts, how long
/// it is, and the bookmark's title. `title` is empty for pages ahead of the first
/// bookmark, which belong to no bookmark but still need a file.
struct BookmarkSection: Equatable {
    let startPage: Int
    let pageCount: Int
    let title: String
}

/// Reads the top-level PDF outline as the files it would split into, in page order.
/// Returns nil unless the bookmarks divide the document into at least two sections.
///
/// Real-world outlines are untidy, so: entries are sorted by page, two bookmarks on
/// the same page count once (the first title wins — a second would make a zero-page
/// file), and a first bookmark that isn't on page 1 leaves an untitled leading section.
func bookmarkSections(in document: PDFDocument) -> [BookmarkSection]? {
    let totalPages = document.pageCount
    guard totalPages > 0,
          let root = document.outlineRoot,
          root.numberOfChildren > 0 else { return nil }

    var entries: [(pageIndex: Int, label: String)] = []
    for i in 0..<root.numberOfChildren {
        guard let item = root.child(at: i),
              let page = item.destination?.page
                ?? (item.action as? PDFActionGoTo)?.destination.page else { continue }
        let idx = document.index(for: page)
        guard idx >= 0, idx < totalPages else { continue }
        entries.append((pageIndex: idx, label: item.label ?? ""))
    }
    // Stable, so of two bookmarks on one page the earlier outline entry is kept.
    let sorted = entries.enumerated()
        .sorted { ($0.element.pageIndex, $0.offset) < ($1.element.pageIndex, $1.offset) }
        .map { $0.element }

    var starts: [(page: Int, title: String)] = []
    for entry in sorted where starts.last?.page != entry.pageIndex {
        starts.append((page: entry.pageIndex, title: entry.label))
    }
    if let first = starts.first, first.page > 0 {
        starts.insert((page: 0, title: ""), at: 0)
    }
    guard starts.count >= 2 else { return nil }

    return starts.enumerated().map { i, start in
        let end = i + 1 < starts.count ? starts[i + 1].page : totalPages
        return BookmarkSection(startPage: start.page, pageCount: end - start.page, title: start.title)
    }
}

/// Reads the top-level PDF outline and returns fileSizes (page counts per section)
/// and the corresponding bookmark labels, index-aligned and ordered by page position.
/// Returns nil if the bookmarks don't divide the document into at least two sections.
func splitSizesFromBookmarks(_ document: PDFDocument) -> (sizes: [Int], labels: [String])? {
    guard let sections = bookmarkSections(in: document) else { return nil }
    return (sizes: sections.map { $0.pageCount }, labels: sections.map { $0.title })
}

/// Parses bookmark labels of the form "NN - Piecename - Partname" and extracts
/// a shared base name and per-file suffixes. Returns nil if any label doesn't
/// match the pattern or piece names are inconsistent across labels.
func extractSplitNames(from labels: [String]) -> (baseName: String, suffixes: [String])? {
    guard !labels.isEmpty else { return nil }
    var pieceName: String? = nil
    var suffixes: [String] = []
    for label in labels {
        let parts = label.components(separatedBy: " - ")
        guard parts.count >= 3,
              parts[0].allSatisfy({ $0.isNumber }) else { return nil }
        let piece = parts[1]
        let part = parts[2...].joined(separator: " - ")
        if let existing = pieceName {
            guard piece == existing else { return nil }
        } else {
            pieceName = piece
        }
        suffixes.append(part)
    }
    guard let baseName = pieceName, !baseName.isEmpty else { return nil }
    return (baseName: baseName, suffixes: suffixes)
}

/// How bookmark titles become file names when splitting at bookmarks.
enum BookmarkNameStyle: String, CaseIterable {
    /// "Piece - Title.pdf" — the title is the part, under a shared piece name.
    case pieceAndTitle
    /// "Title.pdf" — the title is already the whole name (a book of separate pieces).
    case titleOnly
}

/// `text` made safe to use in a file name: path characters replaced, line breaks and
/// repeated spaces collapsed, and a trailing ".pdf" dropped. Bookmark titles are free
/// text, and a "/" or ":" in one would otherwise block saving in Step 2.
func fileNameSafe(_ text: String) -> String {
    var s = text.replacingOccurrences(of: ": ", with: " - ")
    s = String(s.unicodeScalars.map { scalar -> Character in
        if "/:\\".unicodeScalars.contains(scalar) { return "-" }
        if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
        return Character(scalar)
    })
    s = s.split(whereSeparator: { $0 == " " }).joined(separator: " ")
    if s.lowercased().hasSuffix(".pdf") { s = String(s.dropLast(4)).trimmingCharacters(in: .whitespaces) }
    return s
}

/// A bookmark title as words. Titles that were made from file names often use "_"
/// for every space ("Bernstein_-_Prelude,_Fugue_and_Riffs_-_Score"), which hides
/// the " - " separators and reads badly in a file name.
func readableBookmarkTitle(_ title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.contains(" ") ? trimmed : trimmed.replacingOccurrences(of: "_", with: " ")
}

/// Turns bookmark titles into a base name and per-file suffixes, index-aligned with
/// `titles`. An empty title gives an empty suffix (Step 2 auto-numbers it).
///
/// `.titleOnly` uses each title whole, with no base name. `.pieceAndTitle` reads the
/// titles as " - "-separated segments: a leading score-order number on every title
/// is dropped (Step 3 adds it back), and the leading segments every title shares
/// ("Composer - Piece") become the base name, leaving what differs as the suffix.
/// With nothing shared, `fallbackBaseName` (the PDF's own name) is the base and the
/// title is the suffix. For ScoreSort's own "NN - Piece - Part" labels this agrees
/// with `extractSplitNames`.
func bookmarkSplitNames(titles: [String],
                        fallbackBaseName: String,
                        style: BookmarkNameStyle) -> (baseName: String, suffixes: [String]) {
    let titles = titles.map(readableBookmarkTitle)
    guard style == .pieceAndTitle else {
        return (baseName: "", suffixes: titles.map(fileNameSafe))
    }

    var parts: [[String]] = titles.map { $0.isEmpty ? [] : $0.components(separatedBy: " - ") }
    func titled() -> [[String]] { parts.filter { !$0.isEmpty } }

    let isNumbered = !titled().isEmpty && titled().allSatisfy {
        $0.count >= 2 && !$0[0].isEmpty && $0[0].allSatisfy { $0.isNumber }
    }
    if isNumbered { parts = parts.map { Array($0.dropFirst()) } }

    // How many leading segments every title shares, always leaving each a part name.
    let named = titled()
    var shared = 0
    if named.count >= 2, let shortest = named.map({ $0.count }).min() {
        while shared < shortest - 1, named.allSatisfy({ $0[shared] == named[0][shared] }) {
            shared += 1
        }
    } else if isNumbered, let only = named.first, only.count >= 2 {
        // One title alone isn't evidence of a shared piece name, unless the numbering
        // already marked it as ScoreSort's own pattern.
        shared = 1
    }

    var baseName = fallbackBaseName
    if shared > 0, let first = named.first {
        let piece = first.prefix(shared).joined(separator: " - ")
        if !piece.trimmingCharacters(in: .whitespaces).isEmpty {
            baseName = piece
            parts = parts.map { Array($0.dropFirst(shared)) }
        }
    }

    return (baseName: fileNameSafe(baseName),
            suffixes: parts.map { fileNameSafe($0.joined(separator: " - ")) })
}

/// The name a split file is saved under, extension included. An empty suffix
/// auto-numbers from the file's position; an empty base name leaves the suffix to
/// stand alone rather than starting the name with a separator.
func splitOutputFileName(base: String, separator: String, suffix: String, fileIndex: Int) -> String {
    let part = suffix.isEmpty ? "\(fileIndex + 1)" : suffix
    return base.isEmpty ? "\(part).pdf" : "\(base)\(separator)\(part).pdf"
}

/// Carries per-file names across a change of split points: a file keeps its name
/// when it still starts on the same page. Without this, adding or removing one split
/// slid every later name onto the wrong file.
func remapFileNames(_ names: [Int: String], from oldSizes: [Int], to newSizes: [Int]) -> [Int: String] {
    func startPages(_ sizes: [Int]) -> [Int] {
        var pos = 0
        return sizes.map { size in defer { pos += size }; return pos }
    }
    var nameAtStart: [Int: String] = [:]
    for (index, start) in startPages(oldSizes).enumerated() {
        if let name = names[index] { nameAtStart[start] = name }
    }
    var result: [Int: String] = [:]
    for (index, start) in startPages(newSizes).enumerated() {
        if let name = nameAtStart[start] { result[index] = name }
    }
    return result
}

/// Returns true if every checked page in `doc` looks like A3 landscape
/// (~1190 × 842 pt — twice the width of A4 portrait).
/// Checks up to the first three pages for consistency.
/// A4 landscape has the same √2 aspect ratio, so width > 1000 pt is used to
/// distinguish the two formats.
func isA3Landscape(_ doc: PDFDocument) -> Bool {
    guard doc.pageCount > 0 else { return false }
    let pagesToCheck = min(doc.pageCount, 3)
    for i in 0..<pagesToCheck {
        guard let page = doc.page(at: i) else { return false }
        let bounds = page.bounds(for: .mediaBox)
        var w = bounds.width, h = bounds.height
        // Many scanners store landscape pages as portrait + a 90°/270° rotation flag
        // rather than actually embedding landscape dimensions.  Swap w/h in that case
        // so we test the visually-correct orientation.
        if page.rotation % 180 != 0 { swap(&w, &h) }
        // A3 landscape in PDF points: ~1190 × 842.
        // Width > 1000 distinguishes A3 from A4 landscape (which is only ~842 pt wide).
        // Upper bound 1500 gives headroom for scanners that embed slightly larger sizes.
        guard w > h, w > 1000, w < 1500 else { return false }
    }
    return true
}

/// Broader check used for the hint banner: returns `true` when pages look landscape
/// and have an aspect ratio close to A3 (√2 ≈ 1.414), but don't meet the strict
/// width thresholds of `isA3Landscape` (e.g. different scanner DPI or page size).
/// The ratio window 1.3–1.6 covers A3 at various resolutions while excluding
/// standard-width landscape scores.
func looksLikeA3Landscape(_ doc: PDFDocument) -> Bool {
    guard doc.pageCount > 0 else { return false }
    let pagesToCheck = min(doc.pageCount, 3)
    for i in 0..<pagesToCheck {
        guard let page = doc.page(at: i) else { return false }
        let bounds = page.bounds(for: .mediaBox)
        var w = bounds.width, h = bounds.height
        if page.rotation % 180 != 0 { swap(&w, &h) }
        guard w > h else { return false }          // must be landscape
        let ratio = w / h
        guard ratio >= 1.3, ratio <= 1.6 else { return false }  // ~A3/A4 proportions
    }
    return true
}

/// Splits every page in `doc` into left and right halves, returning a new
/// PDFDocument with twice as many pages.  The crop/media box of each copy is
/// set to cover only its half so viewers render the correct region.
/// `leftFirst == true` → left half precedes right half (normal reading order).
///
/// The everything-down-the-middle case of `splitScans` (Logic/ScanSplitLogic.swift),
/// which handles page rotation and uneven cuts.
func splitA3Pages(_ doc: PDFDocument, leftFirst: Bool) -> PDFDocument {
    splitScans(doc,
               layouts: Array(repeating: .split(at: 0.5), count: doc.pageCount),
               leftFirst: leftFirst)
}

/// The page to show for a file in the naming steps: its first page that will actually be
/// saved, so a skipped first page (a scan's black background, a blank) doesn't stand in
/// for the part. Falls back to the file's first page when every page is skipped.
func firstKeptPage(fileStart: Int, fileSize: Int, skippedPages: Set<Int>) -> Int {
    (fileStart..<(fileStart + max(fileSize, 0))).first { !skippedPages.contains($0) } ?? fileStart
}

/// Whether a split is worth saving: it must produce something new — two or more files, a
/// file with pages left out, or pages ScoreSort has rebuilt (cut from double pages,
/// reordered, swapped), which makes even one whole file a different PDF.
func splitOutputIsWorthSaving(activeFiles: Int, skippedPages: Int, pagesRebuilt: Bool) -> Bool {
    activeFiles >= 1 && (activeFiles >= 2 || skippedPages > 0 || pagesRebuilt)
}

// MARK: - Writing split files

/// One file a split will write: its name (with `.pdf`) and the pages (0-based, in order)
/// that go into it.
struct SplitFilePlan: Equatable {
    let name: String
    let pages: [Int]
}

/// The files a page → file mapping produces (the Split tab's model), in file order:
/// skipped pages left out, files left with no pages dropped. `fileName` names file *i*.
func splitFilePlans(pageToFile: [Int: Int], pageCount: Int, skippedPages: Set<Int>,
                    fileName: (Int) -> String) -> [SplitFilePlan] {
    var pagesByFile: [Int: [Int]] = [:]
    for page in 0..<pageCount where !skippedPages.contains(page) {
        guard let file = pageToFile[page] else { continue }
        pagesByFile[file, default: []].append(page)
    }
    return pagesByFile.keys.sorted().map { SplitFilePlan(name: fileName($0), pages: pagesByFile[$0]!) }
}

/// What writing a split did: the files written, and the ones that failed with the reason.
struct SplitWriteReport {
    var written: [String] = []
    var failures: [(name: String, reason: String)] = []
}

/// Writes each planned file into `folder`, stamping each one's first page (or every page)
/// as `stampJob` says — each output file is one part. Existing files are replaced.
/// Shared by the Split tab and the command line, so both produce the same files.
func writeSplitFiles(_ plans: [SplitFilePlan], from document: PDFDocument, to folder: URL,
                     stampJob: StampJob?) -> SplitWriteReport {
    var report = SplitWriteReport()
    for plan in plans {
        let assembled = PDFDocument()
        for pageIndex in plan.pages {
            // A copy, so the source document is left as it was.
            guard let page = document.page(at: pageIndex)?.copy() as? PDFPage else { continue }
            assembled.insert(page, at: assembled.pageCount)
        }
        guard assembled.pageCount > 0 else {
            report.failures.append((plan.name, "None of its pages could be read."))
            continue
        }
        let doc = applyingStamp(stampJob, to: assembled, partFirstPages: [0])
        if let reason = savePDFDocument(doc, to: folder.appendingPathComponent(plan.name)) {
            report.failures.append((plan.name, reason))
        } else {
            report.written.append(plan.name)
        }
    }
    return report
}

// MARK: - Booklet deimposition

/// Saddle-stitch booklet deimposition: outer cover scanned first, front face of each
/// sheet before its back face.  Returns an `order` array where `order[readingPos]` is
/// the 0-based index *within the file segment* whose page should appear at that
/// reading position.
///
/// Verified:  N=4 → [1,2,3,0]   N=8 → [1,2,5,6,7,4,3,0]
func coverFirstFrontBackOrder(n: Int) -> [Int] {
    guard n >= 4, n % 4 == 0 else { return [] }
    var result = [Int](repeating: 0, count: n)
    for k in 1...(n / 4) {
        let scanBase = (k - 1) * 4
        // Each sheet occupies 4 scan positions: [front-left, front-right, back-left, back-right]
        // where front-left is the outer spine side.
        result[2 * k - 2]     = scanBase + 1   // reading front page 1 → right side of front scan
        result[2 * k - 1]     = scanBase + 2   // reading front page 2 → left side of back scan
        result[n - 2 * k]     = scanBase + 3   // reading back page 1  → right side of back scan
        result[n - 2 * k + 1] = scanBase + 0   // reading back page 2  → left side of front scan
    }
    return result
}

/// Alternative: inner sheets scanned before the outer cover (less common).
func innerFirstFrontBackOrder(n: Int) -> [Int] {
    guard n >= 8, n % 4 == 0 else { return [] }
    // Rotate the scan indices by n/2 (swap first half and second half of scans).
    return coverFirstFrontBackOrder(n: n).map { ($0 + n / 2) % n }
}

/// Returns candidate reorderings for an n-page booklet segment (n must be ≥ 4 and
/// a multiple of 4).  Each tuple carries a display label, a short description, and
/// the order array (`order[readingPos] = localScanIndex`).
func bookletCandidates(n: Int) -> [(label: String, description: String, order: [Int])] {
    guard n >= 4, n % 4 == 0 else { return [] }
    var result: [(String, String, [Int])] = []

    let standard = coverFirstFrontBackOrder(n: n)
    result.append((
        "Standard (cover first)",
        "Outer cover scanned first; each sheet: front face then back face.",
        standard
    ))

    if n >= 8 {
        let inner = innerFirstFrontBackOrder(n: n)
        result.append((
            "Inner-first",
            "Inner sheets scanned first, outer cover last.",
            inner
        ))
    }

    return result
}
