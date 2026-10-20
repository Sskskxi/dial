import Foundation

/// Video and audio operations, all backed by ffmpeg.
enum MediaOps {
    typealias Progress = (Double) -> Void

    static let gifFilter = "fps=12,scale='min(640,iw)':-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4"

    /// Output container for edits: keep the input's when it's a known video/audio type.
    static func editExt(_ url: URL) -> String {
        let ext = normalizedExt(url.pathExtension)
        return FF.codecArgs(ext).isEmpty ? (FileKind.of(url) == .audio ? "m4a" : "mp4") : ext
    }

    private static func encode(_ url: URL, out: URL, before: [String] = [], filters: [String] = [], codec: [String]? = nil,
                               duration: Double? = nil, progress: @escaping Progress) throws -> URL {
        let args = before + ["-i", url.path] + filters + (codec ?? FF.codecArgs(out.pathExtension)) + [out.path]
        do {
            try FF.run(args, duration: duration ?? FF.duration(url), progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    // MARK: Conversion

    static func convert(_ url: URL, to ext: String, progress: @escaping Progress) throws -> URL {
        let out = Output.url(for: url, ext: ext)
        let streams = FF.streams(url)

        if ext == "gif" {
            return try encode(url, out: out, filters: ["-vf", gifFilter, "-loop", "0"], codec: [], progress: progress)
        }
        // Remux without re-encoding when the codecs already fit the new container.
        let videos = streams.filter { $0.type == "video" }.map(\.codec)
        let audios = streams.filter { $0.type == "audio" }.map(\.codec)
        let fitsMP4 = !videos.isEmpty && videos.allSatisfy { ["h264", "hevc", "mpeg4"].contains($0) }
            && audios.allSatisfy { ["aac", "mp3", "alac", "ac3"].contains($0) }
        var copy: [String]?
        if ["mp4", "mov", "m4v"].contains(ext) && fitsMP4 {
            copy = ["-c", "copy", "-sn", "-dn"] + (videos.contains("hevc") ? ["-tag:v", "hvc1"] : [])
                + (ext == "mov" ? [] : ["-movflags", "+faststart"])
        } else if ext == "mkv" {
            copy = ["-c", "copy"]
        }
        if let copy, let result = try? encode(url, out: out, codec: copy, progress: progress) {
            return result
        }
        return try encode(url, out: out, progress: progress)
    }

    // MARK: Compression

    static func compress(_ url: URL, progress: @escaping Progress) throws -> URL {
        if FileKind.of(url) == .audio {
            let ext = ["m4a", "aac"].contains(normalizedExt(url.pathExtension)) ? "m4a" : "mp3"
            let out = Output.url(for: url, ext: ext, suffix: "compressed")
            let codec = ext == "m4a" ? ["-vn", "-c:a", "aac", "-b:a", "96k"] : ["-vn", "-c:a", "libmp3lame", "-b:a", "128k"]
            return try encode(url, out: out, codec: codec, progress: progress)
        }
        let out = Output.url(for: url, ext: "mp4", suffix: "compressed")
        let codec = ["-c:v", "libx264", "-crf", "28", "-preset", "medium", "-pix_fmt", "yuv420p",
                     "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", "-sn", "-dn"]
        return try encode(url, out: out, codec: codec, progress: progress)
    }

    /// Two-pass encode that hits a target file size.
    static func compress(_ url: URL, targetBytes: Int, progress: @escaping Progress) throws -> URL {
        guard targetBytes < fileSize(url) else {
            throw ToolError("\(url.lastPathComponent) is already under \(formatBytes(targetBytes))")
        }
        let duration = FF.duration(url)
        guard duration > 0 else { throw ToolError("Couldn't read the duration of \(url.lastPathComponent)") }
        let totalKbps = Double(targetBytes) * 8 / 1000 * 0.96 / duration

        if FileKind.of(url) == .audio {
            let kbps = Int(min(320, totalKbps))
            guard kbps >= 32 else { throw ToolError("\(formatBytes(targetBytes)) is too small for this audio") }
            let out = Output.url(for: url, ext: "mp3", suffix: "compressed")
            return try encode(url, out: out, codec: ["-vn", "-c:a", "libmp3lame", "-b:a", "\(kbps)k"], progress: progress)
        }

        let hasAudio = FF.streams(url).contains { $0.type == "audio" }
        let audioKbps = hasAudio ? 96.0 : 0
        let videoKbps = Int(totalKbps - audioKbps)
        guard videoKbps >= 50 else { throw ToolError("\(formatBytes(targetBytes)) is too small for this video") }

        let dir = try Output.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("pass").path
        let video = ["-c:v", "libx264", "-b:v", "\(videoKbps)k", "-preset", "medium", "-pix_fmt", "yuv420p", "-passlogfile", log]
        try FF.run(["-i", url.path] + video + ["-pass", "1", "-an", "-f", "mp4", "/dev/null"], duration: duration) { progress($0 * 0.5) }

        let out = Output.url(for: url, ext: "mp4", suffix: "compressed")
        let audio = hasAudio ? ["-c:a", "aac", "-b:a", "96k"] : ["-an"]
        return try encode(url, out: out, codec: video + ["-pass", "2"] + audio + ["-movflags", "+faststart", "-sn", "-dn"],
                          duration: duration) { progress(0.5 + $0 * 0.5) }
    }

    // MARK: Edits

    static func trim(_ url: URL, from start: Double, to end: Double?, progress: @escaping Progress) throws -> URL {
        let out = Output.url(for: url, ext: editExt(url), suffix: "trimmed")
        let length = (end ?? FF.duration(url)) - start
        guard length > 0 else { throw ToolError("End must be after start") }
        return try encode(url, out: out, before: ["-ss", String(start)], filters: ["-t", String(length)],
                          duration: length, progress: progress)
    }

    static func speed(_ url: URL, factor: Double, progress: @escaping Progress) throws -> URL {
        let out = Output.url(for: url, ext: editExt(url), suffix: "\(factor.formatted())x")
        let streams = FF.streams(url)
        let hasVideo = streams.contains { $0.type == "video" && !["mjpeg", "png"].contains($0.codec) }
        let hasAudio = streams.contains { $0.type == "audio" }
        // atempo only accepts 0.5…100 per instance, so chain it for slower speeds.
        var tempo: [String] = [], remaining = factor
        while remaining < 0.5 { tempo.append("atempo=0.5"); remaining /= 0.5 }
        tempo.append("atempo=\(remaining)")

        var graph: [String] = [], maps: [String] = []
        if hasVideo { graph.append("[0:v]setpts=PTS/\(factor)[v]"); maps += ["-map", "[v]"] }
        if hasAudio { graph.append("[0:a]\(tempo.joined(separator: ","))[a]"); maps += ["-map", "[a]"] }
        guard !graph.isEmpty else { throw ToolError("No audio or video found") }
        return try encode(url, out: out, filters: ["-filter_complex", graph.joined(separator: ";")] + maps,
                          duration: FF.duration(url) / factor, progress: progress)
    }

    static func mute(_ url: URL, progress: @escaping Progress) throws -> URL {
        let out = Output.url(for: url, ext: normalizedExt(url.pathExtension), suffix: "muted")
        return try encode(url, out: out, codec: ["-c", "copy", "-an"], progress: progress)
    }

    static func halfSize(_ url: URL, progress: @escaping Progress) throws -> URL {
        let out = Output.url(for: url, ext: editExt(url), suffix: "half")
        return try encode(url, out: out, filters: ["-vf", "scale=trunc(iw/4)*2:trunc(ih/4)*2"], progress: progress)
    }

    static func snapshot(_ url: URL, at time: Double) throws -> URL {
        let out = Output.url(for: url, ext: "png", suffix: "snapshot")
        return try encode(url, out: out, before: ["-ss", String(time)], codec: ["-frames:v", "1"], duration: 0) { _ in }
    }

    static func split(_ url: URL, progress: @escaping Progress) throws -> [URL] {
        let half = FF.duration(url) / 2
        guard half > 0 else { throw ToolError("Couldn't read the duration") }
        // Re-encode rather than stream-copy so the cut lands exactly, not on the nearest keyframe.
        let ext = editExt(url)
        let first = try encode(url, out: Output.url(for: url, ext: ext, suffix: "part 1"), filters: ["-t", String(half)],
                               duration: half) { progress($0 * 0.5) }
        let second = try encode(url, out: Output.url(for: url, ext: ext, suffix: "part 2"), before: ["-ss", String(half)],
                                duration: half) { progress(0.5 + $0 * 0.5) }
        return [first, second]
    }

    static func join(_ urls: [URL], progress: @escaping Progress) throws -> URL {
        let dir = try Output.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = dir.appendingPathComponent("list.txt")
        try urls.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        let out = Output.url(for: urls[0], ext: editExt(urls[0]), name: "Joined")
        let total = urls.map(FF.duration).reduce(0, +)
        return try encode(list, out: out, before: ["-f", "concat", "-safe", "0"], duration: total, progress: progress)
    }

    static func normalize(_ url: URL, progress: @escaping Progress) throws -> URL {
        let out = Output.url(for: url, ext: editExt(url), suffix: "normalized")
        return try encode(url, out: out, filters: ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", FF.sampleRate(url)], progress: progress)
    }

    static func channels(_ url: URL, _ count: Int, progress: @escaping Progress) throws -> URL {
        let out = Output.url(for: url, ext: editExt(url), suffix: count == 1 ? "mono" : "stereo")
        return try encode(url, out: out, filters: ["-ac", String(count)], progress: progress)
    }

    static func stripMetadata(_ url: URL, progress: @escaping Progress) throws -> URL {
        let out = Output.url(for: url, ext: normalizedExt(url.pathExtension), suffix: "clean")
        return try encode(url, out: out, codec: ["-map_metadata", "-1", "-map_chapters", "-1", "-c", "copy"], progress: progress)
    }
}
