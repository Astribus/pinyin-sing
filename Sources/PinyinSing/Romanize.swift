import Foundation

/// English-letter readings for Korean and Japanese lyrics (Chinese uses pinyin, in Pinyin.swift).
enum Romanize {
    static func hasHangul(_ s: String) -> Bool { s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
    static func hasKana(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x31F0...0x31FF).contains($0.value) }
    }

    // MARK: Japanese

    /// Splits a Japanese line into words with their readings, using macOS's built-in Japanese
    /// tokenizer (it knows kanji readings in context). Spaces and punctuation are kept as
    /// tokens with no reading, so the tokens add back up to the line.
    static func japanese(_ text: String) -> [Token] {
        let ns = text as NSString
        let tok = CFStringTokenizerCreate(nil, text as CFString, CFRangeMake(0, ns.length), kCFStringTokenizerUnitWord,
                                          Locale(identifier: "ja") as CFLocale)
        var out: [Token] = []
        var pos = 0
        func gap(upTo end: Int) {
            guard end > pos else { return }
            let t = ns.substring(with: NSRange(location: pos, length: end - pos))
            if let last = out.last, last.pinyin == nil { out[out.count - 1].text += t } else { out.append(Token(text: t, pinyin: nil)) }
        }
        while CFStringTokenizerAdvanceToNextToken(tok).rawValue != 0 {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            gap(upTo: r.location)
            let word = ns.substring(with: NSRange(location: r.location, length: r.length))
            var reading = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String
            // Particles are sung differently from how they're spelled.
            switch word {
            case "は": reading = "wa"
            case "へ": reading = "e"
            case "を": reading = "o"
            default: break
            }
            let isJapanese = word.unicodeScalars.contains { $0.value >= 0x3040 }
            out.append(Token(text: word, pinyin: isJapanese ? reading : nil))
            pos = r.location + r.length
        }
        gap(upTo: ns.length)
        return out
    }

    // MARK: Korean (Revised Romanization, with the main pronunciation rules)

    /// One token per word (eojeol), romanized the way it's sung: 사랑해요 → saranghaeyo,
    /// 잠이 → jami, 국물 → gungmul.
    static func korean(_ text: String) -> [Token] {
        var out: [Token] = []
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            out.append(Token(text: word, pinyin: hasHangul(word) ? korean(word: word) : nil))
            word = ""
        }
        for ch in text {
            if ch.isWhitespace || (ch.isPunctuation && !hasHangul(String(ch))) {
                flush()
                if let last = out.last, last.pinyin == nil { out[out.count - 1].text += String(ch) }
                else { out.append(Token(text: String(ch), pinyin: nil)) }
            } else {
                word.append(ch)
            }
        }
        flush()
        return out
    }

    private struct Syllable { var initial: Int; var medial: Int; var final: Int }   // final 0 = none

    private static let initials = ["g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h"]
    private static let medials = ["a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo", "u", "wo", "we",
                                  "wi", "yu", "eu", "ui", "i"]
    // Finals at the end of a syllable (before a consonant or at the end of the word).
    private static let finals = ["", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "p", "l", "m", "p", "p",
                                 "t", "t", "ng", "t", "t", "k", "t", "p", "t"]
    // What a final turns into when the next syllable starts with a silent ㅇ (it carries over).
    private static let carried = ["", "g", "kk", "ks", "n", "nj", "n", "d", "r", "lg", "lm", "lb", "ls", "lt", "lp", "r", "m",
                                  "b", "ps", "s", "ss", "", "j", "ch", "k", "t", "p", ""]

    private static func korean(word: String) -> String {
        var syl: [Syllable?] = word.unicodeScalars.map { u in
            guard (0xAC00...0xD7A3).contains(u.value) else { return nil }
            let i = Int(u.value - 0xAC00)
            return Syllable(initial: i / 588, medial: (i % 588) / 28, final: i % 28)
        }
        let scalars = Array(word.unicodeScalars)
        var out = ""
        for k in syl.indices {
            guard let s = syl[k] else { out += String(scalars[k]); continue }
            out += initials[s.initial] + medials[s.medial]
            guard s.final != 0 else { continue }
            let next = k + 1 < syl.count ? syl[k + 1] : nil
            guard let n = next else { out += finals[s.final]; continue }
            let f = s.final, ni = n.initial
            let kSound: Set<Int> = [1, 2, 3, 9, 24], tSound: Set<Int> = [7, 19, 20, 22, 23, 25, 27], pSound: Set<Int> = [17, 18, 14, 26, 11]
            if ni == 11, f != 21 {                       // next starts with silent ㅇ: the final carries over
                out += carried[f]
                continue
            }
            if f == 27, [0, 3, 12].contains(ni) {        // ㅎ + ㄱ/ㄷ/ㅈ → k/t/ch
                syl[k + 1]?.initial = ni == 0 ? 15 : ni == 3 ? 16 : 14
                continue
            }
            if ni == 18, kSound.contains(f) || pSound.contains(f) || tSound.contains(f) {   // ㄱ/ㅂ/ㄷ + ㅎ → k/p/t
                syl[k + 1]?.initial = kSound.contains(f) ? 15 : pSound.contains(f) ? 17 : 16
                continue
            }
            if [2, 6].contains(ni) {                     // before ㄴ/ㅁ: nasal sounds
                if kSound.contains(f) { out += "ng"; continue }
                if tSound.contains(f) { out += "n"; continue }
                if pSound.contains(f) { out += "m"; continue }
                if f == 8, ni == 2 { out += "l"; syl[k + 1]?.initial = 5; continue }   // ㄹ + ㄴ → ll
            }
            if ni == 5 {                                 // before ㄹ
                if f == 8 || f == 4 { out += "l"; syl[k + 1]?.initial = 5; continue }  // → ll
                if [16, 21].contains(f) { out += finals[f]; syl[k + 1]?.initial = 2; continue }   // ㅁ/ㅇ + ㄹ → n
                if kSound.contains(f) { out += "ng"; syl[k + 1]?.initial = 2; continue }
                if pSound.contains(f) { out += "m"; syl[k + 1]?.initial = 2; continue }
            }
            out += finals[f]
        }
        // ㄹ before another ㄹ is written "ll"; initial ㄹ right after it is "l", not "r".
        return out.replacingOccurrences(of: "lr", with: "ll")
    }
}
