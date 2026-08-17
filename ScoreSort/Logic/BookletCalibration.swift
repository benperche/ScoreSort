//
//  BookletCalibration.swift
//  ScoreSort
//
//  The two-sided printing test sheet, and the per-printer memory of the answer.
//
//  Which way a printer turns the paper between sides can't be discovered in software — macOS
//  won't even let an app choose the setting. One folded sheet settles it, so the sheet is
//  generated here rather than taken from the user's own music: made-up pages can carry their
//  own instructions, and work before any files have been added.
//

import AppKit
import PDFKit

// MARK: - Per-printer memory

/// Remembers the duplex answer per printer, because it's a property of the machine rather than
/// of the document — someone who prints at home and at a school needs a different answer at each,
/// and shouldn't have to remember which.
///
/// Only ever consulted for the *default* printer: the real printer is chosen inside the print
/// dialog, by which point the document has already been imposed, so a mid-dialog change can't be
/// reacted to. Covers the ordinary case of the default printer differing between sites.
enum BookletDuplexDefaults {
    private static let key = "combineDuplexFlipByPrinter"

    /// Empty when no printer is configured at all, which is treated as its own "printer".
    static var currentPrinterName: String {
        NSPrintInfo.shared.printer.name
    }

    static func flip(forPrinter printer: String) -> BookletDuplexFlip {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        guard let raw = stored[printer], let flip = BookletDuplexFlip(rawValue: raw) else {
            return .longEdge
        }
        return flip
    }

    static func setFlip(_ flip: BookletDuplexFlip, forPrinter printer: String) {
        var stored = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        stored[printer] = flip.rawValue
        UserDefaults.standard.set(stored, forKey: key)
    }
}

// MARK: - Calibration sheet

/// The four reading pages of the test booklet, before imposition.
///
/// They are ordinary PDF pages carrying a large numeral and a line of instruction, so once the
/// sheet is folded the whole test is "can you read 1, 2, 3, 4 the right way up?" — no reasoning
/// about long edges or short edges required.
func bookletCalibrationPages() -> PDFDocument? {
    let pageBox = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4 portrait
    let bodies = [
        "Fold this sheet in half.\n\nThe four pages should read 1, 2, 3, 4 \u{2014} all the right way up.",
        "If pages 2 and 3 are upside down,\nchoose \u{201C}They\u{2019}re upside down\u{201D} back in ScoreSort\nand print another test sheet.",
        "If you can read this the right way up,\nyour printer is set correctly.",
        "ScoreSort \u{2014} two-sided printing test sheet"
    ]

    let output = NSMutableData()
    guard let consumer = CGDataConsumer(data: output as CFMutableData) else { return nil }
    var box = pageBox
    guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }

    for (index, body) in bodies.enumerated() {
        ctx.beginPage(mediaBox: &box)
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        draw("\(index + 1)",
             in: CGRect(x: 40, y: 430, width: 515, height: 300),
             font: .systemFont(ofSize: 240, weight: .bold))
        draw(body,
             in: CGRect(x: 60, y: 250, width: 475, height: 160),
             font: .systemFont(ofSize: 21, weight: .regular),
             colour: .darkGray)

        NSGraphicsContext.restoreGraphicsState()
        ctx.endPage()
    }
    ctx.closePDF()
    return PDFDocument(data: output as Data)
}

private func draw(_ text: String, in rect: CGRect, font: NSFont, colour: NSColor = .black) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineSpacing = 6
    NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: colour,
        .paragraphStyle: paragraph
    ]).draw(in: rect)
}

/// One physical sheet — the calibration pages imposed exactly the way a real booklet would be,
/// including the duplex compensation. Running the genuine imposition matters: a mocked-up sheet
/// would prove nothing about what the user's actual booklets will do.
func bookletCalibrationSheet(sheetSize: BookletSheetSize,
                             pageScale: Double = 1.0,
                             rotateBackFaces: Bool) -> PDFDocument? {
    guard let pages = bookletCalibrationPages() else { return nil }
    return imposedBookletDocument(pages,
                                  segments: [0..<pages.pageCount],
                                  sheetSize: sheetSize,
                                  pageScale: pageScale,
                                  rotateBackFaces: rotateBackFaces)?.doc
}
