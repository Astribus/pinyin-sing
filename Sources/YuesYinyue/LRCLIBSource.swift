import Foundation

/// Lyrics source: LRCLIB (lrclib.net), a free, open lyrics database.
extension LyricsService {
    // MARK: LRCLIB (free, open lyrics database)

    struct LRCLibItem: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let syncedLyrics: String?
    }

    static func lrclib(title: String, artist: String, duration: Double) async throws -> SavedSong? {
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [.init(name: "track_name", value: title)]
        if !artist.isEmpty { c.queryItems!.append(.init(name: "artist_name", value: artist)) }
        let items: [LRCLibItem] = try await get(c.url!, referer: nil)
        let synced = items.filter { ($0.syncedLyrics ?? "").isEmpty == false }
        guard let best = synced.min(by: { abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration) }),
              let text = best.syncedLyrics else { return nil }
        if duration > 0, let d = best.duration, abs(d - duration) > 15 { return nil }
        let lines = LyricsParser.lrc(text)
        guard lines.count > 2 else { return nil }
        return SavedSong(id: "", title: best.trackName ?? title, artist: best.artistName ?? artist,
                         duration: best.duration, source: "LRCLIB",
                         timing: lines.contains { $0.words != nil } ? .word : .line, lines: lines)
    }
}
