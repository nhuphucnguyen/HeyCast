import AppKit

/// Emoji search backed by the bundled emoji.json dataset (generated from
/// Unicode character data — see scripts/gen_emoji.py).
struct EmojiEntry: Identifiable, Equatable {
    let id: Int
    let character: String
    let name: String
}

final class EmojiIndex {
    private(set) var entries: [EmojiEntry] = []

    func load(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var loaded: [EmojiEntry] = []
            if let url = Self.resourceURL,
               let data = try? Data(contentsOf: url),
               let raw = try? JSONDecoder().decode([[String: String]].self, from: data) {
                for (i, item) in raw.enumerated() {
                    guard let c = item["c"], let n = item["n"] else { continue }
                    loaded.append(EmojiEntry(id: i, character: c, name: n))
                }
            }
            DispatchQueue.main.async {
                self?.entries = loaded
                completion?()
            }
        }
    }

    static var resourceURL: URL? {
        if let url = Bundle.main.url(forResource: "emoji", withExtension: "json") {
            return url
        }
        return Bundle.module.url(forResource: "emoji", withExtension: "json")
    }

    func search(_ query: String, limit: Int = 120) -> [EmojiEntry] {
        guard !query.isEmpty else { return Array(entries.prefix(limit)) }
        var scored: [(EmojiEntry, Int)] = []
        for entry in entries {
            if let s = FuzzyMatch.score(query, entry.name) {
                scored.append((entry, s))
            }
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map(\.0)
    }
}
