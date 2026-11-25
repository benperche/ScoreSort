//
//  PartRecognition.swift
//  ScoreSort
//
//  Reading part names off the page (#17), on the Mac itself with the Vision framework —
//  nothing leaves the computer.
//
//  Two halves:
//  - **Recognition** (`recognizePageText`, `recognizePages`): the top of a page rendered
//    through Core Graphics (`renderScan`, safe off the main thread), Vision's text
//    recognition, and each line's text with its box on the page. Many pages are read in
//    parallel.
//  - **Interpretation** (pure, tested with plain lines): which line is the part name
//    (`partNameLine`) and what to call it (`recognisedPartName`), whether a page is a score
//    (`looksLikeScorePage`), where on the page the name sits (`partNameFocus`, which the Split
//    tab's naming preview starts at), and where the parts of a multi-part PDF start
//    (`readParts`).
//
//  Tuned on hand-copied rental parts (Stravinsky's *Ebony Concerto*), where Vision finds the
//  text reliably but misreads it often ("Eb Alte Sexabhene", "Jrombore", "Horx"): names are
//  matched to the instrument order with a forgiving whole-word match, and named from the
//  instrument matched, not from the text read.
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

/// How carefully Vision reads. `.fast` finds *where* text is as well as `.accurate` does but
/// misreads more: it's for the Step 2 preview's starting point (`partNameFocus`). Names come
/// from `.accurate`.
nonisolated enum PartReadMode: String, Sendable, Hashable {
    case fast
    case accurate
}

/// The share of a page's height read for part names: they sit at the top of a part's first
/// page, above or beside the first system. (A score's instrument labels further down this
/// area tell a score page from a part.)
nonisolated let partNameReadFraction: CGFloat = 0.4

/// The text in the top `fraction` of a page, read with Vision. Rendered at `width` pixels
/// across. Nil when the page couldn't be rendered or Vision failed (it can't run on some
/// Macs, GitHub's virtual runners among them); a page with no text is an empty array.
/// Safe to call for different pages on different threads at once.
nonisolated func recognizePageText(_ source: ScanRenderSource, mode: PartReadMode = .accurate,
                                   fraction: CGFloat = partNameReadFraction,
                                   width: Int = 1600) -> [RecognizedLine]? {
    guard let page = renderScan(source, width: width), page.height > 0 else { return nil }
    let keep = max(1, Int((CGFloat(page.height) * min(max(fraction, 0.05), 1)).rounded()))
    guard let top = page.cropping(to: CGRect(x: 0, y: 0, width: page.width, height: keep)),
          let lines = recognizeText(in: top, mode: mode) else { return nil }
    // Boxes come back as fractions of the crop; make them fractions of the whole page.
    let share = CGFloat(keep) / CGFloat(page.height)
    return lines.map { line in
        RecognizedLine(text: line.text,
                       box: CGRect(x: line.box.minX, y: line.box.minY * share,
                                   width: line.box.width, height: line.box.height * share),
                       confidence: line.confidence)
    }
}

/// `recognizePageText` for many pages at once, several in parallel (as `renderScans` does:
/// a 40-page scan reads in about 4 s rather than 35). Nil for a page with no source (built in
/// memory), one that couldn't be read, or one skipped because `isCancelled` turned true.
/// `progress` is called once per page as it finishes, from any thread.
nonisolated func recognizePages(_ sources: [ScanRenderSource?], mode: PartReadMode = .accurate,
                                isCancelled: @escaping @Sendable () -> Bool = { false },
                                progress: (@Sendable (Int) -> Void)? = nil) -> [[RecognizedLine]?] {
    final class Box: @unchecked Sendable {
        var pages: [[RecognizedLine]?]
        let lock = NSLock()
        init(count: Int) { pages = Array(repeating: nil, count: count) }
    }
    let box = Box(count: sources.count)
    DispatchQueue.concurrentPerform(iterations: sources.count) { i in
        guard let source = sources[i], !isCancelled() else { return }
        let lines = recognizePageText(source, mode: mode)
        box.lock.lock()
        box.pages[i] = lines
        box.lock.unlock()
        progress?(i)
    }
    return box.pages
}

/// Vision's text recognition on an image: each line, its box as fractions of the image
/// (y from the top), and how sure Vision is. Without language correction, which "corrects"
/// part names ("Euph" → "Eupho") badly. Nil if Vision failed.
nonisolated func recognizeText(in image: CGImage, mode: PartReadMode = .accurate) -> [RecognizedLine]? {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = mode == .fast ? .fast : .accurate
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([request])) != nil else { return nil }
    return (request.results ?? []).compactMap { observation in
        guard let best = observation.topCandidates(1).first else { return nil }
        let b = observation.boundingBox   // normalised, origin bottom-left
        return RecognizedLine(text: best.string,
                              box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height),
                              confidence: best.confidence)
    }
}

// MARK: - Matching instruments

/// A line's text as score order reads it: lowercased, with flats and sharps spelled the way
/// part names are typed ("B♭" → "bb"), punctuation as spaces.
nonisolated func normalisedPartText(_ text: String) -> String {
    var s = text.lowercased()
        .replacingOccurrences(of: "♭", with: "b")
        .replacingOccurrences(of: "♯", with: "#")
    s = String(s.map { $0.isLetter || $0.isNumber || $0 == "#" || $0 == "'" ? $0 : " " })
    return s.split(separator: " ").joined(separator: " ")
}

/// Letters a scanner's text reader mixes up in hand-copied parts — a copyist's T read as J
/// or I, o and e, a and o, m and n, p and b — which cost half an edit in `misreadDistance`.
private nonisolated let lookalikeLetters: Set<String> = {
    let pairs = ["jt", "it", "lt", "il", "l1", "i1", "eo", "ao", "ae", "ce", "co", "mn", "rn",
                 "bp", "uv", "o0", "s5", "hn", "uo", "ui", "rt", "cr"]
    return Set(pairs.flatMap { [$0, String($0.reversed())] })
}()

/// How far apart two spellings are: an edit distance in which mixing up lookalike letters
/// (`lookalikeLetters`) costs half.
nonisolated func misreadDistance(_ a: String, _ b: String) -> Double {
    let x = Array(a), y = Array(b)
    if x.isEmpty { return Double(y.count) }
    if y.isEmpty { return Double(x.count) }
    var previous = (0...y.count).map(Double.init)
    var current = previous
    for i in 1...x.count {
        current[0] = Double(i)
        for j in 1...y.count {
            let substitution: Double = x[i - 1] == y[j - 1] ? 0
                : lookalikeLetters.contains(String([x[i - 1], y[j - 1]])) ? 0.5 : 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + substitution)
        }
        swap(&previous, &current)
    }
    return previous[y.count]
}

/// Words that look like instruments to a forgiving match but are directions or sections —
/// "Brass" isn't a bass, nor "Harmon" a horn.
private nonisolated let notInstrumentWords: Set<String> = [
    "brass", "bars", "bar", "base", "basso", "harmon", "mute", "muted", "cont", "solo", "soli",
    "tutti", "tacet", "arco", "pizz", "tempo", "march", "mars", "saxes", "reeds",
    "winds", "strings", "rhythm",
]

/// The instrument order prepared for matching page text: each entry's words, its letter
/// count and its place in the order. Build one per reading, not per line.
nonisolated struct InstrumentMatcher: Sendable {
    struct Phrase: Sendable {
        let index: Int
        let instrument: String
        let words: [String]
        let letters: Int
    }
    let order: [String]
    let phrases: [Phrase]

    init(order: [String]) {
        self.order = order
        phrases = order.enumerated().compactMap { index, instrument in
            let words = normalisedPartText(instrument).split(separator: " ").map(String.init)
            let letters = words.reduce(0) { $0 + $1.count }
            // Jazz's "solo …" entries name the instrument after them ("Solo Bb" is a clarinet);
            // `recognisedPartName` puts the "Solo" back.
            guard letters >= 2, let first = words.first, first != "solo", first != "soli" else { return nil }
            return Phrase(index: index, instrument: instrument, words: words, letters: letters)
        }
    }

    /// A match: the entry, where in the line's words it starts and ends, and whether it was
    /// read exactly.
    struct Match: Equatable, Sendable {
        let index: Int
        let instrument: String
        let firstWord: Int
        let wordCount: Int
        let exact: Bool
    }

    /// The instrument a line of page text names, matching **whole words** — so "Hornpipe"
    /// isn't a horn, nor "Embassy" a bass. The leftmost instrument wins, the longest at the
    /// same place, as for file names. With `forgiving`, a line with no exact match may match
    /// a misreading: about one wrong letter in four (lookalikes half), only for names of four
    /// letters or more, never for `notInstrumentWords`.
    func match(_ text: String, forgiving: Bool = false) -> Match? {
        let words = normalisedPartText(text).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
        var best: Match?
        func consider(_ m: Match) {
            guard let b = best else { best = m; return }
            if m.firstWord < b.firstWord || (m.firstWord == b.firstWord && m.wordCount > b.wordCount)
                || (m.firstWord == b.firstWord && m.wordCount == b.wordCount
                    && m.instrument.count > b.instrument.count) {
                best = m
            }
        }
        for phrase in phrases where phrase.words.count <= words.count {
            for start in 0...(words.count - phrase.words.count)
            where Array(words[start..<(start + phrase.words.count)]) == phrase.words {
                consider(Match(index: phrase.index, instrument: phrase.instrument, firstWord: start,
                               wordCount: phrase.words.count, exact: true))
                break
            }
        }
        if best != nil || !forgiving { return best }

        for phrase in phrases where phrase.letters >= 4 && phrase.words.count <= words.count {
            let allowed = Double(phrase.letters) / 4
            let target = phrase.words.joined(separator: " ")
            for start in 0...(words.count - phrase.words.count) {
                let window = Array(words[start..<(start + phrase.words.count)])
                if window.contains(where: { notInstrumentWords.contains($0) || $0.allSatisfy(\.isNumber) }) { continue }
                let candidate = window.joined(separator: " ")
                guard abs(candidate.count - target.count) <= Int(allowed),
                      misreadDistance(candidate, target) <= allowed else { continue }
                consider(Match(index: phrase.index, instrument: phrase.instrument, firstWord: start,
                               wordCount: phrase.words.count, exact: false))
                break
            }
        }
        return best
    }
}

/// The instrument a line of page text names, as (its position in `order`, the instrument),
/// matching whole words exactly. See `InstrumentMatcher.match`.
nonisolated func instrumentInPageText(_ text: String, order: [String]) -> (Int, String)? {
    InstrumentMatcher(order: order).match(text).map { ($0.index, $0.instrument) }
}

// MARK: - Which line is the part name

/// Part names sit in the top fifth of the page: lower down, an instrument name is a cue
/// ("Bass Clar.") or a doubling instruction.
nonisolated let partNameTopFraction: CGFloat = 0.2

/// Lines starting further right than this aren't part names: they're cues over the music,
/// or the composer.
nonisolated let partNameRightLimit: CGFloat = 0.66

/// The smallest part name, as a fraction of the page height (about 9 pt on A4). A score's
/// instrument labels are smaller.
nonisolated let partNameMinHeight: CGFloat = 0.011

/// True for a line in brackets — a cue ("(Bass Clar.)", "(DRUMS)"), never a part name.
nonisolated func isBracketedLine(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespaces)
    return t.hasPrefix("(") || t.hasPrefix("[") || (t.hasSuffix(")") && t.contains("("))
}

/// True for a page that is a score rather than a part: three or more different instruments
/// named in the area read (a score labels its staves down the left edge).
nonisolated func looksLikeScorePage(_ lines: [RecognizedLine], matcher: InstrumentMatcher) -> Bool {
    var instruments = Set<String>()
    for line in lines where line.confidence >= 0.3 {
        let words = normalisedPartText(line.text).split(separator: " ")
        guard !words.isEmpty, words.count <= 5, !isBracketedLine(line.text),
              let m = matcher.match(line.text, forgiving: line.confidence >= 0.5) else { continue }
        instruments.insert(instrumentIdentityKey(m.instrument))
        if instruments.count >= 3 { return true }
    }
    return false
}

/// The line on a page that is its part name, and the instrument it names: a line in the top
/// fifth, starting in the left two-thirds, at least `partNameMinHeight` tall, short (a name,
/// not a sentence), not in brackets, read with some confidence, not in `ignoring` (titles
/// repeated on every part, from `repeatedLines`), naming an instrument from `order` — exactly,
/// or as a likely misreading when read confidently. Of those, the most prominent: the highest
/// up, then the larger type. None on a score page.
nonisolated func partNameMatch(in lines: [RecognizedLine], matcher: InstrumentMatcher,
                               ignoring repeated: Set<String> = []) -> (line: RecognizedLine, match: InstrumentMatcher.Match)? {
    if looksLikeScorePage(lines, matcher: matcher) { return nil }
    let candidates: [(line: RecognizedLine, match: InstrumentMatcher.Match)] = lines.compactMap { line in
        let text = normalisedPartText(line.text)
        guard line.confidence >= 0.3, !text.isEmpty, text.count <= 40,
              text.split(separator: " ").count <= 6,
              line.box.minY < partNameTopFraction, line.box.minX < partNameRightLimit,
              line.box.height >= partNameMinHeight,
              !isBracketedLine(line.text), !repeated.contains(text),
              let m = matcher.match(line.text, forgiving: line.confidence >= 0.5) else { return nil }
        return (line, m)
    }
    return candidates.min { a, b in
        // Within about a line's height of each other, the bigger type wins; otherwise higher up.
        if abs(a.line.box.minY - b.line.box.minY) < max(a.line.box.height, b.line.box.height) {
            return a.line.box.height > b.line.box.height
        }
        return a.line.box.minY < b.line.box.minY
    }
}

/// `partNameMatch`'s line.
nonisolated func partNameLine(in lines: [RecognizedLine], order: [String],
                              ignoring repeated: Set<String> = []) -> RecognizedLine? {
    partNameMatch(in: lines, matcher: InstrumentMatcher(order: order), ignoring: repeated)?.line
}

/// Where the Step 2 preview should look on a page: the part name's box, or failing that the
/// first clump of text from the top (the most top-left line with two or more letters or
/// digits), so a page whose top-left corner is blank doesn't preview as white. Nil when the
/// page has no text near the top.
nonisolated func partNameFocus(in lines: [RecognizedLine], order: [String]) -> CGRect? {
    if let name = partNameLine(in: lines, order: order) { return name.box }
    let usable = lines.filter { line in
        line.confidence >= 0.3 && line.text.filter { $0.isLetter || $0.isNumber }.count >= 2
    }
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

// MARK: - What to call it

/// A part name as the person would type it, built from the instrument matched rather than the
/// text read ("Eb Alte Sexabhene I" → "Alto Saxophone 1"): the instrument's preferred name
/// (`preferredInstrumentDisplayName`; a bare "Alto", "Tenor" or "Bari" in the saxophone section
/// of `order` is the saxophone), "Solo" when the line says so, and the part number written
/// after it — 1–9, or a roman numeral up to V — or an ordinal before it ("2nd").
nonisolated func recognisedPartName(line: String, match: InstrumentMatcher.Match, order: [String]) -> String {
    let words = normalisedPartText(line).split(separator: " ").map(String.init)
    var name = preferredInstrumentDisplayName(match.instrument)
    let bare = match.instrument.lowercased()
    if ["alto", "tenor", "bari", "baritone"].contains(bare) {
        let neighbours = [match.index - 1, match.index + 1].filter { order.indices.contains($0) }.map { order[$0].lowercased() }
        if neighbours.contains(where: { $0.contains("sax") }) {
            name = preferredInstrumentDisplayName((bare == "baritone" ? "bari" : bare) + " sax")
        }
    }
    name = name.split(separator: " ").map { word in
        guard let first = word.first, first.isLowercase else { return String(word) }
        return first.uppercased() + word.dropFirst()
    }.joined(separator: " ")

    let romans = ["i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5]
    func number(_ word: String) -> Int? {
        if let n = Int(word), (1...9).contains(n) { return n }
        return romans[word]
    }
    var partNumber: Int?
    let after = match.firstWord + match.wordCount
    for word in words.dropFirst(after).prefix(3) {
        if let n = number(word) { partNumber = n; break }
    }
    if partNumber == nil, match.firstWord > 0 {
        let before = words[match.firstWord - 1]
        for suffix in ["st", "nd", "rd", "th"] where before.hasSuffix(suffix) {
            if let n = Int(before.dropLast(2)), (1...9).contains(n) { partNumber = n }
        }
    }
    if words.prefix(match.firstWord).contains("solo"), !name.lowercased().hasPrefix("solo") {
        name = "Solo " + name
    }
    if let partNumber, !name.contains(where: \.isNumber) { name += " \(partNumber)" }
    return name
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

// MARK: - Title pages

/// Tempo and expression words, which head movements inside a part and so mustn't be taken
/// for a title that marks a part's first page.
private nonisolated let tempoWords: [String] = [
    "allegro", "allegretto", "andante", "andantino", "moderato", "adagio", "largo", "lento",
    "presto", "vivo", "vivace", "tempo", "moto", "maestoso", "grave", "rubato", "ritardando",
    "rallentando", "accelerando", "swing", "ballad", "freely", "medium", "tacet", "fine", "coda",
]

/// True for a line that could be a title, composer or publisher — the lines that mark the
/// first page of each part: in the top quarter, read confidently, six letters or more and
/// mostly letters, six words at most, no brackets, no instrument, no tempo or metronome mark.
nonisolated func isTitleLikeLine(_ line: RecognizedLine, matcher: InstrumentMatcher) -> Bool {
    let text = normalisedPartText(line.text)
    let letters = text.filter(\.isLetter).count
    let visible = line.text.filter { !$0.isWhitespace }.count
    guard line.box.minY < 0.25, line.confidence >= 0.5, letters >= 6, visible > 0,
          Double(letters) >= 0.75 * Double(visible),
          text.split(separator: " ").count <= 6,
          !isBracketedLine(line.text), !line.text.contains("="),
          matcher.match(line.text, forgiving: true) == nil else { return false }
    let words = text.split(separator: " ").map(String.init)
    return !words.contains { word in
        word.count >= 4 && tempoWords.contains { misreadDistance(word, $0) <= Double($0.count) / 4 }
    }
}

/// The pages that start a part because they carry a title found on the PDF's first page
/// (fuzzily: "EBONY CONCERTO", "EBINY CONCERTA"), in separate runs of pages — not a header
/// printed on every page (80% or more, with four or more pages), nor a title on two pages in
/// a row (a score's cover and first page).
///
/// `.repeated` with those pages; `.onlyFirst` when the first page has a title no other page
/// repeats — one part, whatever instruments it names later (a sax part's "Bb Clarinet" where
/// the player doubles); `.none` otherwise.
nonisolated enum TitlePages: Equatable, Sendable {
    case repeated(Set<Int>)
    case onlyFirst
    case none
}

nonisolated func titlePages(_ pages: [[RecognizedLine]?], matcher: InstrumentMatcher) -> TitlePages {
    struct Cluster { var text: String; var pages: [Int] }
    var clusters: [Cluster] = []
    for (i, lines) in pages.enumerated() {
        guard let lines else { continue }
        for line in lines where isTitleLikeLine(line, matcher: matcher) {
            let text = normalisedPartText(line.text)
            if let k = clusters.firstIndex(where: { c in
                abs(c.text.count - text.count) <= max(c.text.count, text.count) / 4
                    && misreadDistance(c.text, text) <= Double(max(c.text.count, text.count)) * 0.25
            }) {
                if clusters[k].pages.last != i { clusters[k].pages.append(i) }
            } else {
                clusters.append(Cluster(text: text, pages: [i]))
            }
        }
    }
    let readable = pages.compactMap { $0 }.count
    let firstReadable = pages.firstIndex { $0 != nil }
    var starts = Set<Int>()
    var firstHasTitle = false
    for cluster in clusters {
        let runs = 1 + zip(cluster.pages, cluster.pages.dropFirst()).filter { $1 != $0 + 1 }.count
        let everywhere = readable >= 4 && Double(cluster.pages.count) >= 0.8 * Double(readable)
        if everywhere { continue }
        // Only a title on the first page counts: that page starts a part, so a line that
        // isn't on it ("HARMON" over a muted passage) is a direction, not the title.
        guard cluster.pages.first == firstReadable else { continue }
        firstHasTitle = true
        if runs >= 2 { starts.formUnion(cluster.pages) }
    }
    if !starts.isEmpty { return .repeated(starts) }
    return firstHasTitle ? .onlyFirst : .none
}

// MARK: - Where the parts start

/// A part suggested for a multi-part PDF: the page it starts on (0-based) and its name
/// ("" when its first page's name couldn't be read).
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

/// What reading a PDF's pages found: each page's part name and the parts they suggest.
nonisolated struct PartReading: Equatable, Sendable {
    /// Each page's part name ("Score" for a score page); nil where none was found or the page
    /// couldn't be read.
    let pageNames: [String?]
    /// Pages Vision could read (some text or none).
    let pagesRead: Int
    /// Where parts start and what they're called; empty when there's nothing reliable to
    /// suggest, with `problem` saying why. A single part means the PDF looks like one part.
    let parts: [SuggestedPart]
    /// Why nothing is suggested, for the person; nil when there are parts.
    let problem: String?
    /// How the parts were found: pages carrying the piece's title (`"titles"`), or where the
    /// part name changes (`"names"`).
    let method: String?
}

/// Reads a PDF's parts from each page's recognised lines (nil for a page that couldn't be
/// read). Fewer than half the pages read, or no text anywhere, suggests nothing.
///
/// Where the parts start:
/// - when a title (or composer) is repeated on pages in separate runs, **each of those pages
///   starts a part**, named from its own part name or left blank — so a misread name still
///   gets its split, and an instrument named inside a part (a doubling, a cue) doesn't;
/// - when only the first page has a title, it's one part;
/// - otherwise, where the part name changes (`suggestedParts(pageNames:)`).
nonisolated func readParts(_ pages: [[RecognizedLine]?], order: [String]) -> PartReading {
    let matcher = InstrumentMatcher(order: order)
    let readable = pages.compactMap { $0 }
    let repeated = repeatedLines(readable)
    let names: [String?] = pages.map { lines in
        guard let lines else { return nil }
        if looksLikeScorePage(lines, matcher: matcher) { return "Score" }
        return partNameMatch(in: lines, matcher: matcher, ignoring: repeated)
            .map { recognisedPartName(line: $0.line.text, match: $0.match, order: order) }
    }
    func nothing(_ problem: String) -> PartReading {
        PartReading(pageNames: names, pagesRead: readable.count, parts: [], problem: problem, method: nil)
    }
    guard !pages.isEmpty else { return nothing("There are no pages to read.") }
    guard readable.count * 2 >= pages.count, !readable.isEmpty else {
        return nothing(readable.isEmpty
            ? "ScoreSort couldn't read the pages on this Mac."
            : "Only \(readable.count) of \(pages.count) pages could be read — too few to suggest where the parts start.")
    }
    guard readable.contains(where: { !$0.isEmpty }) else {
        return nothing("No text was found at the tops of the pages.")
    }

    switch titlePages(pages, matcher: matcher) {
    case .repeated(let titled):
        let starts = (titled.union([0])).sorted()
        let parts = starts.map { SuggestedPart(startPage: $0, name: names[$0] ?? "") }
        return PartReading(pageNames: names, pagesRead: readable.count, parts: parts, problem: nil, method: "titles")
    case .onlyFirst:
        let name = names.prefix(3).compactMap { $0 }.first ?? ""
        return PartReading(pageNames: names, pagesRead: readable.count,
                           parts: [SuggestedPart(startPage: 0, name: name)], problem: nil, method: "titles")
    case .none:
        let parts = suggestedParts(pageNames: names)
        if parts.isEmpty {
            return nothing(names.contains { $0 != nil }
                ? "Too few part names were recognised to tell where the parts start."
                : "No part names were recognised at the tops of the pages.")
        }
        return PartReading(pageNames: names, pagesRead: readable.count, parts: parts, problem: nil, method: "names")
    }
}

/// Each page's part name, read off the page, or nil — with titles repeated across the pages
/// set aside. `pages` are the recognised lines of every page.
nonisolated func pagePartNames(_ pages: [[RecognizedLine]], order: [String]) -> [String?] {
    readParts(pages, order: order).pageNames
}
