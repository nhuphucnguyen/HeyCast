import AppKit

// HeyCast entry point: accessory app (no Dock icon), custom menu bar,
// floating launcher panel driven by global hotkeys.

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.mainMenu = buildMainMenu()
    app.setActivationPolicy(.accessory)
    app.run()
}
