import AppKit
import UniformTypeIdentifiers

/// The selectable menu bar icons, stored in UserDefaults as an id string.
enum MenuBarIcon {
    private static let key = "menuBarIcon"
    static let defaultID = "dial"

    static let symbols = [
        "circle.circle.fill", "circle.dashed.inset.filled", "circle.hexagongrid.fill", "sun.max.fill", "sun.min.fill",
        "sparkles", "wand.and.stars", "bolt.fill", "flame.fill", "drop.fill", "leaf.fill", "carrot.fill",
        "star.fill", "heart.fill", "moon.fill", "cloud.fill", "snowflake", "camera.macro",
        "arrow.triangle.2.circlepath", "arrow.left.arrow.right.circle.fill", "arrow.2.squarepath", "arrow.trianglehead.2.clockwise.rotate.90",
        "repeat.circle.fill", "shuffle", "square.stack.3d.up.fill", "cube.fill", "shippingbox.fill", "archivebox.fill",
        "tray.full.fill", "folder.fill", "doc.on.doc.fill", "doc.zipper", "photo.fill", "film.fill", "music.note", "waveform",
        "scissors", "hammer.fill", "wrench.and.screwdriver.fill", "paintbrush.fill", "paintpalette.fill", "pencil.and.scribble",
        "gearshape.fill", "command", "target", "scope", "dial.medium.fill", "atom", "swirl.circle.righthalf.filled",
        "fan.fill", "hurricane", "pawprint.fill", "hare.fill", "tortoise.fill", "ladybug.fill", "fish.fill", "bird.fill",
        "crown.fill", "gift.fill", "cup.and.saucer.fill", "wineglass.fill", "fork.knife", "globe.asia.australia.fill",
        "face.smiling.inverse", "hand.thumbsup.fill", "hand.wave.fill", "eye.fill", "brain.head.profile",
    ]

    /// Every option id in display order: drawn dial icons, the app icon, then SF Symbols that exist on this system.
    static var allIDs: [String] {
        ["dial", "dial-outline", "dial-ticks", "wheel", "app-icon"]
            + symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }.map { "symbol:" + $0 }
    }

    static var current: String {
        get { UserDefaults.standard.string(forKey: key) ?? defaultID }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var customImageURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dial")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("menubar-icon.png")
    }

    static func image(for id: String, size: CGFloat = 18) -> NSImage? {
        switch id {
        case "dial": return dial(size: size, style: .knob)
        case "dial-outline": return dial(size: size, style: .outline)
        case "dial-ticks": return dial(size: size, style: .ticks)
        case "wheel": return wheel(size: size)
        case "app-icon": return resized(NSApp.applicationIconImage, height: size + 2)
        case "custom": return NSImage(contentsOf: customImageURL).map { resized($0, height: size) }
        default:
            guard id.hasPrefix("symbol:") else { return nil }
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .medium)
            let image = NSImage(systemSymbolName: String(id.dropFirst(7)), accessibilityDescription: "Dial")?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            return image
        }
    }

    /// Lets the user pick any image file as the icon.
    static func chooseCustomImage() -> Bool {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.message = "Choose an image for the menu bar"
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url,
              let source = NSImage(contentsOf: url),
              let tiff = resized(source, height: 44).tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: customImageURL)
            return true
        } catch {
            Toast.show("Couldn't save image: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Drawing

    private enum DialStyle { case knob, outline, ticks }

    /// A rotary dial: rim, tick marks and a pointer.
    private static func dial(size: CGFloat, style: DialStyle) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            let r = size / 2 - 1
            NSColor.black.set()
            let pointerAngle = CGFloat.pi * 0.25  // pointing to about 1:30

            switch style {
            case .knob:
                NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
                // Pointer cut out of the filled knob.
                NSGraphicsContext.current?.compositingOperation = .clear
                let pointer = NSBezierPath()
                pointer.move(to: NSPoint(x: c.x + sin(pointerAngle) * r * 0.25, y: c.y + cos(pointerAngle) * r * 0.25))
                pointer.line(to: NSPoint(x: c.x + sin(pointerAngle) * r * 0.72, y: c.y + cos(pointerAngle) * r * 0.72))
                pointer.lineWidth = 2.2
                pointer.lineCapStyle = .round
                pointer.stroke()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            case .outline:
                let rim = NSBezierPath(ovalIn: NSRect(x: c.x - r + 0.5, y: c.y - r + 0.5, width: r * 2 - 1, height: r * 2 - 1))
                rim.lineWidth = 1.5
                rim.stroke()
                let pointer = NSBezierPath()
                pointer.move(to: c)
                pointer.line(to: NSPoint(x: c.x + sin(pointerAngle) * r * 0.62, y: c.y + cos(pointerAngle) * r * 0.62))
                pointer.lineWidth = 1.8
                pointer.lineCapStyle = .round
                pointer.stroke()
                NSBezierPath(ovalIn: NSRect(x: c.x - 1.8, y: c.y - 1.8, width: 3.6, height: 3.6)).fill()
            case .ticks:
                for i in 0..<12 {
                    let a = CGFloat(i) / 12 * 2 * .pi
                    let tick = NSBezierPath()
                    tick.move(to: NSPoint(x: c.x + sin(a) * r * 0.78, y: c.y + cos(a) * r * 0.78))
                    tick.line(to: NSPoint(x: c.x + sin(a) * r, y: c.y + cos(a) * r))
                    tick.lineWidth = i % 3 == 0 ? 1.6 : 1
                    tick.lineCapStyle = .round
                    tick.stroke()
                }
                let knob = r * 0.55
                NSBezierPath(ovalIn: NSRect(x: c.x - knob, y: c.y - knob, width: knob * 2, height: knob * 2)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The radial menu itself: a ring of segments.
    private static func wheel(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            NSColor.black.set()
            for i in 0..<6 {
                let start = CGFloat(i) * 60 + 8, end = CGFloat(i + 1) * 60 - 8
                let segment = NSBezierPath()
                segment.appendArc(withCenter: c, radius: size / 2 - 0.5, startAngle: start, endAngle: end)
                segment.appendArc(withCenter: c, radius: size / 2 - 5, startAngle: end, endAngle: start, clockwise: true)
                segment.close()
                segment.fill()
            }
            NSBezierPath(ovalIn: NSRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func resized(_ image: NSImage, height: CGFloat) -> NSImage {
        let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
        let size = NSSize(width: min(height * ratio, height * 2), height: height)
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }
}

/// A grid of icon buttons shown inside the status menu.
final class IconGridView: NSView {
    private static let columns = 8
    private static let cell: CGFloat = 30
    private static let padding: CGFloat = 12

    private let ids: [String]
    private let onPick: (String) -> Void

    init(ids: [String], current: String, onPick: @escaping (String) -> Void) {
        self.ids = ids
        self.onPick = onPick
        let rows = (ids.count + Self.columns - 1) / Self.columns
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: Self.padding * 2 + CGFloat(Self.columns) * Self.cell,
                                 height: Self.padding + CGFloat(rows) * Self.cell))
        for (i, id) in ids.enumerated() {
            let row = i / Self.columns, col = i % Self.columns
            let button = NSButton(frame: NSRect(x: Self.padding + CGFloat(col) * Self.cell,
                                                y: frame.height - CGFloat(row + 1) * Self.cell,
                                                width: Self.cell - 2, height: Self.cell - 2))
            button.image = MenuBarIcon.image(for: id, size: 17)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.tag = i
            button.target = self
            button.action = #selector(picked(_:))
            button.toolTip = id.replacingOccurrences(of: "symbol:", with: "")
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            if id == current {
                button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.3).cgColor
            }
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func picked(_ sender: NSButton) {
        enclosingMenuItem?.menu?.cancelTracking()
        onPick(ids[sender.tag])
    }
}
