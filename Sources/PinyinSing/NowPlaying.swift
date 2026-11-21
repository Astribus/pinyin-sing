import AppKit
import CryptoKit

/// Watches macOS "Now Playing" (works for 汽水音乐, NetEase, Spotify, YouTube in a browser...).
///
/// Since macOS 15.4 only Apple-signed programs may read Now Playing, so we use
/// mediaremote-adapter (BSD-3-Clause, github.com/ungive/mediaremote-adapter): the
/// system `/usr/bin/perl` loads a small helper framework and prints JSON lines.
@MainActor
final class NowPlayingMonitor: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var adapterError: String?
    /// Album art from the player, when it shares one.
    @Published private(set) var artwork: NSImage?
    private var artworkHash = ""

    // Position = elapsed + (now - stamp) * rate
    private var elapsed: Double = 0
    private var stamp = Date()
    private var rate: Double = 0

    private var process: Process?
    private var buffer = Data()

    func position(at date: Date = Date()) -> Double {
        guard isPlaying else { return elapsed }
        return elapsed + date.timeIntervalSince(stamp) * rate
    }

    func start() {
        guard process == nil else { return }
        guard let paths = Self.adapterPaths() else {
            adapterError = "Couldn't find the Now Playing helper."
            return
        }
        let p = Process()
        // Wrapped in a tiny shell script that stops the helper when this app quits or
        // crashes, so no stray helpers are left running in the background.
        let watchdog = """
        APP="$1"; shift
        /usr/bin/perl "$@" &
        CHILD=$!
        ( while kill -0 "$APP" 2>/dev/null; do sleep 2; done; kill "$CHILD" 2>/dev/null ) &
        wait "$CHILD"
        """
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", watchdog, "sh", String(ProcessInfo.processInfo.processIdentifier),
                       paths.script, paths.framework, "stream",
                       "--no-diff", "--micros", "--debounce=40"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                // The helper can die when players quit; start it again.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.start()
            }
        }
        do {
            try p.run()
            process = p
            adapterError = nil
        } catch {
            adapterError = "Now Playing helper failed to start: \(error.localizedDescription)"
        }
    }

    /// Playback speed the player reports (1 = normal).
    @Published private(set) var playbackRate: Double = 1

    enum Command: String { case togglePlayPause = "2", next = "4", previous = "5" }

    /// Asks the playing app to play/pause or skip. Works with any player that reports to Now Playing.
    func send(_ command: Command) { runOnce(["send", command.rawValue]) }

    /// Jumps the playing song to `seconds`.
    func seek(to seconds: Double) {
        let s = max(0, seconds)
        runOnce(["seek", String(Int64(s * 1_000_000))])
        // Show the jump right away instead of waiting for the player to report it.
        elapsed = s
        stamp = Date()
    }

    /// Changes speed. YouTube in Chrome takes any speed (set on the video itself);
    /// other players only get whole speeds through Now Playing, and many ignore it.
    func setSpeed(_ speed: Double) {
        if track?.bundleID == "com.google.Chrome" {
            let js = "document.querySelectorAll('video').forEach(v=>v.playbackRate=\(String(format: "%.2f", speed)))"
            let script = """
            tell application "Google Chrome"
              repeat with w in windows
                repeat with t in tabs of w
                  if URL of t contains "youtube.com" then execute t javascript "\(js)"
                end repeat
              end repeat
            end tell
            """
            DispatchQueue.global().async {
                var err: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&err)
            }
            return
        }
        runOnce(["speed", String(Int(speed.rounded()))])
    }

    private func runOnce(_ args: [String]) {
        guard let paths = Self.adapterPaths() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [paths.script, paths.framework] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return }
        guard let title = payload["title"] as? String, !title.isEmpty else {
            track = nil
            isPlaying = false
            artwork = nil
            artworkHash = ""
            return
        }
        let micros = { (k: String) -> Double? in (payload[k] as? NSNumber)?.doubleValue }
        let newTrack = Track(
            title: title,
            artist: payload["artist"] as? String ?? "",
            album: payload["album"] as? String ?? "",
            duration: (micros("durationMicros") ?? 0) / 1_000_000,
            bundleID: payload["bundleIdentifier"] as? String ?? ""
        )
        if newTrack != track { track = newTrack }

        let art = payload["artworkData"] as? String ?? ""
        let hash = art.isEmpty ? "" : SHA256.hash(data: Data(art.utf8)).description
        if hash != artworkHash {
            artworkHash = hash
            artwork = Data(base64Encoded: art).flatMap(NSImage.init(data:))
        }

        elapsed = (micros("elapsedTimeMicros") ?? 0) / 1_000_000
        if let ts = micros("timestampEpochMicros") {
            stamp = Date(timeIntervalSince1970: ts / 1_000_000)
        } else {
            stamp = Date()
        }
        rate = micros("playbackRate") ?? 0
        if rate > 0, abs(rate - playbackRate) > 0.01 { playbackRate = rate }
        isPlaying = (payload["playing"] as? Bool ?? false) && rate > 0
    }

    private static func adapterPaths() -> (script: String, framework: String)? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("MediaRemote"))
        }
        // Fallback while developing with `swift run`: the Homebrew copy.
        let cellar = URL(fileURLWithPath: "/opt/homebrew/opt/media-control")
        candidates.append(cellar)
        for base in candidates {
            let script = [base.appendingPathComponent("mediaremote-adapter.pl"),
                          base.appendingPathComponent("lib/media-control/mediaremote-adapter.pl")]
                .first { fm.fileExists(atPath: $0.path) }
            let fw = [base.appendingPathComponent("MediaRemoteAdapter.framework"),
                      base.appendingPathComponent("Frameworks/MediaRemoteAdapter.framework")]
                .first { fm.fileExists(atPath: $0.path) }
            if let s = script, let f = fw {
                return (s.resolvingSymlinksInPath().path, f.resolvingSymlinksInPath().path)
            }
        }
        return nil
    }
}
