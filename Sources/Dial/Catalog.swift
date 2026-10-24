import AppKit
import UniformTypeIdentifiers

enum FileKind {
    case image, video, audio, pdf, document, subtitle, archive, folder, other

    static let extensions: [FileKind: Set<String>] = [
        .image: ["jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp", "gif", "svg", "ico", "avif"],
        .video: ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "3gp", "ts"],
        .audio: ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "aif", "aac", "wma"],
        .pdf: ["pdf"],
        .document: ["txt", "rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "md", "markdown", "webarchive"],
        .subtitle: ["srt", "vtt", "ass"],
        .archive: ["zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz"],
    ]

    static func of(_ url: URL) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if let kind = extensions.first(where: { $0.value.contains(ext) })?.key { return kind }
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return .folder }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
        }
        return .other
    }

    /// The shared kind of all files, or `.other` when they're mixed.
    static func common(_ urls: [URL]) -> FileKind {
        let kinds = Set(urls.map(of))
        return kinds.count == 1 ? kinds.first! : .other
    }
}

enum WheelMode {
    case formats, tools, actions, menu

    var title: String {
        switch self {
        case .formats: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        case .menu: return "File"
        }
    }
}

struct WheelItem {
    let title: String
    let symbol: String
    let action: ([URL]) -> Void
    /// Full-colour image (e.g. an app icon) drawn instead of the SF Symbol.
    var image: NSImage? = nil
}

/// Decides which wheel items a set of files gets in each mode.
enum Catalog {
    static func items(for urls: [URL], mode: WheelMode) -> [WheelItem] {
        let kind = FileKind.common(urls)
        switch mode {
        case .formats: return formats(kind, urls)
        case .tools: return tools(kind, urls)
        case .actions: return actions()
        case .menu: return menu(urls)
        }
    }

    static func label(_ ext: String) -> String {
        switch ext {
        case "jpg": return "JPEG"
        case "tar.gz": return "TAR.GZ"
        default: return ext.uppercased()
        }
    }

    static func symbol(_ ext: String) -> String {
        switch ext {
        case "jpg", "png", "heic", "webp", "tiff", "bmp", "avif", "ico": return "photo"
        case "gif": return "photo.stack"
        case "pdf": return "doc.richtext"
        case "mp4", "mov", "mkv", "webm", "avi", "wmv": return "film"
        case "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff": return "waveform"
        case "zip", "tar.gz": return "doc.zipper"
        case "txt": return "doc.plaintext"
        case "html": return "chevron.left.forwardslash.chevron.right"
        case "srt", "vtt", "ass": return "captions.bubble"
        default: return "doc.text"
        }
    }

    // MARK: Formats

    private static func formats(_ kind: FileKind, _ urls: [URL]) -> [WheelItem] {
        let allSame = { (ext: String) in urls.allSatisfy { normalizedExt($0.pathExtension) == ext } }
        func convert(_ exts: [String], _ op: @escaping (URL, String, @escaping (Double) -> Void) throws -> [URL]) -> [WheelItem] {
            exts.filter { !allSame($0) }.map { ext in
                WheelItem(title: label(ext), symbol: symbol(ext)) { urls in
                    Run.each(urls, "To \(label(ext))") { url, progress in try op(url, ext, progress) }
                }
            }
        }

        var items: [WheelItem]
        switch kind {
        case .image:
            items = convert(["jpg", "png", "heic", "webp", "avif", "tiff", "gif", "bmp", "ico", "pdf"]) { url, ext, _ in
                [try ImageOps.convert(url, to: ext)]
            }
        case .video:
            items = convert(["mp4", "mov", "mkv", "webm", "avi", "gif", "mp3", "m4a"]) { url, ext, progress in
                [try MediaOps.convert(url, to: ext, progress: progress)]
            }
        case .audio:
            items = convert(["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"]) { url, ext, progress in
                [try MediaOps.convert(url, to: ext, progress: progress)]
            }
        case .pdf:
            items = convert(["png", "jpg"]) { url, ext, _ in try PDFOps.toImages(url, ext: ext) }
                + convert(["txt"]) { url, _, _ in [try PDFOps.toText(url)] }
                + convert(["docx", "rtf"]) { url, ext, _ in [try PDFOps.toDocument(url, ext: ext)] }
        case .document:
            items = convert(["pdf", "docx", "txt", "rtf", "html", "odt"]) { url, ext, _ in [try DocOps.convert(url, to: ext)] }
        case .subtitle:
            items = convert(["srt", "vtt", "ass"]) { url, ext, _ in [try SubtitleOps.convert(url, to: ext)] }
        case .archive:
            return [WheelItem(title: "Extract", symbol: "archivebox") { urls in
                Run.each1(urls, "Extracting") { url, _ in try ArchiveOps.extract(url) }
            }]
        case .folder, .other:
            items = []
        }
        return items + archiveItems()
    }

    private static func archiveItems() -> [WheelItem] {
        [
            WheelItem(title: "ZIP", symbol: "doc.zipper") { urls in Run.job("Zipping") { _ in [try ArchiveOps.zip(urls)] } },
            WheelItem(title: "TAR.GZ", symbol: "shippingbox") { urls in Run.job("Archiving") { _ in [try ArchiveOps.tarGz(urls)] } },
        ]
    }

    // MARK: Tools

    private static func tools(_ kind: FileKind, _ urls: [URL]) -> [WheelItem] {
        let multiple = urls.count > 1
        switch kind {
        case .image:
            return [
                WheelItem(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left") { urls in
                    Run.each1(urls, "Compressing") { url, _ in try ImageOps.compress(url, targetBytes: fileSize(url) / 2) }
                },
                compressTo { url, target, _ in try ImageOps.compress(url, targetBytes: target) },
                WheelItem(title: "Resize…", symbol: "arrow.up.left.and.down.right.magnifyingglass") { urls in
                    guard let text = Prompt.text("Resize", "Scale as a percentage of the original size.", default: "50%"),
                          let percent = Double(text.replacingOccurrences(of: "%", with: "")), percent > 0 else { return }
                    Run.each1(urls, "Resizing") { url, _ in try ImageOps.resize(url, scale: percent / 100) }
                },
                WheelItem(title: "Rotate", symbol: "rotate.right") { urls in Run.each1(urls, "Rotating") { u, _ in try ImageOps.rotate(u) } },
                WheelItem(title: "Flip", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right") { urls in
                    Run.each1(urls, "Flipping") { u, _ in try ImageOps.flip(u) }
                },
                WheelItem(title: "B&W", symbol: "circle.lefthalf.filled") { urls in Run.each1(urls, "Grayscale") { u, _ in try ImageOps.grayscale(u) } },
                WheelItem(title: "Cut Out", symbol: "person.crop.rectangle") { urls in
                    Run.each1(urls, "Removing background") { u, _ in try ImageOps.removeBackground(u) }
                },
                WheelItem(title: "Strip Info", symbol: "eye.slash") { urls in Run.each1(urls, "Removing metadata") { u, _ in try ImageOps.stripMetadata(u) } },
                WheelItem(title: "Read QR", symbol: "qrcode.viewfinder") { urls in
                    Run.job("Reading QR code", reveal: false) { _ in
                        let text = try urls.map(ImageOps.readQR).joined(separator: "\n")
                        DispatchQueue.main.async {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            Toast.show("Copied: \(text)")
                        }
                        return []
                    }
                },
                multiple
                    ? WheelItem(title: "Make PDF", symbol: "doc.richtext") { urls in Run.job("Making PDF") { _ in [try ImageOps.makePDF(urls)] } }
                    : infoItem { ImageOps.info($0) },
            ]
        case .video, .audio:
            let video = kind == .video
            var items = [
                WheelItem(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left") { urls in
                    Run.each1(urls, "Compressing") { url, progress in try MediaOps.compress(url, progress: progress) }
                },
                compressTo { url, target, progress in try MediaOps.compress(url, targetBytes: target, progress: progress) },
                WheelItem(title: "Trim…", symbol: "scissors") { urls in
                    guard let text = Prompt.text("Trim", "Start – end, e.g. 0:05 - 1:30. Leave the end empty to keep the rest.", default: "0:00 - "),
                          let range = parseRange(text) else { return }
                    Run.each1(urls, "Trimming") { url, progress in try MediaOps.trim(url, from: range.0, to: range.1, progress: progress) }
                },
                WheelItem(title: "Speed…", symbol: "gauge.with.dots.needle.67percent") { urls in
                    guard let text = Prompt.text("Change Speed", "Speed factor, e.g. 2 for double speed or 0.5 for half.", default: "2"),
                          let factor = Double(text.replacingOccurrences(of: "x", with: "")), factor >= 0.1, factor <= 10 else { return }
                    Run.each1(urls, "Changing speed") { url, progress in try MediaOps.speed(url, factor: factor, progress: progress) }
                },
            ]
            if video {
                items += [
                    WheelItem(title: "Snapshot", symbol: "camera") { urls in
                        guard let text = Prompt.text("Snapshot", "Time of the frame, e.g. 0:05. Leave empty for the middle.") else { return }
                        Run.each1(urls, "Taking snapshot") { url, _ in
                            try MediaOps.snapshot(url, at: parseTime(text) ?? FF.duration(url) / 2)
                        }
                    },
                    WheelItem(title: "Mute", symbol: "speaker.slash") { urls in Run.each1(urls, "Muting") { u, p in try MediaOps.mute(u, progress: p) } },
                    WheelItem(title: "Half Size", symbol: "arrow.down.forward.and.arrow.up.backward") { urls in
                        Run.each1(urls, "Resizing") { u, p in try MediaOps.halfSize(u, progress: p) }
                    },
                    WheelItem(title: "Split", symbol: "square.split.2x1") { urls in Run.each(urls, "Splitting") { u, p in try MediaOps.split(u, progress: p) } },
                ]
            } else {
                items += [
                    WheelItem(title: "Normalize", symbol: "slider.vertical.3") { urls in
                        Run.each1(urls, "Normalizing") { u, p in try MediaOps.normalize(u, progress: p) }
                    },
                    WheelItem(title: "Mono", symbol: "speaker") { urls in Run.each1(urls, "To mono") { u, p in try MediaOps.channels(u, 1, progress: p) } },
                    WheelItem(title: "Stereo", symbol: "speaker.wave.2") { urls in Run.each1(urls, "To stereo") { u, p in try MediaOps.channels(u, 2, progress: p) } },
                ]
            }
            items.append(WheelItem(title: "Strip Info", symbol: "eye.slash") { urls in
                Run.each1(urls, "Removing metadata") { u, p in try MediaOps.stripMetadata(u, progress: p) }
            })
            items.append(multiple
                ? WheelItem(title: "Join", symbol: "rectangle.stack.badge.plus") { urls in
                    Run.job("Joining \(urls.count) files") { p in [try MediaOps.join(urls, progress: p)] }
                }
                : infoItem { FF.info($0) })
            return items
        case .pdf:
            var items = [
                WheelItem(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left") { urls in
                    Run.each1(urls, "Compressing") { u, _ in try PDFOps.compress(u) }
                },
                WheelItem(title: "Split Pages", symbol: "square.split.2x1") { urls in Run.each(urls, "Splitting") { u, _ in try PDFOps.split(u) } },
                WheelItem(title: "Rotate", symbol: "rotate.right") { urls in Run.each1(urls, "Rotating") { u, _ in try PDFOps.rotate(u) } },
                WheelItem(title: "Strip Info", symbol: "eye.slash") { urls in Run.each1(urls, "Removing metadata") { u, _ in try PDFOps.stripMetadata(u) } },
            ]
            items.append(multiple
                ? WheelItem(title: "Merge", symbol: "rectangle.stack.badge.plus") { urls in Run.job("Merging PDFs") { _ in [try PDFOps.merge(urls)] } }
                : infoItem { PDFOps.info($0) })
            return items
        default:
            return []
        }
    }

    private static func compressTo(_ op: @escaping (URL, Int, @escaping (Double) -> Void) throws -> URL) -> WheelItem {
        WheelItem(title: "Compress…", symbol: "slider.horizontal.below.rectangle") { urls in
            guard let spec = Prompt.sizeSpec() else { return }
            Run.each1(urls, "Compressing") { url, progress in try op(url, spec.target(for: url), progress) }
        }
    }

    private static func infoItem(_ read: @escaping (URL) -> String) -> WheelItem {
        WheelItem(title: "Info", symbol: "info.circle") { urls in
            let url = urls[0]
            DispatchQueue.global(qos: .userInitiated).async {
                let text = read(url)
                DispatchQueue.main.async { InfoWindow.show(title: url.lastPathComponent, text: text) }
            }
        }
    }

    private static func parseRange(_ text: String) -> (Double, Double?)? {
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = parseTime(parts[0].isEmpty ? "0" : parts[0]) else { Toast.show("Couldn't read the start time"); return nil }
        let end = parts.count > 1 && !parts[1].isEmpty ? parseTime(parts[1]) : nil
        return (start, end)
    }

    // MARK: Actions

    private static func actions() -> [WheelItem] {
        [
            WheelItem(title: "AirDrop", symbol: "airplayaudio") { urls in
                NSApp.activate()
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
            },
            WheelItem(title: "Share…", symbol: "square.and.arrow.up") { urls in SharePicker.show(urls, at: WheelController.shared.center) },
            WheelItem(title: "Float", symbol: "pin") { urls in Shelf.shared.add(urls) },
            WheelItem(title: "Copy", symbol: "doc.on.doc") { urls in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(urls as [NSURL])
                Toast.show(urls.count == 1 ? "Copied \(urls[0].lastPathComponent)" : "Copied \(urls.count) files")
            },
            WheelItem(title: "Copy To…", symbol: "plus.rectangle.on.folder") { urls in transfer(urls, move: false) },
            WheelItem(title: "Move To…", symbol: "folder") { urls in transfer(urls, move: true) },
            WheelItem(title: "Copy Path", symbol: "link") { urls in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
                Toast.show("Copied path")
            },
            WheelItem(title: "Terminal", symbol: "terminal") { urls in
                let dir = urls[0].hasDirectoryPath ? urls[0] : urls[0].deletingLastPathComponent()
                guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
                NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            },
        ]
    }

    // MARK: Menu (right-click style)

    private static func menu(_ urls: [URL]) -> [WheelItem] {
        [
            WheelItem(title: "Open", symbol: "arrow.up.forward.app") { urls in urls.forEach { NSWorkspace.shared.open($0) } },
            WheelItem(title: "Open With", symbol: "square.grid.2x2") { urls in showOpenWith(urls) },
            WheelItem(title: "Quick Look", symbol: "eye") { urls in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
                process.arguments = ["-p"] + urls.map(\.path)
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
            },
            WheelItem(title: "Get Info", symbol: "info.circle") { urls in
                let list = urls.map { "POSIX file \"\($0.path.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ")
                let script = "tell application \"Finder\"\nactivate\nrepeat with f in {\(list)}\nopen information window of (f as alias)\nend repeat\nend tell"
                NSAppleScript(source: script)?.executeAndReturnError(nil)
            },
            WheelItem(title: "Rename", symbol: "pencil") { urls in rename(urls[0]) },
            WheelItem(title: "Duplicate", symbol: "plus.square.on.square") { urls in
                Run.job("Duplicating") { _ in
                    try urls.map { url in
                        let ext = url.pathExtension
                        let copy = Output.unique(url.deletingLastPathComponent()
                            .appendingPathComponent(Output.baseName(url) + " copy" + (ext.isEmpty ? "" : "." + ext)))
                        try FileManager.default.copyItem(at: url, to: copy)
                        return copy
                    }
                }
            },
            WheelItem(title: "Copy", symbol: "doc.on.doc") { urls in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects(urls as [NSURL])
                Toast.show(urls.count == 1 ? "Copied \(urls[0].lastPathComponent)" : "Copied \(urls.count) files")
            },
            WheelItem(title: "Share…", symbol: "square.and.arrow.up") { urls in SharePicker.show(urls, at: WheelController.shared.center) },
            WheelItem(title: "Trash", symbol: "trash") { urls in
                NSWorkspace.shared.recycle(urls) { _, error in
                    Toast.show(error?.localizedDescription ?? (urls.count == 1 ? "Moved \(urls[0].lastPathComponent) to Trash" : "Moved \(urls.count) files to Trash"))
                }
            },
        ]
    }

    /// A second wheel listing the apps that can open the files.
    private static func showOpenWith(_ urls: [URL]) {
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: urls[0]).prefix(10)
        guard !apps.isEmpty else { Toast.show("No apps can open this file"); return }
        let items = apps.map { app in
            WheelItem(title: FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""),
                      symbol: "app", action: { urls in
                NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }, image: NSWorkspace.shared.icon(forFile: app.path))
        }
        let wheel = WheelController.shared
        wheel.present(Array(items), title: "Open With", urls: urls, at: wheel.center, dragMode: false)
    }

    private static func rename(_ url: URL) {
        guard let name = Prompt.text("Rename", "New name for “\(url.lastPathComponent)”:", default: url.lastPathComponent),
              !name.isEmpty, name != url.lastPathComponent else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            guard !FileManager.default.fileExists(atPath: target.path) else { throw ToolError("“\(name)” already exists") }
            try FileManager.default.moveItem(at: url, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            Toast.show(error.localizedDescription)
        }
    }

    private static func transfer(_ urls: [URL], move: Bool) {
        guard let dest = Prompt.folder(move ? "Move to…" : "Copy to…") else { return }
        Run.job(move ? "Moving" : "Copying") { progress in
            try urls.enumerated().map { i, url in
                let target = Output.unique(dest.appendingPathComponent(url.lastPathComponent))
                if move { try FileManager.default.moveItem(at: url, to: target) } else { try FileManager.default.copyItem(at: url, to: target) }
                progress(Double(i + 1) / Double(urls.count))
                return target
            }
        }
    }
}

/// The system Share menu, shown where the wheel was.
enum SharePicker {
    private static var anchor: NSPanel?
    private static var picker: NSSharingServicePicker?

    static func show(_ urls: [URL], at point: NSPoint) {
        anchor?.orderOut(nil)
        let panel = NSPanel(contentRect: NSRect(x: point.x, y: point.y, width: 1, height: 1),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        anchor = panel
        let picker = NSSharingServicePicker(items: urls)
        self.picker = picker
        NSApp.activate()
        if let view = panel.contentView { picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY) }
    }
}
