//
//  ImagePageResolutionTests.swift
//  ScoreSortTests
//
//  #36: an image added to Combine or Stamp keeps its own resolution on the page (it used to
//  be redrawn at about 72 dpi), up to `maximumImagePageResolution`, and survives saving.
//

import Testing
import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers
@testable import ScoreSort

/// A greyscale image of `width` × `height` pixels with some detail, saved as PNG or JPEG.
private func writeImage(width: Int, height: Int, jpeg: Bool = false) throws -> URL {
    let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(gray: 0, alpha: 1)
    for x in stride(from: 0, to: width, by: 40) { ctx.fill(CGRect(x: x, y: 0, width: 3, height: height)) }
    let image = try #require(ctx.makeImage())
    let url = temporaryFolder("image-pages").appendingPathComponent(jpeg ? "scan.jpg" : "scan.png")
    let type = (jpeg ? UTType.jpeg : UTType.png).identifier as CFString
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil))
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

/// The pixel sizes (and filters) of the images a page draws.
private func embeddedImages(_ page: PDFPage) -> [(width: Int, height: Int, filter: String?)] {
    guard let dict = page.pageRef?.dictionary else { return [] }
    var resources: CGPDFDictionaryRef?
    var xobjects: CGPDFDictionaryRef?
    guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources,
          CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return [] }
    var found: [(Int, Int, String?)] = []
    CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let info = CGPDFStreamGetDictionary(stream) else { return true }
        var w: CGPDFInteger = 0, h: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(info, "Width", &w), CGPDFDictionaryGetInteger(info, "Height", &h) else { return true }
        var name: UnsafePointer<CChar>?
        let filter = CGPDFDictionaryGetName(info, "Filter", &name) ? name.map { String(cString: $0) } : nil
        found.append((Int(w), Int(h), filter))
        return true
    }, nil)
    return found.map { (width: $0.0, height: $0.1, filter: $0.2) }
}

@Suite("Image pages keep their resolution")
struct ImagePageResolutionTests {

    @Test("a scan keeps every pixel on its A4 page, instead of about 72 dpi")
    func keepsPixels() throws {
        let url = try writeImage(width: 2480, height: 3508)   // A4 at 300 dpi
        let page = try #require(pdfPages(fromImageAt: url).first)
        #expect(page.bounds(for: .mediaBox).size == PaperSize.a4.pageSize)
        let images = embeddedImages(page)
        #expect(images.count == 1)
        #expect(images.first?.width == 2480)
        #expect(images.first?.height == 3508)
    }

    @Test("a JPEG keeps its size, and the page stays a reasonable size on disk")
    func jpegStaysSmall() throws {
        let url = try writeImage(width: 2400, height: 3200, jpeg: true)
        let doc = try #require(pdfDocument(forFileAt: url))
        let images = embeddedImages(try #require(doc.page(at: 0)))
        #expect(images.first?.width == 2400)
        let jpegBytes = try #require((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int)
        let pdfBytes = try #require(doc.dataRepresentation()?.count)
        #expect(pdfBytes < jpegBytes * 3 + 50_000, "PDF \(pdfBytes) bytes for a \(jpegBytes)-byte JPEG")
    }

    @Test("a very large image is scaled to the cap, not kept whole")
    func capsHugeImages() throws {
        let url = try writeImage(width: 7000, height: 7000)   // far more than A4 can use
        let page = try #require(pdfPages(fromImageAt: url).first)
        let width = try #require(embeddedImages(page).first?.width)
        // 600 pixels per inch across A4's 595-point width: about 4960 pixels.
        let capped = Int(PaperSize.a4.pageSize.width / 72 * maximumImagePageResolution)
        #expect(abs(width - capped) <= 2, "\(width) vs \(capped)")
    }

    @Test("a small image is never enlarged")
    func neverEnlarges() throws {
        let url = try writeImage(width: 300, height: 400)
        let page = try #require(pdfPages(fromImageAt: url).first)
        #expect(embeddedImages(page).first?.width == 300)
    }

    @Test("the image survives combining, saving and reopening")
    func survivesSaving() throws {
        let url = try writeImage(width: 1654, height: 2339)   // A4 at 200 dpi
        let pages = pdfPages(fromImageAt: url)                 // its one-page document is gone after this
        let combined = PDFDocument()
        for page in pages { combined.insert(page, at: combined.pageCount) }
        let out = temporaryFolder("image-pages").appendingPathComponent("combined.pdf")
        #expect(savePDFDocument(combined, to: out) == nil)
        let reopened = try #require(PDFDocument(url: out))
        #expect(reopened.pageCount == 1)
        #expect(embeddedImages(try #require(reopened.page(at: 0))).first?.width == 1654)
    }

    @Test("on Letter paper the page is Letter and the pixels are kept")
    func letter() throws {
        let url = try writeImage(width: 2550, height: 3300)   // Letter at 300 dpi
        let page = try #require(pdfPages(fromImageAt: url, paper: .letter).first)
        #expect(page.bounds(for: .mediaBox).size == PaperSize.letter.pageSize)
        #expect(embeddedImages(page).first?.width == 2550)
    }
}
