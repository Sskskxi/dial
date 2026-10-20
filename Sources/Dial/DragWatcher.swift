import AppKit

/// Watches for file drags anywhere on screen and opens the wheel when a modifier is held.
///
/// Polls global mouse/keyboard state and the shared drag pasteboard, so it needs no
/// Accessibility or Input Monitoring permission. When macOS withholds the drag
/// pasteboard's contents, it falls back to asking Finder for its selection.
final class DragWatcher {
    private var timer: Timer?
    private let pasteboard = NSPasteboard(name: .drag)
    private var baseline = 0
    private var dragURLs: [URL]?
    private var shownMode: WheelMode?
    private var hideScheduled = false

    // Per-drag state, also used for the diagnostic log.
    private var pressed = false
    private var downLocation = NSPoint.zero
    private var urlSource = "none"
    private var sawModifier = false

    // Modifier-tap state: a quick press-and-release of modifiers with nothing else in between.
    private var tapStart: Date?
    private var tapFlags: CGEventFlags = []

    func start() {
        baseline = pasteboard.changeCount
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.write("Dial started, drag pasteboard access=\(pasteboard.accessBehavior.rawValue) general=\(NSPasteboard.general.accessBehavior.rawValue)")
    }

    private func tick() {
        let mouseDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let wheel = WheelController.shared

        guard mouseDown else {
            if pressed { endPress() }
            checkTap()
            // The drop has been delivered by now (or the drag ended elsewhere): reset.
            if shownMode != nil && wheel.dragMode && !hideScheduled {
                hideScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.hideScheduled = false
                    if !CGEventSource.buttonState(.combinedSessionState, button: .left), wheel.dragMode { wheel.hide() }
                }
            }
            baseline = pasteboard.changeCount
            dragURLs = nil
            shownMode = nil
            return
        }

        tapStart = nil
        if !pressed {
            pressed = true
            downLocation = NSEvent.mouseLocation
            urlSource = "none"
            sawModifier = false
        }

        let mode = currentMode()
        if mode != nil { sawModifier = true }

        // A drag either writes to the drag pasteboard or, at least, moves the pointer while pressed.
        let pasteboardChanged = pasteboard.changeCount != baseline
        let moved = hypot(NSEvent.mouseLocation.x - downLocation.x, NSEvent.mouseLocation.y - downLocation.y) > 8
        guard pasteboardChanged || moved, let mode, mode != shownMode else { return }

        if dragURLs?.isEmpty != false { dragURLs = resolveURLs(pasteboardChanged: pasteboardChanged) }
        guard let urls = dragURLs, !urls.isEmpty else { return }

        let point = wheel.isVisible && wheel.dragMode ? wheel.center : NSEvent.mouseLocation
        if wheel.show(urls, mode: mode, at: point, dragMode: true) { shownMode = mode }
    }

    /// Tapping ⇧ (or ⌥⇧ / ⌘ / ⌥) on its own while Finder is frontmost opens the wheel for the selection;
    /// tapping again closes it.
    private func checkTap() {
        let watched: CGEventFlags = [.maskShift, .maskAlternate, .maskControl, .maskCommand]
        let flags = CGEventSource.flagsState(.combinedSessionState).intersection(watched)
        if !flags.isEmpty {
            if tapStart == nil { tapStart = Date(); tapFlags = [] }
            tapFlags.formUnion(flags)
            return
        }
        guard let start = tapStart else { return }
        tapStart = nil

        // Short hold, and no key press or click since the modifier went down.
        let held = Date().timeIntervalSince(start)
        let source = CGEventSourceStateID.combinedSessionState
        let sinceKey = CGEventSource.secondsSinceLastEventType(source, eventType: .keyDown)
        let sinceClick = min(CGEventSource.secondsSinceLastEventType(source, eventType: .leftMouseDown),
                             CGEventSource.secondsSinceLastEventType(source, eventType: .rightMouseDown))
        guard held < 0.5, sinceKey > held + 0.1, sinceClick > held + 0.1 else { return }

        let mode: WheelMode
        // ⌃ is avoided because double-tapping it is the system Dictation shortcut.
        if tapFlags == .maskCommand {
            mode = .actions
        } else if tapFlags.contains(.maskShift) && tapFlags.contains(.maskAlternate) {
            mode = .tools
        } else if tapFlags == .maskShift {
            mode = .formats
        } else if tapFlags == .maskAlternate {
            mode = .menu
        } else {
            return
        }

        // A single tap closes an open wheel.
        let wheel = WheelController.shared
        if wheel.isVisible && !wheel.dragMode {
            wheel.hide()
            return
        }

        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        let urls = FinderSelection.read()
        Log.write("modifier tap: mode=\(mode) selection=\(urls.count)")
        guard !urls.isEmpty else { return }
        let anchor = FinderLocator.selectedItemPoint()
        Log.write("wheel anchor: \(anchor.map { "file at \($0)" } ?? "mouse pointer")")
        wheel.show(urls, mode: mode, at: anchor ?? NSEvent.mouseLocation, dragMode: false)
    }

    private func currentMode() -> WheelMode? {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        if flags.contains(.maskControl) { return .actions }
        if flags.contains(.maskShift) && flags.contains(.maskAlternate) { return .tools }
        if flags.contains(.maskShift) { return .formats }
        return nil
    }

    private func resolveURLs(pasteboardChanged: Bool) -> [URL] {
        if pasteboardChanged,
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            urlSource = "pasteboard"
            return urls
        }
        // Dragging a file in Finder selects it, so the selection is what's being dragged.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
            let urls = FinderSelection.read()
            urlSource = urls.isEmpty ? "finder-empty" : "finder"
            if urls.isEmpty {
                let names = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
                Log.write("pasteboard read empty; filenames plist=\(String(describing: names)) access=\(pasteboard.accessBehavior.rawValue)")
            }
            return urls
        }
        urlSource = pasteboardChanged ? "pasteboard-empty" : "no-drag"
        return []
    }

    private func endPress() {
        pressed = false
        if sawModifier {
            Log.write("drag with modifier: pasteboardChanged=\(pasteboard.changeCount != baseline) " +
                      "types=\(pasteboard.types?.map(\.rawValue) ?? []) urls=\(dragURLs?.count ?? 0) " +
                      "source=\(urlSource) wheel=\(shownMode.map { "\($0)" } ?? "not shown")")
        }
    }
}

enum FinderSelection {
    private static let script = NSAppleScript(source: """
        tell application "Finder"
            set out to ""
            repeat with f in (get selection)
                set out to out & POSIX path of (f as alias) & linefeed
            end repeat
            return out
        end tell
        """)

    static func read() -> [URL] {
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let error { Log.write("Finder selection failed: \(error)") }
        return (result?.stringValue ?? "")
            .split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}

/// Appends to ~/Library/Logs/Dial.log for troubleshooting.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Dial.log")

    static func write(_ message: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
