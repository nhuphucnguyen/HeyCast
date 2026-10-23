// Regenerates Sources/HeyCast/Resources/emoji.json from Unicode data
// (emoji-test.txt + CLDR annotations, Unicode license).
//
//   swift scripts/gen_emoji.swift Sources/HeyCast/Resources/emoji.json

import Foundation

let emojiTestURL = "https://unicode.org/Public/emoji/latest/emoji-test.txt"
let annotationURLs = [
    "https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotations/en.xml",
    "https://raw.githubusercontent.com/unicode-org/cldr/main/common/annotationsDerived/en.xml",
]

let symbolsGroup = "Unicode Symbols"
let symbolRanges: [ClosedRange<UInt32>] = [
    0x0021...0x007E,  // ASCII punctuation
    0x00A1...0x00BF,  // Latin-1 punctuation and signs
    0x00D7...0x00D7, 0x00F7...0x00F7,
    0x0391...0x03C9,  // Greek letters
    0x2010...0x205E,  // general punctuation
    0x2070...0x209C,  // superscripts and subscripts
    0x20A0...0x20C0,  // currency
    0x2100...0x218B,  // letterlike and number forms
    0x2190...0x23FF,  // arrows, math operators, technical (⌘ ⌥ ⇧)
    0x25A0...0x27BF,  // geometric shapes, misc symbols, dingbats
    0x27F0...0x27FF, 0x2900...0x297F,  // supplemental arrows
    0x2B00...0x2B2F,
    0xF8FF...0xF8FF,  // Apple logo
]
let greekLetters: ClosedRange<UInt32> = 0x0391...0x03C9
let symbolCategories: Set<Unicode.GeneralCategory> = [
    .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
    .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
    .initialPunctuation, .finalPunctuation, .otherPunctuation,
    .letterNumber, .otherNumber, .privateUse,
]
// Mac keys CLDR doesn't annotate.
let extraKeywords: [String: [String]] = [
    "⌘": ["command", "cmd"], "⌥": ["option", "alt"], "⇧": ["shift"], "⌃": ["control", "ctrl"],
    "⇪": ["caps lock"], "⏎": ["return", "enter"], "↩": ["return", "enter"], "⌫": ["delete", "backspace"],
    "⌦": ["forward delete"], "⎋": ["escape", "esc"], "⇥": ["tab"], "⏏": ["eject"], "\u{F8FF}": ["apple", "mac"],
]
let skinTones: Set<UInt32> = [0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF]

struct Entry: Encodable {
    let c: String
    let n: String
    let g: Int
    let v: Double
    var k: [String]?
    var t: [String]?
}

struct Output: Encodable {
    let groups: [String]
    let emoji: [Entry]
}

func download(_ url: String) -> String {
    guard let data = try? Data(contentsOf: URL(string: url)!), let text = String(data: data, encoding: .utf8) else {
        fatalError("could not download \(url)")
    }
    return text
}

// Scalar-level: Character-based matching can't see a variation selector inside a cluster.
func bare(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.filter { $0 != "\u{FE0F}" })) }

final class Annotations: NSObject, XMLParserDelegate {
    var keywords: [String: [String]] = [:]
    var names: [String: String] = [:]
    private var cp: String?
    private var isName = false
    private var text = ""

    func parse(_ xml: String) {
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        guard element == "annotation" else { return }
        cp = attributes["cp"].map(bare)
        isName = attributes["type"] == "tts"
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        guard element == "annotation", let cp else { return }
        if isName {
            names[cp] = names[cp] ?? text
        } else if keywords[cp] == nil {
            keywords[cp] = text.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
        self.cp = nil
    }
}

let annotations = Annotations()
annotationURLs.forEach { annotations.parse(download($0)) }

func keywords(for character: String, name: String) -> [String]? {
    let words = ((extraKeywords[character] ?? []) + (annotations.keywords[bare(character)] ?? []))
        .filter { $0 != name.lowercased() }
    return words.isEmpty ? nil : words
}

// emoji-test.txt lines: "1F44B 1F3FB ; fully-qualified # 👋🏻 E1.0 waving hand: light skin tone"
let linePattern = try! NSRegularExpression(pattern: #"^([0-9A-F ]+?)\s*;\s*(\S+)\s*#\s*\S+\s+E(\d+\.\d+)\s+(.+)$"#)
var groups: [String] = []
var entries: [Entry] = []
var indexByBase: [String: Int] = [:]
var group = ""

for line in download(emojiTestURL).split(separator: "\n").map(String.init) {
    if line.hasPrefix("# group:") {
        group = line.dropFirst("# group:".count).trimmingCharacters(in: .whitespaces)
        if group != "Component" { groups.append(group) }
        continue
    }
    let range = NSRange(line.startIndex..., in: line)
    guard group != "Component",
          let match = linePattern.firstMatch(in: line, range: range),
          line[Range(match.range(at: 2), in: line)!] == "fully-qualified"
    else { continue }
    let field = { (i: Int) in String(line[Range(match.range(at: i), in: line)!]) }
    let scalars = field(1).split(separator: " ").compactMap { UInt32($0, radix: 16) }
    let character = String(String.UnicodeScalarView(scalars.compactMap(Unicode.Scalar.init)))
    let tones = scalars.filter(skinTones.contains)

    if !tones.isEmpty {
        let base = bare(String(String.UnicodeScalarView(scalars.filter { !skinTones.contains($0) }.compactMap(Unicode.Scalar.init))))
        if Set(tones).count == 1, let index = indexByBase[base] {
            entries[index].t = (entries[index].t ?? []) + [character]
        }
        continue
    }
    let name = field(4)
    indexByBase[bare(character)] = entries.count
    entries.append(Entry(c: character, n: name, g: groups.count - 1, v: Double(field(3))!,
                         k: keywords(for: character, name: name)))
}

for index in entries.indices where entries[index].t?.count != skinTones.count {
    entries[index].t = nil
}

let emojiCharacters = Set(entries.map { bare($0.c) })
groups.append(symbolsGroup)
for scalar in symbolRanges.joined().compactMap(Unicode.Scalar.init) {
    let character = String(scalar)
    let category = scalar.properties.generalCategory
    let isGreek = greekLetters.contains(scalar.value) && scalar.properties.isAlphabetic
    guard symbolCategories.contains(category) || isGreek, !emojiCharacters.contains(character) else { continue }
    let unicodeName = scalar == "\u{F8FF}" ? "apple logo" : scalar.properties.name?.lowercased()
    guard let name = annotations.names[character] ?? unicodeName else { continue }
    entries.append(Entry(c: character, n: name, g: groups.count - 1, v: 0, k: keywords(for: character, name: name)))
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
try! encoder.encode(Output(groups: groups, emoji: entries)).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
let emojiCount = entries.filter { $0.g < groups.count - 1 }.count
print("wrote \(emojiCount) emoji in \(groups.count - 1) groups (\(entries.filter { $0.t != nil }.count) with skin tones) "
      + "and \(entries.count - emojiCount) symbols")
