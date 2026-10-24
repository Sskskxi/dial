import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = DragWatcher()
    private var dropZone: DropZone?
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let iconMenu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        applyIcon()
        statusItem.menu = buildMenu()
        watcher.start()

        if Shell.find("ffmpeg") == nil {
            Toast.show("Dial: video & audio need ffmpeg — run “brew install ffmpeg”")
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for hint in ["Select files in Finder, then double-tap:", "    ⇧ ⇧  Convert", "    ⌥⇧ ⌥⇧  Tools", "    ⌘ ⌘  Actions", "Triple-tap ⇧ ⇧ ⇧  File menu (like right-click)",
                     "Tap once to close", "…or hold ⇧ / ⌥⇧ / ⌃ while dragging a file"] {
            let item = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Drop Window", action: #selector(openDropZone), keyEquivalent: "d").target = self
        menu.addItem(withTitle: "Show/Hide Floating Shelf", action: #selector(toggleShelf), keyEquivalent: "f").target = self
        menu.addItem(.separator())
        let iconItem = NSMenuItem(title: "Menu Bar Icon", action: nil, keyEquivalent: "")
        iconItem.submenu = iconMenu
        menu.addItem(iconItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dial", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        rebuildIconMenu()
    }

    private func applyIcon() {
        statusItem.button?.image = MenuBarIcon.image(for: MenuBarIcon.current)
            ?? MenuBarIcon.image(for: MenuBarIcon.defaultID)
    }

    private func rebuildIconMenu() {
        iconMenu.removeAllItems()
        let grid = NSMenuItem()
        grid.view = IconGridView(ids: MenuBarIcon.allIDs, current: MenuBarIcon.current) { [weak self] id in
            MenuBarIcon.current = id
            self?.applyIcon()
        }
        iconMenu.addItem(grid)
        iconMenu.addItem(.separator())
        if FileManager.default.fileExists(atPath: MenuBarIcon.customImageURL.path) {
            let custom = NSMenuItem(title: "Use My Custom Image", action: #selector(useCustomIcon), keyEquivalent: "")
            custom.image = MenuBarIcon.image(for: "custom", size: 16)
            custom.state = MenuBarIcon.current == "custom" ? .on : .off
            custom.target = self
            iconMenu.addItem(custom)
        }
        iconMenu.addItem(withTitle: "Choose Custom Image…", action: #selector(chooseCustomIcon), keyEquivalent: "").target = self
        iconMenu.addItem(withTitle: "Reset to Default", action: #selector(resetIcon), keyEquivalent: "").target = self
    }

    @objc private func useCustomIcon() {
        MenuBarIcon.current = "custom"
        applyIcon()
    }

    @objc private func chooseCustomIcon() {
        if MenuBarIcon.chooseCustomImage() { useCustomIcon() }
    }

    @objc private func resetIcon() {
        MenuBarIcon.current = MenuBarIcon.defaultID
        applyIcon()
    }

    @objc private func openDropZone() {
        if dropZone == nil { dropZone = DropZone() }
        dropZone?.show()
    }

    @objc private func toggleShelf() { Shelf.shared.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Toast.show("Couldn't change login item: \(error.localizedDescription)")
        }
    }
}

/// A small window you can drop files on when dragging with modifiers isn't convenient.
final class DropZone: NSObject {
    private let window: NSPanel

    override init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 180),
                         styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.title = "Dial"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.level = .floating
        let glass = HUDBackground(frame: NSRect(x: 0, y: 0, width: 260, height: 180))
        glass.cornerRadius = 26
        let zone = DropZoneView(frame: glass.bounds)
        zone.autoresizingMask = [.width, .height]
        glass.addSubview(zone)
        window.contentView = glass
        window.center()
    }

    func show() {
        window.orderFrontRegardless()
    }
}

private final class DropZoneView: NSView {
    private var targeted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 16, dy: 16).offsetBy(dx: 0, dy: -6), xRadius: 16, yRadius: 16)
        box.setLineDash([6, 4], count: 2, phase: 0)
        box.lineWidth = 2
        (targeted ? WheelView.accent : NSColor.tertiaryLabelColor).setStroke()
        let icon = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 22, weight: .regular).applying(.init(paletteColors: [targeted ? WheelView.accent : .secondaryLabelColor])))
        icon?.draw(in: NSRect(x: bounds.midX - 11, y: bounds.midY + 14, width: 22, height: 24))
        if targeted { WheelView.accent.withAlphaComponent(0.12).setFill(); box.fill() }
        box.stroke()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                                                    .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
        let hint: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5),
                                                   .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
        ("Drop files here" as NSString).draw(in: NSRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20), withAttributes: title)
        ("Hold ⌥ for Tools, ⌃ for Actions" as NSString)
            .draw(in: NSRect(x: 0, y: bounds.midY - 30, width: bounds.width, height: 16), withAttributes: hint)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { targeted = true; return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        targeted = false
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        let flags = NSEvent.modifierFlags
        let mode: WheelMode = flags.contains(.control) ? .actions : flags.contains(.option) ? .tools : .formats
        let point = NSEvent.mouseLocation
        DispatchQueue.main.async {
            WheelController.shared.show(urls, mode: mode, at: point, dragMode: false)
        }
        return true
    }
}
