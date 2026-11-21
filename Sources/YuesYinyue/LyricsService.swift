import Foundation

/// Finds timed lyrics online. Tries NetEase first (best Chinese catalog), then LRCLIB.
enum LyricsService {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) YuesYinyue/0.1"

    static func find(for track: Track) async -> SavedSong? {
        let artist = TitleCleaner.artist(track.artist)
        for title in TitleCleaner.searchVariants(track.title) {
            if let s = try? await netease(title: title, artist: artist, duration: track.duration) {
                return s.with(track: track)
            }
            if let s = try? await lrclib(title: title, artist: artist, duration: track.duration) {
                return s.with(track: track)
            }
        }
        return nil
    }

    /// Splits "胖虎(董欣怡), 牧言 MuYan" into comparable names: full-width characters made
    /// half-width (（ → (), lowercased, split on , / & 、 feat., with and without the part in brackets.
    static func artistParts(_ s: String) -> [String] {
        let half = (s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s).lowercased()
        let pieces = half.replacingOccurrences(of: #"\s*(,|/|&|、|;|\bfeat\.?|\bft\.?|\bx\b)\s*"#,
                                               with: "|", options: .regularExpression)
            .split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var out: [String] = []
        for p in pieces {
            out.append(p)
            let bare = p.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !bare.isEmpty, bare != p { out.append(bare) }
            // "牧言 MuYan": also try just the Chinese name.
            if let first = p.split(separator: " ").first, first.count < p.count { out.append(String(first)) }
        }
        return out
    }

    /// True if any name in `artist` matches any of the source's artist names.
    static func sameArtist(_ artist: String, _ names: [String]) -> Bool {
        let mine = artistParts(artist)
        let theirs = names.flatMap(artistParts)
        return mine.contains { m in theirs.contains { t in m == t || (m.count > 1 && t.contains(m)) || (t.count > 1 && m.contains(t)) } }
    }

    /// No cookies and no cache: NetEase starts returning unrelated songs to a session that
    /// keeps its cookies.
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func get<T: Decodable>(_ url: URL, referer: String?) async throws -> T {
        var r = URLRequest(url: url, timeoutInterval: 10)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer { r.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, _) = try await session.data(for: r)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private extension SavedSong {
    /// Saves under the *player's* title/artist so the same song is found again next time.
    func with(track: Track) -> SavedSong {
        var s = self
        s.id = track.key
        s.title = TitleCleaner.title(track.title)
        s.artist = TitleCleaner.artist(track.artist)
        if track.duration > 0 { s.duration = track.duration }
        return s
    }
}
