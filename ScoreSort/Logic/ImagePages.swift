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
import ObjectiveC

/// Image formats ScoreSort can turn into pages.
let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "bmp", "gif"]

/// Everything that can become a page: PDFs plus the images above.
let pageableFileExtensions: Set<String> = supportedImageExtensions.union(["pdf"])

/// Renders one frame of an image as an A4 PDF page, scaled to fit on a white background.
func makeA4Page(from cgImage: CGImage) -> PDFPage? {
    makePage(from: cgImage, paper: .a4)
}

/// The most detail an image keeps on its page, in pixels per inch of printed page. Far
/// more than any printer uses; only very large photos are ever scaled down to it, so a
/// 48-megapixel photo doesn't make a huge PDF.
let maximumImagePageResolution: CGFloat = 600

/// One frame of an image as a page of `paper` (portrait), fitted and centred on white.
/// An image has no page size of its own, so it takes the default paper.
///
/// The image is placed into a real PDF page at its own resolution (#36). It used to be
/// redrawn into a page-sized bitmap at one pixel per point, about 72 dpi, so scans and photos
/// printed blurry. Drawing the `CGImage` into a PDF context keeps its pixels, and a JPEG is
/// usually embedded as it is, so the file grows little.
func makePage(from cgImage: CGImage, paper: PaperSize) -> PDFPage? {
    let size = paper.pageSize
    let imgW = CGFloat(cgImage.width)
    let imgH = CGFloat(cgImage.height)
    guard imgW > 0, imgH > 0 else { return nil }

    let scale = min(size.width / imgW, size.height / imgH)
    let drawRect = CGRect(x: (size.width - imgW * scale) / 2,
                          y: (size.height - imgH * scale) / 2,
                          width: imgW * scale, height: imgH * scale)

    let data = NSMutableData()
    var mediaBox = CGRect(origin: .zero, size: size)
    guard let consumer = CGDataConsumer(data: data as CFMutableData),
          let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
    ctx.beginPDFPage(nil)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(mediaBox)
    ctx.interpolationQuality = .high
    ctx.draw(cgImage, in: drawRect)
    ctx.endPDFPage()
    ctx.closePDF()

    guard let document = PDFDocument(data: data as Data), let page = document.page(at: 0) else { return nil }
    // A PDFPage doesn't keep its document alive, and this one-page document would otherwise
    // be gone before the page is inserted anywhere. The page holds on to it.
    objc_setAssociatedObject(page, &imagePageDocumentKey, document, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    return page
}

private nonisolated(unsafe) var imagePageDocumentKey: UInt8 = 0

/// Every frame of an image file as PDF pages of `paper` — multi-page TIFFs and animated GIFs
/// therefore come through as several pages. The app and the command line pass
/// `PaperSize.current`. A frame with more detail than the page can use
/// (`maximumImagePageResolution`) is scaled down first; anything else keeps every pixel.
func pdfPages(fromImageAt url: URL, paper: PaperSize = .a4) -> [PDFPage] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
    var pages: [PDFPage] = []
    for index in 0..<CGImageSourceGetCount(source) {
        guard let full = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
        let image = imageCapped(full, source: source, index: index, paper: paper)
        guard let page = makePage(from: image, paper: paper) else { continue }
        pages.append(page)
    }
    return pages
}

/// `image`, or a scaled-down copy if it has more than `maximumImagePageResolution` pixels per
/// inch once fitted onto `paper`.
private func imageCapped(_ image: CGImage, source: CGImageSource, index: Int, paper: PaperSize) -> CGImage {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    let fit = min(paper.pageSize.width / w, paper.pageSize.height / h)   // points per pixel
    let pixelsPerInch = 72 / fit
    guard pixelsPerInch > maximumImagePageResolution else { return image }
    let longest = max(w, h) * maximumImagePageResolution / pixelsPerInch
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: Int(longest.rounded()),
        kCGImageSourceCreateThumbnailWithTransform: false,   // as the full image: EXIF orientation not applied
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) ?? image
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
