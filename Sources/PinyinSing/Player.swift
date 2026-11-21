import AppKit

/// Opens a saved song in the app it came from, behind the dashboard.
/// Each app supports something different:
/// - YouTube (Chrome): the video's address, saved while it played
/// - Spotify: its own track link (spotify:track:…), read from Spotify while it played
/// - NetEase: its `orpheus://` link with the NetEase song id
/// - 汽水音乐: has no link to a song, so it opens the app and puts the song name on the
///   clipboard for its search box
@MainActor
enum Player {
    enum Outcome { case playing, openedApp(String), unavailable }

    static func play(_ song: SavedSong) async -> Outcome {
        guard let app = song.app else { return .unavailable }
        switch app {
        case "com.google.Chrome", "com.apple.Safari":
            // The video it was played from, or a YouTube search for it.
            let link = song.playLink ?? "https://www.youtube.com/results?search_query=" + query(song)
            if let url = URL(string: link) { open(url, in: app); return .playing }
        case "com.spotify.client":
            if let link = song.playLink {
                openApp(app)
                runScript("tell application \"Spotify\" to play track \"\(link)\"")
                return .playing
            }
            if let url = URL(string: "spotify:search:" + query(song)) { open(url, in: app); return .playing }
        case "com.netease.163music":
            var id = song.neteaseID
            if id == nil { id = await LyricsService.neteaseID(title: song.title, artist: song.artist, duration: song.duration ?? 0) }
            if let id, let url = orpheus(id) { open(url, in: app); return .playing }
        default: break
        }
        // No way to open the exact song: open the app and leave the name ready to paste into its search.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(song.title) \(song.artist)", forType: .string)
        openApp(app)
        return .openedApp(Track.name(forBundle: app))
    }

    /// Reads a link to what's playing right now, so the song can be opened again later.
    static func currentLink(for track: Track) -> String? {
        switch track.bundleID {
        case "com.spotify.client":
            return runScript("tell application \"Spotify\" to get spotify url of current track")
        case "com.google.Chrome":
            // The YouTube tab whose title has the song in it (or the front YouTube tab).
            let t = track.title.replacingOccurrences(of: "\"", with: "")
            return runScript("""
            tell application "Google Chrome"
              set best to ""
              repeat with w in windows
                repeat with tb in tabs of w
                  set u to URL of tb
                  if u contains "youtube.com/watch" or u contains "music.youtube.com" then
                    if title of tb contains "\(t)" then return u
                    if best is "" then set best to u
                  end if
                end repeat
              end repeat
              return best
            end tell
            """).flatMap { $0.isEmpty ? nil : $0 }
        default:
            return nil
        }
    }

    private static func query(_ s: SavedSong) -> String {
        "\(s.title) \(s.artist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s.title
    }

    /// Music apps on this Mac that a song can be opened in.
    static var installedApps: [String] {
        ["com.soda.music", "com.netease.163music", "com.google.Chrome", "com.spotify.client"]
            .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
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
