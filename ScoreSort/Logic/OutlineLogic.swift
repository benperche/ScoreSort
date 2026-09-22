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
/// `PDFDocument(url:)`) with the outline it was opened with, unless pages were inserted or
/// removed — so an outline assigned afterwards, or an edit to the existing one, is visible in
/// memory but never reaches the file: a reopened copy has `outlineRoot == nil`. Only the
/// outline is affected; page rotation, crop boxes, annotations and document attributes set
/// on the same document are saved normally. Stamping and booklet imposition both hand back
/// such a document. One created with `PDFDocument()` writes its outline as expected.
/// (`.burnInAnnotationsOption` also forces a full rewrite, but it would flatten any links
/// and markup on the source pages.)
func outlineReadyDocument(from doc: PDFDocument) -> PDFDocument {
    let fresh = PDFDocument()
    for i in 0..<doc.pageCount {
        if let page = doc.page(at: i) { fresh.insert(page, at: fresh.pageCount) }
    }
    return fresh
}
