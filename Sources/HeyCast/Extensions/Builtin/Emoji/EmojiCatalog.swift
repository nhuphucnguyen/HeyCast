import AppKit
import CoreText

struct Emoji: Decodable {
    let character: String
    let name: String
    let group: Int
    let version: Double
    let keywords: [String]
    let skinTones: [String]

    private enum CodingKeys: String, CodingKey {
        case character = "c", name = "n", group = "g", version = "v", keywords = "k", skinTones = "t"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        character = try c.decode(String.self, forKey: .character)
        name = try c.decode(String.self, forKey: .name)
        group = try c.decode(Int.self, forKey: .group)
        version = try c.decode(Double.self, forKey: .version)
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        skinTones = try c.decodeIfPresent([String].self, forKey: .skinTones) ?? []
    }

    func withSkinTone(_ tone: Int?) -> String {
        guard let tone, skinTones.indices.contains(tone) else { return character }
        return skinTones[tone]
    }

    var unicodeDescription: String {
        character.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }
}

struct EmojiCatalog {
    let groups: [String]
    let emoji: [Emoji]

    private struct File: Decodable {
        let groups: [String]
        let emoji: [Emoji]
    }

    // macOS 13, the minimum deployment target, ships Emoji 15.0.
    private static let alwaysSupportedVersion = 15.0

    static func load() -> EmojiCatalog {
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "json")
                ?? Bundle.module.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data)
        else { return EmojiCatalog(groups: [], emoji: []) }
        let renderable = file.emoji.filter { $0.version <= alwaysSupportedVersion || rendersAsOneGlyph($0.character) }
        return EmojiCatalog(groups: file.groups, emoji: renderable)
    }

    private static func rendersAsOneGlyph(_ text: String) -> Bool {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun], runs.count == 1 else { return false }
        let attributes = CTRunGetAttributes(runs[0]) as NSDictionary
        let runFont = attributes[kCTFontAttributeName] as! CTFont
        return CTRunGetGlyphCount(runs[0]) == 1
            && (CTFontCopyPostScriptName(runFont) as String).hasPrefix("AppleColorEmoji")
    }

    func search(_ query: String, boost: (Emoji) -> Int) -> [Emoji] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return emoji.enumerated()
            .compactMap { index, entry in score(entry, words: words).map { (index, entry, $0 * 10 + boost(entry)) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }

    private func score(_ entry: Emoji, words: [String]) -> Int? {
        let name = entry.name.lowercased()
        let nameWords = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var total = 0
        for word in words {
            if nameWords.contains(word) { total += 6 }
            else if entry.keywords.contains(word) { total += 4 }
            else if nameWords.contains(where: { $0.hasPrefix(word) }) { total += 3 }
            else if entry.keywords.contains(where: { $0.hasPrefix(word) }) { total += 2 }
            else { return nil }
        }
        if name == words.joined(separator: " ") { total += 10 }
        else if nameWords.first == words.first { total += 2 }
        return total
    }
}
