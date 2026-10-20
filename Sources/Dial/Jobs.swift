import AppKit

/// Runs file jobs in the background and shows their progress in a small HUD.
enum Run {
    private static let queue = DispatchQueue(label: "dial.jobs", qos: .userInitiated, attributes: .concurrent)
    private static let limiter = DispatchSemaphore(value: 2)
    /// Set by the command-line test mode: print results and exit instead of revealing.
    static var headless = false

    static func job(_ title: String, reveal: Bool = true, _ work: @escaping (_ progress: @escaping (Double) -> Void) throws -> [URL]) {
        let row = JobsHUD.shared.add(title)
        queue.async {
            limiter.wait()
            defer { limiter.signal() }
            do {
                let outputs = try work { p in DispatchQueue.main.async { row.setProgress(p) } }
                DispatchQueue.main.async {
                    row.finish(error: nil)
                    if headless { outputs.forEach { print("OK", $0.path) }; exit(0) }
                    if reveal && !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                }
            } catch {
                DispatchQueue.main.async {
                    row.finish(error: error)
                    if headless { print("FAIL", error.localizedDescription); exit(1) }
                }
            }
        }
    }

    /// Applies `op` to each file in turn, as one job. Failures on some files don't stop the rest.
    static func each(_ urls: [URL], _ title: String, _ op: @escaping (URL, @escaping (Double) -> Void) throws -> [URL]) {
        let label = urls.count > 1 ? "\(title) · \(urls.count) files" : "\(title) · \(urls[0].lastPathComponent)"
        job(label) { progress in
            var outputs: [URL] = [], failures: [String] = []
            for (i, url) in urls.enumerated() {
                do {
                    outputs += try op(url) { p in progress((Double(i) + p) / Double(urls.count)) }
                } catch {
                    failures.append(urls.count > 1 ? "\(url.lastPathComponent): \(error.localizedDescription)" : error.localizedDescription)
                }
                progress(Double(i + 1) / Double(urls.count))
            }
            if !failures.isEmpty {
                let message = failures.count == 1 ? failures[0] : "\(failures.count) files failed. \(failures[0])"
                if outputs.isEmpty { throw ToolError(message) }
                DispatchQueue.main.async { Toast.show(message) }
            }
            return outputs
        }
    }

    /// Single-output convenience over `each`.
    static func each1(_ urls: [URL], _ title: String, _ op: @escaping (URL, @escaping (Double) -> Void) throws -> URL) {
        each(urls, title) { url, progress in [try op(url, progress)] }
    }
}

// MARK: - HUD

final class JobRow: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let bar = NSProgressIndicator()

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .systemRed
        detailLabel.maximumNumberOfLines = 4
        detailLabel.isHidden = true

        let stack = NSStackView(views: [titleLabel, bar, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 280),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setProgress(_ p: Double) { bar.doubleValue = p }

    func finish(error: Error?) {
        bar.doubleValue = 1
        if let error {
            titleLabel.stringValue = "✕ " + titleLabel.stringValue
            detailLabel.stringValue = error.localizedDescription
            detailLabel.isHidden = false
            bar.isHidden = true
        } else {
            titleLabel.stringValue = "✓ " + titleLabel.stringValue
        }
        JobsHUD.shared.relayout()
        DispatchQueue.main.asyncAfter(deadline: .now() + (error == nil ? 1.5 : 8)) { JobsHUD.shared.remove(self) }
    }

    override func mouseDown(with event: NSEvent) { JobsHUD.shared.remove(self) }
}

final class JobsHUD {
    static let shared = JobsHUD()
    private let panel: NSPanel
    private let stack = NSStackView()

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let bg = HUDBackground(frame: panel.contentLayoutRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: bg.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -14),
        ])
        panel.contentView = bg
    }

    func add(_ title: String) -> JobRow {
        let row = JobRow(title: title)
        stack.addArrangedSubview(row)
        relayout()
        return row
    }

    func remove(_ row: JobRow) {
        guard row.superview != nil else { return }
        stack.removeArrangedSubview(row)
        row.removeFromSuperview()
        relayout()
    }

    func relayout() {
        guard !stack.arrangedSubviews.isEmpty, let screen = NSScreen.main?.visibleFrame else {
            panel.orderOut(nil)
            return
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView!.fittingSize
        panel.setFrame(NSRect(x: screen.maxX - size.width - 12, y: screen.maxY - size.height - 12,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }
}
