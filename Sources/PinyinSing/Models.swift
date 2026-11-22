import Foundation

/// One sung word (or character) with its own timing, in seconds.
struct LyricWord: Codable, Hashable {
    var text: String
    var start: Double
    var duration: Double
}

/// One lyric line. `words` is filled only when the source has word-by-word timing.
struct LyricLine: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Double
    var text: String
    var words: [LyricWord]? = nil
    /// Pinyin the user typed in by hand, one entry per Chinese character.
    var pinyinOverride: [String]? = nil
    /// English translation of the line (made on the Mac, saved with the song).
    var translation: String? = nil
}

enum Timing: String, Codable {
    case word   // every word has its own time
    case line   // only each line has a start time
    case none   // plain text, no timing
}

struct SavedSong: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var duration: Double?
    var source: String
    var timing: Timing
    var lines: [LyricLine]
    var savedAt: Date = Date()
    /// Seconds added to the playback time, for lyrics that run early or late.
    var offset: Double = 0
    /// Other title|artist keys (from other apps) that are this same song.
    var aliases: [String]? = nil
    /// Platform it was last played on (see `Platform`): "qishui", "netease", "spotify", "youtube"...
    var app: String? = nil
    /// Every platform it has been played on. The song shows up under each one in the sidebar.
    var apps: [String]? = nil
    /// A link that opens this exact song, per platform (YouTube video, Spotify track...).
    var links: [String: String]? = nil
    /// Older single link (before songs could belong to several platforms). Moved into `links`.
    var playLink: String? = nil
    var neteaseID: Int? = nil
    var playCount: Int? = nil
    var lastPlayed: Date? = nil

    var appName: String? { app.map { Platform.name($0) } }
    /// All platforms it was played on, last-played first.
    var platforms: [String] {
        var out = app.map { [$0] } ?? []
        for p in apps ?? [] where !out.contains(p) { out.append(p) }
        return out
    }
    func isOn(_ platform: String) -> Bool { app == platform || (apps ?? []).contains(platform) }
}

/// A user-made collection of saved songs.
struct Album: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var songIDs: [String] = []
    var created = Date()
}

/// What macOS says is playing right now.
struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var bundleID: String

    var key: String { SongKey.make(title: title, artist: artist) }

    var playerName: String { Platform.name(Platform.from(bundle: bundleID)) }

    static func name(forBundle bundleID: String) -> String {
        switch bundleID {
        case "com.soda.music": return "汽水音乐"
        case "com.netease.163music": return "NetEase"
        case "com.spotify.client": return "Spotify"
        case "com.google.Chrome": return "Chrome"
        case "com.apple.Safari": return "Safari"
        case "com.apple.Music": return "Apple Music"
        default: return bundleID
        }
    }
}

enum SongKey {
    static func make(title: String, artist: String) -> String {
        let t = TitleCleaner.title(title).lowercased()
        let a = TitleCleaner.artist(artist).lowercased()
        return "\(t)|\(a)"
    }
}

/// Removes the extra bits players add to titles (YouTube "- Topic", "(Official MV)", etc).
enum TitleCleaner {
    static func artist(_ s: String) -> String {
        var a = s.trimmingCharacters(in: .whitespaces)
        if a.hasSuffix(" - Topic") { a = String(a.dropLast(8)) }
        return a
    }

    static func title(_ s: String) -> String {
        var t = s
        // Drop bracketed extras such as (Official MV), 【MV】, [Lyrics]
        let patterns = [#"\((?i:official|mv|lyric|audio|music video|live|动态歌词|歌词)[^)]*\)"#,
                        #"【[^】]*】"#, #"\[[^\]]*\]"#, #"「|」|《|》"#]
        for p in patterns {
            t = t.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Shorter guesses to search with when the full title finds nothing.
    static func searchVariants(_ s: String) -> [String] {
        let base = title(s)
        var out = [base]
        for sep in ["_", " - ", "-", "（", "("] {
            if let r = base.range(of: sep) {
                let head = String(base[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty, !out.contains(head) { out.append(head) }
            }
        }
        return out
    }
}

/// Where a song is played: a music service, not the program. YouTube and Spotify can both play
/// in Chrome, so browser songs are sorted by the tab they're playing in (see `Player.browserInfo`).
enum Platform {
    static let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
                                        "com.microsoft.edgemac", "com.brave.Browser"]

    static func isBrowser(_ bundleID: String) -> Bool { browsers.contains(bundleID) }

    /// The platform for an app's bundle id. Browsers come back as "browser" until the tab is checked.
    static func from(bundle: String) -> String {
        switch bundle {
        case "com.soda.music": return "qishui"
        case "com.netease.163music": return "netease"
        case "com.spotify.client": return "spotify"
        case "com.apple.Music": return "applemusic"
        default: return isBrowser(bundle) ? "browser" : bundle
        }
    }

    /// Older saved songs stored the app's bundle id; this turns it into a platform.
    static func migrate(_ old: String) -> String {
        if old == "com.google.Chrome" || old == "com.apple.Safari" { return "youtube" }
        return from(bundle: old)
    }

    static func name(_ id: String) -> String {
        switch id {
        case "qishui": return "汽水音乐"
        case "netease": return "NetEase"
        case "spotify": return "Spotify"
        case "youtube": return "YouTube"
        case "applemusic": return "Apple Music"
        case "browser": return "Browser"
        default: return Track.name(forBundle: id)
        }
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case "qishui": return "bubbles.and.sparkles.fill"
        case "netease": return "cloud.fill"
        case "spotify": return "dot.radiowaves.left.and.right"
        case "youtube": return "play.rectangle.fill"
        case "applemusic": return "music.note"
        default: return "app.fill"
        }
    }
}
