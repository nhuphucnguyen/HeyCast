import AppKit

/// Application lifecycle: accessory activation, menu bar (hidden but provides
/// ⌘Q/⌘C/⌘V), tray icon, panel wiring, URL scheme and clipboard monitoring.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    private var model: LauncherModel!
    private var panelController: PanelController!
    private var statusItemController = StatusItemController()
    private var settingsController = SettingsWindowController()
    private var clipboardService: ClipboardService!
    private var pendingURLs: [URL] = []

    override init() {
        super.init()
        Self.shared = self
    }

    /// Setup runs here (before Apple events like heycast:// URLs arrive).
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        model = LauncherModel()
        panelController = PanelController(model: model)
        statusItemController.install(model: model)

        NotificationService.shared.setup()
        NotificationService.shared.onOpenMessage = { [weak self] id in
            guard let self else { return }
            if let message = self.model.assistantMessages.first(where: { $0.id == id }) {
                self.model.openAssistantMessage(message)
            }
            self.model.show(to: .assistant)
        }
        model.onAssistantUnread = { [weak self] unread in
            self?.statusItemController.updateBadge(unread: unread)
        }
        statusItemController.updateBadge(unread: model.assistantUnread)

        clipboardService = ClipboardService()
        clipboardService.onCapture = { [weak self] capture in
            self?.model.handleClipboardCapture(capture)
        }
        clipboardService.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        for url in pendingURLs {
            handleURLScheme(url)
        }
        pendingURLs.removeAll()

        if model.config.showOnStartup {
            model.show()
        }
        NSLog("HeyCast started (v%@)", LauncherModel.appVersion)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model?.saveRankingNow()
    }

    // MARK: URL scheme (heycast://show | toggle | quit | open?target=NAME)

    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("%@", "HeyCast: open URLs called: \(urls)")
        guard model != nil else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls where url.scheme?.lowercased() == "heycast" {
            handleURLScheme(url)
        }
    }

    private func handleURLScheme(_ url: URL) {
        let host = url.host?.lowercased() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        NSLog("%@", "HeyCast: URL scheme action '\(host)'")
        switch host {
        case "show":
            if !model.panelIsVisible { model.show() }
        case "toggle":
            model.toggle()
        case "screenshot":
            // Debug aid: capture the launcher panel to /tmp/heycast_panel.png
            panelController.capturePanel(to: URL(fileURLWithPath: "/tmp/heycast_panel.png"))
        case "capture":
            panelController.captureAllWindows()
        case "query":
            let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let text = params.first(where: { $0.name == "text" })?.value {
                if !model.panelIsVisible { model.show() }
                model.query = text.removingPercentEncoding ?? text
            }
        case "down":
            model.moveSelection(1)
        case "up":
            model.moveSelection(-1)
        case "pin":
            // Same toggle as ⌘P on the clipboard page; also handy for scripts.
            if model.page == .clipboard,
               model.filteredClipboardItems.indices.contains(model.selectedIndex) {
                model.toggleClipboardPin(model.filteredClipboardItems[model.selectedIndex])
            }
        case "enter":
            // Same as pressing return on the highlighted row (routes
            // "@alias question" on the main page too).
            model.handleMainSubmit()
        case "ask":
            // Fire-and-forget: heycast://ask?text=...&agent=alias (silent —
            // no panel pop-up; the answer lands in the inbox + notification)
            let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let text = params.first(where: { $0.name == "text" })?.value?.removingPercentEncoding
            let agentAlias = params.first(where: { $0.name == "agent" })?.value?.removingPercentEncoding
            guard let text, !text.isEmpty else { break }
            if let agentAlias {
                model.sendToAgent(alias: agentAlias, text: text, showLoading: false)
            } else {
                model.sendToDefaultAgent(text, showLoading: false)
            }
        case "esc":
            model.escPressed()
        case "page":
            let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let name = params.first(where: { $0.name == "name" })?.value,
               let page = Page(rawValue: name) {
                model.show(to: page)
            }
        case "settings":
            let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let tabName = params.first(where: { $0.name == "tab" })?.value?.lowercased()
            let tab = SettingsTab(rawValue: tabName ?? "") ?? .general
            let add = params.first(where: { $0.name == "add" })?.value == "1"
            let editIndex = params.first(where: { $0.name == "edit" })?.value.flatMap(Int.init)
            settingsController.show(model: model, tab: tab, addAgent: add, editAgentIndex: editIndex)
        case "quit":
            model.saveRankingNow()
            exit(0)
        case "open":
            let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let target = params.first(where: { $0.name == "target" })?.value?.lowercased() {
                if let entry = model.appIndex.entry(named: target) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
                }
            }
        default:
            break
        }
    }

    // MARK: settings

    func showSettings() {
        settingsController.show(model: model)
    }

    func settingsDidClose() {
        panelController.refreshTheme()
        statusItemController.refresh(model: model)
    }
}

/// Minimal main menu so standard shortcuts (⌘Q, ⌘C, ⌘V, ⌘A, ⌘X) work inside
/// the launcher's text field even though the app is an LSUIElement agent.
@MainActor
func buildMainMenu() -> NSMenu {
    let menu = NSMenu()

    let appItem = NSMenuItem()
    menu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(NSMenuItem(title: "About HeyCast", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: "Quit HeyCast", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    menu.addItem(editItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
    editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
    editMenu.addItem(.separator())
    editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
    editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
    editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
    editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
    editItem.submenu = editMenu

    return menu
}

