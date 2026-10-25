import Foundation
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Version comparison (pure, no AppKit — unit tested)

/// A dotted numeric version like `1.0.3`. Any trailing non-numeric suffix
/// (e.g. the local `1.0.0-dev` build) is treated as a pre-release of the
/// numeric part, so a dev build never claims to be newer than a real release.
struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]
    /// True when the string carried a suffix the numeric parse dropped
    /// (e.g. `-dev`, `-beta`). A suffixed build sorts *below* the bare number.
    let hasPreReleaseSuffix: Bool

    init(_ raw: String) {
        // Drop a leading "v" and anything from the first "-"/"+" onward.
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        let core: Substring
        if let cut = s.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            core = s[s.startIndex..<cut]
            hasPreReleaseSuffix = cut < s.endIndex && s.distance(from: cut, to: s.endIndex) > 0
        } else {
            core = Substring(s)
            hasPreReleaseSuffix = false
        }
        let parsed = core.split(separator: ".").map { Int($0) ?? 0 }
        components = parsed.isEmpty ? [0] : parsed
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let n = max(lhs.components.count, rhs.components.count)
        for i in 0..<n {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        // Equal numeric core: a pre-release suffix is older than the bare release.
        if lhs.hasPreReleaseSuffix != rhs.hasPreReleaseSuffix {
            return lhs.hasPreReleaseSuffix && !rhs.hasPreReleaseSuffix
        }
        return false
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    var description: String { components.map(String.init).joined(separator: ".") }
}

/// Decodes just the fields we need from the GitHub "latest release" payload.
struct LatestRelease {
    let tag: String
    let version: AppVersion
    let htmlURL: String
    let assetName: String
    let assetDownloadURL: String
    /// Expected digest as a lowercase hex sha256, or nil if the API omitted it.
    let assetSHA256: String?

    /// Parse from the raw JSON the GitHub releases API returns. Pure, testable.
    init?(json: [String: Any]) {
        guard let tag = json["tag_name"] as? String,
              let html = json["html_url"] as? String,
              let assets = json["assets"] as? [[String: Any]] else { return nil }
        // Pick the .zip app bundle asset.
        guard let zip = assets.first(where: {
            ($0["name"] as? String)?.hasSuffix(".zip") == true
        }),
            let name = zip["name"] as? String,
            let dl = zip["browser_download_url"] as? String
        else { return nil }
        self.tag = tag
        self.version = AppVersion(tag)
        self.htmlURL = html
        self.assetName = name
        self.assetDownloadURL = dl
        if let digest = zip["digest"] as? String {
            // Format is "sha256:<hex>".
            self.assetSHA256 = digest
                .replacingOccurrences(of: "sha256:", with: "")
                .lowercased()
        } else {
            self.assetSHA256 = nil
        }
    }
}

// MARK: - Update checker (AppKit side)

#if canImport(AppKit)

@MainActor
final class UpdateChecker: ObservableObject {
    static let releasesAPI =
        URL(string: "https://api.github.com/repos/g4bcloud/iPaint/releases/latest")!

    private let skipKey = "SkippedUpdateVersion"

    /// The current running version from the bundle's Info.plist.
    let currentVersion: AppVersion = {
        let s = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return AppVersion(s ?? "1.0.0-dev")
    }()

    /// Run once, shortly after launch. Silent on any failure — this is a
    /// nice-to-have, not something worth interrupting the user with an error.
    func checkOnLaunch() {
        Task { await self.check() }
    }

    private func check() async {
        guard let latest = await fetchLatest() else { return }
        guard latest.version > currentVersion else { return }
        // Honour a per-version skip.
        if UserDefaults.standard.string(forKey: skipKey) == latest.tag { return }
        presentPrompt(for: latest)
    }

    private func fetchLatest() async -> LatestRelease? {
        var req = URLRequest(url: Self.releasesAPI)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("iPaint-update-check", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return LatestRelease(json: obj)
    }

    // MARK: Prompt

    private func presentPrompt(for latest: LatestRelease) {
        let alert = NSAlert()
        alert.messageText = "A new version of iPaint is available"
        alert.informativeText =
            "iPaint \(latest.version) is available — you have \(currentVersion). "
            + "Update now and iPaint will replace itself and relaunch."
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await self.performUpdate(latest) }
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(latest.tag, forKey: skipKey)
        default:
            break
        }
    }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Update failed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Download + verify + self-replace

    private func performUpdate(_ latest: LatestRelease) async {
        // The app must live somewhere we can actually overwrite. If it is still
        // inside the downloaded zip, a read-only volume, or a quarantined temp
        // dir, tell the user to move it to Applications first.
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            fail("iPaint is not running from an .app bundle, so it can't replace itself. "
                 + "Download the update from the Releases page instead.")
            return
        }
        let installDir = bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: installDir.path) else {
            fail("iPaint can't update itself here because “\(installDir.path)” is read-only. "
                 + "Move iPaint to your Applications folder and try again.")
            return
        }

        guard let dlURL = URL(string: latest.assetDownloadURL) else {
            fail("The release download link was malformed.")
            return
        }

        // 1. Download the zip.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iPaint-update-\(UUID().uuidString)")
        let zipURL = tmpDir.appendingPathComponent(latest.assetName)
        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            var req = URLRequest(url: dlURL)
            req.timeoutInterval = 120
            req.setValue("iPaint-update-check", forHTTPHeaderField: "User-Agent")
            let (fileURL, resp) = try await URLSession.shared.download(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                fail("Couldn't download the update (server returned an error).")
                return
            }
            try FileManager.default.moveItem(at: fileURL, to: zipURL)
        } catch {
            fail("Couldn't download the update: \(error.localizedDescription)")
            return
        }

        // 2. Verify the SHA-256 against the digest the API published, if any.
        if let expected = latest.assetSHA256 {
            guard let actual = Self.sha256Hex(ofFileAt: zipURL), actual == expected else {
                fail("The downloaded update failed its integrity check and was discarded.")
                try? FileManager.default.removeItem(at: tmpDir)
                return
            }
        }

        // 3. Unpack with ditto (preserves the bundle + resource forks).
        let unpackDir = tmpDir.appendingPathComponent("unpacked")
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, unpackDir.path]) == 0,
              let newApp = try? FileManager.default.contentsOfDirectory(
                at: unpackDir, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
        else {
            fail("The downloaded update couldn't be unpacked.")
            try? FileManager.default.removeItem(at: tmpDir)
            return
        }

        // 4. Verify the new bundle's code signature before trusting it.
        guard Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) == 0 else {
            fail("The downloaded update's signature couldn't be verified and was discarded.")
            try? FileManager.default.removeItem(at: tmpDir)
            return
        }

        // 5. Hand off to a detached helper that waits for us to quit, swaps the
        //    bundle, relaunches, and cleans up. Then terminate ourselves.
        launchReplaceHelper(newApp: newApp, installedApp: bundleURL, tmpDir: tmpDir)
        NSApp.terminate(nil)
    }

    /// Spawns a `/bin/sh` script that outlives this process.
    private func launchReplaceHelper(newApp: URL, installedApp: URL, tmpDir: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Wait for our PID to disappear, then ditto the new bundle over the old
        // one, reopen it, and remove the temp dir. Quoting guards paths with spaces.
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        /usr/bin/ditto '\(newApp.path)' '\(installedApp.path)'
        /usr/bin/open '\(installedApp.path)'
        /bin/rm -rf '\(tmpDir.path)'
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
        // Deliberately not waited on — it must survive our termination.
    }

    // MARK: Small process + hashing helpers

    @discardableResult
    private static func run(_ launchPath: String, _ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return -1
        }
    }

    /// Streams the file through SHA-256 so a large zip never loads fully into memory.
    static func sha256Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while case let chunk = handle.readData(ofLength: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

#endif
