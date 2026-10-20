import AppKit

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Runs `work` on the main thread, blocking the caller if needed.
func onMain<T>(_ work: () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try work() }
    return try DispatchQueue.main.sync(execute: work)
}

func normalizedExt(_ ext: String) -> String {
    switch ext.lowercased() {
    case "jpeg", "jpe": return "jpg"
    case "tif": return "tiff"
    case "aif": return "aiff"
    case "htm": return "html"
    case "heif": return "heic"
    default: return ext.lowercased()
    }
}

// MARK: - Output paths

enum Output {
    static var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    /// Strips the extension, treating `.tar.gz` style double extensions as one.
    static func baseName(_ url: URL) -> String {
        var name = url.lastPathComponent
        for double in [".tar.gz", ".tar.bz2", ".tar.xz"] where name.lowercased().hasSuffix(double) {
            return String(name.dropLast(double.count))
        }
        if !url.hasDirectoryPath || !url.pathExtension.isEmpty, let dot = name.lastIndex(of: "."), dot != name.startIndex {
            name = String(name[..<dot])
        }
        return name
    }

    /// A free URL next to `input` (or in Downloads when that folder is read-only).
    static func url(for input: URL, ext: String, suffix: String? = nil, name: String? = nil) -> URL {
        var dir = input.deletingLastPathComponent()
        if !FileManager.default.isWritableFile(atPath: dir.path) { dir = downloads }
        var base = name ?? baseName(input)
        if let suffix { base += " " + suffix }
        return unique(dir.appendingPathComponent(ext.isEmpty ? base : base + "." + ext))
    }

    static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        for i in 2... {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dial-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

func fileSize(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
}

func formatBytes(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

// MARK: - Parsing user input

/// A compression target: a percentage of the original size or an absolute size.
enum SizeSpec {
    case percent(Double)
    case bytes(Int)

    static func parse(_ text: String) -> SizeSpec? {
        let s = text.lowercased().replacingOccurrences(of: " ", with: "")
        if s.hasSuffix("%"), let p = Double(s.dropLast()), p > 0, p < 100 { return .percent(p) }
        let units: [(String, Double)] = [("gb", 1e9), ("mb", 1e6), ("kb", 1e3), ("g", 1e9), ("m", 1e6), ("k", 1e3)]
        for (unit, mult) in units where s.hasSuffix(unit) {
            if let v = Double(s.dropLast(unit.count)), v > 0 { return .bytes(Int(v * mult)) }
        }
        if let v = Double(s), v > 0 { return .bytes(Int(v * 1e6)) }
        return nil
    }

    func target(for url: URL) -> Int {
        switch self {
        case .percent(let p): return Int(Double(fileSize(url)) * p / 100)
        case .bytes(let b): return b
        }
    }
}

/// Parses "90", "1:30" or "1:02:03" into seconds.
func parseTime(_ text: String) -> Double? {
    let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
    guard !parts.isEmpty, parts.count <= 3, !parts.contains(where: { $0 == nil }) else { return nil }
    return parts.reduce(0) { $0 * 60 + $1! }
}

// MARK: - Dialogs

enum Prompt {
    static func text(_ title: String, _ message: String, default value: String = "") -> String? {
        if Run.headless { return ProcessInfo.processInfo.environment["DIAL_INPUT"] ?? value }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    static func folder(_ title: String) -> URL? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.message = title
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks for a compression target, e.g. "50%" or "8 MB".
    static func sizeSpec() -> SizeSpec? {
        guard let text = text("Compress to…", "Enter a percentage of the original size (e.g. 50%) or a target size (e.g. 8 MB).", default: "50%") else { return nil }
        guard let spec = SizeSpec.parse(text) else { Toast.show("Couldn't understand “\(text)”"); return nil }
        return spec
    }
}

// MARK: - Toast

enum Toast {
    private static var panel: NSPanel?

    static func show(_ text: String) {
        panel?.orderOut(nil)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 4
        label.preferredMaxLayoutWidth = 360
        let size = label.fittingSize
        let width = min(400, size.width + 32), height = size.height + 20

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = HUDBackground(frame: NSRect(x: 0, y: 0, width: width, height: height))
        label.frame = NSRect(x: 16, y: 10, width: width - 32, height: size.height)
        bg.addSubview(label)
        p.contentView = bg
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.midX - width / 2, y: screen.maxY - height - 12))
        }
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if panel === p { p.orderOut(nil); panel = nil }
        }
    }
}

/// Dark rounded translucent background shared by the HUD-style panels.
/// Liquid Glass background (macOS 26+), falling back to a blurred HUD material.
/// Add content as ordinary subviews; they sit on top of the glass.
class HUDBackground: NSView {
    private let surface: NSView

    var cornerRadius: CGFloat = 18 {
        didSet { applyCornerRadius() }
    }

    override init(frame: NSRect) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: frame.size))
            glass.contentView = NSView()
            glass.style = .regular
            surface = glass
        } else {
            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
            blur.material = .hudWindow
            blur.state = .active
            blur.blendingMode = .behindWindow
            blur.wantsLayer = true
            blur.layer?.masksToBounds = true
            surface = blur
        }
        super.init(frame: frame)
        surface.autoresizingMask = [.width, .height]
        addSubview(surface)
        applyCornerRadius()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Tints the glass toward a colour; a more opaque tint makes it frostier.
    func setTint(_ color: NSColor?) {
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.tintColor = color
        }
    }

    /// Makes the glass react to pointer interaction (macOS 27+).
    func setInteractive(_ interactive: Bool) {
        if #available(macOS 27.0, *), let glass = surface as? NSGlassEffectView {
            glass.effectIsInteractive = interactive
        }
    }

    private func applyCornerRadius() {
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else {
            surface.layer?.cornerRadius = cornerRadius
        }
    }
}

// MARK: - Info window

enum InfoWindow {
    private static var windows: [NSWindow] = []

    static func show(title: String, text: String) {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.string = text
        w.contentView = scroll
        w.center()
        windows.removeAll { !$0.isVisible }
        windows.append(w)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }
}
