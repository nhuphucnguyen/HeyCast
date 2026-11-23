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

/// A chat/agent endpoint reachable from the Assistant page. Hermes is one
/// example; any OpenAI-compatible API, the Anthropic API, or an MCP
/// streamable-HTTP server works. API keys live in config.json for now
/// (Keychain hardening is a planned follow-up).
struct AgentConfig: Codable, Equatable {
    var name: String = ""               // display name, e.g. "Hermes"
    var alias: String = ""              // "@alias question" routing prefix
    var type: String = "openai"         // openai | anthropic | mcp
    var baseURL: String = ""            // openai: incl. /v1; mcp: endpoint URL
    var model: String? = nil            // openai/anthropic model id
    var tool: String? = nil             // mcp: tool to call (else first listed)
    var apiKey: String? = nil           // Bearer / x-api-key; oauth: phase 2
    var visionModel: String? = nil      // used when a screenshot is attached
    var visionBaseURL: String? = nil    // e.g. z.ai vision lives on the general endpoint
}

// Tolerant decoding (see notes on Config) lives in an extension so the
// memberwise initializer keeps working for call sites that build agents.
extension AgentConfig {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(String.self, forKey: .name) { name = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .alias) { alias = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .type) { type = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .baseURL) { baseURL = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .model) { model = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .tool) { tool = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .apiKey) { apiKey = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .visionModel) { visionModel = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .visionBaseURL) { visionBaseURL = v }
    }
}

struct ThemeConfig: Codable, Equatable {
    var mode: ThemeMode = .dark
    var blur: Bool = true
    /// Liquid Glass panel background (macOS 26+); ignored on older systems.
    var liquidGlass: Bool = true
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
        if let v = try c.decodeIfPresent(Bool.self, forKey: .liquidGlass) { liquidGlass = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .showIcons) { showIcons = v }
        if let v = try c.decodeIfPresent(Bool.self, forKey: .showScrollBar) { showScrollBar = v }
        backgroundColor = try c.decodeIfPresent(String.self, forKey: .backgroundColor)
        textColor = try c.decodeIfPresent(String.self, forKey: .textColor)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
    }
}

struct Config: Codable, Equatable {
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
    var clipboardImagePreviewPopOut: Bool = true
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
    var agents: [AgentConfig] = []
    var defaultAgent: String? = nil  // alias of the agent ⌘↵ / the ask page use
    // Notes capture prefixes typed in the main search; "" disables one.
    // Trigger prefixes are unified: special triggers always start with "@"
    // or "/" ("/" is the default style). Values saved by older builds that
    // still equal the old defaults migrate to the new slash defaults.
    var assistantPrefix: String = "/"         // "/alias question" (was "@" hardcoded)
    var notesInboxPrefix: String = "/todo "   // todo/thought capture (was "/t ", then ";")
    var notesWordPrefix: String = "/word "    // vocabulary capture (was "/w ", then "w ")
    var notesNotePrefix: String = "/note "    // titled note capture (was "/n ", then "n ")
    var tcPrefix: String = "/tc"              // Thanh Cong TC feed
    // Thanh Cong TC feed (/tc) — read-only Mighty Networks reader. The data
    // access rules are documented in the thanhcongtc repo
    // (docs/mighty-networks-data-access.md): browser-session cookies in a
    // Netscape jar, GETs only, client-side author filter.
    var tcCookiePath: String = "~/.cache/thanhcongtc.cookies.txt"
    var tcAuthor: String = "Thanh Cong Vu"
    var tcRootSpaceID: Int = 23859093
    var tcSpaces: [Int] = [23941095, 23877153, 23894431, 24278852]
    var tcRefreshMinutes: Int = 15

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
        if let v = try c.decodeIfPresent(Bool.self, forKey: .clipboardImagePreviewPopOut) { clipboardImagePreviewPopOut = v }
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
        if let v = try c.decodeIfPresent([AgentConfig].self, forKey: .agents) { agents = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .defaultAgent) { defaultAgent = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .notesInboxPrefix) { notesInboxPrefix = Self.migratedTrigger(v, oldDefault: "/t ", newDefault: "/todo ") }
        if let v = try c.decodeIfPresent(String.self, forKey: .notesWordPrefix) { notesWordPrefix = Self.migratedTrigger(v, oldDefault: "/w ", newDefault: "/word ") }
        if let v = try c.decodeIfPresent(String.self, forKey: .notesNotePrefix) { notesNotePrefix = Self.migratedTrigger(v, oldDefault: "/n ", newDefault: "/note ") }
        if let v = try c.decodeIfPresent(String.self, forKey: .assistantPrefix) { assistantPrefix = Self.migratedTrigger(v, oldDefault: "", newDefault: "/") }
        if let v = try c.decodeIfPresent(String.self, forKey: .tcPrefix) { tcPrefix = Self.migratedTrigger(v, oldDefault: "", newDefault: "/tc") }
        if let v = try c.decodeIfPresent(String.self, forKey: .tcCookiePath) { tcCookiePath = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .tcAuthor) { tcAuthor = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .tcRootSpaceID) { tcRootSpaceID = v }
        if let v = try c.decodeIfPresent([Int].self, forKey: .tcSpaces) { tcSpaces = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .tcRefreshMinutes), (5...1440).contains(v) { tcRefreshMinutes = v }
    }

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("HeyCast", isDirectory: true)
    }()

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    enum FileIssue: Error { case missing }

    /// Reads + decodes config.json. Throws `.missing` when the file isn't
    /// there and the decoding error when the JSON is broken (e.g. an editor
    /// mid-save) — callers that must not lose the running config use this
    /// instead of `load()`.
    static func loadFromDisk() throws -> Config {
        guard let data = try? Data(contentsOf: fileURL) else { throw FileIssue.missing }
        return try JSONDecoder().decode(Config.self, from: data)
    }

    static func load() -> Config {
        let defaults = Config()
        do {
            return try loadFromDisk()
        } catch FileIssue.missing {
            defaults.save()
            return defaults
        } catch {
            // Keep valid parts by decoding field-by-field is overkill; fall back
            // to defaults but preserve the broken file for the user to inspect.
            let backup = directory.appendingPathComponent("config.json.invalid")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            return defaults
        }
    }

    // MARK: - search trigger prefixes

    /// Unified trigger style: special triggers always start with "@" or "/",
    /// or are empty (which disables a notes capture trigger). Anything else —
    /// including values saved before the unification that match the old
    /// defaults — falls back to the new default.
    static func migratedTrigger(_ stored: String, oldDefault: String, newDefault: String) -> String {
        if stored.isEmpty { return oldDefault.isEmpty ? newDefault : stored }
        if stored == oldDefault { return newDefault }
        if stored.hasPrefix("@") || stored.hasPrefix("/") { return stored }
        return newDefault
    }

    /// Same rule for values edited in Settings (applied before saving).
    static func sanitizedTrigger(_ value: String, fallback: String, allowEmpty: Bool) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return allowEmpty ? "" : fallback }
        if trimmed.hasPrefix("@") || trimmed.hasPrefix("/") { return value }
        return fallback
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
