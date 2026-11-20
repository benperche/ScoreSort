//
//  ImagePages.swift
//  ScoreSort
//
//  Turning image files into PDF pages. Scanners and phones produce parts as JPEGs, PNGs and
//  HEICs as often as PDFs, so the Combine and Stamp tabs both accept them and page them the
//  same way: fitted onto the default paper (A4 or Letter, `PaperSize`), centred, on white.
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
    makePage(from: cgImage, paper: .a4)
}

/// Renders one frame of an image as a page of `paper` (portrait), scaled to fit on a white
/// background. An image has no page size of its own, so it takes the default paper.
func makePage(from cgImage: CGImage, paper: PaperSize) -> PDFPage? {
    let size = paper.pageSize
    let imgW = CGFloat(cgImage.width)
    let imgH = CGFloat(cgImage.height)
    guard imgW > 0, imgH > 0 else { return nil }

    let scale = min(size.width / imgW, size.height / imgH)
    let drawW = imgW * scale
    let drawH = imgH * scale
    let drawRect = CGRect(x: (size.width - drawW) / 2,
                          y: (size.height - drawH) / 2,
                          width: drawW, height: drawH)

    guard let ctx = CGContext(data: nil,
                              width: Int(size.width), height: Int(size.height),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(origin: .zero, size: size))
    ctx.draw(cgImage, in: drawRect)

    guard let rendered = ctx.makeImage() else { return nil }
    let nsImage = NSImage(cgImage: rendered, size: size)
    guard let page = PDFPage(image: nsImage) else { return nil }
    page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
    return page
}

/// Every frame of an image file as PDF pages of `paper` — multi-page TIFFs and animated GIFs
/// therefore come through as several pages. The app and the command line pass
/// `PaperSize.current`.
func pdfPages(fromImageAt url: URL, paper: PaperSize = .a4) -> [PDFPage] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
    var pages: [PDFPage] = []
    for index in 0..<CGImageSourceGetCount(source) {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil),
              let page = makePage(from: cgImage, paper: paper) else { continue }
        pages.append(page)
    }
    return pages
}

/// A document for `url`, whether it's a PDF or one of the supported images.
///
/// Pages from `PDFPage(image:)` carry a `pageRef`, so they draw through Core Graphics like
/// any other page — the stamp preview and the flattener both handle them as-is, with no
/// round trip through PDF data needed.
///
/// `paper` is the page size an image is fitted onto; a PDF keeps its own.
func pdfDocument(forFileAt url: URL, paper: PaperSize = .a4) -> PDFDocument? {
    if url.pathExtension.lowercased() == "pdf" {
        return PDFDocument(url: url)
    }

    let pages = pdfPages(fromImageAt: url, paper: paper)
    guard !pages.isEmpty else { return nil }

    let document = PDFDocument()
    for (index, page) in pages.enumerated() { document.insert(page, at: index) }
    return document
}
