import AppKit
import SwiftUI

/// Maccy/Spotlight-style popup: a nonactivating panel that becomes the key
/// window WITHOUT activating HeyCast, so the previously frontmost app stays
/// active and its caret is never disturbed (see styleMask in PanelController).
final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Panel background for macOS 26+: the system Liquid Glass material.
/// Encapsulated in its own class because NSGlassEffectView can't be named in
/// stored properties at a pre-26 deployment target.
@available(macOS 26.0, *)
final class LauncherGlassView: NSView {
    private let glass = NSGlassEffectView()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        glass.cornerRadius = cornerRadius
        glass.style = .regular
        if #available(macOS 27.0, *) {
            // The whole panel is interactive (rows, grid, buttons) — glass
            // should respond to those interactions.
            glass.effectIsInteractive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var content: NSView? {
        get { glass.contentView }
        set { glass.contentView = newValue }
    }

    /// A custom background color from the config tints the glass toward it;
    /// preset palettes leave the glass untinted (the material adapts to
    /// dark/light itself).
    func update(theme: Theme) {
        if let hex = theme.customBackgroundHex, let tint = NSColor(hex: hex) {
            glass.tintColor = tint
        } else {
            glass.tintColor = nil
        }
    }
}

/// Owns the floating launcher panel: glass/vibrancy background, dynamic
/// resizing, positioning, hide-on-blur and the local keyboard monitor that
/// implements the launcher key bindings.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: LauncherPanel
    let model: LauncherModel
    private let imageViewer = ClipboardImageViewerController()
    private let vibrancyView = NSVisualEffectView()
    private let hostingView: NSHostingView<AnyView>
    /// Non-nil (as a plain NSView) while the Liquid Glass background is in
    /// use; otherwise the vibrancy view is live.
    private var glassBackground: NSView?
    private var keyMonitor: Any?
    private var isPositionedOnce = false
    private static let panelCornerRadius: CGFloat = 16

    init(model: LauncherModel) {
        self.model = model
        // .nonactivatingPanel is the load-bearing piece: the panel takes key
        // status while the user's app stays frontmost, so hiding needs no
        // focus handback and the caret reappears where it was.
        self.panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: LauncherModel.windowWidth, height: 150),
            styleMask: [.nonactivatingPanel, .borderless, .titled],
            backing: .buffered,
            defer: false
        )
        self.hostingView = NSHostingView(rootView: AnyView(LauncherView(model: model)))
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
        vibrancyView.layer?.cornerRadius = Self.panelCornerRadius
        vibrancyView.layer?.cornerCurve = .continuous
        vibrancyView.layer?.masksToBounds = true

        embedHosting(in: vibrancyView)
        panel.contentView = vibrancyView
        applyThemeBackground()

        model.onShowPanel = { [weak self] in self?.showPanel() }
        model.onHidePanel = { [weak self] in self?.hidePanel() }
        model.onShowImageViewer = { [weak self] in
            guard let self else { return }
            self.imageViewer.toggle(model: self.model, parent: self.panel)
        }
        model.onLayoutChanged = { [weak self] in
            self?.resizeToFitContent()
            self?.refreshTheme()
        }
        model.onOpenSettings = { AppDelegate.shared?.showSettings() }

        installKeyMonitor()
    }

    /// Pins the hosting view to all edges of a plain container view.
    private func embedHosting(in container: NSView) {
        container.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func applyThemeBackground() {
        if model.theme.usesGlass, glassBackground == nil {
            installGlass()
        } else if !model.theme.usesGlass, glassBackground != nil {
            installVibrancy()
        }

        if #available(macOS 26.0, *), let glass = glassBackground as? LauncherGlassView {
            vibrancyView.isHidden = true
            glass.update(theme: model.theme)
        } else {
            vibrancyView.isHidden = false
            vibrancyView.blendingMode = .behindWindow
            if model.theme.blur {
                // .hudWindow is always dark and ignores appearance, which made the
                // light theme unreadable; use a light-following material for light.
                vibrancyView.material = model.theme.isDark ? .hudWindow : .windowBackground
            } else {
                vibrancyView.material = .titlebar
                vibrancyView.blendingMode = .withinWindow
            }
        }
    }

    private func installGlass() {
        guard #available(macOS 26.0, *) else { return }
        let glass = LauncherGlassView(cornerRadius: Self.panelCornerRadius)
        glassBackground = glass
        glass.content = hostingView
        panel.contentView = glass
    }

    private func installVibrancy() {
        glassBackground = nil
        embedHosting(in: vibrancyView)
        panel.contentView = vibrancyView
    }

    // MARK: show/hide

    private func showPanel() {
        NSLog("%@", "HeyCast: showPanel (frame before: \(panel.frame))")
        positionPanelIfNeeded()
        resizeToFitContent()
        // Order front without touching app activation, then take key status
        // for the search field. NSApp.activate is deliberately not called:
        // activating HeyCast here is what used to drop the user's caret.
        panel.orderFrontRegardless()
        panel.makeKey()
        isPositionedOnce = true
        NSLog("%@", "HeyCast: showPanel done (frame after: \(panel.frame), visible: \(panel.isVisible), key: \(panel.isKeyWindow))")
    }

    private func hidePanel() {
        NSLog("HeyCast: hidePanel called")
        imageViewer.close(reason: "panel hidden")
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

    /// Resize the panel to match the current content, keeping the top edge
    /// fixed. Width changes (the clipboard image preview slideout) anchor to
    /// one edge so the list stays put under the pointer — normally the left,
    /// but the right when the panel already sits against the right of the
    /// screen (Maccy's slideout picks the side with room the same way). The
    /// choice sticks until the next growth so a later collapse shrinks from
    /// the same side, and left-anchored growth clamps to the screen edge.
    /// Width changes animate; height changes stay instant.
    private enum WidthAnchor { case left, right }
    private var widthAnchor: WidthAnchor = .left

    func resizeToFitContent() {
        let newSize = model.desiredWindowSize
        let current = panel.frame
        guard abs(current.width - newSize.width) > 0.5 || abs(current.height - newSize.height) > 0.5 else { return }
        let screenMaxX = panel.screen?.visibleFrame.maxX ?? current.maxX
        if newSize.width > current.width {
            widthAnchor = current.maxX >= screenMaxX - 60 ? .right : .left
        }
        var x = current.minX
        var width = newSize.width
        if widthAnchor == .right {
            x = current.maxX - width
        } else if x + width > screenMaxX - 24 {
            width = max(current.width, screenMaxX - 24 - x)
        }
        let newFrame = NSRect(x: x, y: current.maxY - newSize.height, width: width, height: newSize.height)
        panel.setFrame(newFrame, display: true,
                       animate: abs(newSize.width - current.width) > 0.5)
    }

    // MARK: keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isKeyWindow else { return event }
            return self.handleKeyDown(event)
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // Esc over the image viewer dismisses just the viewer; the launcher
        // panel stays key (the viewer never takes key status).
        if imageViewer.isVisible, event.keyCode == 53 {
            imageViewer.close(reason: "esc")
            return nil
        }

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
            if cmd, page == .main {
                // ⌘↵ sends the query to the default agent (fire-and-forget).
                model.sendToDefaultAgent(model.query)
            } else if page == .main {
                // handleMainSubmit routes "@alias question" to the agent;
                // anything else opens the highlighted result.
                model.handleMainSubmit()
            } else {
                model.openFocused()
            }
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
            case "v":
                // ⌘V with an image on the clipboard: attach it for the next
                // agent question (the chip under the search bar acknowledges
                // it). With text on the clipboard, normal text paste wins.
                if (page == .main || page == .assistant),
                   ClipboardService.clipboardHasImage, !ClipboardService.clipboardHasText {
                    model.pasteClipboardImage()
                    return nil
                }
                return event
            case "p":
                // Maccy's pin shortcut; only meaningful on the clipboard page.
                if page == .clipboard, model.filteredClipboardItems.indices.contains(model.selectedIndex) {
                    model.toggleClipboardPin(model.filteredClipboardItems[model.selectedIndex])
                    return nil
                }
                return event
                case "r":
                    model.reloadConfig(force: true)
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
        case .assistant:
            guard model.assistantMessages.indices.contains(index) else { return }
            model.selectedIndex = index
            model.openFocused()
        }
    }

    /// Re-apply appearance after a theme change.
    func refreshTheme() {
        let appearance = NSAppearance(named: model.theme.isDark ? .darkAqua : .aqua)
        if panel.appearance != appearance { panel.appearance = appearance }
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
        // Child windows (the image viewer) don't appear in NSApp.windows.
        for window in panel.childWindows ?? [] {
            captureWindow(window, to: URL(fileURLWithPath: "/tmp/heycast_viewer.png"))
        }
    }

    private func captureWindow(_ window: NSWindow, to url: URL) {
        let number = window.windowNumber
        NSLog("%@", "HeyCast: capturing window num=\(number) title=\(window.title) visible=\(window.isVisible)")
        guard number > 0, number < Int(UInt32.max) else { return }
        let windowID = CGWindowID(UInt32(number))
        if let cgImage = CGWindowListCreateImage(.infinite, .optionIncludingWindow, windowID, [.bestResolution]) {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                NSLog("%@", "HeyCast: captured \(url.path)")
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
