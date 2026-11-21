import Foundation

/// Works out how "sung" each token of a line is at time `t` (0 = white, 1 = full color).
enum Karaoke {
    static func progress(line: LyricLine, tokens: [Token], next: Double?, t: Double,
                         timing: Timing, fill: LineFill) -> [Double] {
        if timing == .none { return Array(repeating: 0, count: tokens.count) }

        // Time window for each visible (non-space) character, in order.
        let charTimes: [(Double, Double)]
        if let words = line.words, !words.isEmpty {
            var ct: [(Double, Double)] = []
            for w in words {
                let chars = w.text.filter { !$0.isWhitespace }
                guard !chars.isEmpty else { continue }
                let each = w.duration / Double(chars.count)
                for i in 0..<chars.count { ct.append((w.start + each * Double(i), each)) }
            }
            charTimes = ct
        } else {
            let n = line.text.filter { !$0.isWhitespace }.count
            let end = next ?? (line.start + 5)
            switch fill {
            case .wholeLine:
                // A quick 0.12 s fade-in instead of a hard switch, so it isn't caught up in
                // the slower scroll animation.
                let v = min(1, max(0, (t - line.start) / 0.12))
                return tokens.map { _ in v }
            case .sweep:
                // Sing speed is about 3 characters a second; don't stretch the fill over
                // the instrumental gap before the next line.
                let span = min(max(0.4, (end - line.start) * 0.85), Double(n) * 0.32 + 0.25)
                let each = span / Double(max(n, 1))
                charTimes = (0..<n).map { (line.start + each * Double($0), each) }
            }
        }

        // A character fills quickly when it starts (at most 0.18 s) instead of over its whole
        // length, so it reads as "now" rather than finishing at the end of the sound.
        let quick = charTimes.map { ($0.0, min($0.1, 0.18)) }
        var out: [Double] = []
        var i = 0
        for tok in tokens {
            var sum = 0.0, count = 0
            for ch in tok.text where !ch.isWhitespace {
                if i < charTimes.count {
                    let (s, d) = quick[i]
                    sum += d <= 0 ? (t >= s ? 1 : 0) : min(1, max(0, (t - s) / d))
                } else {
                    sum += min(1, max(0, (t - line.start) / 0.12))
                }
                count += 1
                i += 1
            }
            out.append(count == 0 ? (out.last ?? 0) : sum / Double(count))
        }
        return out
    }

    /// Index of the line being sung at time `t` (-1 before the first line).
    static func currentIndex(_ lines: [LyricLine], t: Double) -> Int {
        var lo = 0, hi = lines.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].start <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans
    }
}
