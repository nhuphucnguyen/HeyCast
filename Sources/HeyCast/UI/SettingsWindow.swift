import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, clipboard, assistant, appearance, commands
}

/// Settings window with General / Clipboard / Assistant / Appearance /
/// Commands tabs. Edits a draft config and pushes it into the model (which
/// persists + applies hotkeys).
@MainActor
final class SettingsWindowController {
    static let windowIdentifier = "HeyCastSettings"

    private var window: NSWindow?
    private weak var model: LauncherModel?

    func show(model: LauncherModel, tab: SettingsTab = .general, addAgent: Bool = false) {
        self.model = model
        if window == nil {
            NSLog("HeyCast: creating settings window")
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "HeyCast Settings"
            window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
            window.isReleasedWhenClosed = false
            window.center()
            window.level = .floating
            self.window = window
        }
        // Rebuild the view on every open so the draft reflects changes made
        // elsewhere (tray menu, edited config.json + Refresh) while closed.
        window?.contentView = NSHostingView(rootView: SettingsView(model: model, initialTab: tab,
                                                                  initialAdd: addAgent))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("HeyCast: settings window shown (visible: \(window?.isVisible ?? false))")
    }

    func hide() {
        window?.orderOut(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: LauncherModel
    @State private var draft: Config
    @State private var tab: SettingsTab
    @State private var newShellCommand = ""
    @State private var newShellAlias = ""
    @State private var newModeName = ""
    @State private var newModeCommand = ""

    @State private var showingAddAgent = false

    init(model: LauncherModel, initialTab: SettingsTab = .general, initialAdd: Bool = false) {
        self.model = model
        _draft = State(initialValue: model.config)
        _tab = State(initialValue: initialTab)
        _showingAddAgent = State(initialValue: initialAdd)
    }

    var body: some View {
        TabView(selection: $tab) {
            generalTab.tabItem { Label("General", systemImage: "switch.2") }.tag(SettingsTab.general)
            clipboardTab.tabItem { Label("Clipboard", systemImage: "clipboard") }.tag(SettingsTab.clipboard)
            assistantTab.tabItem { Label("Assistant", systemImage: "sparkles") }.tag(SettingsTab.assistant)
            appearanceTab.tabItem { Label("Appearance", systemImage: "paintbrush") }.tag(SettingsTab.appearance)
            commandsTab.tabItem { Label("Commands", systemImage: "terminal") }.tag(SettingsTab.commands)
        }
        .padding(20)
        .frame(width: 640, height: 560)
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
            }
            Section("Behavior") {
                Toggle("Haptic feedback while typing", isOn: $draft.hapticFeedback).onChange(of: draft.hapticFeedback) { _ in persist() }
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

    // MARK: clipboard

    private var clipboardTab: some View {
        Form {
            Section("History") {
                Toggle("Save clipboard history", isOn: $draft.clipboardHistoryEnabled)
                    .onChange(of: draft.clipboardHistoryEnabled) { _ in persist() }
                Toggle("Pause capture (existing history stays available)", isOn: $draft.clipboardCapturePaused)
                    .disabled(!draft.clipboardHistoryEnabled)
                    .onChange(of: draft.clipboardCapturePaused) { _ in persist() }
                Stepper(value: $draft.clipboardHistorySize, in: 10...1000, step: 10) {
                    Text("Keep last \(draft.clipboardHistorySize) entries")
                }
                .disabled(!draft.clipboardHistoryEnabled)
                .onChange(of: draft.clipboardHistorySize) { _ in persist() }
                Button("Clear History") { model.clearClipboard() }
            }
            Section("Selecting entries") {
                TextField("Open clipboard hotkey (e.g. SUPER+SHIFT+C)", text: $draft.clipboardHotkey)
                    .onSubmit { persist() }
                Toggle("Paste into previous app on select", isOn: $draft.clipboardPasteOnSelect)
                    .onChange(of: draft.clipboardPasteOnSelect) { _ in persist() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: assistant

    private var assistantTab: some View {
        Form {
            Section("Agents") {
                if draft.agents.isEmpty {
                    Text("No agents yet.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(draft.agents.indices, id: \.self) { index in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Button {
                                draft.defaultAgent = (draft.defaultAgent == draft.agents[index].alias)
                                    ? nil : draft.agents[index].alias
                                persist()
                            } label: {
                                Label(draft.defaultAgent == draft.agents[index].alias ? "Default" : "Set Default",
                                      systemImage: draft.defaultAgent == draft.agents[index].alias ? "star.fill" : "star")
                            }
                            .buttonStyle(.borderless)
                            .help("The default agent answers ⌘↵ and the Assistant page")
                            Button("Remove", role: .destructive) {
                                if draft.defaultAgent == draft.agents[index].alias { draft.defaultAgent = nil }
                                draft.agents.remove(at: index)
                                persist()
                            }
                            .buttonStyle(.borderless)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(draft.agents[index].name)  ·  @\(draft.agents[index].alias)")
                                .font(.system(size: 13, weight: .medium))
                            Text("\(draft.agents[index].type) — \(draft.agents[index].baseURL)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Button {
                    showingAddAgent = true
                } label: {
                    Label("Add Agent…", systemImage: "plus")
                }
            }
            Section {
                Text("Ask from anywhere: \"@alias your question\" + Enter, or ⌘↵ for the default agent. On the Assistant page, type and press Enter. The panel hides immediately; the answer arrives as a notification and waits in the Assistant inbox.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("API keys are stored in config.json (~/Library/Application Support/HeyCast). Keep the file private; Keychain storage is planned.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddAgent) {
            AddAgentSheet(takenAliases: Set(draft.agents.map(\.alias))) { agent in
                draft.agents.append(agent)
                if draft.defaultAgent == nil { draft.defaultAgent = agent.alias }
                persist()
            }
        }
    }

    /// Focused add-agent dialog: label above each bordered field so it's obvious
    /// what goes where. Enter adds, Escape cancels.
    struct AddAgentSheet: View {
    var takenAliases: Set<String>
    var onAdd: (AgentConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var alias = ""
    @State private var type = "openai"
    @State private var baseURL = ""
    @State private var modelOrTool = ""
    @State private var apiKey = ""
    @FocusState private var nameFocused: Bool

    private var aliasClean: String {
        alias.trimmingCharacters(in: .whitespaces).lowercased()
    }
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !aliasClean.isEmpty
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !takenAliases.contains(aliasClean)
    }
    private var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty && aliasClean.isEmpty { return nil }
        if takenAliases.contains(aliasClean) { return "That alias is already used" }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name is required" }
        if aliasClean.isEmpty { return "Alias is required" }
        if baseURL.trimmingCharacters(in: .whitespaces).isEmpty { return "URL is required" }
        return nil
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Agent").font(.headline)

            field("Name") {
                TextField("e.g. Hermes", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }
            field("Alias — you'll type @alias in the search bar") {
                HStack(spacing: 4) {
                    Text("@").foregroundStyle(.secondary)
                    TextField("hermes", text: $alias)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }
            }
            field("Type") {
                Picker("", selection: $type) {
                    Text("OpenAI-compatible").tag("openai")
                    Text("Anthropic").tag("anthropic")
                    Text("MCP server").tag("mcp")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            field(type == "mcp" ? "Endpoint URL" : "Base URL") {
                TextField(type == "mcp"
                          ? "https://hermes.example.com/mcp"
                          : (type == "anthropic" ? "https://api.anthropic.com" : "https://api.openai.com/v1"),
                          text: $baseURL)
                    .textFieldStyle(.roundedBorder)
            }
            field(type == "mcp" ? "Tool to call — optional" : "Model") {
                TextField(type == "mcp"
                          ? "leave empty to use the first listed tool"
                          : (type == "anthropic" ? "claude-sonnet-4-5" : "glm-5.3, gpt-4o-mini, …"),
                          text: $modelOrTool)
                    .textFieldStyle(.roundedBorder)
            }
            field("API Key") {
                SecureField("Bearer token", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                if let problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    var base = baseURL.trimmingCharacters(in: .whitespaces)
                    if type == "anthropic", base.isEmpty { base = "https://api.anthropic.com" }
                    onAdd(AgentConfig(
                        name: name.trimmingCharacters(in: .whitespaces),
                        alias: aliasClean,
                        type: type,
                        baseURL: base,
                        model: (type == "mcp" || modelOrTool.isEmpty) ? nil : modelOrTool,
                        tool: (type == "mcp" && !modelOrTool.isEmpty) ? modelOrTool : nil,
                        apiKey: apiKey.isEmpty ? nil : apiKey))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { nameFocused = true }
    }
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
