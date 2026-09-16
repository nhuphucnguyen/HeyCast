import AppKit
import SwiftUI

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the floating launcher panel: vibrancy background, dynamic resizing,
/// positioning, hide-on-blur and the local keyboard monitor that implements
/// the launcher key bindings.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: LauncherPanel
    let model: LauncherModel
    private let vibrancyView = NSVisualEffectView()
    private var keyMonitor: Any?
    private var isPositionedOnce = false

    init(model: LauncherModel) {
        self.model = model
        self.panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: LauncherModel.windowWidth, height: 150),
            styleMask: [.borderless, .titled],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.appearance = NSAppearance(named: model.theme.isDark ? .darkAqua : .aqua)

        vibrancyView.material = .hudWindow
        vibrancyView.blendingMode = .behindWindow
        vibrancyView.state = .active
        vibrancyView.wantsLayer = true
        vibrancyView.layer?.cornerRadius = 16
        vibrancyView.layer?.cornerCurve = .continuous
        vibrancyView.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: AnyView(LauncherView(model: model)))
        vibrancyView.addSubview(hosting)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: vibrancyView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: vibrancyView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: vibrancyView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: vibrancyView.bottomAnchor),
        ])
        panel.contentView = vibrancyView
        applyThemeBackground()

        model.onShowPanel = { [weak self] in self?.showPanel() }
        model.onHidePanel = { [weak self] in self?.hidePanel() }
        model.onLayoutChanged = { [weak self] in self?.resizeToFitContent() }
        model.onOpenSettings = { AppDelegate.shared?.showSettings() }

        installKeyMonitor()
    }

    private func applyThemeBackground() {
        vibrancyView.blendingMode = .behindWindow
        if model.theme.blur {
            // .hudWindow is always dark and ignores appearance, which made the
            // light theme unreadable; use a light-following material for light.
            vibrancyView.material = model.theme.isDark ? .hudWindow : .windowBackground
            vibrancyView.isHidden = false
        } else {
            vibrancyView.isHidden = false
            vibrancyView.material = .titlebar
            vibrancyView.blendingMode = .withinWindow
            vibrancyView.blendingMode = .withinWindow
        }
    }

    // MARK: show/hide

    private func showPanel() {
        NSLog("HeyCast: showPanel (frame before: \(panel.frame))")
        positionPanelIfNeeded()
        resizeToFitContent()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        isPositionedOnce = true
        NSLog("HeyCast: showPanel done (frame after: \(panel.frame), visible: \(panel.isVisible), key: \(panel.isKeyWindow))")
    }

    private func hidePanel() {
        NSLog("HeyCast: hidePanel called")
        panel.orderOut(nil)
    }

    private func positionPanelIfNeeded() {
        guard let screen = screenWithMouse() else { return }
        let size = model.desiredWindowSize
        let frame = anchoredFrame(size: size, location: model.config.windowLocation, screen: screen)
        panel.setFrame(frame, display: true)
    }

    private func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func anchoredFrame(size: NSSize, location: WindowLocation, screen: NSScreen) -> NSRect {
        let sf = screen.frame
        let w = size.width, h = size.height
        let x: CGFloat, y: CGFloat
        switch location {
        case .mouseScreenTopCenter: x = sf.midX - w / 2; y = sf.maxY - sf.height * 0.28 - h / 2
        case .topLeft: x = sf.minX; y = sf.maxY - h
        case .topCenter: x = sf.midX - w / 2; y = sf.maxY - h
        case .topRight: x = sf.maxX - w; y = sf.maxY - h
        case .middleLeft: x = sf.minX; y = sf.midY - h / 2
        case .middleCenter: x = sf.midX - w / 2; y = sf.midY - h / 2
        case .middleRight: x = sf.maxX - w; y = sf.midY - h / 2
        case .bottomLeft: x = sf.minX; y = sf.minY
        case .bottomCenter: x = sf.midX - w / 2; y = sf.minY
        case .bottomRight: x = sf.maxX - w; y = sf.minY
        }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// Resize the panel to match the current content, keeping the top edge fixed.
    func resizeToFitContent() {
        let newSize = model.desiredWindowSize
        let current = panel.frame
        guard abs(current.width - newSize.width) > 0.5 || abs(current.height - newSize.height) > 0.5 else { return }
        let newFrame = NSRect(x: current.minX + (current.width - newSize.width) / 2,
                              y: current.maxY - newSize.height,
                              width: newSize.width,
                              height: newSize.height)
        panel.setFrame(newFrame, display: true)
    }

    // MARK: keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handleKeyDown(event)
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let ctrl = flags.contains(.control)

        switch event.keyCode {
        case 126: // up
            model.moveSelection(page == .emoji ? -6 : -1)
            return nil
        case 125: // down
            model.moveSelection(page == .emoji ? 6 : 1)
            return nil
        case 123: // left
            if page == .emoji { model.moveSelection(-1); return nil }
            return event
        case 124: // right
            if page == .emoji { model.moveSelection(1); return nil }
            return event
        case 36, 76: // return / enter
            model.openFocused()
            return nil
        case 53: // escape
            model.escPressed()
            return nil
        case 35 where ctrl: // ctrl+p
            model.moveSelection(-1)
            return nil
        case 45 where ctrl: // ctrl+n
            model.moveSelection(1)
            return nil
        default:
            break
        }

        if cmd {
            switch event.charactersIgnoringModifiers {
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                let index = Int(event.charactersIgnoringModifiers!)! - 1
                openResult(at: index)
                return nil
            case "p":
                // Maccy's pin shortcut; only meaningful on the clipboard page.
                if page == .clipboard, model.filteredClipboardItems.indices.contains(model.selectedIndex) {
                    model.toggleClipboardPin(model.filteredClipboardItems[model.selectedIndex])
                    return nil
                }
                return event
            case "r":
                model.reloadConfig()
                return nil
            case ",":
                AppDelegate.shared?.showSettings()
                return nil
            default:
                return event
            }
        }
        return event
    }

    private func openResult(at index: Int) {
        switch model.page {
        case .main:
            guard model.results.indices.contains(index) else { return }
            model.selectedIndex = index
            model.openResult(model.results[index])
        case .clipboard:
            guard model.filteredClipboardItems.indices.contains(index) else { return }
            model.selectedIndex = index
            model.openFocused()
        case .emoji:
            guard model.emojiResults.indices.contains(index) else { return }
            model.selectedIndex = index
            model.openFocused()
        case .files:
            guard model.fileSearchService.results.indices.contains(index) else { return }
            model.selectedIndex = index
            model.openFocused()
        }
    }

    /// Re-apply appearance after a theme change.
    func refreshTheme() {
        panel.appearance = NSAppearance(named: model.theme.isDark ? .darkAqua : .aqua)
        applyThemeBackground()
    }

    /// Capture this window's rendered content (allowed for the owning process
    /// without Screen Recording permission).
    func capturePanel(to url: URL) {
        captureWindow(panel, to: url)
    }

    /// Capture every app window (panel + settings) to /tmp for verification.
    func captureAllWindows() {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.width > 1 && window.windowNumber > 0 {
            let label = window == panel ? "panel" : "win\(index)"
            captureWindow(window, to: URL(fileURLWithPath: "/tmp/heycast_\(label).png"))
        }
    }

    private func captureWindow(_ window: NSWindow, to url: URL) {
        let number = window.windowNumber
        NSLog("HeyCast: capturing window num=\(number) title=\(window.title) visible=\(window.isVisible)")
        guard number > 0, number < Int(UInt32.max) else { return }
        let windowID = CGWindowID(UInt32(number))
        if let cgImage = CGWindowListCreateImage(.infinite, .optionIncludingWindow, windowID, [.bestResolution]) {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                NSLog("HeyCast: captured \(url.path)")
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Hide when the launcher loses focus, unless the settings window
        // (owned by the same app) took it.
        if let key = NSApp.keyWindow, key != panel, key.identifier == NSUserInterfaceItemIdentifier("HeyCastSettings") {
            return
        }
        if model.panelIsVisible {
            model.hide()
        }
    }

    var page: Page { model.page }
}
