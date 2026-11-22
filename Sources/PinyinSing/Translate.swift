import Foundation
import Translation

/// English translations of lyric lines with Apple's on-device translator (macOS 26+).
/// Each song is translated once and the result is saved with it. The first time, macOS asks
/// to download the language pack (for example Chinese → English).
@MainActor
enum LyricTranslator {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// The song's language: Korean if it has Hangul, Japanese if it has kana, otherwise Chinese
    /// (traditional or simplified, whichever the lyrics use).
    static func language(of song: SavedSong) -> Locale.Language {
        let text = song.lines.prefix(40).map(\.text).joined()
        if Romanize.hasHangul(text) { return Locale.Language(identifier: "ko") }
        if Romanize.hasKana(text) { return Locale.Language(identifier: "ja") }
        let simplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        return Locale.Language(identifier: simplified == text ? "zh-Hans" : "zh-Hant")
    }

    /// Lines worth translating: they have Chinese, Japanese or Korean in them, aren't
    /// credit lines, and don't have a translation yet.
    static func pending(_ song: SavedSong) -> [Int] {
        song.lines.indices.filter { i in
            let t = song.lines[i].text
            guard song.lines[i].translation == nil else { return false }
            guard t.unicodeScalars.contains(where: { $0.value >= 0x3040 }) else { return false }
            return t.range(of: #"^\s*(作词|作曲|编曲|制作人|监制|混音|母带|和声|录音|出品|发行|词|曲)\s*[:：]"#,
                           options: .regularExpression) == nil
        }
    }

    enum Outcome { case done(SavedSong), needsDownload(Locale.Language), unavailable }

    /// Translates the lines that don't have a translation yet. If the language pack isn't on
    /// this Mac, says so (Settings then offers to download it).
    static func translate(_ song: SavedSong) async -> Outcome {
        let todo = pending(song)
        guard !todo.isEmpty else { return .done(song) }
        guard #available(macOS 26.0, *) else { return .unavailable }
        let source = language(of: song), target = Locale.Language(identifier: "en")
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else { return status == .supported ? .needsDownload(source) : .unavailable }
        let session = TranslationSession(installedSource: source, target: target)
        do {
            let requests = todo.map { TranslationSession.Request(sourceText: song.lines[$0].text, clientIdentifier: String($0)) }
            let responses = try await session.translations(from: requests)
            var s = song
            for r in responses {
                if let id = r.clientIdentifier, let i = Int(id), i < s.lines.count { s.lines[i].translation = r.targetText }
            }
            return .done(s)
        } catch {
            return .unavailable
        }
    }

    static func name(_ language: Locale.Language) -> String {
        switch language.minimalIdentifier {
        case "ko": return "Korean"
        case "ja": return "Japanese"
        case "zh-Hant": return "Chinese (Traditional)"
        default: return "Chinese"
        }
    }
}
