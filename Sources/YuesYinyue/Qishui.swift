import Foundation

/// Lyrics from 汽水音乐's public share page. Every 汽水音乐 share link points at a track id, and the
/// share page's data includes the full lyrics with a time for every character (KRC).
/// 汽水音乐 doesn't tell macOS the track id, so the user copies the song's share link once.
enum Qishui {
    struct Result {
        var song: SavedSong
        var title: String
        var artist: String
        var duration: Double
    }

    /// True if the text looks like a 汽水音乐 link (or a bare track id).
    static func looksLikeLink(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.contains("qishui.") || t.contains("luna.douyin.com") || t.range(of: #"^\d{17,20}$"#, options: .regularExpression) != nil
    }

    static func fetch(link text: String) async throws -> Result? {
        guard let id = try await trackID(from: text) else { return nil }
        var c = URLComponents(string: "https://beta-luna.douyin.com/luna/h5/seo_track")!
        c.queryItems = [.init(name: "device_platform", value: "web"), .init(name: "track_id", value: id)]
        var r = URLRequest(url: c.url!, timeoutInterval: 10)
        r.setValue(LyricsService.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await LyricsService.session.data(for: r)
        let page = try JSONDecoder().decode(SEO.self, from: data)
        guard let track = page.seo_track?.track, let content = page.lyric?.content else { return nil }
        let lines = page.lyric?.type == "krc" ? LyricsParser.krc(content) : LyricsParser.lrc(content)
        guard !lines.isEmpty else { return nil }
        let artist = track.artists?.map(\.name).joined(separator: " / ") ?? ""
        let duration = (track.duration ?? 0) / 1000
        let song = SavedSong(id: SongKey.make(title: track.name, artist: artist), title: track.name, artist: artist,
                             duration: duration > 0 ? duration : nil, source: "汽水音乐",
                             timing: lines.contains { $0.words != nil } ? .word : .line, lines: lines)
        return Result(song: song, title: track.name, artist: artist, duration: duration)
    }

    /// Accepts a full link, a short share link (followed to its real address), or a bare id.
    static func trackID(from text: String) async throws -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = firstMatch(#"^(\d{17,20})$"#, in: t) { return id }
        if let id = id(inURL: t) { return id }
        guard let urlText = firstMatch(#"(https?://[^\s，。]+)"#, in: t), let url = URL(string: urlText) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.setValue(LyricsService.userAgent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await LyricsService.session.data(for: r)
        return response.url.flatMap { id(inURL: $0.absoluteString) }
    }

    private static func id(inURL s: String) -> String? {
        firstMatch(#"track_id=(\d{10,})"#, in: s) ?? firstMatch(#"/track/(\d{10,})"#, in: s)
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private struct SEO: Decodable {
        struct Lyric: Decodable { let content: String?; let type: String? }
        struct Artist: Decodable { let name: String }
        struct Track: Decodable { let name: String; let artists: [Artist]?; let duration: Double? }
        struct Wrap: Decodable { let track: Track? }
        let lyric: Lyric?
        let seo_track: Wrap?
    }
}
