import Foundation

enum LyricsParser {
    /// LRC: `[01:23.45]line`, several tags per line allowed.
    /// Enhanced LRC word tags `<01:23.45>word` are read as word timing.
    static func lrc(_ text: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let tag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("{") { continue } // NetEase credit metadata
            let ns = line as NSString
            let matches = tag.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let body = ns.substring(from: matches.last!.range.location + matches.last!.range.length)
            let (plain, words) = enhancedWords(body)
            let clean = plain.trimmingCharacters(in: .whitespaces)
            for m in matches {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                out.append(LyricLine(start: mm * 60 + ss, text: clean, words: words))
            }
        }
        return out.sorted { $0.start < $1.start }.filter { !$0.text.isEmpty }
    }

    private static func enhancedWords(_ body: String) -> (String, [LyricWord]?) {
        let wt = try! NSRegularExpression(pattern: #"<(\d{1,3}):(\d{1,2}(?:\.\d{1,3})?)>"#)
        let ns = body as NSString
        let ms = wt.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !ms.isEmpty else { return (body, nil) }
        var words: [LyricWord] = []
        var plain = ""
        for (i, m) in ms.enumerated() {
            let t = (Double(ns.substring(with: m.range(at: 1))) ?? 0) * 60
                + (Double(ns.substring(with: m.range(at: 2))) ?? 0)
            let from = m.range.location + m.range.length
            let to = i + 1 < ms.count ? ms[i + 1].range.location : ns.length
            let w = ns.substring(with: NSRange(location: from, length: to - from))
            plain += w
            if !w.isEmpty { words.append(LyricWord(text: w, start: t, duration: 0)) }
        }
        // Each word lasts until the next one starts.
        for i in words.indices {
            let next = i + 1 < words.count ? words[i + 1].start : words[i].start + 0.6
            words[i].duration = max(0.05, next - words[i].start)
        }
        return (plain, words.isEmpty ? nil : words)
    }

    /// NetEase YRC: `[startMs,durMs](wordStartMs,wordDurMs,0)word...`
    static func yrc(_ text: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let head = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
        let word = try! NSRegularExpression(pattern: #"\((\d+),(\d+),\d+\)([^(]*)"#)
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            guard let h = head.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { continue }
            let start = (Double(ns.substring(with: h.range(at: 1))) ?? 0) / 1000
            var words: [LyricWord] = []
            for m in word.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                let s = (Double(ns.substring(with: m.range(at: 1))) ?? 0) / 1000
                let d = (Double(ns.substring(with: m.range(at: 2))) ?? 0) / 1000
                words.append(LyricWord(text: ns.substring(with: m.range(at: 3)), start: s, duration: d))
            }
            let textLine = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            if !textLine.isEmpty {
                out.append(LyricLine(start: start, text: textLine, words: words))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// 汽水音乐 KRC: `[lineStartMs,lineDurMs]<offsetMs,durMs,0>字...`, word times relative to the line.
    static func krc(_ text: String) -> [LyricLine] {
        var out: [LyricLine] = []
        let head = try! NSRegularExpression(pattern: #"^\[(\d+),(\d+)\]"#)
        let word = try! NSRegularExpression(pattern: #"<(\d+),(\d+),-?\d+>([^<]*)"#)
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            guard let h = head.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { continue }
            let start = (Double(ns.substring(with: h.range(at: 1))) ?? 0) / 1000
            var words: [LyricWord] = []
            for m in word.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
                let off = (Double(ns.substring(with: m.range(at: 1))) ?? 0) / 1000
                let d = (Double(ns.substring(with: m.range(at: 2))) ?? 0) / 1000
                let w = ns.substring(with: m.range(at: 3))
                if !w.isEmpty { words.append(LyricWord(text: w, start: start + off, duration: max(0.05, d))) }
            }
            let line = words.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { out.append(LyricLine(start: start, text: line, words: words)) }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Plain text with no timing (pasted by the user).
    static func plain(_ text: String) -> [LyricLine] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { LyricLine(start: 0, text: $0) }
    }

    /// Picks the right parser for pasted text.
    static func pasted(_ text: String) -> ([LyricLine], Timing) {
        let timed = lrc(text)
        if !timed.isEmpty {
            return (timed, timed.contains { $0.words != nil } ? .word : .line)
        }
        let y = yrc(text)
        if !y.isEmpty { return (y, .word) }
        let k = krc(text)
        if !k.isEmpty { return (k, .word) }
        return (plain(text), .none)
    }
}
