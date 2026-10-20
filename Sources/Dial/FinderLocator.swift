import AppKit
import ApplicationServices

/// Finds where Finder's selected item is drawn on screen, using the Accessibility API.
enum FinderLocator {
    private static var askedForPermission = false

    /// Screen point (Cocoa coordinates) at the first selected item's icon, or nil if unknown.
    static func selectedItemPoint() -> NSPoint? {
        guard isTrusted(prompt: true),
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        else { return nil }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        guard var element: AXUIElement = attribute(app, kAXFocusedUIElementAttribute) else { return nil }

        // The selection lives on the focused view (icon grid, list, columns or desktop) or one of its parents.
        for _ in 0..<5 {
            for key in [kAXSelectedChildrenAttribute, kAXSelectedRowsAttribute, kAXSelectedCellsAttribute] {
                if let items: [AXUIElement] = attribute(element, key), let first = items.first, let point = iconPoint(first) {
                    return point
                }
            }
            guard let parent: AXUIElement = attribute(element, kAXParentAttribute) else { break }
            element = parent
        }
        return nil
    }

    private static func isTrusted(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() { return true }
        if prompt && !askedForPermission {
            askedForPermission = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            Toast.show("Allow Dial in Accessibility to open the wheel on the file itself")
        }
        return false
    }

    private static func iconPoint(_ item: AXUIElement) -> NSPoint? {
        // List-view rows span the whole window; the icon sits at the left of the name cell.
        let role: String? = attribute(item, kAXRoleAttribute)
        if role == kAXRowRole, let cells: [AXUIElement] = attribute(item, kAXChildrenAttribute),
           let cell = cells.first, let frame = frame(cell) {
            return cocoaPoint(x: frame.minX + min(frame.width / 2, 24), y: frame.midY)
        }
        guard let frame = frame(item) else { return nil }
        return cocoaPoint(x: frame.midX, y: frame.midY)
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = attribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue, .cgPoint, &position)
        AXValueGetValue(sizeValue, .cgSize, &size)
        return size.width > 0 ? CGRect(origin: position, size: size) : nil
    }

    /// Accessibility uses top-left-origin coordinates relative to the primary screen.
    private static func cocoaPoint(x: CGFloat, y: CGFloat) -> NSPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSPoint(x: x, y: primaryHeight - y)
    }

    private static func attribute<T>(_ element: AXUIElement, _ key: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
