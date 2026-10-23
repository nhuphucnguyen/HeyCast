import AppKit

@MainActor
final class EmojiExtension: HeyCastExtension, ExtensionPage {
    let id = "emoji"
    let title = "Emoji & Symbols"
    let symbolName = "face.smiling"
    let searchPlaceholder = "Search emoji & symbols…"
    let preferredSize: NSSize? = NSSize(width: 680, height: 460)
    private(set) var content = PageContent(layout: .grid(columns: 8), sections: [])

    var page: ExtensionPage? { self }

    private struct Usage: Codable {
        var count: Int
        var lastUsed: Date
    }

    private struct State: Codable {
        var pinned: [String] = []
        var usage: [String: Usage] = [:]
        var skinTone: Int?
    }

    private static let toneNames = ["Light", "Medium-Light", "Medium", "Medium-Dark", "Dark"]
    private static let frequentlyUsedLimit = 16
    private static let symbolsGroup = "Unicode Symbols"

    private lazy var catalog = EmojiCatalog.load()
    private lazy var emojiByCharacter: [String: Emoji] = {
        var map: [String: Emoji] = [:]
        for emoji in catalog.emoji {
            map[emoji.character] = emoji
            for variant in emoji.skinTones { map[variant] = emoji }
        }
        return map
    }()
    private var state: State?
    private var query = ""

    func commands(_ ctx: ExtensionContext) -> [ResultItem] {
        [ResultItem(id: "builtin-emoji", title: "Search Emoji & Symbols", subtitle: "Emoji",
                    icon: .symbol(symbolName), searchName: "emoji", action: .switchPage(.extension(id)))]
    }

    func didAppear(ctx: ExtensionContext) {
        if state == nil { state = ctx.store(for: id).load(State.self) ?? State() }
        query = ""
        rebuild()
    }

    func queryChanged(_ query: String, ctx: ExtensionContext) {
        self.query = query.trimmingCharacters(in: .whitespaces)
        rebuild()
    }

    // MARK: - actions

    func perform(_ key: String, payload: String, ctx: ExtensionContext) {
        switch key {
        case "paste", "paste-keep":
            recordUse(of: payload)
            ctx.paste(payload, keepOpen: key == "paste-keep")
        case "copy", "copy-keep":
            recordUse(of: payload)
            ctx.copy(payload, keepOpen: key == "copy-keep")
        case "copy-raw":
            ctx.copy(payload, keepOpen: false)
        case "toggle-pin":
            if state?.pinned.contains(payload) == true {
                state?.pinned.removeAll { $0 == payload }
            } else {
                state?.pinned.append(payload)
            }
        case "move-up", "move-down":
            movePinned(payload, by: key == "move-up" ? -1 : 1)
        case "reset-ranking":
            state?.usage[payload] = nil
        case "skin-tone":
            state?.skinTone = Int(payload)
        default:
            return
        }
        if let state { ctx.store(for: id).save(state) }
        rebuild()
        ctx.reloadPage()
    }

    private func recordUse(of character: String) {
        guard let base = emojiByCharacter[character]?.character else { return }
        state?.usage[base, default: Usage(count: 0, lastUsed: .now)].count += 1
        state?.usage[base]?.lastUsed = .now
    }

    private func movePinned(_ character: String, by delta: Int) {
        guard var pinned = state?.pinned, let index = pinned.firstIndex(of: character) else { return }
        let target = index + delta
        guard pinned.indices.contains(target) else { return }
        pinned.swapAt(index, target)
        state?.pinned = pinned
    }

    private func frecency(_ emoji: Emoji) -> Double {
        guard let usage = state?.usage[emoji.character] else { return 0 }
        let days = -usage.lastUsed.timeIntervalSinceNow / 86_400
        let recency = days < 1 ? 4 : days < 7 ? 2 : days < 30 ? 1 : 0.25
        return Double(usage.count) * recency
    }

    // MARK: - content

    private func rebuild() {
        content.sections = query.isEmpty ? browseSections() : [searchSection()]
    }

    private func browseSections() -> [ItemSection] {
        let pinned = (state?.pinned ?? []).compactMap { emojiByCharacter[$0] }
        let frequent = catalog.emoji
            .filter { frecency($0) > 0 && !(state?.pinned.contains($0.character) ?? false) }
            .sorted { frecency($0) > frecency($1) }
            .prefix(Self.frequentlyUsedLimit)
        var sections = [
            section("Pinned", Array(pinned), isPinned: true),
            section("Frequently Used", Array(frequent)),
        ]
        for (index, group) in catalog.groups.enumerated() {
            sections.append(section(group, catalog.emoji.filter { $0.group == index }))
        }
        return sections.filter { !$0.items.isEmpty }
    }

    private func searchSection() -> ItemSection {
        let results = catalog.search(query) { Int(min(9, frecency($0))) }
        return section("Results", results)
    }

    private func section(_ title: String, _ emoji: [Emoji], isPinned: Bool = false) -> ItemSection {
        let sectionText = emoji.map { $0.withSkinTone(state?.skinTone) }.joined()
        let items = emoji.map { entry in
            ResultItem(id: "\(title)-\(entry.character)",
                       title: entry.name.prefix(1).uppercased() + entry.name.dropFirst(),
                       icon: .emoji(entry.withSkinTone(state?.skinTone)),
                       actions: actions(for: entry, isPinned: isPinned, sectionText: sectionText))
        }
        return ItemSection(title: title, items: items)
    }

    private func actions(for emoji: Emoji, isPinned: Bool, sectionText: String) -> [ItemAction] {
        let shown = emoji.withSkinTone(state?.skinTone)
        let noun = catalog.groups[emoji.group] == Self.symbolsGroup ? "Symbol" : "Emoji"
        var actions = [
            ItemAction("Paste \(noun)", symbolName: "doc.on.clipboard", kind: run("paste", shown)),
            ItemAction("Copy \(noun)", symbolName: "doc.on.doc",
                       shortcut: ActionShortcut(key: ActionShortcut.returnKey, modifiers: [.command]),
                       kind: run("copy", shown)),
            ItemAction("Paste and Keep Window Open", symbolName: "doc.on.clipboard",
                       shortcut: ActionShortcut(key: ActionShortcut.returnKey, modifiers: [.option]),
                       kind: run("paste-keep", shown)),
            ItemAction("Copy and Keep Window Open", symbolName: "doc.on.doc",
                       shortcut: ActionShortcut(key: ActionShortcut.returnKey, modifiers: [.option, .command]),
                       kind: run("copy-keep", shown)),
        ]
        if !emoji.skinTones.isEmpty {
            actions.append(.submenu("Paste with Skin Tone…", symbolName: "hand.raised", toneChoices(emoji, key: "paste")))
            actions.append(.submenu("Copy with Skin Tone…", symbolName: "hand.raised", toneChoices(emoji, key: "copy")))
        }
        actions += [
            ItemAction("Copy Unicode", symbolName: "number",
                       shortcut: ActionShortcut(key: "u", modifiers: [.command, .shift]),
                       kind: run("copy-raw", emoji.unicodeDescription)),
            ItemAction("Copy All \(noun == "Emoji" ? "Emojis" : "Symbols") from Section", symbolName: "square.grid.2x2",
                       shortcut: ActionShortcut(key: "a", modifiers: [.command, .shift]),
                       kind: run("copy-raw", sectionText)),
        ]
        let pinned = state?.pinned.contains(emoji.character) ?? false
        actions.append(ItemAction(pinned ? "Unpin \(noun)" : "Pin \(noun)", symbolName: pinned ? "pin.slash" : "pin",
                                  shortcut: ActionShortcut(key: "p", modifiers: [.command, .shift]),
                                  kind: run("toggle-pin", emoji.character)))
        if isPinned {
            actions.append(ItemAction("Move Up in Pinned", symbolName: "arrow.up",
                                      shortcut: ActionShortcut(key: ActionShortcut.upArrow, modifiers: [.option, .command]),
                                      kind: run("move-up", emoji.character)))
            actions.append(ItemAction("Move Down in Pinned", symbolName: "arrow.down",
                                      shortcut: ActionShortcut(key: ActionShortcut.downArrow, modifiers: [.option, .command]),
                                      kind: run("move-down", emoji.character)))
        }
        if frecency(emoji) > 0 {
            actions.append(ItemAction("Reset Ranking", symbolName: "arrow.counterclockwise",
                                      kind: run("reset-ranking", emoji.character)))
        }
        if !emoji.skinTones.isEmpty {
            actions.append(.submenu("Set Default Skin Tone…", symbolName: "paintpalette", defaultToneChoices(emoji)))
        }
        return actions
    }

    private func toneChoices(_ emoji: Emoji, key: String) -> [ItemAction] {
        [ItemAction("\(emoji.character)  Default", kind: run(key, emoji.character))]
            + zip(emoji.skinTones, Self.toneNames).map { variant, name in
                ItemAction("\(variant)  \(name)", kind: run(key, variant))
            }
    }

    private func defaultToneChoices(_ emoji: Emoji) -> [ItemAction] {
        let current = state?.skinTone
        let none = ItemAction("\(emoji.character)  None", symbolName: current == nil ? "checkmark" : nil,
                              kind: run("skin-tone", ""))
        return [none] + emoji.skinTones.enumerated().map { index, variant in
            ItemAction("\(variant)  \(Self.toneNames[index])", symbolName: current == index ? "checkmark" : nil,
                       kind: run("skin-tone", String(index)))
        }
    }

    private func run(_ key: String, _ payload: String) -> ResultAction {
        .extension(id: id, key: key, payload: payload)
    }
}
