//
//  PrintLogic.swift
//  ScoreSort
//
//  Printing a PDFDocument through the system print dialog.
//
//  An earlier attempt at this drew pages into a hand-rolled NSView subclass and was
//  abandoned; PDFKit's own print operation is the supported route and does the page
//  handling for us. Written as a free function so any tab holding a document can use it —
//  currently only the Combine tab does.
//

import AppKit
import PDFKit

/// `kPMDuplexingStr` with dots swapped for underscores, which is the form
/// `NSPrintInfo.printSettings` uses (dots don't play well with key-value coding).
private let duplexingSettingKey = "com_apple_print_PrintSettings_PMDuplexing"

/// Opens the system print dialog for `doc`.
///
/// The paper is turned to match the document's own pages — booklet sheets are landscape,
/// and without this they land on portrait paper and get squashed into a corner. Auto-rotate
/// stays off so PDFKit can't turn individual sheets and break the fold; the orientation is
/// decided here instead.
///
/// `twoSidedShortEdge` presets the duplex mode a folded booklet needs. It is a *request*:
/// drivers may ignore it, and the user can always change it in the dialog.
@MainActor
func printPDFDocument(_ doc: PDFDocument,
                      jobName: String,
                      twoSidedShortEdge: Bool,
                      in window: NSWindow?,
                      onError: PDFAlertHandler) {
    guard doc.pageCount > 0 else {
        onError("Nothing to Print", "There are no pages to print.", true)
        return
    }

    guard let info = printSettings(for: doc, basedOn: NSPrintInfo.shared,
                                   twoSidedShortEdge: twoSidedShortEdge) else {
        onError("Error", "Could not read the current print settings.", true)
        return
    }

    guard let operation = printOperation(for: doc, info: info) else {
        onError("Error", "Could not prepare the document for printing.", true)
        return
    }
    operation.jobTitle = jobName
    operation.showsPrintPanel = true
    operation.showsProgressPanel = true

    // The modal-for-window form; the bare runOperation() has known silent-failure problems.
    if let window {
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    } else {
        operation.run()
    }
}

/// The print settings `doc` should go out with, derived from `base` (normally
/// `NSPrintInfo.shared`, so the user's chosen printer and paper carry through).
/// Split out from `printPDFDocument` so the settings can be asserted in tests — the dialog
/// itself can't be driven headlessly.
func printSettings(for doc: PDFDocument,
                   basedOn base: NSPrintInfo,
                   twoSidedShortEdge: Bool) -> NSPrintInfo? {
    guard let info = base.copy() as? NSPrintInfo else { return nil }
    info.topMargin = 0
    info.bottomMargin = 0
    info.leftMargin = 0
    info.rightMargin = 0
    // Centred, which matters more for booklets than for anything else: the sheet has to sit
    // squarely on the paper or the fold line won't land in the middle of it. Centring only
    // translates the sheet, so it can't disturb the imposition.
    info.isHorizontallyCentered = true
    info.isVerticallyCentered = true

    // Turn the paper to match the sheets. Setting `orientation` swaps the paper size with it,
    // so an A4 queue becomes 842 × 595 — exactly an A5 booklet's sheet.
    let sheet = visualPageBox(for: doc.page(at: 0))
    info.orientation = sheet.width > sheet.height ? .landscape : .portrait

    // Booklets fold across the short edge of a landscape sheet, so tumble is the mode that
    // puts the back of each sheet the right way up.
    //
    // Set through the printSettings dictionary rather than PMSetDuplex: the Core Printing
    // setter isn't declared in the public SDK (PrintCore exposes only the opaque
    // PMPrintSettings typedef), whereas this key is the documented convention — NSPrintInfo.h
    // says other parts of the printing system use "com.apple.print.PrintSettings.*" keys with
    // the dots replaced by underscores, and PMPrintSettingsKeys.h spells this one
    // kPMDuplexingStr = "com.apple.print.PrintSettings.PMDuplexing".
    info.printSettings[duplexingSettingKey] =
        NSNumber(value: twoSidedShortEdge ? kPMDuplexTumble : kPMDuplexNone)

    return info
}

/// Down-scale only. An imposed sheet is exactly full-bleed A4/A3, but printers have an
/// unprintable hardware margin, so demanding 1:1 would clip the outer edges of the music.
/// Shrinking to fit is uniform, so the two halves stay symmetrical about the fold; scaling
/// *up* is what would wreck the layout, and this mode never does that.
/// (`.pageScaleDownToFit`, not `.downSampleToFit` — PDFKit keeps the kPDFPrintPageScale… spelling.)
func printOperation(for doc: PDFDocument, info: NSPrintInfo) -> NSPrintOperation? {
    doc.printOperation(for: info, scalingMode: .pageScaleDownToFit, autoRotate: false)
}
