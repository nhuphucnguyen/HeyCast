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

    /// Setup runs here (before Apple events like swiftcast:// URLs arrive).
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        model = LauncherModel()
        panelController = PanelController(model: model)
        statusItemController.install(model: model)

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
        NSLog("SwiftCast started (v%@)", LauncherModel.appVersion)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model?.saveRankingNow()
    }

    // MARK: URL scheme (swiftcast://show | toggle | quit | open?target=NAME)

    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("SwiftCast: open URLs called: \(urls)")
        guard model != nil else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        for url in urls where url.scheme?.lowercased() == "swiftcast" {
            handleURLScheme(url)
        }
    }

    private func handleURLScheme(_ url: URL) {
        let host = url.host?.lowercased() ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        NSLog("SwiftCast: URL scheme action '\(host)'")
        switch host {
        case "show":
            if !model.panelIsVisible { model.show() }
        case "toggle":
            model.toggle()
        case "screenshot":
            // Debug aid: capture the launcher panel to /tmp/swiftcast_panel.png
            panelController.capturePanel(to: URL(fileURLWithPath: "/tmp/swiftcast_panel.png"))
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
        case "esc":
            model.escPressed()
        case "page":
            let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let name = params.first(where: { $0.name == "name" })?.value,
               let page = Page(rawValue: name) {
                model.show(to: page)
            }
        case "settings":
            showSettings()
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
    appMenu.addItem(NSMenuItem(title: "About SwiftCast", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: "Quit SwiftCast", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
