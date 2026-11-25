//
//  PartRecognition.swift
//  ScoreSort
//
//  Reading part names off the page (#17), on the Mac itself with the Vision framework —
//  nothing leaves the computer.
//
//  Two halves:
//  - **Recognition** (`recognizePageText`): the top of a page rendered through Core Graphics
//    (`renderScan`, safe off the main thread), Vision's text recognition, and each line's text
//    with its box on the page.
//  - **Interpretation** (pure, tested with plain strings): which line is the part name
//    (`partNameLine`), where on the page it sits (`partNameFocus`, which the Split tab's naming
//    preview scrolls to), and where the parts of a multi-part PDF start (`suggestedParts`).
//
//  Graceful fallback over partial fill (CLAUDE.md): pages that can't be read confidently are
//  left for the person, never guessed.
//

import Foundation
import CoreGraphics
import Vision

// MARK: - Recognition

/// One line of text found on a page.
nonisolated struct RecognizedLine: Equatable, Sendable {
    let text: String
    /// Where it is on the page as the reader sees it, as fractions of the page: x from the
    /// left, y from the **top**.
    let box: CGRect
    let confidence: Float
}

/// The share of a page's height read for part names: they sit at the top of a part's first
/// page, above or beside the first system.
nonisolated let partNameReadFraction: CGFloat = 0.4

/// The text in the top `fraction` of a page, read with Vision. Rendered at `width` pixels
/// across. Safe to call for different pages on different threads at once.
nonisolated func recognizePageText(_ source: ScanRenderSource, fraction: CGFloat = partNameReadFraction,
                                   width: Int = 1600) -> [RecognizedLine] {
    guard let page = renderScan(source, width: width), page.height > 0 else { return [] }
    let keep = max(1, Int((CGFloat(page.height) * min(max(fraction, 0.05), 1)).rounded()))
    guard let top = page.cropping(to: CGRect(x: 0, y: 0, width: page.width, height: keep)) else { return [] }
    let lines = recognizeText(in: top)
    // Boxes come back as fractions of the crop; make them fractions of the whole page.
    let share = CGFloat(keep) / CGFloat(page.height)
    return lines.map { line in
        RecognizedLine(text: line.text,
                       box: CGRect(x: line.box.minX, y: line.box.minY * share,
                                   width: line.box.width, height: line.box.height * share),
                       confidence: line.confidence)
    }
}

/// Vision's text recognition on an image: each line, its box as fractions of the image
/// (y from the top), and how sure Vision is. Accurate rather than fast, and without language
/// correction, which "corrects" part names ("Euph" → "Eupho") badly.
nonisolated func recognizeText(in image: CGImage) -> [RecognizedLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
    return results.compactMap { observation in
        guard let best = observation.topCandidates(1).first else { return nil }
        let b = observation.boundingBox   // normalised, origin bottom-left
        return RecognizedLine(text: best.string,
                              box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height),
                              confidence: best.confidence)
    }
}

// MARK: - Which line is the part name

/// A line's text as score order reads it: lowercased, with flats and sharps spelled the way
/// part names are typed ("B♭" → "bb"), punctuation as spaces.
nonisolated func normalisedPartText(_ text: String) -> String {
    var s = text.lowercased()
        .replacingOccurrences(of: "♭", with: "b")
        .replacingOccurrences(of: "♯", with: "#")
    s = String(s.map { $0.isLetter || $0.isNumber || $0 == "#" || $0 == "'" ? $0 : " " })
    return s.split(separator: " ").joined(separator: " ")
}

/// The instrument a line of page text names, as (its position in `order`, the instrument),
/// matching **whole words** only — so "Hornpipe" isn't a horn, nor "Embassy" a bass. The
/// leftmost instrument wins, longest first at the same place, as for file names.
nonisolated func instrumentInPageText(_ text: String, order: [String]) -> (Int, String)? {
    let line = " " + normalisedPartText(text) + " "
    var best: (index: Int, instrument: String, position: Int)?
    for (index, instrument) in order.enumerated() {
        let phrase = " " + normalisedPartText(instrument) + " "
        guard phrase.count > 2, let range = line.range(of: phrase) else { continue }
        let position = line.distance(from: line.startIndex, to: range.lowerBound)
        if best == nil || position < best!.position
            || (position == best!.position && instrument.count > best!.instrument.count) {
            best = (index, instrument, position)
        }
    }
    return best.map { ($0.index, $0.instrument) }
}

/// The line on a page that is its part name: one that names an instrument from `order`, is
/// short (a part name, not a sentence), was read confidently, and isn't in `ignoring` (titles
/// and credits repeated on every part, from `repeatedLines`). Of those, the most prominent: the
/// highest up, then the larger type.
nonisolated func partNameLine(in lines: [RecognizedLine], order: [String],
                              ignoring repeated: Set<String> = []) -> RecognizedLine? {
    let candidates = lines.filter { line in
        let text = normalisedPartText(line.text)
        return line.confidence >= 0.3
            && !text.isEmpty && text.count <= 40
            && !repeated.contains(text)
            && instrumentInPageText(line.text, order: order) != nil
    }
    return candidates.min { a, b in
        // Within about a line's height of each other, the bigger type wins; otherwise higher up.
        if abs(a.box.minY - b.box.minY) < max(a.box.height, b.box.height) {
            return a.box.height > b.box.height
        }
        return a.box.minY < b.box.minY
    }
}

/// Where the Step 2 preview should look on a page: the part name's box, or failing that the
/// first clump of text from the top (the most top-left line), so a page whose top-left corner
/// is blank doesn't preview as white. Nil when the page has no text near the top.
nonisolated func partNameFocus(in lines: [RecognizedLine], order: [String]) -> CGRect? {
    if let name = partNameLine(in: lines, order: order) { return name.box }
    let usable = lines.filter { $0.confidence >= 0.3 && !normalisedPartText($0.text).isEmpty }
    return usable.min { ($0.box.minY + $0.box.minX * 0.25) < ($1.box.minY + $1.box.minX * 0.25) }?.box
}

/// Normalised lines that are titles, composers or publishers rather than part names, which
/// must never be taken for one ("Trumpet Voluntary" on the flute part). Two signs:
/// - it turns up in **separate runs** of pages, at least three pages in all — a title is on the
///   first page of each part, with the part's later pages in between; a part's own running
///   header ("Flute" on every page of a long flute part) is one unbroken run, so it stays;
/// - or it's on nearly every page (80%, with four or more pages).
nonisolated func repeatedLines(_ pages: [[RecognizedLine]]) -> Set<String> {
    guard pages.count >= 3 else { return [] }
    var onPages: [String: [Int]] = [:]
    for (i, lines) in pages.enumerated() {
        for text in Set(lines.map { normalisedPartText($0.text) }) where !text.isEmpty { onPages[text, default: []].append(i) }
    }
    var repeated: Set<String> = []
    for (text, indices) in onPages where indices.count >= 3 {
        let runs = 1 + zip(indices, indices.dropFirst()).filter { $1 != $0 + 1 }.count
        if runs >= 2 || (pages.count >= 4 && Double(indices.count) >= 0.8 * Double(pages.count)) {
            repeated.insert(text)
        }
    }
    return repeated
}

/// A part name as the person would type it: the recognised line tidied up — flats spelled
/// "b", stray punctuation and spacing gone, the first letter of each word capitalised (but
/// "Bb", "Eb", roman numerals and the rest kept as read).
nonisolated func tidiedPartName(_ text: String) -> String {
    let words = text.replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")
        .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "#" || $0 == "'" || $0 == "/" || $0 == "-" || $0 == ".") })
    return words.map { word in
        guard let first = word.first, first.isLowercase else { return String(word) }
        return first.uppercased() + word.dropFirst()
    }.joined(separator: " ")
}

// MARK: - Where the parts start

/// A part suggested for a multi-part PDF: the page it starts on (0-based) and its name.
nonisolated struct SuggestedPart: Equatable, Sendable {
    let startPage: Int
    let name: String
}

/// Parts from each page's recognised part name (nil where none was found): a part starts
/// where the name changes; pages without a name belong to the part before them. Names are
/// compared as typed ("Clarinet 1" and "Clarinet 2" are different parts; a running header
/// repeating the name on later pages isn't a new part). Empty when fewer than two pages have
/// a name, or when the first named page isn't near the start: then there's nothing reliable
/// to suggest.
nonisolated func suggestedParts(pageNames: [String?]) -> [SuggestedPart] {
    let named = pageNames.enumerated().compactMap { i, n in n.map { (i, $0) } }
    guard named.count >= 2, let first = named.first, first.0 <= 2 else { return [] }
    var parts: [SuggestedPart] = []
    for (page, name) in named {
        if let last = parts.last, normalisedPartText(last.name) == normalisedPartText(name) { continue }
        parts.append(SuggestedPart(startPage: parts.isEmpty ? 0 : page, name: name))
    }
    return parts
}

/// Each page's part name, read off the page, or nil — the recognised line tidied, with titles
/// repeated across the pages set aside. `pages` are the recognised lines of every page.
nonisolated func pagePartNames(_ pages: [[RecognizedLine]], order: [String]) -> [String?] {
    let repeated = repeatedLines(pages)
    return pages.map { lines in
        partNameLine(in: lines, order: order, ignoring: repeated).map { tidiedPartName($0.text) }
    }
}
