import Foundation

/// Lyrics source: NetEase Cloud Music's public web search and lyric endpoints.
/// Unofficial; it's kept in its own file so it can be removed on its own if needed.
extension LyricsService {
    // MARK: NetEase Cloud Music (public web API, line timing; word timing when it's returned)

    struct NESearch: Decodable {
        struct Result: Decodable { let songs: [Song]? }
        struct Song: Decodable {
            let id: Int
            let name: String
            let artists: [Artist]
            let duration: Double?
        }
        struct Artist: Decodable { let name: String }
        let result: Result?
    }

    struct NELyric: Decodable {
        struct Block: Decodable { let lyric: String? }
        let lrc: Block?
        let yrc: Block?
    }

    static func netease(title: String, artist: String, duration: Double) async throws -> SavedSong? {
        // Search "title + first artist (no brackets)", then the title alone, and score all results together.
        let parts = artistParts(artist)
        let shortArtist = parts.first { !$0.contains("(") } ?? parts.first ?? ""
        var songs: [NESearch.Song] = []
        for q in Set(["\(title) \(shortArtist)", title]).sorted(by: { $0.count > $1.count }) {
            var c = URLComponents(string: "https://music.163.com/api/search/get")!
            c.queryItems = [.init(name: "s", value: q), .init(name: "type", value: "1"), .init(name: "limit", value: "15")]
            if let r: NESearch = try? await get(c.url!, referer: "https://music.163.com") {
                for s in r.result?.songs ?? [] where !songs.contains(where: { $0.id == s.id }) { songs.append(s) }
            }
        }
        guard !songs.isEmpty else { return nil }

        let best = songs.max { score($0, title, artist, duration) < score($1, title, artist, duration) }!
        guard score(best, title, artist, duration) > 1 else { return nil }
        // Same title by a different singer is usually a cover with different timing.
        // Only accept it if the length matches almost exactly.
        let artistMatches = artist.isEmpty || sameArtist(artist, best.artists.map(\.name))
        if !artistMatches {
            guard duration > 0, let d = best.duration, abs(d / 1000 - duration) < 2,
                  best.name.lowercased() == title.lowercased() else { return nil }
        }

        var lc = URLComponents(string: "https://music.163.com/api/song/lyric")!
        lc.queryItems = [.init(name: "id", value: String(best.id)), .init(name: "lv", value: "1"),
                         .init(name: "yv", value: "1"), .init(name: "tv", value: "-1")]
        let lyr: NELyric = try await get(lc.url!, referer: "https://music.163.com")

        if let y = lyr.yrc?.lyric, case let lines = LyricsParser.yrc(y), !lines.isEmpty {
            var s = SavedSong(id: "", title: best.name, artist: best.artists.first?.name ?? artist,
                              duration: (best.duration ?? 0) / 1000, source: "NetEase", timing: .word, lines: lines)
            s.neteaseID = best.id
            return s
        }
        if let l = lyr.lrc?.lyric, case let lines = LyricsParser.lrc(l), lines.count > 2 {
            var s = SavedSong(id: "", title: best.name, artist: best.artists.first?.name ?? artist,
                              duration: (best.duration ?? 0) / 1000, source: "NetEase",
                              timing: lines.contains { $0.words != nil } ? .word : .line, lines: lines)
            s.neteaseID = best.id
            return s
        }
        return nil
    }

    /// NetEase's id for a song (used to open it in the NetEase app).
    static func neteaseID(title: String, artist: String, duration: Double) async -> Int? {
        var c = URLComponents(string: "https://music.163.com/api/search/get")!
        c.queryItems = [.init(name: "s", value: "\(title) \(artist)"),
                        .init(name: "type", value: "1"), .init(name: "limit", value: "10")]
        guard let search: NESearch = try? await get(c.url!, referer: "https://music.163.com"),
              let songs = search.result?.songs, !songs.isEmpty else { return nil }
        let best = songs.max { score($0, title, artist, duration) < score($1, title, artist, duration) }!
        return score(best, title, artist, duration) > 2 ? best.id : nil
    }

    static func score(_ s: NESearch.Song, _ title: String, _ artist: String, _ duration: Double) -> Double {
        var v = 0.0
        let n = s.name.lowercased(), t = title.lowercased()
        if n == t { v += 3 } else if n.contains(t) || t.contains(n) { v += 1.5 }
        if sameArtist(artist, s.artists.map(\.name)) { v += 2 }
        if duration > 0, let d = s.duration {
            let diff = abs(d / 1000 - duration)
            if diff < 3 { v += 2 } else if diff < 10 { v += 1 } else if diff > 30 { v -= 1 }
        }
        return v
    }
}
