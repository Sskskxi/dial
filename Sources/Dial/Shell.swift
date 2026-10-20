import Foundation

enum Shell {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    static func find(_ name: String) -> String? {
        searchPaths.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func require(_ name: String, brew formula: String) throws -> String {
        guard let path = find(name) else {
            throw ToolError("\(name) not found. Install it with: brew install \(formula)")
        }
        return path
    }

    /// Runs a process and returns its stdout. `onLine` receives stdout lines as they arrive.
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil, onLine: ((String) -> Void)? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let lock = NSLock()
        var output = Data(), errors = Data(), pending = ""
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock(); output.append(data); lock.unlock()
            guard let onLine, let text = String(data: data, encoding: .utf8) else { return }
            pending += text
            while let nl = pending.firstIndex(of: "\n") {
                onLine(String(pending[..<nl]))
                pending.removeSubrange(...nl)
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            lock.lock(); errors.append(data); lock.unlock()
        }

        try process.run()
        process.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        output.append(out.fileHandleForReading.readDataToEndOfFile())
        errors.append(err.fileHandleForReading.readDataToEndOfFile())
        lock.unlock()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors, as: UTF8.self)
                .split(separator: "\n").suffix(2).joined(separator: "\n")
            throw ToolError("\(process.executableURL!.lastPathComponent) failed: \(message)")
        }
        return String(decoding: output, as: UTF8.self)
    }
}

// MARK: - ffmpeg

enum FF {
    struct Stream { let codec: String; let type: String }

    static func run(_ args: [String], duration: Double, progress: @escaping (Double) -> Void) throws {
        let ffmpeg = try Shell.require("ffmpeg", brew: "ffmpeg")
        try Shell.run(ffmpeg, ["-hide_banner", "-y", "-nostdin", "-progress", "pipe:1", "-nostats"] + args) { line in
            if duration > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                progress(min(1, max(0, us / 1e6 / duration)))
            }
        }
    }

    private static func probe(_ args: [String]) -> String {
        guard let ffprobe = Shell.find("ffprobe"),
              let out = try? Shell.run(ffprobe, ["-v", "error"] + args) else { return "" }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func duration(_ url: URL) -> Double {
        Double(probe(["-show_entries", "format=duration", "-of", "default=nw=1:nk=1", url.path])) ?? 0
    }

    static func streams(_ url: URL) -> [Stream] {
        probe(["-show_entries", "stream=codec_name,codec_type", "-of", "csv=p=0", url.path])
            .split(separator: "\n").compactMap { line in
                let parts = line.split(separator: ",").map(String.init)
                return parts.count >= 2 ? Stream(codec: parts[0], type: parts[1]) : nil
            }
    }

    static func sampleRate(_ url: URL) -> String {
        let rate = probe(["-select_streams", "a:0", "-show_entries", "stream=sample_rate", "-of", "default=nw=1:nk=1", url.path])
        return rate.isEmpty ? "48000" : rate
    }

    static func info(_ url: URL) -> String {
        probe(["-show_format", "-show_streams", "-pretty", url.path])
    }

    static let h264 = ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"]

    /// Encoder arguments for a given output extension.
    static func codecArgs(_ ext: String) -> [String] {
        switch ext {
        case "mp4", "m4v": return h264 + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-sn", "-dn"]
        case "mov": return h264 + ["-c:a", "aac", "-b:a", "192k", "-sn", "-dn"]
        case "mkv": return h264 + ["-c:a", "aac", "-b:a", "192k"]
        case "webm": return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4",
                             "-c:a", "libopus", "-b:a", "128k", "-sn"]
        case "avi": return ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3", "-sn"]
        case "wmv": return ["-c:v", "wmv2", "-b:v", "5M", "-c:a", "wmav2", "-b:a", "192k", "-sn"]
        case "mp3": return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a", "aac": return ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case "wav": return ["-vn", "-c:a", "pcm_s16le"]
        case "flac": return ["-vn", "-c:a", "flac"]
        case "ogg": return ["-vn", "-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-q:a", "6"]
        case "opus": return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case "aiff": return ["-vn", "-c:a", "pcm_s16be"]
        default: return []
        }
    }
}
