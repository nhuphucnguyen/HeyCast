import Foundation

enum ThemeMode: String, Codable, CaseIterable {
    case dark, light, system
}

enum MainPane: String, Codable, CaseIterable {
    case blank, favourites, frequentlyUsed, events

    var displayName: String {
        switch self {
        case .blank: return "HeyCast"
        case .favourites: return "Favourites"
        case .frequentlyUsed: return "Frequently Used"
        case .events: return "Events"
        }
    }
}

enum WindowLocation: String, Codable, CaseIterable {
    case mouseScreenTopCenter // "default": top center of the screen under the mouse
    case topLeft, topCenter, topRight
    case middleLeft, middleCenter, middleRight
    case bottomLeft, bottomCenter, bottomRight
}

struct ShellCommandConfig: Codable, Equatable {
    var command: String
    var alias: String
    var hotkey: String?
    var iconPath: String?
}

struct ThemeConfig: Codable {
    var mode: ThemeMode = .dark
    var blur: Bool = true
    var showIcons: Bool = true
    var showScrollBar: Bool = false
    var backgroundColor: String? = nil  // hex like "#101014", overrides preset
    var textColor: String? = nil
    var fontName: String? = nil
}

struct Config: Codable {
    var toggleHotkey: String = "ALT+SPACE"
    var clipboardHotkey: String = "SUPER+SHIFT+C"
    var placeholder: String = "Time to be productive!"
    var searchURL: String = "https://duckduckgo.com/?q=%s"
    var hapticFeedback: Bool = false
    var showTrayIcon: Bool = true
    var theme: ThemeConfig = ThemeConfig()
    var windowLocation: WindowLocation = .mouseScreenTopCenter
    var mainPage: MainPane = .blank
    var clearOnHide: Bool = false
    var clearOnEnter: Bool = true
    var startAtLogin: Bool = false
    var showOnStartup: Bool = false
    var clipboardHistoryEnabled: Bool = true
    var clipboardPasteOnSelect: Bool = false
    var shells: [ShellCommandConfig] = []
    var modes: [String: String] = [:]
    var aliases: [String: String] = [:]
    var searchDirs: [String] = ["~"]
    var blacklist: [String] = []
    var debounceDelayMS: Int = 300
    var eventDurationMinutes: Int = 60
    var inputSourceOnOpen: String? = nil
    var restoreInputSourceOnClose: Bool = true

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HeyCast", isDirectory: true)
    }()

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    static func load() -> Config {
        let defaults = Config()
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: Self.fileURL) else {
            defaults.save()
            return defaults
        }
        do {
            let decoded = try JSONDecoder().decode(Config.self, from: data)
            return decoded
        } catch {
            // Keep valid parts by decoding field-by-field is overkill; fall back
            // to defaults but preserve the broken file for the user to inspect.
            let backup = directory.appendingPathComponent("config.json.invalid")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            return defaults
        }
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

struct RankingStore {
    /// search name -> usage count. A count of -1 marks a favourite.
    private(set) var counts: [String: Int] = [:]

    static var fileURL: URL { Config.directory.appendingPathComponent("ranking.json") }

    static func load() -> RankingStore {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let dict = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return RankingStore()
        }
        return RankingStore(counts: dict)
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(counts) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    func isFavorite(_ name: String) -> Bool { counts[name] == -1 }
    func usage(of name: String) -> Int { max(0, counts[name] ?? 0) }

    mutating func bump(_ name: String) {
        let current = counts[name] ?? 0
        counts[name] = current < 0 ? current : current + 1
    }

    mutating func toggleFavorite(_ name: String) {
        if counts[name] == -1 {
            counts[name] = 0
        } else {
            counts[name] = -1
        }
    }
}
