import AppKit

extension LauncherModel {
    func perform(_ action: ItemAction, on item: ResultItem) {
        if !action.children.isEmpty {
            actionPanelSubmenu = action
            actionPanelIndex = 0
            if !actionPanelOpen { actionPanelOpen = true }
            onLayoutChanged?()
            return
        }
        closeActionPanel()
        switch action.kind {
        case let .launchApp(url, searchName):
            NSWorkspace.shared.open(url)
            ranking.bump(searchName)
            afterOpen(searchName: searchName, hideWindow: true)

        case let .askAgent(alias, text):
            sendToAgent(alias: alias, text: text)
            afterOpen(searchName: nil, hideWindow: true)

        case .openURL(let url):
            NSWorkspace.shared.open(url)
            afterOpen(searchName: item.searchName, hideWindow: true)

        case .runShell(let command):
            ShellRunner.run(command)
            afterOpen(searchName: item.searchName, hideWindow: true)

        case .copyText(let text):
            copyText(text)

        case .showInFinder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
            hide()

        case .toggleFavorite:
            toggleFavorite(item)

        case .uninstall(let url):
            beginUninstall(appPath: url.path)

        case .quitApp(let name):
            AppIndex.terminateApp(named: name)
            afterOpen(searchName: nil, hideWindow: true)

        case .quitAll:
            AppIndex.terminateAllApps()
            afterOpen(searchName: nil, hideWindow: true)

        case .quitSelf:
            saveRankingNow()
            exit(0)

        case .switchPage(let target):
            switchPage(target)

        case .openSettings:
            onOpenSettings?()
            hide()

        case .reload:
            reloadConfig(force: true)

        case .openEvent:
            CalendarService.openInCalendar()
            hide()

        case let .extension(id, key, payload):
            extensions.perform(extensionID: id, key: key, payload: payload, ctx: self)

        case .display:
            break
        }
    }

    static func appActions(url: URL, searchName: String, favorite: Bool) -> [ItemAction] {
        [
            ItemAction("Open Application", symbolName: "arrow.up.forward.app",
                       kind: .launchApp(url, searchName: searchName)),
            ItemAction(symbolName: "folder", shortcut: ActionShortcut(key: "f", modifiers: [.command, .shift]),
                       kind: .showInFinder(url)),
            ItemAction("Copy Path", symbolName: "doc.on.doc", shortcut: ActionShortcut(key: "c", modifiers: [.command, .shift]),
                       kind: .copyText(url.path)),
            ItemAction(favorite ? "Remove from Favourites" : "Add to Favourites",
                       symbolName: favorite ? "heart.slash" : "heart", kind: .toggleFavorite),
            ItemAction(symbolName: "trash", shortcut: ActionShortcut(key: "x", modifiers: [.control]),
                       style: .destructive, kind: .uninstall(url)),
        ]
    }

    // MARK: - action panel

    var supportsItemActions: Bool {
        switch page {
        case .main, .extension: return true
        default: return false
        }
    }

    var selectedItem: ResultItem? {
        let items: [ResultItem]
        switch page {
        case .main: items = results
        case .extension: items = extensionPage?.content.items ?? []
        default: return nil
        }
        return items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    var actionPanelActions: [ItemAction] {
        actionPanelSubmenu?.children ?? selectedItem?.actions ?? []
    }

    func toggleActionPanel() {
        if actionPanelOpen {
            closeActionPanel()
        } else {
            openActionPanel()
        }
    }

    func openActionPanel() {
        guard let item = selectedItem, item.hasActions else { return }
        actionPanelIndex = 0
        actionPanelSubmenu = nil
        if !actionPanelOpen {
            actionPanelOpen = true
            onLayoutChanged?()
        }
    }

    func closeActionPanel() {
        guard actionPanelOpen else { return }
        actionPanelOpen = false
        actionPanelSubmenu = nil
        onLayoutChanged?()
    }

    func closeActionPanelSubmenu() {
        actionPanelSubmenu = nil
        actionPanelIndex = 0
        onLayoutChanged?()
    }

    func moveActionPanelSelection(_ delta: Int) {
        let count = actionPanelActions.count
        guard count > 0 else { return }
        actionPanelIndex = max(0, min(count - 1, actionPanelIndex + delta))
    }

    func performActionPanelSelection() {
        let actions = actionPanelActions
        guard let item = selectedItem, actions.indices.contains(actionPanelIndex) else { return }
        perform(actions[actionPanelIndex], on: item)
    }

    func performShortcut(_ event: NSEvent) -> Bool {
        guard let item = selectedItem,
              let action = item.actions.first(where: { $0.shortcut?.matches(event) == true })
        else { return false }
        perform(action, on: item)
        return true
    }

    var actionPanelHeight: CGFloat {
        guard actionPanelOpen else { return 0 }
        return CGFloat(actionPanelActions.count) * Self.actionPanelRowHeight + 16
    }

    static let actionPanelRowHeight: CGFloat = 30
}

extension LauncherModel: ExtensionContext {
    var targetApplication: NSRunningApplication? {
        frontmostApp ?? NSWorkspace.shared.frontmostApplication
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func copy(_ text: String, keepOpen: Bool) {
        ClipboardService.copy(text: text)
        if !keepOpen { afterOpen(searchName: nil, hideWindow: true) }
    }

    func paste(_ text: String, keepOpen: Bool) {
        ClipboardService.copy(text: text)
        guard let pid = targetApplication?.processIdentifier else { return }
        if !keepOpen { hide() }
        ClipboardService.simulatePaste(toPid: pid)
    }

    func signalFailure() {
        HapticsService.failure(enabled: true)
    }

    func store(for extensionID: String) -> ExtensionStore {
        ExtensionStore(extensionID: extensionID)
    }

    func clearQuery() {
        query = ""
    }

    func reloadPage() {
        guard extensionPage != nil else { return }
        let selectedID = selectedItem?.id
        objectWillChange.send()
        let items = extensionPage?.content.items ?? []
        selectedIndex = items.firstIndex { $0.id == selectedID } ?? min(selectedIndex, max(0, items.count - 1))
        onLayoutChanged?()
    }
}
