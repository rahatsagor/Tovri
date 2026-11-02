import Foundation

/// Fast subsequence fuzzy matcher used by the palette, file finder and completion.
enum Fuzzy {
    struct Match {
        var score: Int
        var positions: [Int]
    }

    @inline(__always) static func lower(_ c: UInt16) -> UInt16 {
        if c < 128 { return (c >= 65 && c <= 90) ? c + 32 : c }
        return c < 0x2000 ? folded[Int(c)] : c
    }

    /// Lowercase letters without accents for Latin, Greek and Cyrillic (É, é and e all become e),
    /// built on first use so ASCII-only matching never pays for it. Letters that fold to more
    /// than one character (ß) stay as they are, the same on both sides of a match.
    private static let folded: [UInt16] = (0..<0x2000).map { i in
        let c = UInt16(i)
        guard i >= 128, let scalar = Unicode.Scalar(c) else { return c }
        let f = Array(String(Character(scalar)).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf16)
        return f.count == 1 ? f[0] : c
    }

    @inline(__always) private static func isCombiningMark(_ c: UInt16) -> Bool { c >= 0x300 && c <= 0x36F }

    @inline(__always) private static func isBoundary(_ prev: UInt16, _ cur: UInt16) -> Bool {
        if prev == 47 || prev == 95 || prev == 45 || prev == 46 || prev == 32 || prev == 92 || prev == 58 { return true }
        return prev >= 97 && prev <= 122 && cur >= 65 && cur <= 90
    }

    /// Names can be stored decomposed (é as e plus a combining accent, as HFS+ does); the accent
    /// is dropped from the query and simply skipped in names, so both forms match.
    static func prepare(_ query: String) -> [UInt16] {
        let s = query.utf16.contains { $0 >= 128 } ? query.precomposedStringWithCanonicalMapping : query
        return s.utf16.compactMap { $0 == 32 || isCombiningMark($0) ? nil : lower($0) }
    }

    static func match(_ q: [UInt16], _ c: [UInt16], basenameStart: Int = 0, wantPositions: Bool = true) -> Match? {
        if q.isEmpty { return Match(score: 0, positions: []) }
        let n = c.count
        var qi = 0
        var i = 0
        while i < n && qi < q.count {
            if lower(c[i]) == q[qi] { qi += 1 }
            i += 1
        }
        if qi < q.count { return nil }

        func attempt(_ start: Int) -> Match? {
            var pos: [Int] = []
            pos.reserveCapacity(q.count)
            var score = 0
            var qi = 0
            var prev = -2
            var i = start
            var first = -1
            var lastPos = -1
            while i < n && qi < q.count {
                let ch = c[i]
                if lower(ch) == q[qi] {
                    var s = 1
                    if prev == i - 1 { s += 7 }
                    if i == 0 || isBoundary(c[i - 1], ch) { s += 9 }
                    if i >= basenameStart { s += 3 }
                    score += s
                    if wantPositions { pos.append(i) }
                    if first < 0 { first = i }
                    lastPos = i
                    prev = i
                    qi += 1
                }
                i += 1
            }
            if qi < q.count { return nil }
            score -= (lastPos - first) / 3
            score -= n / 24
            if first == basenameStart { score += 8 }
            if first == 0 { score += 4 }
            return Match(score: score, positions: pos)
        }

        var best = attempt(0)
        var tries = 0
        var k = 1
        while k < n && tries < 6 {
            if lower(c[k]) == q[0] && (isBoundary(c[k - 1], c[k]) || k == basenameStart) {
                if let r = attempt(k), r.score > (best?.score ?? Int.min) { best = r }
                tries += 1
            }
            k += 1
        }
        return best
    }
}
