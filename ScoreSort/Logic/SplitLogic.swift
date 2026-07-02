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

/// Reads the top-level PDF outline and returns fileSizes (page counts per section)
/// and the corresponding bookmark labels, both ordered by page position.
/// Returns nil if the document has fewer than two usable top-level bookmarks.
func splitSizesFromBookmarks(_ document: PDFDocument) -> (sizes: [Int], labels: [String])? {
    let totalPages = document.pageCount
    guard totalPages > 0,
          let root = document.outlineRoot,
          root.numberOfChildren > 0 else { return nil }

    var entries: [(pageIndex: Int, label: String)] = []
    for i in 0..<root.numberOfChildren {
        guard let item = root.child(at: i),
              let page = item.destination?.page else { continue }
        let idx = document.index(for: page)
        guard idx < totalPages else { continue }
        entries.append((pageIndex: idx, label: item.label ?? ""))
    }
    entries.sort { $0.pageIndex < $1.pageIndex }

    let markers = entries.compactMap { $0.pageIndex > 0 ? $0.pageIndex : nil }
    guard !markers.isEmpty else { return nil }

    var sizes: [Int] = []
    var prev = 0
    for marker in markers {
        sizes.append(marker - prev)
        prev = marker
    }
    sizes.append(totalPages - prev)
    return (sizes: sizes, labels: entries.map { $0.label })
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
func splitA3Pages(_ doc: PDFDocument, leftFirst: Bool) -> PDFDocument {
    let result = PDFDocument()
    for i in 0..<doc.pageCount {
        guard let page = doc.page(at: i) else { continue }
        let media = page.bounds(for: .mediaBox)
        let rot = ((page.rotation % 360) + 360) % 360

        // When a page carries a rotation flag, the mediaBox is in *native* coordinates
        // (the unrotated space). We must split along the native axis that corresponds
        // to the visual horizontal divide.
        //
        //   0°  → landscape stored as landscape: split on native X axis
        //  90°  → portrait native, rotated 90° CCW to look landscape:
        //          visual left = native TOP half  (high Y)
        // 180°  → landscape stored upside-down:  visual left = native RIGHT half
        // 270°  → portrait native, rotated 270° CW to look landscape:
        //          visual left = native BOTTOM half (low Y)

        let nativeFirstBox: CGRect
        let nativeSecondBox: CGRect

        switch rot {
        case 90:
            // PDF rotation is clockwise. 90° CW: native top → visual right,
            // so visual left = native BOTTOM half (low y).
            let halfH = media.height / 2.0
            let nativeTop    = CGRect(x: media.minX, y: media.minY + halfH, width: media.width, height: halfH)
            let nativeBottom = CGRect(x: media.minX, y: media.minY,         width: media.width, height: halfH)
            nativeFirstBox  = leftFirst ? nativeBottom : nativeTop
            nativeSecondBox = leftFirst ? nativeTop    : nativeBottom
        case 270:
            // 270° CW (= 90° CCW): native top → visual left,
            // so visual left = native TOP half (high y).
            let halfH = media.height / 2.0
            let nativeTop    = CGRect(x: media.minX, y: media.minY + halfH, width: media.width, height: halfH)
            let nativeBottom = CGRect(x: media.minX, y: media.minY,         width: media.width, height: halfH)
            nativeFirstBox  = leftFirst ? nativeTop    : nativeBottom
            nativeSecondBox = leftFirst ? nativeBottom : nativeTop
        case 180:
            let halfW = media.width / 2.0
            let nativeLeft  = CGRect(x: media.minX,         y: media.minY, width: halfW, height: media.height)
            let nativeRight = CGRect(x: media.minX + halfW, y: media.minY, width: halfW, height: media.height)
            // 180°: visual left → native right half
            nativeFirstBox  = leftFirst ? nativeRight : nativeLeft
            nativeSecondBox = leftFirst ? nativeLeft  : nativeRight
        default: // 0° — standard landscape
            let halfW = media.width / 2.0
            let nativeLeft  = CGRect(x: media.minX,         y: media.minY, width: halfW, height: media.height)
            let nativeRight = CGRect(x: media.minX + halfW, y: media.minY, width: halfW, height: media.height)
            nativeFirstBox  = leftFirst ? nativeLeft  : nativeRight
            nativeSecondBox = leftFirst ? nativeRight : nativeLeft
        }

        guard let firstPage  = page.copy() as? PDFPage,
              let secondPage = page.copy() as? PDFPage else { continue }
        firstPage.setBounds(nativeFirstBox,   for: .mediaBox)
        firstPage.setBounds(nativeFirstBox,   for: .cropBox)
        secondPage.setBounds(nativeSecondBox, for: .mediaBox)
        secondPage.setBounds(nativeSecondBox, for: .cropBox)
        result.insert(firstPage,  at: result.pageCount)
        result.insert(secondPage, at: result.pageCount)
    }
    return result
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
