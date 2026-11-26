import Foundation

/// Learns from what the user opens so search and the empty page can rank it.
///
/// Three signals, all kept on-device in `usage.json`:
/// - **Frecency** — every use adds 1 to a score that halves every
///   `halfLife`. Old habits fade on their own; storage is one number + a
///   timestamp per item (Firefox-style exponential frecency).
/// - **Query → pick** — what was typed when an item was chosen ("s" → Slack),
///   so the same query surfaces the same pick next time even when another
///   item is a better text match (Alfred-style "knowledge").
/// - **Hour of day** — a decayed 24-bucket histogram per item, used to tilt
///   the empty-page suggestions towards what is usually opened at this hour.
///
/// Favourites are an explicit choice and live in their own set, so starring
/// an item never erases its history.
struct UsageStore {
    static let halfLife: TimeInterval = 10 * 86_400
    /// Below this decayed score an entry is forgotten on save (a single use
    /// reaches it after ~6 weeks).
    static let forgetBelow = 0.05
    static let maxQueryLength = 32

    struct Item: Codable, Equatable {
        var score: Double
        var lastUsed: Date
        var hours: [Double] = Array(repeating: 0, count: 24)
    }

    struct Hit: Codable, Equatable {
        var score: Double
        var lastUsed: Date
    }

    private(set) var items: [String: Item] = [:]
    /// normalized query -> item key -> hit
    private(set) var queries: [String: [String: Hit]] = [:]
    private(set) var favorites: Set<String> = []

    // MARK: - persistence

    static var fileURL: URL { Config.directory.appendingPathComponent("usage.json") }
    /// Pre-UsageStore counts ({name: count}, -1 = favourite); read once to migrate.
    static var legacyURL: URL { Config.directory.appendingPathComponent("ranking.json") }

    private struct Snapshot: Codable {
        var version = 1
        var items: [String: Item]
        var queries: [String: [String: Hit]]
        var favorites: [String]
    }

    static func load(now: Date = .now) -> UsageStore {
        if let data = try? Data(contentsOf: fileURL),
           let snap = try? JSONDecoder.usage.decode(Snapshot.self, from: data) {
            return UsageStore(items: snap.items, queries: snap.queries, favorites: Set(snap.favorites))
        }
        if let data = try? Data(contentsOf: legacyURL),
           let counts = try? JSONDecoder().decode([String: Int].self, from: data) {
            return migrated(from: counts, now: now)
        }
        return UsageStore()
    }

    /// All-time counts carry no dates, so they seed a modest score that the
    /// half-life then fades unless the app keeps being used.
    static func migrated(from counts: [String: Int], now: Date) -> UsageStore {
        var store = UsageStore()
        for (name, count) in counts {
            if count < 0 {
                store.favorites.insert(name)
            } else if count > 0 {
                store.items[name] = Item(score: min(Double(count), 20) * 0.5, lastUsed: now)
            }
        }
        return store
    }

    mutating func save(now: Date = .now) {
        prune(now: now)
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let snap = Snapshot(items: items, queries: queries, favorites: favorites.sorted())
        if let data = try? JSONEncoder.usage.encode(snap) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    // MARK: - recording

    mutating func recordUse(_ key: String, query: String, now: Date = .now) {
        let calendarHour = Calendar.current.component(.hour, from: now)
        var item = items[key] ?? Item(score: 0, lastUsed: now)
        let factor = Self.decay(since: item.lastUsed, now: now)
        item.score = item.score * factor + 1
        item.hours = item.hours.map { $0 * factor }
        item.hours[calendarHour] += 1
        item.lastUsed = now
        items[key] = item

        let q = Self.normalize(query)
        guard !q.isEmpty else { return }
        var hits = queries[q] ?? [:]
        let old = hits[key]
        hits[key] = Hit(score: (old.map { $0.score * Self.decay(since: $0.lastUsed, now: now) } ?? 0) + 1,
                        lastUsed: now)
        queries[q] = hits
    }

    mutating func toggleFavorite(_ key: String) {
        if favorites.contains(key) { favorites.remove(key) } else { favorites.insert(key) }
    }

    /// Forget everything learned about one item (favourite status is kept).
    mutating func reset(_ key: String) {
        items[key] = nil
        for q in queries.keys {
            queries[q]?[key] = nil
            if queries[q]?.isEmpty == true { queries[q] = nil }
        }
    }

    mutating func resetAll() {
        items = [:]
        queries = [:]
    }

    // MARK: - reading

    func isFavorite(_ key: String) -> Bool { favorites.contains(key) }

    func hasUsage(_ key: String) -> Bool { items[key] != nil }

    /// Decayed use count: ~1 per use, halving every `halfLife`.
    func frecency(_ key: String, now: Date = .now) -> Double {
        guard let item = items[key] else { return 0 }
        return item.score * Self.decay(since: item.lastUsed, now: now)
    }

    /// How strongly `query` has led to picking `key`. Exact past queries
    /// count fully; a past query the current one is a prefix of (typing
    /// towards it) or that is a prefix of the current one counts half.
    func queryAffinity(_ key: String, query: String, now: Date = .now) -> Double {
        let q = Self.normalize(query)
        guard !q.isEmpty else { return 0 }
        var total = 0.0
        for (stored, hits) in queries {
            guard let hit = hits[key] else { continue }
            let weight: Double
            if stored == q { weight = 1 }
            else if stored.hasPrefix(q) || q.hasPrefix(stored) { weight = 0.5 }
            else { continue }
            total += weight * hit.score * Self.decay(since: hit.lastUsed, now: now)
        }
        return total
    }

    /// How much more (>1) or less (<1) than average `key` is used around
    /// this hour. Smoothed towards 1 so a handful of uses can't swing it.
    func hourAffinity(_ key: String, now: Date = .now) -> Double {
        guard let item = items[key] else { return 1 }
        let h = Calendar.current.component(.hour, from: now)
        let total = item.hours.reduce(0, +)
        guard total > 0 else { return 1 }
        // Neighbouring hours count half: habits don't respect the clock.
        let window = item.hours[h] + 0.5 * (item.hours[(h + 23) % 24] + item.hours[(h + 1) % 24])
        let uniform = 2.0 / 24.0       // share a uniform histogram puts in the window
        let prior = 4.0                // pseudo-uses spread uniformly
        let share = (window + prior * uniform) / (total + prior)
        return min(4, max(0.25, share / uniform))
    }

    /// Search boost added to the fuzzy score (which runs ~20–130). Learned
    /// query picks dominate — one pick (+40) is enough to beat a slightly
    /// better text match — while general frecency only breaks near-ties.
    func searchBoost(_ key: String, query: String, now: Date = .now) -> Int {
        let learned = min(80, 40 * log2(1 + queryAffinity(key, query: query, now: now)))
        let usage = min(30, 10 * log2(1 + frecency(key, now: now)))
        let favorite = isFavorite(key) ? 25.0 : 0
        return Int(learned + usage + favorite)
    }

    /// Empty-page ranking: frecency tilted by time of day.
    func suggestionScore(_ key: String, now: Date = .now) -> Double {
        frecency(key, now: now) * hourAffinity(key, now: now)
    }

    // MARK: - helpers

    static func decay(since then: Date, now: Date) -> Double {
        let dt = max(0, now.timeIntervalSince(then))
        return pow(0.5, dt / halfLife)
    }

    static func normalize(_ query: String) -> String {
        String(query.trimmingCharacters(in: .whitespaces).lowercased().prefix(maxQueryLength))
    }

    private mutating func prune(now: Date) {
        items = items.filter { $0.value.score * Self.decay(since: $0.value.lastUsed, now: now) >= Self.forgetBelow }
        for (q, hits) in queries {
            let kept = hits.filter { $0.value.score * Self.decay(since: $0.value.lastUsed, now: now) >= Self.forgetBelow }
            queries[q] = kept.isEmpty ? nil : kept
        }
    }
}

private extension JSONEncoder {
    static var usage: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

private extension JSONDecoder {
    static var usage: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
