//
//  OutlineLogic.swift
//  ScoreSort
//
//  Getting a table of contents into the saved file, not just into memory.
//

import PDFKit

/// A new document holding `doc`'s pages, to attach a `PDFOutline` to when the outline has to
/// survive being saved. Use the result in place of `doc`.
///
/// PDFKit on macOS 27.0 (26A428) saves a document it *opened* (`PDFDocument(data:)` or
/// `PDFDocument(url:)`) from its original structure unless the pages themselves changed, so
/// an outline assigned afterwards is visible in memory but never reaches the file: no
/// `/Outlines` is written and a reopened copy has `outlineRoot == nil`. Stamping and booklet
/// imposition both hand back such a document. A document created with `PDFDocument()` has
/// no original to fall back on, so saving always writes a fresh catalog, outline included.
/// (`.burnInAnnotationsOption` also forces a full rewrite, but it would flatten any links
/// and markup on the source pages.)
func outlineReadyDocument(from doc: PDFDocument) -> PDFDocument {
    let fresh = PDFDocument()
    for i in 0..<doc.pageCount {
        if let page = doc.page(at: i) { fresh.insert(page, at: fresh.pageCount) }
    }
    return fresh
}
