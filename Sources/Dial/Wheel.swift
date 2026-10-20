import AppKit

/// The radial menu that appears around the pointer.
final class WheelController {
    static let shared = WheelController()

    private let panel = WheelPanel()
    private let root = NSView(frame: NSRect(x: 0, y: 0, width: WheelView.size, height: WheelView.size))
    private let view = WheelView(frame: NSRect(x: 0, y: 0, width: WheelView.size, height: WheelView.size))
    private(set) var urls: [URL] = []
    private(set) var center: NSPoint = .zero
    /// True while the wheel is a drop target for an ongoing drag, false when it's clicked.
    private(set) var dragMode = false

    var isVisible: Bool { panel.isVisible }

    private init() {
        let inset = WheelView.size / 2 - WheelView.outerRadius
        let disc = HUDBackground(frame: root.bounds.insetBy(dx: inset, dy: inset))
        disc.cornerRadius = WheelView.outerRadius
        disc.setInteractive(true)
        disc.setTint(NSColor.windowBackgroundColor.withAlphaComponent(0.45))
        let hubInset = WheelView.size / 2 - WheelView.hubRadius
        let hub = HUDBackground(frame: root.bounds.insetBy(dx: hubInset, dy: hubInset))
        hub.cornerRadius = WheelView.hubRadius
        hub.setTint(NSColor.windowBackgroundColor.withAlphaComponent(0.6))
        root.addSubview(disc)
        root.addSubview(hub)
        root.addSubview(view)
        root.wantsLayer = true
        panel.contentView = root
    }

    @discardableResult
    func show(_ urls: [URL], mode: WheelMode, at point: NSPoint, dragMode: Bool) -> Bool {
        var mode = mode
        var items = Catalog.items(for: urls, mode: mode)
        if items.isEmpty && mode == .tools {
            mode = .formats
            items = Catalog.items(for: urls, mode: mode)
        }
        guard !items.isEmpty else { return false }
        present(items, title: mode.title, urls: urls, at: point, dragMode: dragMode)
        return true
    }

    /// Shows an arbitrary set of items, e.g. a follow-up wheel such as "Open With".
    func present(_ items: [WheelItem], title: String, urls: [URL], at point: NSPoint, dragMode: Bool) {
        self.urls = urls
        self.dragMode = dragMode
        center = point
        view.configure(items: items, title: title,
                       subtitle: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
        let size = WheelView.size
        var frame = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        // Keep the whole wheel on the screen it opens on.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - size)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - size)
        }
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
            popIn()
        }
        if !dragMode {
            NSApp.activate()
            panel.makeKey()
        }
    }

    /// Springy scale-up from the centre, like system menus and popovers.
    private func popIn() {
        guard let layer = root.layer else { return }
        let c = WheelView.size / 2
        var start = CATransform3DMakeTranslation(c, c, 0)
        start = CATransform3DScale(start, 0.82, 0.82, 1)
        start = CATransform3DTranslate(start, -c, -c, 0)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = start
        spring.toValue = CATransform3DIdentity
        spring.damping = 16
        spring.stiffness = 260
        spring.mass = 0.9
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
    }

    func highlight(_ index: Int?) { view.highlighted = index }

    func hide() {
        panel.orderOut(nil)
        view.highlighted = nil
    }

    func pick(_ item: WheelItem, urls dropped: [URL]?) {
        let targets = dropped?.isEmpty == false ? dropped! : urls
        DispatchQueue.main.async {
            self.hide()
            item.action(targets)
        }
    }
}

final class WheelPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        if !WheelController.shared.dragMode { WheelController.shared.hide() }
    }
}

final class WheelView: NSView {
    static let size: CGFloat = 380
    static let outerRadius: CGFloat = 170
    static let hubRadius: CGFloat = 50
    private let outerRadius = WheelView.outerRadius
    private let innerRadius = WheelView.hubRadius + 6
    static var accent: NSColor { .controlAccentColor }

    private var items: [WheelItem] = []
    private var title = ""
    private var subtitle = ""
    var highlighted: Int? {
        didSet { if highlighted != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(items: [WheelItem], title: String, subtitle: String) {
        self.items = items
        self.title = title
        self.subtitle = subtitle
        highlighted = nil
        needsDisplay = true
    }

    private var middle: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private var segment: CGFloat { 2 * .pi / CGFloat(max(items.count, 1)) }

    /// Segment under a point. Segment 0 is centred at 12 o'clock, going clockwise.
    func index(at point: NSPoint) -> Int? {
        let dx = point.x - middle.x, dy = point.y - middle.y
        let r = hypot(dx, dy)
        guard !items.isEmpty, r > innerRadius, r < outerRadius + 30 else { return nil }
        var angle = atan2(dx, dy)
        if angle < 0 { angle += 2 * .pi }
        return Int((angle + segment / 2) / segment) % items.count
    }

    /// Converts a clockwise-from-top angle to AppKit's counter-clockwise-from-x degrees.
    private func appKitDegrees(_ angle: CGFloat) -> CGFloat { 90 - angle * 180 / .pi }

    private func point(angle: CGFloat, radius: CGFloat) -> NSPoint {
        NSPoint(x: middle.x + radius * sin(angle), y: middle.y + radius * cos(angle))
    }

    override func draw(_ dirtyRect: NSRect) {
        // The glass disc and hub are separate views underneath; this draws only the content.
        // Clear glass shows the desktop through, so give text and icons a soft halo for legibility.
        let halo = NSShadow()
        halo.shadowColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9)
        halo.shadowBlurRadius = 4
        halo.shadowOffset = .zero
        halo.set()
        let labelRadius = (outerRadius + innerRadius) / 2 + 2
        for (i, item) in items.enumerated() {
            let mid = CGFloat(i) * segment
            if i == highlighted {
                // Inset wedge, stroked in the same colour with round joins to soften its corners.
                let gap: CGFloat = 7
                let wedge = NSBezierPath()
                wedge.appendArc(withCenter: middle, radius: outerRadius - gap - 6,
                                startAngle: appKitDegrees(mid - segment / 2 + 0.03), endAngle: appKitDegrees(mid + segment / 2 - 0.03), clockwise: true)
                wedge.appendArc(withCenter: middle, radius: innerRadius + gap,
                                startAngle: appKitDegrees(mid + segment / 2 - 0.06), endAngle: appKitDegrees(mid - segment / 2 + 0.06), clockwise: false)
                wedge.close()
                wedge.lineJoinStyle = .round
                wedge.lineWidth = 12
                Self.accent.setFill()
                Self.accent.setStroke()
                wedge.fill()
                wedge.stroke()
            }
            if items.count > 1 && highlighted != i && highlighted != (i + items.count - 1) % items.count {
                let divider = NSBezierPath()
                divider.move(to: point(angle: mid - segment / 2, radius: innerRadius + 14))
                divider.line(to: point(angle: mid - segment / 2, radius: outerRadius - 14))
                NSColor.separatorColor.setStroke()
                divider.lineWidth = 1
                divider.lineCapStyle = .round
                divider.stroke()
            }
            drawItem(item, at: point(angle: mid, radius: labelRadius), active: i == highlighted)
        }

        let centerText = highlighted.map { items[$0].title } ?? title
        drawCentered(centerText, at: NSPoint(x: middle.x, y: middle.y + 6), size: 13, weight: .semibold, color: .labelColor, maxWidth: WheelView.hubRadius * 1.8)
        drawCentered(highlighted == nil ? subtitle : "Release to run", at: NSPoint(x: middle.x, y: middle.y - 11),
                     size: 9.5, weight: .regular, color: .secondaryLabelColor, maxWidth: WheelView.hubRadius * 1.7)
    }

    private func drawItem(_ item: WheelItem, at p: NSPoint, active: Bool) {
        let color = active ? NSColor.alternateSelectedControlTextColor : NSColor.labelColor
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let image = item.image {
            image.draw(in: NSRect(x: p.x - 13, y: p.y + 1, width: 26, height: 26))
        } else if let icon = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)?
            .withSymbolConfiguration(config) {
            let s = icon.size
            icon.draw(in: NSRect(x: p.x - s.width / 2, y: p.y + 2, width: s.width, height: s.height))
        }
        drawCentered(item.title, at: NSPoint(x: p.x, y: p.y - 12), size: 10.5, weight: .semibold, color: color, maxWidth: 76)
    }

    private func drawCentered(_ text: String, at p: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor, maxWidth: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: color, .paragraphStyle: style]
        let height = (text as NSString).size(withAttributes: attrs).height
        (text as NSString).draw(in: NSRect(x: p.x - maxWidth / 2, y: p.y - height / 2, width: maxWidth, height: height), withAttributes: attrs)
    }

    // MARK: Drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = index(at: convert(sender.draggingLocation, from: nil))
        return highlighted == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = index(at: convert(sender.draggingLocation, from: nil)) else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        WheelController.shared.pick(items[i], urls: urls)
        return true
    }

    // MARK: Click mode

    override func mouseMoved(with event: NSEvent) {
        guard !WheelController.shared.dragMode else { return }
        highlighted = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) {
            WheelController.shared.pick(items[i], urls: nil)
        } else {
            WheelController.shared.hide()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { WheelController.shared.hide() } else { super.keyDown(with: event) }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
