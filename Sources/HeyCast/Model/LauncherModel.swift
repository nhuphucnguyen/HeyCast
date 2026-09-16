import AppKit
import Combine
import UniformTypeIdentifiers

/// Central launcher state machine. Owns the query/results/pages and dispatches
/// result actions to the native services. All state lives on the main actor.
@MainActor
final class LauncherModel: ObservableObject {
    // MARK: published UI state
    @Published var query = "" {
        didSet { queryChanged() }
    }
    @Published private(set) var results: [ResultItem] = []
    @Published var selectedIndex = 0
    @Published private(set) var page: Page = .main
    @Published private(set) var mode = "default"
    @Published private(set) var theme: Theme
    @Published private(set) var clipboardItems: [ClipboardEntry] = []
    @Published private(set) var emojiResults: [EmojiEntry] = []
    @Published private(set) var fileResults: [FileSearchService.FileHit] = []
    @Published var clipboardPreviewIndex: Int? = nil
    @Published private(set) var showFavoriteHint = false

    // MARK: config & stores
    var config: Config {
        didSet {
            theme = Theme.resolve(config: config, systemDark: systemDark)
            applyHotkeys()
        }
    }
    var ranking: RankingStore {
        didSet { scheduleRankingSave() }
    }

    // MARK: services
    let appIndex = AppIndex()
    let emojiIndex = EmojiIndex()
    let clipboardStore = ClipboardStore()
    let fileSearchService = FileSearchService()
    let calendarService = CalendarService()

    // MARK: window/session state (wired by PanelController/AppDelegate)
    var frontmostApp: NSRunningApplication?
    var savedInputSource: String?
    var onShowPanel: (() -> Void)?
    var onHidePanel: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onLayoutChanged: (() -> Void)?
    private var shellHotkeys: [Shortcut: ShellCommandConfig] = [:]
    private var rankingSaveTask: Task<Void, Never>?
    private var fileSearchDebounceTask: Task<Void, Never>?
    private var emojiDebounceTask: Task<Void, Never>?

    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    init() {
        config = Config.load()
        ranking = RankingStore.load()
        theme = Theme.resolve(config: config, systemDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)

        observeSystemAppearance()
        fileSearchService.onUpdate = { [weak self] in self?.fileSearchUpdated() }

        clipboardItems = clipboardStore.load(limit: 300)

        emojiIndex.load { [weak self] in
            guard let self, self.page == .emoji else { return }
            self.emojiResults = Array(self.emojiIndex.entries.prefix(120))
            self.onLayoutChanged?()
        }
        appIndex.load(blacklist: config.blacklist) { [weak self] in
            guard let self, self.page == .main else { return }
            self.refreshResults()
        }
        calendarService.requestAccess()
        applyHotkeys()
        if config.mainPage == .events {
            refreshResults()
        }
    }

    // MARK: - window control

    @Published private(set) var panelIsVisible = false

    func toggle() {
        if panelIsVisible { hide() } else { show() }
    }

    func show(to targetPage: Page = .main) {
        frontmostApp = NSWorkspace.shared.frontmostApplication
        if config.restoreInputSourceOnClose {
            savedInputSource = InputSourceService.currentSourceID()
        }
        if let source = config.inputSourceOnOpen {
            _ = InputSourceService.select(sourceID: source)
        }
        page = targetPage
        query = ""
        selectedIndex = 0
        clipboardPreviewIndex = nil
        refreshResults()
        panelIsVisible = true
        onShowPanel?()
    }

    func hide() {
        panelIsVisible = false
        if config.restoreInputSourceOnClose, let saved = savedInputSource {
            _ = InputSourceService.select(sourceID: saved)
            savedInputSource = nil
        }
        if config.clearOnHide && !query.isEmpty {
            query = ""
            refreshResults()
        }
        onHidePanel?()
    }

    // MARK: - pages

    func switchPage(_ target: Page) {
        page = target
        query = ""
        selectedIndex = 0
        clipboardPreviewIndex = nil
        refreshResults()
        onLayoutChanged?()
    }

    func escPressed() {
        if !query.isEmpty {
            query = ""
        } else if page != .main {
            switchPage(.main)
        } else {
            hide()
        }
    }

    // MARK: - selection

    var maxSelection: Int {
        switch page {
        case .emoji: return emojiResults.count
        case .clipboard: return filteredClipboardItems.count
        case .files: return fileResults.count
        case .main: return results.count
        }
    }

    func moveSelection(_ delta: Int) {
        let count = maxSelection
        guard count > 0 else { return }
        var next = selectedIndex + delta
        if next < 0 { next = count - 1 }
        if next >= count { next = 0 }
        selectedIndex = next
        if page == .clipboard {
            clipboardPreviewIndex = filteredClipboardItems.indices.contains(selectedIndex) ? selectedIndex : nil
        }
    }

    func openFocused() {
        switch page {
        case .main:
            guard results.indices.contains(selectedIndex) else { return }
            openResult(results[selectedIndex])
        case .files:
            guard fileSearchService.results.indices.contains(selectedIndex) else { return }
            let hit = fileSearchService.results[selectedIndex]
            NSWorkspace.shared.open(URL(fileURLWithPath: hit.path))
            afterOpen(searchName: nil, hideWindow: true)
        case .clipboard:
            guard filteredClipboardItems.indices.contains(selectedIndex) else { return }
            copyClipboardEntry(filteredClipboardItems[selectedIndex])
        case .emoji:
            guard emojiResults.indices.contains(selectedIndex) else { return }
            copyText(emojiResults[selectedIndex].character)
        }
    }

    // MARK: - query pipeline

    private func queryChanged() {
        switch page {
        case .main:
            refreshResults()
            HapticsService.tick(enabled: config.hapticFeedback)
        case .files:
            fileSearchDebounceTask?.cancel()
            let text = query
            if text.count < 2 {
                fileSearchService.cancel()
                fileSearchService.results = []
                onLayoutChanged?()
                return
            }
            fileSearchDebounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.config.debounceDelayMS ?? 300) * 1_000_000))
                guard !Task.isCancelled else { return }
                self?.runFileSearch(text)
            }
        case .emoji:
            emojiDebounceTask?.cancel()
            let text = query
            emojiDebounceTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.config.debounceDelayMS ?? 300) * 1_000_000))
                guard !Task.isCancelled else { return }
                self?.runEmojiSearch(text)
            }
        case .clipboard:
            selectedIndex = 0
            clipboardPreviewIndex = nil
        }
        onLayoutChanged?()
    }

    private func runFileSearch(_ text: String) {
        fileResults = []
        fileSearchService.search(text, searchDirs: config.searchDirs)
        selectedIndex = 0
        onLayoutChanged?()
    }

    private func runEmojiSearch(_ text: String) {
        emojiResults = emojiIndex.search(text)
        selectedIndex = 0
        onLayoutChanged?()
    }

    private func fileSearchUpdated() {
        fileResults = fileSearchService.results
        guard page == .files else { return }
        if !fileResults.indices.contains(selectedIndex) {
            selectedIndex = max(0, fileResults.count - 1)
        }
        onLayoutChanged?()
    }

    // MARK: main page result assembly

    func refreshResults() {
        guard page == .main else { return }
        if query.isEmpty {
            results = emptyQueryResults()
        } else {
            results = searchResults(for: query)
        }
        if !results.indices.contains(selectedIndex) { selectedIndex = 0 }
        onLayoutChanged?()
    }

    private func emptyQueryResults() -> [ResultItem] {
        switch config.mainPage {
        case .favourites:
            let favs = appIndex.apps.filter { ranking.isFavorite($0.searchName) }
                .sorted { $0.name < $1.name }
                .map { self.result(for: $0) }
            return favs.isEmpty ? builtinResults().filter { $0.action != .display } : favs + builtinResults()
        case .frequentlyUsed:
            let ranked = appIndex.apps
                .filter { ranking.usage(of: $0.searchName) > 0 }
                .sorted { ranking.usage(of: $0.searchName) > ranking.usage(of: $1.searchName) }
                .prefix(5)
                .map { self.result(for: $0) }
            return ranked
        case .events:
            let events = calendarService.upcomingEvents(withinMinutes: config.eventDurationMinutes)
            return events.map { event in
                ResultItem(id: "event-\(event.id)",
                           title: event.title,
                           subtitle: event.subtitle,
                           icon: .symbol("calendar"),
                           action: .openEvent(event.id))
            }
        case .blank:
            return builtinResults()
        }
    }

    private func result(for entry: AppIndex.Entry) -> ResultItem {
        ResultItem(id: "app-\(entry.path)",
                   title: entry.name,
                   subtitle: "Application",
                   icon: .app(entry.icon),
                   favorite: ranking.isFavorite(entry.searchName),
                   searchName: entry.searchName,
                   action: .launchApp(URL(fileURLWithPath: entry.path), searchName: entry.searchName))
    }

    private func searchResults(for rawQuery: String) -> [ResultItem] {
        var query = rawQuery
        if let expanded = config.aliases[query.lowercased()] {
            query = expanded
        }

        // Easter eggs: exact matches short-circuit everything else.
        if let egg = easterEggResult(for: query.lowercased()) {
            return [egg]
        }

        var out: [ResultItem] = []

        // App fuzzy search
        let matches = appIndex.search(query)
        for (entry, score) in matches.prefix(30) {
            let usageBoost = ranking.usage(of: entry.searchName) * 2
            let favBoost = ranking.isFavorite(entry.searchName) ? 10_000 : 0
            _ = score + usageBoost + favBoost
            out.append(result(for: entry))
        }

        // Shell commands
        for shell in config.shells {
            if let s = FuzzyMatch.score(query, shell.alias.lowercased()) {
                out.append(ResultItem(id: "shell-\(shell.alias)",
                                      title: shell.alias,
                                      subtitle: "Shell Command",
                                      icon: .symbol("terminal"),
                                      searchName: "shell:\(shell.alias)",
                                      action: .runShell(shell.command)))
                _ = s
            }
        }

        // Modes
        for (name, command) in config.modes.sorted(by: { $0.key < $1.key }) {
            if let s = FuzzyMatch.score(query, "\(name) mode") {
                out.append(ResultItem(id: "mode-\(name)",
                                      title: "\(name.capitalized) Mode",
                                      subtitle: "Switch Modes",
                                      icon: .symbol("switch.2"),
                                      searchName: "mode:\(name)",
                                      action: .runShell(command)))
                _ = s
            }
        }

        // Builtins
        for builtin in builtinResults() {
            if let s = FuzzyMatch.score(query, builtin.title.lowercased()) {
                out.append(builtin)
                _ = s
            }
        }

        // Tiling actions
        for tile in TilingPosition.allCases {
            if let s = FuzzyMatch.score(query, tile.displayName.lowercased()) {
                out.append(ResultItem(id: "tile-\(tile.rawValue)",
                                      title: tile.displayName,
                                      subtitle: "Window Tiling",
                                      icon: .symbol(tile.symbolName),
                                      action: .tile(tile)))
                _ = s
            }
        }

        // Quit …
        if query.lowercased().hasPrefix("quit") {
            out.append(ResultItem(id: "builtin-quit-self",
                                  title: "Quit HeyCast",
                                  subtitle: "Utility",
                                  icon: .symbol("power"),
                                  action: .quitSelf))
            out.append(ResultItem(id: "builtin-quit-all",
                                  title: "Quit All Apps",
                                  subtitle: "Utility",
                                  icon: .symbol("power.dotted"),
                                  action: .quitAll))
            for app in AppIndex.runningAppNames() where app.name.lowercased().hasPrefix(String(query.dropFirst(4)).trimmingCharacters(in: .whitespaces).lowercased()) || query.lowercased() == "quit" {
                out.append(ResultItem(id: "quit-\(app.name)",
                                      title: "Quit \(app.name)",
                                      subtitle: "Quit App",
                                      icon: app.path.map { .app(AppIndex.icon(for: $0)) } ?? .symbol("xmark.app"),
                                      action: .quitApp(app.name)))
            }
        }

        // Deferred classifiers are shown when nothing else matched.
        if out.isEmpty {
            out = deferredResults(for: query)
        }
        return Array(out.prefix(30))
    }

    /// URL / unit conversion / calculator / web-search rows.
    private func deferredResults(for query: String) -> [ResultItem] {
        var out: [ResultItem] = []

        if isURLLike(query) {
            let urlString = query.hasPrefix("http://") || query.hasPrefix("https://") ? query : "https://" + query
            if let url = URL(string: urlString) {
                out.append(ResultItem(id: "url-\(query)",
                                      title: "Open \(url.host ?? query)",
                                      subtitle: "Website",
                                      icon: .symbol("globe"),
                                      action: .openURL(url)))
            }
        }

        if let conversions = UnitConversion.convert(query) {
            for conversion in conversions.prefix(8) {
                out.append(ResultItem(id: "unit-\(query)-\(conversion.targetUnit)",
                                      title: "\(conversion.value) \(conversion.targetUnit)",
                                      subtitle: conversion.sourceDescription,
                                      icon: .symbol("ruler"),
                                      action: .copyText("\(conversion.value) \(conversion.targetUnit)")))
            }
        }

        if let value = Calculator.evaluate(query) {
            out.append(ResultItem(id: "calc-\(query)",
                                  title: Calculator.format(value),
                                  subtitle: query,
                                  icon: .symbol("equal.square"),
                                  action: .copyText(Calculator.format(value))))
        }

        let wordCount = query.split(separator: " ").count
        if query.hasSuffix("?") || wordCount >= 3 {
            let searchTerms = query.hasSuffix("?") ? String(query.dropLast()) : query
            if let url = searchURL(for: searchTerms) {
                out.append(ResultItem(id: "web-\(query)",
                                      title: "Search for: \(searchTerms)",
                                      subtitle: "Web Search",
                                      icon: .symbol("magnifyingglass"),
                                      action: .openURL(url)))
            }
        }
        return out
    }

    private func searchURL(for terms: String) -> URL? {
        let encoded = terms.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: " ", with: "+") ?? terms
        let template = config.searchURL
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    private func isURLLike(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(where: { $0.isWhitespace }) { return false }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return true }
        // crude reversed-TLD heuristic: something.tld
        guard let dotRange = trimmed.range(of: ".", options: .backwards) else { return false }
        let tld = trimmed[dotRange.upperBound...]
        let host = trimmed[..<dotRange.lowerBound]
        return tld.count >= 2 && tld.allSatisfy(\.isLetter) && !host.isEmpty
    }

    private func easterEggResult(for query: String) -> ResultItem? {
        switch query {
        case "randomvar":
            let n = Int.random(in: 0...100)
            return ResultItem(id: "egg-randomvar", title: "\(n)", subtitle: "Easter egg",
                              icon: .symbol("dice"), action: .copyText("\(n)"))
        case "67":
            return ResultItem(id: "egg-67", title: "67", subtitle: "Easter egg",
                              icon: .symbol("dice"), action: .copyText("67"))
        case "lemon":
            return ResultItem(id: "egg-lemon", title: "Lemon", subtitle: "🍋 Easter egg",
                              icon: .emoji("🍋"), action: .display)
        case "zombo":
            return ResultItem(id: "egg-zombo", title: "🫳 🌱", subtitle: "Welcome to zombo.com",
                              icon: .none, action: .openURL(URL(string: "https://zombo.com")!))
        default:
            return nil
        }
    }

    private func builtinResults() -> [ResultItem] {
        var out = [
            ResultItem(id: "builtin-settings", title: "Open HeyCast Preferences", subtitle: "Settings",
                       icon: .symbol("gearshape"), searchName: "settings", action: .openSettings),
            ResultItem(id: "builtin-emoji", title: "Search for an Emoji", subtitle: "Emoji search",
                       icon: .symbol("face.smiling"), searchName: "emoji", action: .switchPage(.emoji)),
            ResultItem(id: "builtin-clipboard", title: "Clipboard History", subtitle: "Clipboard",
                       icon: .symbol("clipboard"), searchName: "clipboard", action: .switchPage(.clipboard)),
            ResultItem(id: "builtin-files", title: "Search for a file", subtitle: "File search",
                       icon: .symbol("folder"), searchName: "file search", action: .switchPage(.files)),
            ResultItem(id: "builtin-reload", title: "Reload HeyCast", subtitle: "Reloads config & apps",
                       icon: .symbol("arrow.clockwise"), searchName: "reload", action: .reload),
            ResultItem(id: "builtin-version", title: "HeyCast v\(Self.appVersion)", subtitle: "Ready when you are.",
                       icon: .symbol("bolt.fill"), action: .display),
            ResultItem(id: "builtin-ferris", title: "Ferris Plushies", subtitle: "Easter egg",
                       icon: .symbol("crown"), action: .openURL(URL(string: "https://ferris.rs")!)),
        ]
        // favourites toggle hint for app rows is handled in the row UI
        out.append(contentsOf: builtinTileResults())
        return out
    }

    private func builtinTileResults() -> [ResultItem] {
        TilingPosition.allCases.map { tile in
            ResultItem(id: "tile-\(tile.rawValue)",
                       title: tile.displayName,
                       subtitle: "Window Tiling",
                       icon: .symbol(tile.symbolName),
                       action: .tile(tile))
        }
    }

    // MARK: - actions

    func openResult(_ item: ResultItem) {
        switch item.action {
        case let .launchApp(url, searchName):
            NSWorkspace.shared.open(url)
            ranking.bump(searchName)
            afterOpen(searchName: searchName, hideWindow: true)

        case .openURL(let url):
            NSWorkspace.shared.open(url)
            afterOpen(searchName: item.searchName, hideWindow: true)

        case .runShell(let command):
            ShellRunner.run(command)
            afterOpen(searchName: item.searchName, hideWindow: true)

        case .copyText(let text):
            copyText(text)

        case .copyEmoji(let text):
            copyText(text)

        case .quitApp(let name):
            AppIndex.terminateApp(named: name)
            afterOpen(searchName: nil, hideWindow: true)

        case .quitAll:
            AppIndex.terminateAllApps()
            afterOpen(searchName: nil, hideWindow: true)

        case .quitSelf:
            saveRankingNow()
            exit(0)

        case .tile(let position):
            let target = frontmostApp ?? NSWorkspace.shared.frontmostApplication
            let ok = target.flatMap { TilingService.tile(application: $0, position: position) } ?? false
            if !ok {
                HapticsService.failure(enabled: true)
            }
            hide()

        case .switchPage(let target):
            switchPage(target)

        case .openSettings:
            onOpenSettings?()
            hide()

        case .reload:
            reloadConfig()

        case .openEvent:
            CalendarService.openInCalendar()
            hide()

        case .display:
            break
        }
    }

    private func afterOpen(searchName: String?, hideWindow: Bool) {
        if hideWindow {
            hide()
            if config.clearOnEnter { query = "" }
        }
        _ = searchName
    }

    func copyText(_ text: String) {
        ClipboardService.copy(text: text)
        afterOpen(searchName: nil, hideWindow: true)
    }

    func copyClipboardEntry(_ entry: ClipboardEntry) {
        ClipboardService.copy(entry: entry)
        if config.clipboardPasteOnSelect, let pid = frontmostApp?.processIdentifier {
            hide()
            ClipboardService.simulatePaste(toPid: pid)
        } else {
            afterOpen(searchName: nil, hideWindow: true)
        }
    }

    func deleteClipboardEntry(_ entry: ClipboardEntry) {
        clipboardStore.delete(id: entry.id)
        clipboardItems.removeAll { $0.id == entry.id }
    }

    func clearClipboard() {
        clipboardStore.deleteAll()
        clipboardItems.removeAll()
    }

    func toggleFavorite(_ item: ResultItem) {
        guard let name = item.searchName else { return }
        ranking.toggleFavorite(name)
        refreshResults()
    }

    var filteredClipboardItems: [ClipboardEntry] {
        let q = query.lowercased()
        guard !q.isEmpty else { return clipboardItems }
        return clipboardItems.filter { entry in
            switch entry.kind {
            case .image: return "image".contains(q) || q.contains("image")
            case .url, .text: return entry.text?.lowercased().contains(q) ?? false
            }
        }
    }

    // MARK: - clipboard capture

    func handleClipboardCapture(_ capture: ClipboardService.Capture) {
        guard config.clipboardHistoryEnabled else { return }
        let content: (kind: ClipboardEntry.Kind, text: String?, imageData: Data?)
        switch capture.content {
        case .text(let t): content = (.text, t, nil)
        case .url(let t): content = (.url, t, nil)
        case .image(let data): content = (.image, nil, data)
        }
        // dedupe: move existing equal content to the top
        if let existingIndex = clipboardItems.firstIndex(where: {
            $0.kind == content.kind && $0.text == content.text && $0.imageData == content.imageData
        }) {
            let existing = clipboardItems.remove(at: existingIndex)
            clipboardItems.insert(existing, at: 0)
            return
        }
        // Entries need a unique, stable ID for SwiftUI identity: use the
        // SQLite row id, falling back to a negative counter if the write failed.
        let id = clipboardStore.insert(kind: content.kind, text: content.text, imageData: content.imageData)
            ?? nextFallbackClipboardID()
        let entry = ClipboardEntry(id: id, kind: content.kind, text: content.text,
                                   imageData: content.imageData, createdAt: Date())
        clipboardItems.insert(entry, at: 0)
        if clipboardItems.count > 300 {
            clipboardItems.removeLast(clipboardItems.count - 300)
        }
    }

    private func nextFallbackClipboardID() -> Int64 {
        fallbackClipboardID -= 1
        return fallbackClipboardID
    }
    private var fallbackClipboardID: Int64 = 0

    // MARK: - hotkeys

    private func applyHotkeys() {
        var shortcuts: [Shortcut] = []
        if let toggle = Shortcut(string: config.toggleHotkey) { shortcuts.append(toggle) }
        if config.clipboardHistoryEnabled, let cb = Shortcut(string: config.clipboardHotkey) { shortcuts.append(cb) }

        shellHotkeys = [:]
        for shell in config.shells {
            guard let hkString = shell.hotkey, let hk = Shortcut(string: hkString) else { continue }
            shellHotkeys[hk] = shell
            shortcuts.append(hk)
        }

        HotKeyManager.shared.onHotKey = { [weak self] shortcut in
            guard let self else { return }
            if let toggle = Shortcut(string: self.config.toggleHotkey), shortcut == toggle {
                self.toggle()
            } else if let cb = Shortcut(string: self.config.clipboardHotkey),
                      shortcut == cb, self.config.clipboardHistoryEnabled {
                if self.panelIsVisible && self.page == .clipboard {
                    self.hide()
                } else {
                    self.show(to: .clipboard)
                }
            } else if let shell = self.shellHotkeys[shortcut] {
                ShellRunner.run(shell.command)
            }
        }
        HotKeyManager.shared.update(shortcuts: shortcuts)
    }

    // MARK: - config reload

    func updateConfig(_ newConfig: Config) {
        config = newConfig
        config.save()
        theme = Theme.resolve(config: config, systemDark: systemDark)
        refreshResults()
        onLayoutChanged?()
    }

    func reloadConfig() {
        config = Config.load()
        appIndex.load(blacklist: config.blacklist) { [weak self] in
            self?.refreshResults()
        }
        refreshResults()
        onLayoutChanged?()
    }

    func saveConfig() {
        config.save()
    }

    // MARK: - layout

    static let windowWidth: CGFloat = 550
    static let clipboardWindowWidth: CGFloat = 620
    static let searchHeaderHeight: CGFloat = 56
    static let rowHeight: CGFloat = 48
    static let footerHeight: CGFloat = 26
    static let maxVisibleRows = 5
    static let chromePadding: CGFloat = 14

    var desiredWindowSize: NSSize {
        switch page {
        case .main, .files:
            let rowCount = min(page == .main ? results.count : fileResults.count, Self.maxVisibleRows)
            let height = Self.chromePadding + Self.searchHeaderHeight
                + CGFloat(rowCount) * Self.rowHeight
                + (rowCount > 0 ? Self.footerHeight : 0)
                + Self.chromePadding / 2
            return NSSize(width: Self.windowWidth, height: max(96, height))
        case .emoji:
            let rows = CGFloat(max(1, (emojiResults.count + 5) / 6))
            let gridHeight = min(rows * 64 + 10, 320)
            let height = Self.chromePadding + Self.searchHeaderHeight + gridHeight + Self.footerHeight + Self.chromePadding / 2
            return NSSize(width: Self.windowWidth, height: height)
        case .clipboard:
            return NSSize(width: Self.clipboardWindowWidth, height: 480)
        }
    }

    var footerText: String {
        if !mode.isEmpty && mode != "default" {
            return "\(mode.capitalized) Mode"
        }
        switch page {
        case .main:
            if query.isEmpty { return config.mainPage.displayName }
            let count = results.count
            return count == 1 ? "1 result found" : count == 0 ? "No results found" : "\(count) results found"
        case .files:
            let count = fileResults.count
            return count == 1 ? "1 result found" : "\(count) results found"
        case .clipboard: return "Clipboard history"
        case .emoji: return "Emoji search"
        }
    }

    // MARK: - system appearance

    private var appearanceObserver: Any?

    private func observeSystemAppearance() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard let self else { return }
                let dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
                self.setSystemDark(dark)
            }
        }
    }

    private func setSystemDark(_ dark: Bool) {
        systemDark = dark
        theme = Theme.resolve(config: config, systemDark: dark)
    }
    private var systemDark = true { didSet { theme = Theme.resolve(config: config, systemDark: systemDark) } }

    // MARK: - ranking persistence

    private func scheduleRankingSave() {
        rankingSaveTask?.cancel()
        rankingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveRankingNow()
        }
    }

    func saveRankingNow() {
        ranking.save()
    }
}

extension Shortcut {
    /// canonical lowercase config-style key for comparisons
    var stringKey: String {
        var out = ""
        if modifiers.contains(.control) { out += "ctrl+" }
        if modifiers.contains(.option) { out += "alt+" }
        if modifiers.contains(.shift) { out += "shift+" }
        if modifiers.contains(.command) { out += "super+" }
        if let name = Shortcut.keyName(for: keyCode) {
            let mapped = ["space": "space", "return": "return", "enter": "return", "escape": "escape"]
            out += (mapped[name] ?? name.lowercased())
        } else {
            out += "\(keyCode)"
        }
        return out
    }
}

/// Fire-and-forget shell execution.
enum ShellRunner {
    static func run(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try? process.run()
    }
}
