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
/// Scaling and auto-rotation are off: imposed booklet sheets are already positioned
/// exactly, and letting PDFKit re-fit or re-rotate them would undo the imposition. Margins
/// are zeroed and centring disabled for the same reason — otherwise a two-up sheet gets
/// shrunk into the printer's imageable area.
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

    guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else {
        onError("Error", "Could not read the current print settings.", true)
        return
    }
    info.topMargin = 0
    info.bottomMargin = 0
    info.leftMargin = 0
    info.rightMargin = 0
    info.isHorizontallyCentered = false
    info.isVerticallyCentered = false

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

    // .pageScaleNone, not .none — PDFKit's enum keeps the kPDFPrintPageScale… spelling.
    guard let operation = doc.printOperation(for: info, scalingMode: .pageScaleNone,
                                             autoRotate: false) else {
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
