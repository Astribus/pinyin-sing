import AppKit

/// Opens a saved song on the platform it was last played on, behind the dashboard.
/// Each platform supports something different:
/// - YouTube: the video's address (saved while it played), or a YouTube search
/// - Spotify: the Spotify app with its track link or a search; without the app, Spotify's web player
/// - NetEase: its `orpheus://` link with the NetEase song id
/// - 汽水音乐: has no link to a song, so it opens the app and puts the song name on the
///   clipboard for its search box
@MainActor
enum Player {
    enum Outcome { case playing(String), openedApp(String), unavailable }

    static let spotifyApp = "com.spotify.client"
    static var hasSpotifyApp: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: spotifyApp) != nil }

    static func play(_ song: SavedSong) async -> Outcome {
        guard let platform = song.app else { return .unavailable }
        let link = song.links?[platform] ?? song.playLink
        switch platform {
        case "youtube":
            let target = link ?? "https://www.youtube.com/results?search_query=" + query(song)
            if let url = URL(string: target) { openInBrowser(url); return .playing("YouTube") }
        case "spotify":
            if hasSpotifyApp {
                if let link, link.hasPrefix("spotify:") {
                    openApp(spotifyApp)
                    runScript("tell application \"Spotify\" to play track \"\(link)\"")
                    return .playing("Spotify")
                }
                if let url = URL(string: "spotify:search:" + query(song)) { open(url, in: spotifyApp); return .playing("Spotify") }
            }
            let web = link.flatMap { $0.hasPrefix("http") ? $0 : nil } ?? "https://open.spotify.com/search/" + query(song)
            if let url = URL(string: web) { openInBrowser(url); return .playing("Spotify") }
        case "netease":
            var id = song.neteaseID
            if id == nil { id = await LyricsService.neteaseID(title: song.title, artist: song.artist, duration: song.duration ?? 0) }
            if let id, let url = orpheus(id) { open(url, in: "com.netease.163music"); return .playing("NetEase") }
        default: break
        }
        // No way to open the exact song: open the app and leave the name ready to paste into its search.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(song.title) \(song.artist)", forType: .string)
        openApp(bundle(for: platform))
        return .openedApp(Platform.name(platform))
    }

    private static func bundle(for platform: String) -> String {
        switch platform {
        case "qishui": return "com.soda.music"
        case "netease": return "com.netease.163music"
        case "spotify": return spotifyApp
        case "applemusic": return "com.apple.Music"
        default: return platform
        }
    }

    /// Platforms a song can be opened on from this Mac (for the "Open in…" chooser).
    static var choosablePlatforms: [String] {
        var out: [String] = []
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.soda.music") != nil { out.append("qishui") }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.netease.163music") != nil { out.append("netease") }
        out += ["spotify", "youtube"]
        return out
    }

    /// Which platform a track is really on, and a link back to it.
    /// For a browser this looks at its tabs: the one whose title has the song in it decides
    /// (open.spotify.com → Spotify, youtube.com → YouTube); if none does, any Spotify or YouTube tab.
    static func identify(_ track: Track) -> (platform: String, link: String?) {
        let platform = Platform.from(bundle: track.bundleID)
        if track.bundleID == spotifyApp {
            return ("spotify", runScript("tell application \"Spotify\" to get spotify url of current track"))
        }
        guard platform == "browser" else { return (platform, nil) }
        let tabs = browserTabs(track.bundleID)
        let title = TitleCleaner.title(track.title).lowercased()
        func kind(_ url: String) -> String? {
            if url.contains("open.spotify.com") { return "spotify" }
            if url.contains("youtube.com") || url.contains("youtu.be") { return "youtube" }
            if url.contains("music.163.com") { return "netease" }
            return nil
        }
        let matching = tabs.filter { !title.isEmpty && $0.title.lowercased().contains(title) }
        if let hit = matching.first(where: { kind($0.url) != nil }), let k = kind(hit.url) {
            return (k, link(for: k, url: hit.url))
        }
        // No tab names the song: go by which site is open, but don't save a link, since we
        // can't tell which tab is the one playing.
        for k in ["spotify", "youtube"] where tabs.contains(where: { kind($0.url) == k }) {
            return (k, nil)
        }
        return ("browser", nil)
    }

    /// Only links that point at one song are worth saving.
    private static func link(for platform: String, url: String) -> String? {
        switch platform {
        case "youtube": return url.contains("watch") || url.contains("youtu.be") ? url : nil
        case "spotify": return url.contains("/track/") ? url : nil
        default: return nil
        }
    }

    private static func browserTabs(_ bundleID: String) -> [(url: String, title: String)] {
        let script: String
        switch bundleID {
        case "com.apple.Safari":
            script = """
            tell application "Safari"
              set out to ""
              repeat with w in windows
                repeat with t in tabs of w
                  set out to out & (URL of t) & tab & (name of t) & linefeed
                end repeat
              end repeat
              return out
            end tell
            """
        default:
            let name = bundleID == "com.google.Chrome" ? "Google Chrome" : (NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent ?? "Google Chrome")
            script = """
            tell application "\(name)"
              set out to ""
              repeat with w in windows
                repeat with t in tabs of w
                  set out to out & (URL of t) & tab & (title of t) & linefeed
                end repeat
              end repeat
              return out
            end tell
            """
        }
        return (runScript(script) ?? "").split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    private static func openInBrowser(_ url: URL) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.open(url, configuration: cfg)
    }

    private static func query(_ s: SavedSong) -> String {
        "\(s.title) \(s.artist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s.title
    }

    private static func orpheus(_ id: Int) -> URL? {
        let json = #"{"type":"song","id":"\#(id)","cmd":"play"}"#
        return URL(string: "orpheus://" + Data(json.utf8).base64EncodedString())
    }

    private static func open(_ url: URL, in bundleID: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSWorkspace.shared.open(url); return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false   // stay behind the dashboard
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg)
    }

    private static func openApp(_ bundleID: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: cfg)
    }

    @discardableResult
    private static func runScript(_ source: String) -> String? {
        var err: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue
    }
}
