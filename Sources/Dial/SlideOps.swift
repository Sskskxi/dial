import AppKit

// MARK: - Presentations (PowerPoint, Keynote, OpenDocument)

/// Converts slide decks with LibreOffice (headless, preferred) or, failing that, Keynote.
enum SlideOps {
    static let installHint = "Install LibreOffice to convert slides: brew install --cask libreoffice"

    /// The binary inside LibreOffice.app comes first: Homebrew's `soffice` is a wrapper script,
    /// and the bundled fonts are found relative to the real binary.
    static var soffice: String? {
        [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice",
        ].first { FileManager.default.isExecutableFile(atPath: $0) } ?? Shell.find("soffice")
    }

    static var keynote: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Keynote")
    }

    /// LibreOffice refuses to run twice on one profile, so conversions take turns.
    private static let lock = NSLock()
    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Dial")
    }
    private static var profile: URL { support.appendingPathComponent("LibreOffice") }

    /// Headless LibreOffice finds fonts through fontconfig, which on macOS only sees LibreOffice's own
    /// fonts — so Korean, Japanese and Chinese text comes out blank. This adds the system fonts and
    /// maps common Windows fonts to their closest Mac equivalents.
    private static func fontConfig(for soffice: String) throws -> URL {
        let bundled = URL(fileURLWithPath: soffice).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/fonts/truetype").path
        func alias(_ families: [String], to mac: String) -> String {
            families.map { "  <alias binding=\"same\"><family>\($0)</family><prefer><family>\(mac)</family></prefer></alias>" }
                .joined(separator: "\n")
        }
        let config = """
        <?xml version="1.0"?>
        <!DOCTYPE fontconfig SYSTEM "fonts.dtd">
        <fontconfig>
          <dir>/System/Library/Fonts</dir>
          <dir>/Library/Fonts</dir>
          <dir>~/Library/Fonts</dir>
          <dir>\(bundled)</dir>
          <include ignore_missing="yes">\(bundled)/fc_local.conf</include>
          <cachedir>\(support.appendingPathComponent("fontconfig-cache").path)</cachedir>
        \(alias(["맑은 고딕", "Malgun Gothic", "굴림", "Gulim", "돋움", "Dotum", "나눔고딕", "NanumGothic"], to: "Apple SD Gothic Neo"))
        \(alias(["바탕", "Batang", "궁서", "Gungsuh", "나눔명조", "NanumMyeongjo"], to: "AppleMyungjo"))
        \(alias(["ＭＳ Ｐゴシック", "MS PGothic", "MS Gothic", "Meiryo", "Yu Gothic", "游ゴシック"], to: "Hiragino Sans"))
        \(alias(["宋体", "SimSun", "微软雅黑", "Microsoft YaHei", "DengXian", "等线"], to: "PingFang SC"))
        \(alias(["新細明體", "PMingLiU", "微軟正黑體", "Microsoft JhengHei"], to: "PingFang TC"))
          <alias><family>sans-serif</family><prefer><family>Helvetica Neue</family><family>Apple SD Gothic Neo</family>
            <family>Hiragino Sans</family><family>PingFang SC</family></prefer></alias>
        </fontconfig>
        """
        let url = support.appendingPathComponent("fonts.conf")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if (try? String(contentsOf: url, encoding: .utf8)) != config {
            try config.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Saves the deck as `ext` ("pdf" or "pptx") next to the original.
    static func convert(_ url: URL, to ext: String) throws -> URL {
        let dir = try Output.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = Output.url(for: url, ext: ext)
        try FileManager.default.moveItem(at: try export(url, to: ext, in: dir), to: out)
        return out
    }

    /// One image per slide, rendered from a PDF export.
    static func toImages(_ url: URL, ext: String) throws -> [URL] {
        let dir = try Output.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        return try PDFOps.toImages(try export(url, to: "pdf", in: dir), ext: ext, like: url)
    }

    /// Exports into `dir` and returns the new file.
    private static func export(_ url: URL, to ext: String, in dir: URL) throws -> URL {
        if let soffice { return try libreOffice(soffice, url, to: ext, in: dir) }
        if keynote != nil { return try viaKeynote(url, to: ext, in: dir) }
        throw ToolError(installHint)
    }

    private static func libreOffice(_ exe: String, _ url: URL, to ext: String, in dir: URL) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        // Copy under a plain name: soffice mangles some characters in output names.
        let input = dir.appendingPathComponent("deck." + url.pathExtension.lowercased())
        try FileManager.default.copyItem(at: url, to: input)
        try Shell.run(exe, ["-env:UserInstallation=" + profile.absoluteString, "--headless", "--norestore",
                            "--nolockcheck", "--convert-to", ext, "--outdir", dir.path, input.path],
                      env: ["FONTCONFIG_FILE": try fontConfig(for: exe).path])
        let out = dir.appendingPathComponent("deck." + ext)
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw ToolError("LibreOffice couldn't convert \(url.lastPathComponent)")
        }
        return out
    }

    private static func viaKeynote(_ url: URL, to ext: String, in dir: URL) throws -> URL {
        let out = dir.appendingPathComponent("deck." + ext)
        let format = ext == "pdf" ? "PDF" : "Microsoft PowerPoint"
        let script = """
        on run argv
            tell application "Keynote"
                set theDoc to open (POSIX file (item 1 of argv))
                export theDoc to (POSIX file (item 2 of argv)) as \(format)
                close theDoc saving no
            end tell
        end run
        """
        try Shell.run("/usr/bin/osascript", ["-e", script, url.path, out.path])
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw ToolError("Keynote couldn't convert \(url.lastPathComponent)")
        }
        return out
    }
}
