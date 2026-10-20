import AppKit

let app = NSApplication.shared
let args = CommandLine.arguments

func parseMode(_ name: String) -> WheelMode {
    switch name {
    case "tools": return .tools
    case "actions": return .actions
    case "menu": return .menu
    default: return .formats
    }
}

// Headless mode for testing: Dial --run formats|tools|actions "<item title>" file...
if args.count > 4, args[1] == "--run" {
    let mode = parseMode(args[2])
    let urls = args[4...].map { URL(fileURLWithPath: $0) }
    Run.headless = true
    app.setActivationPolicy(.prohibited)
    DispatchQueue.main.async {
        guard let item = Catalog.items(for: urls, mode: mode).first(where: { $0.title == args[3] }) else {
            print("No item “\(args[3])”. Available:", Catalog.items(for: urls, mode: mode).map(\.title))
            exit(2)
        }
        item.action(urls)
    }
    app.run()
}

// Renders the wheel to a PNG: Dial --preview formats|tools|actions out.png file...
if args.count > 4, args[1] == "--preview" {
    let mode = parseMode(args[2])
    let urls = args[4...].map { URL(fileURLWithPath: $0) }
    let view = WheelView(frame: NSRect(x: 0, y: 0, width: WheelView.size, height: WheelView.size))
    view.configure(items: Catalog.items(for: urls, mode: mode), title: mode.title, subtitle: urls[0].lastPathComponent)
    view.highlighted = 1
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
    exit(0)
}

// Shows the real wheel at screen centre for a few seconds: Dial --show formats|tools|actions file...
if args.count > 3, args[1] == "--show" {
    let mode = parseMode(args[2])
    let urls = args[3...].map { URL(fileURLWithPath: $0) }
    app.setActivationPolicy(.accessory)
    DispatchQueue.main.async {
        let frame = NSScreen.main!.frame
        WheelController.shared.show(urls, mode: mode, at: NSPoint(x: frame.midX, y: frame.midY), dragMode: true)
        WheelController.shared.highlight(1)
        Toast.show("Converted photo.png to JPEG")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
    app.run()
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
