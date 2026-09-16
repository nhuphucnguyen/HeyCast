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

    init() {}

    // Tolerant decoding: a config written by an older build (missing keys)
    // must fall back to the declared defaults instead of failing the whole
    // file — the synthesized decoder throws keyNotFound for missing keys,
    // which used to reset every setting whenever a new field shipped.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let raw = try c.decodeIfPresent(String.self, forKey: .mode),
           let value = ThemeMode(rawValue: raw) { mode = value }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .blur) { blur = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .showIcons) { showIcons = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .showScrollBar) { showScrollBar = v }
        backgroundColor = try c.decodeIfPresent(String.self, forKey: .backgroundColor)
        textColor = try c.decodeIfPresent(String.self, forKey: .textColor)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
    }
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
    var clipboardCapturePaused: Bool = false
    var clipboardHistorySize: Int = 200
    var shells: [ShellCommandConfig] = []
    var modes: [String: String] = [:]
    var aliases: [String: String] = [:]
    var searchDirs: [String] = ["~"]
    var blacklist: [String] = []
    var debounceDelayMS: Int = 300
    var eventDurationMinutes: Int = 60
    var inputSourceOnOpen: String? = nil
    var restoreInputSourceOnClose: Bool = true

    init() {}

    // Tolerant decoding — see ThemeConfig.init(from:). Invalid enum values
    // also fall back to their defaults instead of discarding the file.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(String.self, forKey: .toggleHotkey) { toggleHotkey = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .clipboardHotkey) { clipboardHotkey = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .placeholder) { placeholder = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .searchURL) { searchURL = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .hapticFeedback) { hapticFeedback = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .showTrayIcon) { showTrayIcon = v }
        theme = try c.decodeIfPresent(ThemeConfig.self, forKey: .theme) ?? theme
        if let raw = try c.decodeIfPresent(String.self, forKey: .windowLocation),
           let v = WindowLocation(rawValue: raw) { windowLocation = v }
        if let raw = try c.decodeIfPresent(String.self, forKey: .mainPage),
           let v = MainPane(rawValue: raw) { mainPage = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .clearOnHide) { clearOnHide = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .clearOnEnter) { clearOnEnter = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .startAtLogin) { startAtLogin = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .showOnStartup) { showOnStartup = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .clipboardHistoryEnabled) { clipboardHistoryEnabled = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .clipboardPasteOnSelect) { clipboardPasteOnSelect = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .clipboardCapturePaused) { clipboardCapturePaused = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .clipboardHistorySize), (10...1000).contains(v) { clipboardHistorySize = v }
        if let v = try c.decodeIfPresent([ShellCommandConfig].self, forKey: .shells) { shells = v }
        if let v = try c.decodeIfPresent([String: String].self, forKey: .modes) { modes = v }
        if let v = try c.decodeIfPresent([String: String].self, forKey: .aliases) { aliases = v }
        if let v = try c.decodeIfPresent([String].self, forKey: .searchDirs) { searchDirs = v }
        if let v = try c.decodeIfPresent([String].self, forKey: .blacklist) { blacklist = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .debounceDelayMS) { debounceDelayMS = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .eventDurationMinutes) { eventDurationMinutes = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .inputSourceOnOpen) { inputSourceOnOpen = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .restoreInputSourceOnClose) { restoreInputSourceOnClose = v }
    }

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
            try? FileManager.default.removeItem(at: backup)
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
