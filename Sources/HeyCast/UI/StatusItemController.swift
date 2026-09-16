import AppKit

/// Menu bar (tray) status item, mirroring RustCast's tray menu.
@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?
    private weak var model: LauncherModel?

    func install(model: LauncherModel) {
        self.model = model
        guard model.config.showTrayIcon else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "HeyCast")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        item.button?.image = icon
        item.menu = buildMenu()
        statusItem = item
    }

    func refresh(model: LauncherModel) {
        if model.config.showTrayIcon && statusItem == nil {
            install(model: model)
        } else if !model.config.showTrayIcon, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        } else {
            statusItem?.menu = buildMenu()
        }
    }

    /// Unread assistant responses show as a small dot next to the bolt —
    /// no extra menu bar icon.
    func updateBadge(unread: Int) {
        statusItem?.button?.title = unread > 0 ? " •" : ""
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let version = NSMenuItem(title: "HeyCast v\(LauncherModel.appVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        let toggle = NSMenuItem(title: "Toggle View", action: #selector(toggleView), keyEquivalent: "space")
        toggle.keyEquivalentModifierMask = [.option]
        toggle.target = self
        menu.addItem(toggle)

        let settings = NSMenuItem(title: "Open Preferences", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshConfig), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        // Maccy's "ignore events": pause capture without hiding old history.
        if model?.config.clipboardHistoryEnabled == true {
            let paused = model?.config.clipboardCapturePaused ?? false
            let pause = NSMenuItem(title: paused ? "Resume Clipboard History" : "Pause Clipboard History",
                                   action: #selector(toggleClipboardPause), keyEquivalent: "")
            pause.target = self
            menu.addItem(pause)
        }

        if let model, !model.config.modes.isEmpty {
            let modesMenu = NSMenu()
            for name in model.config.modes.keys.sorted() {
                let item = NSMenuItem(title: name.capitalized + " Mode", action: #selector(switchMode(_:)), keyEquivalent: "")
                item.representedObject = name
                item.target = self
                modesMenu.addItem(item)
            }
            let modes = NSMenuItem(title: "Modes", action: nil, keyEquivalent: "")
            modes.submenu = modesMenu
            menu.addItem(modes)
        }

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About HeyCast", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let github = NSMenuItem(title: "HeyCast on GitHub", action: #selector(openGitHub), keyEquivalent: "")
        github.target = self
        menu.addItem(github)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit HeyCast", action: #selector(quit), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func toggleView() { model?.toggle() }
    @objc private func openSettings() { AppDelegate.shared?.showSettings() }
    @objc private func refreshConfig() { model?.reloadConfig() }
    @objc private func toggleClipboardPause() {
        guard let model else { return }
        model.config.clipboardCapturePaused.toggle()
        model.config.save()
        statusItem?.menu = buildMenu()
    }
    @objc private func switchMode(_ sender: NSMenuItem) {
        guard let model, let name = sender.representedObject as? String,
              let command = model.config.modes[name] else { return }
        ShellRunner.run(command)
    }
    @objc private func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "HeyCast",
            .applicationVersion: LauncherModel.appVersion,
        ])
    }
    @objc private func openGitHub() {
        NSWorkspace.shared.open(URL(string: "https://github.com/nhuphucnguyen/HeyCast")!)
    }
    @objc private func quit() {
        model?.saveRankingNow()
        NSApplication.shared.terminate(nil)
    }
}
