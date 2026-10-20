import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum ImageOps {
    static let lossy: Set<String> = ["jpg", "heic", "webp", "avif"]

    static func utType(_ ext: String) -> UTType? {
        switch ext {
        case "jpg": return .jpeg
        case "png": return .png
        case "heic": return .heic
        case "avif": return UTType("public.avif")
        case "tiff": return .tiff
        case "bmp": return .bmp
        case "gif": return .gif
        case "ico": return .ico
        default: return nil
        }
    }

    // MARK: Loading and saving

    /// Loads an image at full size with its orientation applied (SVG via NSImage).
    static func load(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 {
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel ?? max(w, h, 1),
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return image }
        }
        if let ns = NSImage(contentsOf: url), ns.size.width > 0 {
            return try render(ns, scale: url.pathExtension.lowercased() == "svg" ? 2 : 1)
        }
        throw ToolError("Can't read \(url.lastPathComponent) as an image")
    }

    private static func render(_ image: NSImage, scale: CGFloat) throws -> CGImage {
        let w = Int(image.size.width * scale), h = Int(image.size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ToolError("Can't render image") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = ctx.makeImage() else { throw ToolError("Can't render image") }
        return cg
    }

    /// Source metadata (EXIF, GPS…) minus orientation, since pixels are already upright.
    static func metadata(_ url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        props.removeValue(forKey: kCGImagePropertyOrientation)
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        return props
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    }

    static func flatten(_ image: CGImage) -> CGImage {
        guard hasAlpha(image),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func resized(_ image: CGImage, scale: Double) -> CGImage {
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Encodes to the given format. WebP goes through cwebp; PDF through PDFKit.
    static func encode(_ image: CGImage, ext: String, quality: Double = 0.9, properties: [CFString: Any] = [:]) throws -> Data {
        switch ext {
        case "pdf":
            let ns = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            guard let page = PDFPage(image: ns), let data = { let d = PDFDocument(); d.insert(page, at: 0); return d.dataRepresentation() }()
            else { throw ToolError("Couldn't create PDF") }
            return data
        case "webp":
            let cwebp = try Shell.require("cwebp", brew: "webp")
            let dir = try Output.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let png = dir.appendingPathComponent("in.png"), out = dir.appendingPathComponent("out.webp")
            try encode(image, ext: "png").write(to: png)
            try Shell.run(cwebp, ["-quiet", "-metadata", "none", "-q", String(Int(quality * 100)), png.path, "-o", out.path])
            return try Data(contentsOf: out)
        default:
            guard let type = utType(ext) else { throw ToolError("Can't write \(ext.uppercased())") }
            var img = ["jpg", "bmp"].contains(ext) ? flatten(image) : image
            if ext == "ico" { img = squareIcon(img) }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
                throw ToolError("Can't write \(ext.uppercased())")
            }
            var opts = properties
            opts[kCGImageDestinationLossyCompressionQuality] = quality
            CGImageDestinationAddImage(dest, img, opts as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw ToolError("Couldn't encode \(ext.uppercased())") }
            return data as Data
        }
    }

    /// ICO needs a square image of at most 256px: fit the image onto a transparent square.
    private static func squareIcon(_ image: CGImage) -> CGImage {
        let side = min(256, max(image.width, image.height))
        let scale = Double(side) / Double(max(image.width, image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Writable extension closest to the input's, falling back to PNG.
    static func sameFormat(_ url: URL) -> String {
        let ext = normalizedExt(url.pathExtension)
        return utType(ext) != nil || ext == "webp" ? ext : "png"
    }

    private static func write(_ image: CGImage, like url: URL, suffix: String, keepMetadata: Bool = true) throws -> URL {
        let ext = sameFormat(url)
        let out = Output.url(for: url, ext: ext, suffix: suffix)
        try encode(image, ext: ext, quality: 0.92, properties: keepMetadata ? metadata(url) : [:]).write(to: out)
        return out
    }

    // MARK: Conversions

    static func convert(_ url: URL, to ext: String) throws -> URL {
        let out = Output.url(for: url, ext: ext)
        try encode(try load(url), ext: ext, quality: 0.9, properties: metadata(url)).write(to: out)
        return out
    }

    /// Compresses to at most `targetBytes`, lowering quality first and then resolution.
    static func compress(_ url: URL, targetBytes: Int) throws -> URL {
        guard targetBytes < fileSize(url) else {
            throw ToolError("\(url.lastPathComponent) is already under \(formatBytes(targetBytes))")
        }
        var ext = sameFormat(url)
        if !lossy.contains(ext) && ext != "png" { ext = "jpg" }
        let full = try load(url)
        let props = metadata(url)
        var scale = 1.0
        var best: Data?

        while best == nil && scale >= 0.1 {
            let image = scale < 1 ? resized(full, scale: scale) : full
            if ext == "png" {
                let data = try encode(image, ext: "png", properties: props)
                if data.count <= targetBytes { best = data }
            } else {
                var lo = 0.05, hi = 0.95
                for _ in 0..<7 {
                    let q = (lo + hi) / 2
                    let data = try encode(image, ext: ext, quality: q, properties: props)
                    if data.count <= targetBytes { best = data; lo = q } else { hi = q }
                }
            }
            scale *= 0.8
        }
        guard let best else { throw ToolError("Couldn't get \(url.lastPathComponent) under \(formatBytes(targetBytes))") }
        let out = Output.url(for: url, ext: ext, suffix: "compressed")
        try best.write(to: out)
        return out
    }

    static func resize(_ url: URL, scale: Double) throws -> URL {
        let image = try load(url)
        return try write(resized(image, scale: scale), like: url, suffix: "\(Int(scale * 100))%")
    }

    static func transform(_ url: URL, suffix: String, _ apply: (CIImage) -> CIImage) throws -> URL {
        let input = CIImage(cgImage: try load(url))
        let output = apply(input)
        guard let cg = CIContext().createCGImage(output, from: output.extent) else { throw ToolError("Couldn't process image") }
        return try write(cg, like: url, suffix: suffix)
    }

    static func rotate(_ url: URL) throws -> URL { try transform(url, suffix: "rotated") { $0.oriented(.right) } }
    static func flip(_ url: URL) throws -> URL { try transform(url, suffix: "flipped") { $0.oriented(.upMirrored) } }
    static func grayscale(_ url: URL) throws -> URL {
        try transform(url, suffix: "mono") { $0.applyingFilter("CIPhotoEffectMono") }
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        try write(try load(url), like: url, suffix: "clean", keepMetadata: false)
    }

    static func removeBackground(_ url: URL) throws -> URL {
        let handler = VNImageRequestHandler(cgImage: try load(url))
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first else { throw ToolError("No subject found in \(url.lastPathComponent)") }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { throw ToolError("Couldn't cut out subject") }
        let out = Output.url(for: url, ext: "png", suffix: "cutout")
        try encode(cg, ext: "png").write(to: out)
        return out
    }

    static func readQR(_ url: URL) throws -> String {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: try load(url)).perform([request])
        let texts = request.results?.compactMap(\.payloadStringValue) ?? []
        guard !texts.isEmpty else { throw ToolError("No QR code found") }
        return texts.joined(separator: "\n")
    }

    static func makePDF(_ urls: [URL]) throws -> URL {
        let doc = PDFDocument()
        for url in urls {
            let cg = try load(url)
            let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            if let page = PDFPage(image: ns) { doc.insert(page, at: doc.pageCount) }
        }
        let out = Output.url(for: urls[0], ext: "pdf", name: urls.count > 1 ? "Combined" : nil)
        guard doc.write(to: out) else { throw ToolError("Couldn't write PDF") }
        return out
    }

    static func info(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return "No metadata" }
        return describe(props, indent: "")
    }

    private static func describe(_ dict: [String: Any], indent: String) -> String {
        dict.keys.sorted().map { key in
            if let sub = dict[key] as? [String: Any] {
                return "\(indent)\(key):\n" + describe(sub, indent: indent + "    ")
            }
            return "\(indent)\(key): \(dict[key]!)"
        }.joined(separator: "\n")
    }
}
