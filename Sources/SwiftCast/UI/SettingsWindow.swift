import AppKit
import SwiftUI

/// Settings window with General / Appearance / Commands tabs. Edits a draft
/// config and pushes it into the model (which persists + applies hotkeys).
@MainActor
final class SettingsWindowController {
    static let windowIdentifier = "SwiftCastSettings"

    private var window: NSWindow?
    private weak var model: LauncherModel?

    func show(model: LauncherModel) {
        self.model = model
        if window == nil {
            let content = SettingsView(model: model)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "SwiftCast Settings"
            window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
            window.isReleasedWhenClosed = false
            window.center()
            window.level = .floating
            window.contentView = NSHostingView(rootView: content)
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() {
        window?.orderOut(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: LauncherModel
    @State private var draft: Config
    @State private var newShellCommand = ""
    @State private var newShellAlias = ""
    @State private var newModeName = ""
    @State private var newModeCommand = ""

    init(model: LauncherModel) {
        self.model = model
        _draft = State(initialValue: model.config)
    }

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "switch.2") }
            appearanceTab.tabItem { Label("Appearance", systemImage: "paintbrush") }
            commandsTab.tabItem { Label("Commands", systemImage: "terminal") }
        }
        .padding(20)
        .frame(width: 620, height: 480)
        .onDisappear { persist() }
    }

    private func persist() {
        model.updateConfig(draft)
    }

    // MARK: general

    private var generalTab: some View {
        Form {
            Section("Launcher") {
                TextField("Placeholder text", text: $draft.placeholder).onSubmit { persist() }
                TextField("Search engine URL (%s is the query)", text: $draft.searchURL).onSubmit { persist() }
                Picker("Window position", selection: $draft.windowLocation) {
                    ForEach(WindowLocation.allCases, id: \.self) { location in
                        Text(location.label).tag(location)
                    }
                }
                .onChange(of: draft.windowLocation) { _ in persist() }
                Picker("Empty page shows", selection: $draft.mainPage) {
                    ForEach(MainPane.allCases, id: \.self) { pane in
                        Text(pane.displayName).tag(pane)
                    }
                }
                .onChange(of: draft.mainPage) { _ in persist() }
                Toggle("Show tray icon", isOn: $draft.showTrayIcon).onChange(of: draft.showTrayIcon) { _ in persist() }
            }
            Section("Hotkeys") {
                TextField("Toggle hotkey (e.g. ALT+SPACE)", text: $draft.toggleHotkey).onSubmit { persist() }
                TextField("Clipboard hotkey (e.g. SUPER+SHIFT+C)", text: $draft.clipboardHotkey).onSubmit { persist() }
            }
            Section("Behavior") {
                Toggle("Haptic feedback while typing", isOn: $draft.hapticFeedback).onChange(of: draft.hapticFeedback) { _ in persist() }
                Toggle("Clipboard history", isOn: $draft.clipboardHistoryEnabled).onChange(of: draft.clipboardHistoryEnabled) { _ in persist() }
                Toggle("Paste on clipboard select", isOn: $draft.clipboardPasteOnSelect).onChange(of: draft.clipboardPasteOnSelect) { _ in persist() }
                Toggle("Clear search on hide", isOn: $draft.clearOnHide).onChange(of: draft.clearOnHide) { _ in persist() }
                Toggle("Hide window after opening a result", isOn: $draft.clearOnEnter).onChange(of: draft.clearOnEnter) { _ in persist() }
                Toggle("Start at login", isOn: $draft.startAtLogin).onChange(of: draft.startAtLogin) { newValue in
                    persist()
                    LoginItemService.setEnabled(newValue)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: appearance

    private var appearanceTab: some View {
        Form {
            Section("Theme") {
                Picker("Mode", selection: $draft.theme.mode) {
                    ForEach(ThemeMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .onChange(of: draft.theme.mode) { _ in persist() }
                Toggle("Blur background (vibrancy)", isOn: $draft.theme.blur).onChange(of: draft.theme.blur) { _ in persist() }
                Toggle("Show icons", isOn: $draft.theme.showIcons).onChange(of: draft.theme.showIcons) { _ in persist() }
                Toggle("Show scroll bar", isOn: $draft.theme.showScrollBar).onChange(of: draft.theme.showScrollBar) { _ in persist() }
            }
            Section("Customization") {
                TextField("Font name (e.g. Fira Code)", text: Binding(
                    get: { draft.theme.fontName ?? "" },
                    set: { draft.theme.fontName = $0.isEmpty ? nil : $0 }
                )).onSubmit { persist() }
                TextField("Text color hex (e.g. #f2f2f4)", text: Binding(
                    get: { draft.theme.textColor ?? "" },
                    set: { draft.theme.textColor = $0.isEmpty ? nil : $0 }
                )).onSubmit { persist() }
                TextField("Background color hex (e.g. #101014)", text: Binding(
                    get: { draft.theme.backgroundColor ?? "" },
                    set: { draft.theme.backgroundColor = $0.isEmpty ? nil : $0 }
                )).onSubmit { persist() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: commands

    private var commandsTab: some View {
        Form {
            Section("Shell commands") {
                ForEach(draft.shells, id: \.alias) { shell in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(shell.alias).font(.system(size: 13, weight: .medium))
                            Text(shell.command).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") {
                            draft.shells.removeAll { $0.alias == shell.alias }
                            persist()
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("alias", text: $newShellAlias).frame(width: 110)
                    TextField("command", text: $newShellCommand)
                    Button("Add") {
                        let alias = newShellAlias.trimmingCharacters(in: .whitespaces)
                        let command = newShellCommand.trimmingCharacters(in: .whitespaces)
                        guard !alias.isEmpty, !command.isEmpty else { return }
                        draft.shells.append(ShellCommandConfig(command: command, alias: alias, hotkey: nil, iconPath: nil))
                        newShellAlias = ""
                        newShellCommand = ""
                        persist()
                    }
                }
            }
            Section("Modes") {
                ForEach(draft.modes.sorted(by: { $0.key < $1.key }), id: \.key) { name, command in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(name.capitalized + " Mode").font(.system(size: 13, weight: .medium))
                            Text(command).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") {
                            draft.modes.removeValue(forKey: name)
                            persist()
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("mode name", text: $newModeName).frame(width: 110)
                    TextField("script path", text: $newModeCommand)
                    Button("Add") {
                        let name = newModeName.trimmingCharacters(in: .whitespaces).lowercased()
                        let command = newModeCommand.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, !command.isEmpty else { return }
                        draft.modes[name] = command
                        newModeName = ""
                        newModeCommand = ""
                        persist()
                    }
                }
            }
            Section("Search aliases") {
                ForEach(draft.aliases.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    HStack {
                        Text("\(key) → \(value)").font(.system(size: 12))
                        Spacer()
                        Button("Remove") {
                            draft.aliases.removeValue(forKey: key)
                            persist()
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Text("Edit config.json to add aliases (input → expanded query).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

extension WindowLocation {
    var label: String {
        switch self {
        case .mouseScreenTopCenter: return "Top center (screen under mouse)"
        case .topLeft: return "Top left"
        case .topCenter: return "Top center"
        case .topRight: return "Top right"
        case .middleLeft: return "Middle left"
        case .middleCenter: return "Middle center"
        case .middleRight: return "Middle right"
        case .bottomLeft: return "Bottom left"
        case .bottomCenter: return "Bottom center"
        case .bottomRight: return "Bottom right"
        }
    }
}
