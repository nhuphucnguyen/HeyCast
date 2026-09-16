import AppKit

enum Page: String, CaseIterable {
    case main
    case files
    case clipboard
    case emoji
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
    case copyEmoji(String)
    case quitApp(String)
    case quitAll
    case quitSelf
    case tile(TilingPosition)
    case switchPage(Page)
    case openSettings
    case reload
    case openEvent(String) // calendar identifier
    case display
}

struct ResultItem: Identifiable, Equatable {
    static func == (lhs: ResultItem, rhs: ResultItem) -> Bool { lhs.id == rhs.id }

    let id: String
    var title: String
    var subtitle: String
    var icon: ResultIcon
    var favorite: Bool
    var action: ResultAction
    var searchName: String?   // ranking/favourites key (apps, builtins, shells)

    init(id: String,
         title: String,
         subtitle: String = "",
         icon: ResultIcon = .none,
         favorite: Bool = false,
         searchName: String? = nil,
         action: ResultAction) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.favorite = favorite
        self.searchName = searchName
        self.action = action
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
