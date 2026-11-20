//
//  PaperSize.swift
//  ScoreSort
//
//  The paper ScoreSort assumes when there is no page to follow: A4 in most of the world,
//  US Letter in North America (where booklets print on Tabloid, 11 × 17 in).
//
//  Output made from PDFs keeps the source's page size — a booklet's sheet is two of its
//  pages side by side, a split half is half its sheet. The default is used only where
//  nothing says otherwise: images turned into pages, blank pages, a booklet fitted onto one
//  sheet of paper, the two-sided test sheet and the stamp designer's blank page.
//
//  The logic takes a `PaperSize` parameter that defaults to A4, so it stays pure and the
//  tests are the same on any Mac; the app and the command line pass `PaperSize.current`.
//

import Foundation
import AppKit

/// A standard paper size.
nonisolated enum PaperSize: String, CaseIterable, Identifiable, Sendable {
    case a4
    case letter

    var id: String { rawValue }

    /// Portrait, in PDF points (1/72 in).
    var pageSize: CGSize {
        switch self {
        case .a4:     return CGSize(width: 595, height: 842)    // 210 × 297 mm
        case .letter: return CGSize(width: 612, height: 792)    // 8.5 × 11 in
        }
    }

    /// The portrait page, at the origin.
    var pageBox: CGRect { CGRect(origin: .zero, size: pageSize) }

    /// The same paper turned landscape — what a half-size booklet prints on.
    var landscapeBox: CGRect { CGRect(x: 0, y: 0, width: pageSize.height, height: pageSize.width) }

    /// "A4", "Letter".
    var name: String {
        switch self {
        case .a4:     return "A4"
        case .letter: return "Letter"
        }
    }

    /// The sheet two of these pages fill side by side: A3, or Tabloid (11 × 17 in).
    var doubleSheetName: String {
        switch self {
        case .a4:     return "A3"
        case .letter: return "Tabloid"
        }
    }

    /// The page of a booklet folded from this paper: A5, or half-letter.
    var halfName: String {
        switch self {
        case .a4:     return "A5"
        case .letter: return "half-letter"
        }
    }

    /// Which standard paper `size` is, either way up, within a few points; nil for anything
    /// else. Printers report paper sizes rounded a little differently.
    static func matching(_ size: CGSize) -> PaperSize? {
        let short = min(size.width, size.height), long = max(size.width, size.height)
        return allCases.first {
            abs($0.pageSize.width - short) <= 4 && abs($0.pageSize.height - long) <= 4
        }
    }

    /// Regions where Letter is the everyday paper (ISO 3166 codes). Everywhere else uses A4.
    static let letterRegions: Set<String> = [
        "US", "CA", "MX", "PR", "PH", "CL", "CO", "VE", "CR", "GT", "PA", "SV", "DO", "NI", "BZ",
    ]

    /// The paper for a region code: Letter in North America (and a few others), else A4.
    static func forRegion(_ region: String?) -> PaperSize {
        guard let region else { return .a4 }
        return letterRegions.contains(region.uppercased()) ? .letter : .a4
    }

    /// What "Automatic" means: the default printer's paper if it's A4 or Letter, otherwise
    /// the region's. Pure, so it can be tested; `system` supplies the real values.
    static func automatic(printerPaper: CGSize?, region: String?) -> PaperSize {
        printerPaper.flatMap(matching) ?? forRegion(region)
    }
}

/// The Settings choice (Settings ▸ Combiner ▸ Paper size).
nonisolated enum PaperSizeChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case a4
    case letter

    var id: String { rawValue }

    /// The `UserDefaults` key (`@AppStorage` in the Combiner pane). The command line reads it
    /// too: same bundle, same defaults.
    static let defaultsKey = "paperSize"

    /// The paper this choice means; `automatic` is only worked out when it's needed.
    func resolved(automatic: @autoclosure () -> PaperSize) -> PaperSize {
        switch self {
        case .automatic: return automatic()
        case .a4:        return .a4
        case .letter:    return .letter
        }
    }
}

extension PaperSize {
    /// The system's paper, worked out once per launch: asking the print system can be slow.
    @MainActor private static var cachedSystem: PaperSize?

    /// The default printer's paper (macOS's "Default paper size" when it has no preference
    /// of its own), or the region's.
    @MainActor static var system: PaperSize {
        if let cachedSystem { return cachedSystem }
        let found = automatic(printerPaper: NSPrintInfo.shared.paperSize,
                              region: Locale.current.region?.identifier)
        cachedSystem = found
        return found
    }

    /// The paper to use where there's no page to follow: the Settings choice, with Automatic
    /// resolved from the system.
    @MainActor static var current: PaperSize {
        let stored = UserDefaults.standard.string(forKey: PaperSizeChoice.defaultsKey)
        let choice = stored.flatMap(PaperSizeChoice.init(rawValue:)) ?? .automatic
        return choice.resolved(automatic: system)
    }
}
