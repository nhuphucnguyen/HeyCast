import AppKit

enum Page: String, CaseIterable {
    case main
    case files
    case clipboard
    case emoji
    case assistant
    case uninstall
}

enum ResultIcon {
    case none
    case app(NSImage)     // real app/file icon
    case symbol(String)   // SF Symbol name
    case emoji(String)    // text glyph (emoji cell)
}

enum ResultAction: Equatable {
    case launchApp(URL, searchName: String)
    case openURL(URL)
    case runShell(String)
    case copyText(String)
    case showInFinder(URL)
    case toggleFavorite
    case uninstall(URL)
    case quitApp(String)
    case quitAll
    case quitSelf
    case switchPage(Page)
    case openSettings
    case reload
    case openEvent(String) // calendar identifier
    case display
    case askAgent(alias: String, text: String) // fire-and-forget assistant request
    case `extension`(id: String, key: String, payload: String)
}

struct ActionShortcut: Equatable {
    var key: String                      // charactersIgnoringModifiers, lowercased
    var modifiers: NSEvent.ModifierFlags

    static func == (lhs: ActionShortcut, rhs: ActionShortcut) -> Bool {
        lhs.key == rhs.key && lhs.modifiers == rhs.modifiers
    }

    func matches(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return flags == modifiers && event.charactersIgnoringModifiers?.lowercased() == key
    }

    var displayString: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        return out + key.uppercased()
    }
}

// Plain data so rows can later come from out-of-process extensions.
struct ItemAction: Equatable {
    enum Style { case regular, destructive }

    var title: String
    var symbolName: String?
    var shortcut: ActionShortcut?
    var style: Style = .regular
    var kind: ResultAction

    init(_ title: String? = nil, symbolName: String? = nil, shortcut: ActionShortcut? = nil,
         style: Style = .regular, kind: ResultAction) {
        self.title = title ?? Self.defaultTitle(for: kind)
        self.symbolName = symbolName
        self.shortcut = shortcut
        self.style = style
        self.kind = kind
    }

    private static func defaultTitle(for kind: ResultAction) -> String {
        switch kind {
        case .copyText: return "Copy to Clipboard"
        case .runShell: return "Run"
        case .showInFinder: return "Show in Finder"
        case .uninstall: return "Uninstall…"
        default: return "Open"
        }
    }
}

struct ResultItem: Identifiable, Equatable {
    static func == (lhs: ResultItem, rhs: ResultItem) -> Bool { lhs.id == rhs.id }

    let id: String
    var title: String
    var subtitle: String
    var icon: ResultIcon
    var favorite: Bool
    // First is the primary (↵) action.
    var actions: [ItemAction]
    var searchName: String?   // ranking/favourites key (apps, builtins, shells)

    var action: ResultAction { actions.first?.kind ?? .display }

    var hasActions: Bool { actions.contains { $0.kind != .display } }

    init(id: String,
         title: String,
         subtitle: String = "",
         icon: ResultIcon = .none,
         favorite: Bool = false,
         searchName: String? = nil,
         action: ResultAction) {
        self.init(id: id, title: title, subtitle: subtitle, icon: icon, favorite: favorite,
                  searchName: searchName, actions: [ItemAction(kind: action)])
    }

    init(id: String,
         title: String,
         subtitle: String = "",
         icon: ResultIcon = .none,
         favorite: Bool = false,
         searchName: String? = nil,
         actions: [ItemAction]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.favorite = favorite
        self.searchName = searchName
        self.actions = actions
    }
}

enum TilingPosition: String, CaseIterable {
    case leftHalf, rightHalf
    case topHalf, bottomHalf
    case topLeftQuarter, topRightQuarter, bottomLeftQuarter, bottomRightQuarter
    case leftThird, centerThird, rightThird
    case maximize

    var displayName: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeftQuarter: return "Top Left Quarter"
        case .topRightQuarter: return "Top Right Quarter"
        case .bottomLeftQuarter: return "Bottom Left Quarter"
        case .bottomRightQuarter: return "Bottom Right Quarter"
        case .leftThird: return "Left Third"
        case .centerThird: return "Center Third"
        case .rightThird: return "Right Third"
        case .maximize: return "Maximize"
        }
    }

    var symbolName: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeftQuarter: return "rectangle.split.2x2"
        case .topRightQuarter: return "rectangle.split.2x2"
        case .bottomLeftQuarter: return "rectangle.split.2x2"
        case .bottomRightQuarter: return "rectangle.split.2x2"
        case .leftThird: return "rectangle.leadingthird.filled"
        case .centerThird: return "rectangle.centerthird.filled"
        case .rightThird: return "rectangle.trailingthird.filled"
        case .maximize: return "arrow.up.backward.and.arrow.down.forward"
        }
    }
}
