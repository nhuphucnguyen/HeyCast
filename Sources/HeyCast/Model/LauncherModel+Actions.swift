import AppKit

extension LauncherModel {
    func perform(_ action: ItemAction, on item: ResultItem) {
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

    var selectedResult: ResultItem? {
        guard page == .main, results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    func toggleActionPanel() {
        if actionPanelOpen {
            closeActionPanel()
        } else {
            openActionPanel()
        }
    }

    func openActionPanel() {
        guard let item = selectedResult, item.hasActions else { return }
        actionPanelIndex = 0
        if !actionPanelOpen {
            actionPanelOpen = true
            onLayoutChanged?()
        }
    }

    func closeActionPanel() {
        guard actionPanelOpen else { return }
        actionPanelOpen = false
        onLayoutChanged?()
    }

    func moveActionPanelSelection(_ delta: Int) {
        guard let count = selectedResult?.actions.count, count > 0 else { return }
        actionPanelIndex = max(0, min(count - 1, actionPanelIndex + delta))
    }

    func performActionPanelSelection() {
        guard let item = selectedResult, item.actions.indices.contains(actionPanelIndex) else { return }
        perform(item.actions[actionPanelIndex], on: item)
    }

    func performShortcut(_ event: NSEvent) -> Bool {
        guard let item = selectedResult,
              let action = item.actions.first(where: { $0.shortcut?.matches(event) == true })
        else { return false }
        perform(action, on: item)
        return true
    }

    var actionPanelHeight: CGFloat {
        guard actionPanelOpen, let count = selectedResult?.actions.count else { return 0 }
        return CGFloat(count) * Self.actionPanelRowHeight + 16
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

    func signalFailure() {
        HapticsService.failure(enabled: true)
    }
}
