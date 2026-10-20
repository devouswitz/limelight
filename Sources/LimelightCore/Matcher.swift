import Foundation

/// Scores a folded query token against a folded name. Higher is better; 0 means no match.
///
/// Bands, best first: exact name, exact name minus extension, prefix, word start,
/// word initials ("vsc" → "Visual Studio Code"), mid-word substring, typo, fuzzy.
/// Within a band, a token that covers more of the name ranks higher.
public enum Matcher {
    public static let exact = 1000
    public static let stemExact = 950
    public static let prefix = 800
    public static let wordPrefix = 600
    public static let initials = 520
    public static let substring = 400
    public static let typo = 260
    public static let fuzzy = 100

    @inline(__always) static func isSeparator(_ b: UInt8) -> Bool {
        switch b {
        case 32, 38, 39, 40, 41, 43, 44, 45, 46, 47, 58, 91, 93, 95: return true
        default: return false
        }
    }
    @inline(__always) static func isLower(_ b: UInt8) -> Bool { b &- 97 < 26 }
    @inline(__always) static func isUpper(_ b: UInt8) -> Bool { b &- 65 < 26 }
    @inline(__always) static func isDigit(_ b: UInt8) -> Bool { b &- 48 < 10 }

    /// Word starts: after a separator, at a letter/digit change, or at a camelCase hump
    /// (the hump needs `o`, the original bytes, aligned with `n`).
    @inline(__always)
    static func isBoundary(_ n: UnsafeBufferPointer<UInt8>, _ o: UnsafeBufferPointer<UInt8>?, _ i: Int) -> Bool {
        if i == 0 { return true }
        let p = n[i - 1], c = n[i]
        if isSeparator(p) { return true }
        if isDigit(p) != isDigit(c), isDigit(p) || isLower(p), isDigit(c) || isLower(c) { return true }
        if let o, isUpper(o[i]), isLower(o[i - 1]) { return true }
        return false
    }

    @inline(__always)
    static func matchesAt(_ t: UnsafeBufferPointer<UInt8>, _ n: UnsafeBufferPointer<UInt8>, _ i: Int) -> Bool {
        memcmp(t.baseAddress!, n.baseAddress! + i, t.count) == 0
    }

    public static func score(
        _ t: UnsafeBufferPointer<UInt8>,
        in n: UnsafeBufferPointer<UInt8>,
        original o: UnsafeBufferPointer<UInt8>? = nil,
        stem: Int? = nil,
        fuzzy allowFuzzy: Bool = false
    ) -> Int {
        let tc = t.count, nc = n.count
        guard tc > 0, nc > 0 else { return 0 }
        var best = 0
        if tc <= nc {
            let first = t[0]
            var i = 0
            while i <= nc - tc {
                if n[i] == first, matchesAt(t, n, i) {
                    if i == 0 {
                        if tc == nc { return exact }
                        if stem == tc || (stem == nil && n[tc] == 46 && !n[(tc + 1)...].contains(46)) { return stemExact }
                        return prefix + 100 * tc / nc
                    }
                    let band = isBoundary(n, o, i) ? wordPrefix : substring
                    best = max(best, band + 100 * tc / nc)
                }
                i += 1
            }
            if best < initials, tc >= 2, initialPositions(t, n, o) != nil {
                best = initials + 100 * tc / nc
            }
            if best > 0 { return best }
        }
        guard allowFuzzy else { return 0 }
        if tc >= 4, isTypo(t, n, o) { return typo }
        if let s = fuzzyScore(t, n, o) { return fuzzy + s }
        return 0
    }

    /// Positions of the word starts that spell out `t`, if any.
    static func initialPositions(_ t: UnsafeBufferPointer<UInt8>, _ n: UnsafeBufferPointer<UInt8>, _ o: UnsafeBufferPointer<UInt8>?) -> [Int]? {
        var ti = 0
        var hits: [Int] = []
        for i in 0..<n.count where ti < t.count && n[i] == t[ti] && isBoundary(n, o, i) {
            hits.append(i)
            ti += 1
        }
        return ti == t.count ? hits : nil
    }

    /// The tightest in-order match of `t`'s characters, scored for word starts and runs.
    /// Rejects scattered matches so a stray letter here and there doesn't count.
    static func fuzzyScore(_ t: UnsafeBufferPointer<UInt8>, _ n: UnsafeBufferPointer<UInt8>, _ o: UnsafeBufferPointer<UInt8>?) -> Int? {
        guard let pos = fuzzyPositions(t, n) else { return nil }
        var s = 0
        var prev = -2
        for p in pos {
            s += 16
            if isBoundary(n, o, p) { s += 10 }
            if p == prev + 1 { s += 6 } else if prev >= 0 { s -= min(p - prev - 1, 6) * 2 }
            prev = p
        }
        if pos[0] == 0 { s += 8 }
        guard s >= 14 * t.count else { return nil }
        return min(s, 150)
    }

    static func fuzzyPositions(_ t: UnsafeBufferPointer<UInt8>, _ n: UnsafeBufferPointer<UInt8>) -> [Int]? {
        var ti = 0
        var end = -1
        for i in 0..<n.count where n[i] == t[ti] {
            ti += 1
            if ti == t.count { end = i; break }
        }
        guard end >= 0 else { return nil }
        // Walk back from the end to find the latest start, which gives the tightest window.
        ti = t.count - 1
        var start = end
        var i = end
        while i >= 0 {
            if n[i] == t[ti] {
                if ti == 0 { start = i; break }
                ti -= 1
            }
            i -= 1
        }
        var pos: [Int] = []
        ti = 0
        for j in start...end where ti < t.count && n[j] == t[ti] {
            pos.append(j)
            ti += 1
        }
        return pos
    }

    /// One insertion, deletion, substitution or transposition against the start of some word.
    static func isTypo(_ t: UnsafeBufferPointer<UInt8>, _ n: UnsafeBufferPointer<UInt8>, _ o: UnsafeBufferPointer<UInt8>?) -> Bool {
        let tc = t.count
        for w in 0..<n.count where isBoundary(n, o, w) {
            for len in max(1, tc - 1)...(tc + 1) where w + len <= n.count {
                if osaDistance(t, n, from: w, length: len, limit: 1) <= 1 { return true }
            }
        }
        return false
    }

    static func osaDistance(_ a: UnsafeBufferPointer<UInt8>, _ n: UnsafeBufferPointer<UInt8>, from: Int, length: Int, limit: Int) -> Int {
        let m = a.count
        var prev2 = [Int](repeating: 0, count: length + 1)
        var prev = Array(0...length)
        var cur = [Int](repeating: 0, count: length + 1)
        for i in 1...m {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...length {
                let cost = a[i - 1] == n[from + j - 1] ? 0 : 1
                var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == n[from + j - 2], a[i - 2] == n[from + j - 1] {
                    v = min(v, prev2[j - 2] + 1)
                }
                cur[j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > limit { return limit + 1 }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[length]
    }

    // MARK: - Array conveniences

    public static func score(_ token: [UInt8], in name: [UInt8], original: [UInt8]? = nil, stem: Int? = nil, fuzzy: Bool = false) -> Int {
        token.withUnsafeBufferPointer { t in
            name.withUnsafeBufferPointer { n in
                if let original, original.count == name.count {
                    return original.withUnsafeBufferPointer { o in
                        score(t, in: n, original: o, stem: stem, fuzzy: fuzzy)
                    }
                }
                return score(t, in: n, original: nil, stem: stem, fuzzy: fuzzy)
            }
        }
    }

    /// Character ranges of `name` to emphasize for `query`, mirroring how `score` matched.
    public static func highlights(for query: String, in name: String) -> [Range<String.Index>] {
        // Fold character by character so folded byte offsets map back to the original string.
        var folded: [UInt8] = []
        var owner: [String.Index] = []
        var original: [UInt8] = []
        var aligned = true
        for idx in name.indices {
            let ch = String(name[idx])
            let f = Fold.bytes(ch)
            let raw = Array(ch.utf8)
            if raw.count != f.count { aligned = false }
            folded.append(contentsOf: f)
            original.append(contentsOf: raw.count == f.count ? raw : f)
            owner.append(contentsOf: repeatElement(idx, count: f.count))
        }
        var marked = Set<String.Index>()
        for token in Fold.tokens(query) {
            let positions: [Int]? = token.withUnsafeBufferPointer { t in
                folded.withUnsafeBufferPointer { n in
                    original.withUnsafeBufferPointer { o in
                        matchPositions(t, n, aligned ? o : nil)
                    }
                }
            }
            for p in positions ?? [] { marked.insert(owner[p]) }
        }
        var ranges: [Range<String.Index>] = []
        for idx in name.indices where marked.contains(idx) {
            let next = name.index(after: idx)
            if let last = ranges.last, last.upperBound == idx {
                ranges[ranges.count - 1] = last.lowerBound..<next
            } else {
                ranges.append(idx..<next)
            }
        }
        return ranges
    }

    static func matchPositions(_ t: UnsafeBufferPointer<UInt8>, _ n: UnsafeBufferPointer<UInt8>, _ o: UnsafeBufferPointer<UInt8>?) -> [Int]? {
        let tc = t.count, nc = n.count
        guard tc > 0, tc <= nc else { return nil }
        var firstAny: Int?
        for i in 0...(nc - tc) where matchesAt(t, n, i) {
            if i == 0 || isBoundary(n, o, i) { return Array(i..<(i + tc)) }
            if firstAny == nil { firstAny = i }
        }
        if tc >= 2, let p = initialPositions(t, n, o) { return p }
        if let i = firstAny { return Array(i..<(i + tc)) }
        return fuzzyPositions(t, n)
    }
}
