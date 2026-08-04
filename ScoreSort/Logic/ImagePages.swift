//
//  ImagePages.swift
//  ScoreSort
//
//  Turning image files into PDF pages. Scanners and phones produce parts as JPEGs, PNGs and
//  HEICs as often as PDFs, so the Combine and Stamp tabs both accept them and page them the
//  same way: fitted onto A4, centred, on white.
//
//  No view state; unit-tested directly.
//

import Foundation
import AppKit
import PDFKit
import ImageIO

/// Image formats ScoreSort can turn into pages.
let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "bmp", "gif"]

/// Everything that can become a page: PDFs plus the images above.
let pageableFileExtensions: Set<String> = supportedImageExtensions.union(["pdf"])

/// Renders one frame of an image as an A4 PDF page, scaled to fit on a white background.
func makeA4Page(from cgImage: CGImage) -> PDFPage? {
    let a4 = CGSize(width: 595, height: 842)
    let imgW = CGFloat(cgImage.width)
    let imgH = CGFloat(cgImage.height)
    guard imgW > 0, imgH > 0 else { return nil }

    let scale = min(a4.width / imgW, a4.height / imgH)
    let drawW = imgW * scale
    let drawH = imgH * scale
    let drawRect = CGRect(x: (a4.width - drawW) / 2,
                          y: (a4.height - drawH) / 2,
                          width: drawW, height: drawH)

    guard let ctx = CGContext(data: nil,
                              width: Int(a4.width), height: Int(a4.height),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(origin: .zero, size: a4))
    ctx.draw(cgImage, in: drawRect)

    guard let rendered = ctx.makeImage() else { return nil }
    let nsImage = NSImage(cgImage: rendered, size: a4)
    guard let page = PDFPage(image: nsImage) else { return nil }
    page.setBounds(CGRect(origin: .zero, size: a4), for: .mediaBox)
    return page
}

/// Every frame of an image file as A4 PDF pages — multi-page TIFFs and animated GIFs
/// therefore come through as several pages.
func pdfPages(fromImageAt url: URL) -> [PDFPage] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
    var pages: [PDFPage] = []
    for index in 0..<CGImageSourceGetCount(source) {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil),
              let page = makeA4Page(from: cgImage) else { continue }
        pages.append(page)
    }
    return pages
}

/// A document for `url`, whether it's a PDF or one of the supported images.
///
/// Pages from `PDFPage(image:)` carry a `pageRef`, so they draw through Core Graphics like
/// any other page — the stamp preview and the flattener both handle them as-is, with no
/// round trip through PDF data needed.
func pdfDocument(forFileAt url: URL) -> PDFDocument? {
    if url.pathExtension.lowercased() == "pdf" {
        return PDFDocument(url: url)
    }

    let pages = pdfPages(fromImageAt: url)
    guard !pages.isEmpty else { return nil }

    let document = PDFDocument()
    for (index, page) in pages.enumerated() { document.insert(page, at: index) }
    return document
}
