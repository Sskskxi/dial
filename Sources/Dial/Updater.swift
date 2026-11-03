import AppKit

/// Checks GitHub Releases for a newer Dial and installs it in place.
enum Updater {
    static let repo = "Sskskxi/dial"

    struct Release {
        let version: String
        let download: URL
        let page: URL
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func isNewer(_ version: String, than other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedDescending
    }

    /// Fetches the latest release. `done` is called on the main queue.
    static func fetchLatest(_ done: @escaping (Result<Release, Error>) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Dial/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result = Result<Release, Error> {
                if let error { throw error }
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data else {
                    throw ToolError("GitHub didn't answer. Try again later.")
                }
                struct Asset: Decodable { let name: String; let browser_download_url: URL }
                struct Payload: Decodable { let tag_name: String; let html_url: URL; let assets: [Asset] }
                let payload = try JSONDecoder().decode(Payload.self, from: data)
                guard let zip = payload.assets.first(where: { $0.name == "Dial.zip" }) else {
                    throw ToolError("The latest release has no Dial.zip")
                }
                let tag = payload.tag_name
                return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                               download: zip.browser_download_url, page: payload.html_url)
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    /// Downloads the release, swaps it in for the running app and relaunches.
    static func install(_ release: Release) {
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app" else { Toast.show("Updates only work from Dial.app"); return }
        guard FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            Toast.show("Can't write to \(app.deletingLastPathComponent().path). Update with install.sh instead.")
            return
        }

        Run.job("Updating to Dial \(release.version)", reveal: false) { progress in
            let dir = try Output.tempDir()
            let zip = dir.appendingPathComponent("Dial.zip")
            try download(release.download, to: zip, progress: progress)
            try Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
            let fresh = dir.appendingPathComponent("Dial.app")
            guard Bundle(url: fresh)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw ToolError("The download doesn't look like Dial")
            }
            try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", fresh.path])

            // Once Dial has quit: move the old copy aside, put the new one in, and reopen.
            // If the copy fails, the old app goes back where it was.
            let script = """
            while kill -0 "$0" 2>/dev/null; do sleep 0.2; done
            mv "$1" "$3/old.app" && { ditto "$2" "$1" || { rm -rf "$1"; mv "$3/old.app" "$1"; }; }
            open "$1"
            rm -rf "$3"
            """
            let swap = Process()
            swap.executableURL = URL(fileURLWithPath: "/bin/sh")
            swap.arguments = ["-c", script, String(ProcessInfo.processInfo.processIdentifier), app.path, fresh.path, dir.path]
            try swap.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            return []
        }
    }

    private static func download(_ url: URL, to destination: URL, progress: @escaping (Double) -> Void) throws {
        let done = DispatchSemaphore(value: 0)
        var failure: Error?
        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
            defer { done.signal() }
            do {
                if let error { throw error }
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw ToolError("Download failed")
                }
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }
        let observer = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted * 0.9) }
        task.resume()
        done.wait()
        observer.invalidate()
        if let failure { throw failure }
    }
}
