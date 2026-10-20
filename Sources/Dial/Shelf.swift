import AppKit

/// A floating shelf that holds files so they can be dragged out later.
final class Shelf {
    static let shared = Shelf()

    private let panel: NSPanel
    private let stack = NSStackView()
    private(set) var urls: [URL] = []

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 132, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let bg = ShelfDropView(frame: panel.contentLayoutRect)
        let header = NSTextField(labelWithString: "Floating")
        header.font = .systemFont(ofSize: 11, weight: .bold)
        header.textColor = .secondaryLabelColor
        let clear = NSButton(title: "Clear", target: nil, action: nil)
        clear.bezelStyle = .inline
        clear.controlSize = .mini
        clear.target = self
        clear.action = #selector(clearAll)
        let top = NSStackView(views: [header, NSView(), clear])
        top.orientation = .horizontal

        stack.orientation = .vertical
        stack.spacing = 6
        let outer = NSStackView(views: [top, stack])
        outer.orientation = .vertical
        outer.alignment = .centerX
        outer.spacing = 8
        outer.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 10),
            outer.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -10),
            outer.topAnchor.constraint(equalTo: bg.topAnchor, constant: 8),
            outer.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -10),
            top.widthAnchor.constraint(equalToConstant: 112),
        ])
        panel.contentView = bg
    }

    func add(_ new: [URL]) {
        for url in new where !urls.contains(url) { urls.append(url) }
        rebuild()
    }

    func remove(_ url: URL) {
        urls.removeAll { $0 == url }
        rebuild()
    }

    @objc private func clearAll() {
        urls.removeAll()
        rebuild()
    }

    func toggle() {
        if panel.isVisible { panel.orderOut(nil) } else { rebuild(force: true) }
    }

    private func rebuild(force: Bool = false) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        urls.forEach { stack.addArrangedSubview(ShelfItemView(url: $0)) }
        if urls.isEmpty && !force {
            panel.orderOut(nil)
            return
        }
        let wasVisible = panel.isVisible
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView!.fittingSize
        let height = max(size.height, 90)
        if wasVisible {
            // Keep the top edge where the user put it.
            let top = panel.frame.maxY
            panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: 132, height: height), display: true)
        } else if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.maxX - 132 - 16, y: screen.midY - height / 2, width: 132, height: height), display: true)
        }
        panel.orderFrontRegardless()
    }
}

private final class ShelfDropView: HUDBackground {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingSource is ShelfItemView ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return false }
        Shelf.shared.add(urls)
        return true
    }
}

private final class ShelfItemView: NSView, NSDraggingSource {
    let url: URL
    private let icon: NSImageView

    init(url: URL) {
        self.url = url
        icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        let label = NSTextField(labelWithString: url.lastPathComponent)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .labelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")!,
                             target: nil, action: nil)
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(removeSelf)

        [icon, label, close].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 112),
            icon.topAnchor.constraint(equalTo: topAnchor),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            close.topAnchor.constraint(equalTo: topAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        toolTip = url.path
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeSelf() { Shelf.shared.remove(url) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { NSWorkspace.shared.open(url) }
    }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(icon.frame, contents: icon.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .link, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == .move { Shelf.shared.remove(url) }
    }
}
