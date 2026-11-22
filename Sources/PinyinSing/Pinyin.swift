import Foundation
import JavaScriptCore

/// One piece of a lyric line: a Chinese character (with pinyin) or a run of other text.
struct Token: Hashable {
    var text: String
    var pinyin: String?   // nil for non-Chinese text
}

enum ToneStyle: String, CaseIterable, Identifiable {
    case marks = "symbol"   // nǐ hǎo
    case numbers = "num"    // ni3 hao3
    case none = "none"      // ni hao
    var id: String { rawValue }
    var label: String {
        switch self {
        case .marks: return "Tone marks (nǐ hǎo)"
        case .numbers: return "Numbers (ni3 hao3)"
        case .none: return "No tones (ni hao)"
        }
    }
    /// A short example of the style, for compact pickers.
    var sample: String {
        switch self {
        case .marks: return "yīn yuè"
        case .numbers: return "yin1 yue4"
        case .none: return "yin yue"
        }
    }
}

/// Automatic pinyin using pinyin-pro (MIT, github.com/zh-lx/pinyin-pro), run in
/// macOS's built-in JavaScript engine. It handles characters with more than one
/// reading (行 = xíng / háng) much better than the system converter.
@MainActor
final class PinyinEngine {
    static let shared = PinyinEngine()

    private let context: JSContext?
    private var cache: [String: [Token]] = [:]

    private init() {
        let ctx = JSContext()
        if let url = PinyinEngine.scriptURL(), let js = try? String(contentsOf: url, encoding: .utf8) {
            ctx?.evaluateScript(js)
            ctx?.evaluateScript("""
            function yyTokens(text, tone) {
              return pinyinPro.pinyin(text, { type: 'all', toneType: tone })
                .map(function (x) { return [x.origin, x.isZh ? x.pinyin : null]; });
            }
            """)
        }
        context = ctx
    }

    /// Reading tokens for a line: Korean and Japanese get their romanization, Chinese gets pinyin.
    /// `japanese` reads kanji-only lines the Japanese way (for songs that have kana elsewhere).
    func tokens(_ text: String, style: ToneStyle, japanese: Bool = false) -> [Token] {
        let key = style.rawValue + (japanese ? "j" : "") + "\u{1}" + text
        if let hit = cache[key] { return hit }
        if Romanize.hasHangul(text) {
            let t = Romanize.korean(text)
            cache[key] = t
            return t
        }
        if japanese || Romanize.hasKana(text) {
            let t = Romanize.japanese(text)
            cache[key] = t
            return t
        }
        var out: [Token] = []
        // pinyin-pro reads simplified characters best (著 → zhe, 車站 → chē zhàn), so look up
        // the pinyin on a simplified copy but keep showing the song's own characters.
        let original = Array(text)
        let simplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text
        let lookup = Array(simplified).count == original.count ? simplified : text
        if let fn = context?.objectForKeyedSubscript("yyTokens"),
           let arr = fn.call(withArguments: [lookup, style.rawValue])?.toArray() as? [[Any]] {
            var pos = 0
            for pair in arr {
                var origin = pair.first as? String ?? ""
                let n = origin.count
                if lookup != text, pos + n <= original.count {
                    origin = String(original[pos..<pos + n])
                }
                pos += n
                let py = pair.count > 1 ? pair[1] as? String : nil
                // Merge neighbouring non-Chinese characters into one token.
                if py == nil, let last = out.last, last.pinyin == nil {
                    out[out.count - 1].text += origin
                } else {
                    out.append(Token(text: origin, pinyin: py))
                }
            }
        } else {
            out = text.map { Token(text: String($0), pinyin: Self.fallback(String($0))) }
        }
        cache[key] = out
        return out
    }

    /// Tokens for a line, using the user's own pinyin where they fixed it.
    func tokens(for line: LyricLine, style: ToneStyle, japanese: Bool = false) -> [Token] {
        // Credit lines added by Chinese lyric sites (作词 : …) stay Chinese even in a Japanese song.
        let credit = line.text.range(of: #"^\s*(作词|作曲|编曲|制作人|监制|混音|母带|和声|录音|出品|发行|词|曲)\s*[:：]"#,
                                     options: .regularExpression) != nil
        var t = tokens(line.text, style: style, japanese: japanese && !credit)
        if let fix = line.pinyinOverride {
            var i = 0
            for k in t.indices where t[k].pinyin != nil {
                if i < fix.count, !fix[i].isEmpty { t[k].pinyin = fix[i] }
                i += 1
            }
        }
        return t
    }

    private var japaneseSongs: [String: Bool] = [:]

    /// True if any line of the song has kana, so its kanji are read as Japanese.
    func isJapanese(_ song: SavedSong) -> Bool {
        let key = song.id + "\u{1}\(song.lines.count)"
        if let hit = japaneseSongs[key] { return hit }
        let v = song.lines.contains { Romanize.hasKana($0.text) }
        japaneseSongs[key] = v
        return v
    }

    private static func fallback(_ ch: String) -> String? {
        guard ch.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return nil }
        let m = NSMutableString(string: ch)
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        return m as String
    }

    private static func scriptURL() -> URL? {
        if let u = Bundle.main.url(forResource: "pinyin-pro", withExtension: "js") { return u }
        #if DEBUG
        // Debug builds run outside the app bundle (`swift run`, `--test`): use the repo's copy.
        // Release builds leave this out, so no local file path ends up in the app.
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Vendor/pinyin-pro.js")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
        #else
        return nil
        #endif
    }
}
