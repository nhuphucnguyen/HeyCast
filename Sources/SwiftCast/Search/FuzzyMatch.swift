/// fzf-style fuzzy subsequence scorer.
///
/// Returns an optional score (higher is better) when every character of
/// `query` appears in `target` in order. Scoring favors prefix matches,
/// word-boundary matches and contiguous runs, matching the feel of nucleo's
/// default matcher used by RustCast.
enum FuzzyMatch {
    static func score(_ query: String, _ target: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let q = Array(query.lowercased())
        let t = Array(target.lowercased())
        guard q.count <= t.count else { return nil }

        // Greedy first pass: every query char must be findable in order.
        var qi = 0
        var ti = 0
        var positions: [Int] = []
        positions.reserveCapacity(q.count)
        while qi < q.count && ti < t.count {
            if t[ti] == q[qi] {
                positions.append(ti)
                qi += 1
            }
            ti += 1
        }
        guard qi == q.count else { return nil }

        var score = 0
        var prev = -2
        for (i, pos) in positions.enumerated() {
            let ch = t[pos]
            var s = 4
            if pos == 0 { s += 22 }                                  // prefix of target
            if pos > 0 && !isWordChar(t[pos - 1]) { s += 16 }        // word boundary
            if pos == prev + 1 { s += 12 }                           // contiguous run
            if ch.isNumber { s += 2 }
            if i == 0 { s += 6 }
            // small penalty for gaps so tighter matches win
            if prev >= 0 && pos > prev + 1 { s -= min(8, pos - prev - 1) }
            score += s
            prev = pos
        }
        // prefer shorter targets for equal matches
        score -= (t.count - q.count) / 4
        // large bonus for an exact full match or clean prefix
        if t == q { score += 60 }
        else if String(t.prefix(q.count)) == String(q) { score += 30 }
        return max(score, 1)
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    /// Filter+sort a list by fuzzy score. Items that do not match are dropped.
    static func ranked<T>(_ items: [T], query: String, key: (T) -> String) -> [(item: T, score: Int)] {
        guard !query.isEmpty else { return items.map { ($0, 0) } }
        var out: [(T, Int)] = []
        out.reserveCapacity(items.count)
        for item in items {
            if let s = score(query, key(item)) {
                out.append((item, s))
            }
        }
        out.sort { $0.1 > $1.1 }
        return out
    }
}
