import AppKit
import PDFKit

// MARK: - PDF

enum PDFOps {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ToolError("Can't open \(url.lastPathComponent)") }
        if doc.isLocked { throw ToolError("\(url.lastPathComponent) is password protected") }
        return doc
    }

    static func write(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws -> URL {
        guard doc.write(to: url, withOptions: options) else { throw ToolError("Couldn't write \(url.lastPathComponent)") }
        return url
    }

    static func toImages(_ url: URL, ext: String) throws -> [URL] {
        let doc = try open(url)
        return try (0..<doc.pageCount).compactMap { i in
            guard let page = doc.page(at: i) else { return nil }
            var size = page.bounds(for: .mediaBox).size
            if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
            let thumb = page.thumbnail(of: NSSize(width: size.width * 2, height: size.height * 2), for: .mediaBox)
            guard let cg = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let out = Output.url(for: url, ext: ext, suffix: doc.pageCount > 1 ? "p\(i + 1)" : nil)
            try ImageOps.encode(ImageOps.flatten(cg), ext: ext).write(to: out)
            return out
        }
    }

    static func attributedText(_ doc: PDFDocument) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i)?.attributedString { text.append(page) }
            if i < doc.pageCount - 1 { text.append(NSAttributedString(string: "\n\u{0C}")) }
        }
        return text
    }

    static func toText(_ url: URL) throws -> URL {
        let out = Output.url(for: url, ext: "txt")
        try (try open(url).string ?? "").write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func toDocument(_ url: URL, ext: String) throws -> URL {
        let text = attributedText(try open(url))
        return try DocOps.save(text, like: url, ext: ext)
    }

    static func compress(_ url: URL) throws -> URL {
        let out = Output.url(for: url, ext: "pdf", suffix: "compressed")
        _ = try write(try open(url), to: out, options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
        if fileSize(out) >= fileSize(url) {
            try? FileManager.default.removeItem(at: out)
            throw ToolError("\(url.lastPathComponent) is already as small as it gets")
        }
        return out
    }

    static func merge(_ urls: [URL]) throws -> URL {
        let merged = PDFDocument()
        for url in urls {
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        return try write(merged, to: Output.url(for: urls[0], ext: "pdf", name: "Merged"))
    }

    static func split(_ url: URL) throws -> [URL] {
        let doc = try open(url)
        return try (0..<doc.pageCount).compactMap { i in
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { return nil }
            let single = PDFDocument()
            single.insert(page, at: 0)
            return try write(single, to: Output.url(for: url, ext: "pdf", suffix: "p\(i + 1)"))
        }
    }

    static func rotate(_ url: URL) throws -> URL {
        let doc = try open(url)
        for i in 0..<doc.pageCount { doc.page(at: i)?.rotation += 90 }
        return try write(doc, to: Output.url(for: url, ext: "pdf", suffix: "rotated"))
    }

    static func stripMetadata(_ url: URL) throws -> URL {
        let doc = try open(url)
        doc.documentAttributes = [:]
        return try write(doc, to: Output.url(for: url, ext: "pdf", suffix: "clean"))
    }

    static func info(_ url: URL) -> String {
        guard let doc = PDFDocument(url: url) else { return "Can't open PDF" }
        var lines = ["Pages: \(doc.pageCount)", "Encrypted: \(doc.isEncrypted)", "Version: \(doc.majorVersion).\(doc.minorVersion)"]
        if let size = doc.page(at: 0)?.bounds(for: .mediaBox).size {
            lines.append("Page size: \(Int(size.width)) × \(Int(size.height)) pt")
        }
        for (key, value) in doc.documentAttributes ?? [:] { lines.append("\(key): \(value)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Text documents

enum DocOps {
    static let types: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "doc": .docFormat, "rtf": .rtf, "html": .html, "odt": .openDocument, "txt": .plain,
    ]

    static func load(_ url: URL) throws -> NSAttributedString {
        if ["md", "markdown"].contains(url.pathExtension.lowercased()) {
            let source = try String(contentsOf: url, encoding: .utf8)
            let parsed = try AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
            return NSAttributedString(parsed)
        }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    static func convert(_ url: URL, to ext: String) throws -> URL {
        try onMain { try save(try load(url), like: url, ext: ext) }
    }

    static func save(_ text: NSAttributedString, like url: URL, ext: String) throws -> URL {
        let out = Output.url(for: url, ext: ext)
        switch ext {
        case "pdf":
            try onMain { try printPDF(text, to: out) }
        case "txt":
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        default:
            guard let type = types[ext] else { throw ToolError("Can't write \(ext.uppercased())") }
            let data = try onMain {
                try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
            }
            try data.write(to: out)
        }
        return out
    }

    /// Lays text out on A4 pages and saves it through the print system.
    static func printPDF(_ text: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo(dictionary: [.jobSavingURL: url])
        info.jobDisposition = .save
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 56; info.bottomMargin = 56; info.leftMargin = 56; info.rightMargin = 56
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 595 - 112, height: 842 - 112))
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.sizeToFit()

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw ToolError("Couldn't create PDF") }
    }
}

// MARK: - Archives

enum ArchiveOps {
    /// Clones the inputs into one temp folder so they can be archived together.
    private static func stage(_ urls: [URL]) throws -> URL {
        let dir = try Output.tempDir()
        for url in urls {
            try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(url.lastPathComponent))
        }
        return dir
    }

    static func zip(_ urls: [URL]) throws -> URL {
        let out = Output.url(for: urls[0], ext: "zip", name: urls.count > 1 ? "Archive" : nil)
        if urls.count == 1 {
            try Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, out.path])
        } else {
            let dir = try stage(urls)
            defer { try? FileManager.default.removeItem(at: dir) }
            try Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", dir.path, out.path])
        }
        return out
    }

    static func tarGz(_ urls: [URL]) throws -> URL {
        let out = Output.url(for: urls[0], ext: "tar.gz", name: urls.count > 1 ? "Archive" : nil)
        let dir = try stage(urls)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Shell.run("/usr/bin/tar", ["--no-mac-metadata", "-czf", out.path, "-C", dir.path] + urls.map(\.lastPathComponent))
        return out
    }

    static func extract(_ url: URL) throws -> URL {
        let parent = Output.url(for: url, ext: "").deletingLastPathComponent()
        let dir = Output.unique(parent.appendingPathComponent(Output.baseName(url)))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = url.lastPathComponent.lowercased()

        if name.hasSuffix(".zip") {
            try Shell.run("/usr/bin/ditto", ["-x", "-k", url.path, dir.path])
        } else if name.hasSuffix(".gz") && !name.hasSuffix(".tar.gz") {
            let out = dir.appendingPathComponent(Output.baseName(url))
            try Shell.run("/bin/sh", ["-c", "gzip -dc \"$0\" > \"$1\"", url.path, out.path])
        } else {
            try Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", dir.path])
        }

        // Unwrap a lone top-level item so we don't end up with Folder/Folder.
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" } ?? []
        try? fm.removeItem(at: dir.appendingPathComponent("__MACOSX"))
        if items.count == 1 {
            let target = Output.unique(parent.appendingPathComponent(items[0].lastPathComponent))
            try fm.moveItem(at: items[0], to: target)
            try fm.removeItem(at: dir)
            return target
        }
        return dir
    }
}

// MARK: - Subtitles

enum SubtitleOps {
    static func convert(_ url: URL, to ext: String) throws -> URL {
        let out = Output.url(for: url, ext: ext)
        try FF.run(["-i", url.path, out.path], duration: 0) { _ in }
        return out
    }
}
