import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, clipboard, assistant, appearance, commands

    var title: String {
        switch self {
        case .general: return "General"
        case .clipboard: return "Clipboard"
        case .assistant: return "Assistant"
        case .appearance: return "Appearance"
        case .commands: return "Commands"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "switch.2"
        case .clipboard: return "clipboard"
        case .assistant: return "sparkles"
        case .appearance: return "paintbrush"
        case .commands: return "terminal"
        }
    }
}

/// Settings window with General / Clipboard / Assistant / Appearance /
/// Commands tabs. Edits a draft config and pushes it into the model (which
/// persists + applies hotkeys).
@MainActor
final class SettingsWindowController {
    static let windowIdentifier = "HeyCastSettings"

    private var window: NSWindow?
    private weak var model: LauncherModel?

    func show(model: LauncherModel, tab: SettingsTab = .general, addAgent: Bool = false, editAgentIndex: Int? = nil) {
        self.model = model
        if window == nil {
            NSLog("HeyCast: creating settings window")
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            // Full-size content with a transparent titlebar so the glass
            // material runs edge to edge (traffic lights float on it, like
            // System Settings); dragging works via isMovableByWindowBackground
            // and the window stays closable with ⌘W.
            window.title = "HeyCast Settings"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
            window.isReleasedWhenClosed = false
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.center()
            window.level = .floating
            self.window = window
        }
        window?.appearance = NSAppearance(named: model.theme.isDark ? .darkAqua : .aqua)
        // Rebuild the view on every open so the draft reflects changes made
        // elsewhere (tray menu, edited config.json + Refresh) while closed,
        // and so the background material follows the current theme config.
        window?.contentView = Self.makeContentView(model: model, tab: tab, addAgent: addAgent, editAgentIndex: editAgentIndex)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSLog("HeyCast: settings window shown (visible: %@)", String(window?.isVisible ?? false))
    }

    /// SwiftUI content over the system Liquid Glass material (macOS 26+,
    /// when the config asks for it) or a vibrancy fallback — the same
    /// background treatment as the launcher panel.
    private static func makeContentView(model: LauncherModel, tab: SettingsTab,
                                        addAgent: Bool, editAgentIndex: Int?) -> NSView {
        let hosting = NSHostingView(rootView: SettingsView(model: model, initialTab: tab,
                                                          initialAdd: addAgent,
                                                          initialEditIndex: editAgentIndex))
        if #available(macOS 26.0, *), model.config.theme.liquidGlass {
            let glass = GlassBackgroundView(cornerRadius: 10)
            glass.content = hosting
            glass.update(theme: model.theme)
            return glass
        }
        let vibrancy = NSVisualEffectView()
        vibrancy.material = model.theme.isDark ? .hudWindow : .windowBackground
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        hosting.translatesAutoresizingMaskIntoConstraints = false
        vibrancy.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: vibrancy.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: vibrancy.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: vibrancy.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: vibrancy.bottomAnchor),
        ])
        return vibrancy
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

    /// Sheet payload: index nil = add mode. item-based presentation guarantees
    /// the form receives the agent being edited at presentation time (with
    /// isPresented, @State init values don't re-apply between presentations).
    private struct AgentSheetContext: Identifiable {
        let index: Int?      // nil = add
        let agent: AgentConfig?
        var id: Int { index ?? -1 }
    }

    @State private var agentSheet: AgentSheetContext?
    @State private var initialAddPending = false
    @State private var initialEditIndex: Int?

    init(model: LauncherModel, initialTab: SettingsTab = .general, initialAdd: Bool = false,
         initialEditIndex: Int? = nil) {
        self.model = model
        _draft = State(initialValue: model.config)
        _tab = State(initialValue: initialTab)
        _initialAddPending = State(initialValue: initialAdd)
        _initialEditIndex = State(initialValue: initialEditIndex)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // Fill the whole window (including the full-size-content titlebar
        // strip); the sidebar's top padding clears the traffic lights.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if initialAddPending {
                initialAddPending = false
                agentSheet = AgentSheetContext(index: nil, agent: nil)
            } else if let editIndex = initialEditIndex, draft.agents.indices.contains(editIndex) {
                agentSheet = AgentSheetContext(index: editIndex, agent: draft.agents[editIndex])
            }
        }
        .onDisappear { persist() }
    }

    /// System-Settings-style shell: an icon sidebar floating on the window's
    /// Liquid Glass background, with the selected tab's form on the right.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 26, height: 26)
                Text("HeyCast").font(.system(size: 13, weight: .semibold))
            }
            // Clears the floating traffic lights in the full-size-content titlebar.
            .padding(.top, 44)
            .padding(.bottom, 14)

            ForEach(SettingsTab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.symbol)
                            .frame(width: 18)
                            .foregroundStyle(tab == item ? Color.accentColor : Color.secondary)
                        Text(item.title)
                            .font(.system(size: 13, weight: tab == item ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .background {
                        if tab == item {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.accentColor.opacity(0.22))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()
            Text("HeyCast \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 12)
        .frame(width: 186, alignment: .leading)
    }

    @ViewBuilder
    private var detail: some View {
        switch tab {
        case .general: generalTab
        case .clipboard: clipboardTab
        case .assistant: assistantTab
        case .appearance: appearanceTab
        case .commands: commandsTab
        }
    }

    private func persist() {
        model.updateConfig(draft)
    }

    /// Inline complaint for hand-typed config values the recorder wouldn't
    /// have produced (unknown keys, missing modifiers, fn, …).
    @ViewBuilder
    private func hotkeyValidation(for value: String) -> some View {
        if let message = Shortcut.validationMessage(for: value) {
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }

    /// Trigger prefixes sanitize themselves on submit: they must start with
    /// "@" or "/", or be empty where that's allowed (see Config).
    private func triggerField(_ label: String, value: Binding<String>,
                              fallback: String, allowEmpty: Bool) -> some View {
        TextField(label, text: value)
            .onSubmit {
                value.wrappedValue = Config.sanitizedTrigger(value.wrappedValue,
                                                             fallback: fallback,
                                                             allowEmpty: allowEmpty)
                persist()
            }
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
                LabeledContent("Ranking") {
                    Button("Clear Learned Ranking") { model.resetAllRanking() }
                }
                Text("Search and Suggested learn from what you open, fading after a few weeks of disuse. Favourites are kept.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show tray icon", isOn: $draft.showTrayIcon).onChange(of: draft.showTrayIcon) { _ in persist() }
            }
            Section("Search triggers") {
                Text("Special triggers typed at the start of the search bar. They must begin with \"@\" or \"/\" — \"/\" is the default style. A trailing space is part of the capture triggers; empty disables one. Press Enter after editing.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                triggerField("Assistant — agent alias follows (e.g. \"/hermes …\")",
                             value: $draft.assistantPrefix, fallback: "/", allowEmpty: false)
                triggerField("Inbox capture — todo/thought (e.g. \"/todo fix the tap\")",
                             value: $draft.notesInboxPrefix, fallback: "/todo ", allowEmpty: true)
                triggerField("Word capture — vocabulary (e.g. \"/word serendipity — luck\")",
                             value: $draft.notesWordPrefix, fallback: "/word ", allowEmpty: true)
                triggerField("Note capture — opens the editor (e.g. \"/note Trip plan\")",
                             value: $draft.notesNotePrefix, fallback: "/note ", allowEmpty: true)
                triggerField("Thanh Cong TC feed", value: $draft.tcPrefix, fallback: "/tc", allowEmpty: false)
            }
            Section {
                LabeledContent("Toggle HeyCast") {
                    HotkeyRecorder(value: $draft.toggleHotkey) { persist() }
                        .frame(width: 190)
                        .help("Click, then press the shortcut. Esc cancels, ⌫ clears.")
                }
                hotkeyValidation(for: draft.toggleHotkey)
                if let issue = model.hotkeyIssue {
                    Text(issue).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Hotkeys")
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
        .scrollContentBackground(.hidden)
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
                LabeledContent("Open clipboard") {
                    HotkeyRecorder(value: $draft.clipboardHotkey) { persist() }
                        .frame(width: 190)
                        .help("Click, then press the shortcut. Esc cancels, ⌫ clears.")
                }
                hotkeyValidation(for: draft.clipboardHotkey)
                Toggle("Paste into previous app on select", isOn: $draft.clipboardPasteOnSelect)
                    .onChange(of: draft.clipboardPasteOnSelect) { _ in persist() }
                Toggle("Pop out preview when an image is selected", isOn: $draft.clipboardImagePreviewPopOut)
                    .onChange(of: draft.clipboardImagePreviewPopOut) { _ in persist() }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
                                agentSheet = AgentSheetContext(index: index, agent: draft.agents[index])
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("Edit agent")
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
                            Text("\(draft.agents[index].name)  ·  \(draft.assistantPrefix)\(draft.agents[index].alias)")
                                .font(.system(size: 13, weight: .medium))
                            Text("\(draft.agents[index].type) — \(draft.agents[index].baseURL)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                Button {
                    agentSheet = AgentSheetContext(index: nil, agent: nil)
                } label: {
                    Label("Add Agent…", systemImage: "plus")
                }
            }
            Section {
                Text("Ask from anywhere: \"\(draft.assistantPrefix)alias your question\" + Enter, or ⌘↵ for the default agent. On the Assistant page, type and press Enter. The panel hides immediately; the answer arrives as a notification and waits in the Assistant inbox.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("API keys are stored in config.json (~/Library/Application Support/HeyCast). Keep the file private; Keychain storage is planned.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(item: $agentSheet) { context in
            AgentFormSheet(
                existing: context.agent,
                takenAliases: Set(draft.agents.map(\.alias))
                    .subtracting(context.agent.map { [$0.alias] } ?? [])) { updated in
                if let index = context.index {
                    let oldAlias = context.agent?.alias
                    draft.agents[index] = updated
                    if draft.defaultAgent == oldAlias { draft.defaultAgent = updated.alias }
                } else {
                    draft.agents.append(updated)
                    if draft.defaultAgent == nil { draft.defaultAgent = updated.alias }
                }
                persist()
            }
        }
    }

    /// Focused agent dialog (add + edit): label above each bordered field so
    /// it's obvious what goes where. Enter saves, Escape cancels. The stored
    /// API key is kept unless a new one is typed.
    struct AgentFormSheet: View {
    let existing: AgentConfig?
    var takenAliases: Set<String>
    var onSave: (AgentConfig) -> Void

    init(existing: AgentConfig? = nil, takenAliases: Set<String>,
         onSave: @escaping (AgentConfig) -> Void) {
        self.existing = existing
        self.takenAliases = takenAliases
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _alias = State(initialValue: existing?.alias ?? "")
        _type = State(initialValue: existing?.type ?? "openai")
        _baseURL = State(initialValue: existing?.baseURL ?? "")
        _modelOrTool = State(initialValue: existing?.model ?? existing?.tool ?? "")
        _visionModel = State(initialValue: existing?.visionModel ?? "")
        _visionBaseURL = State(initialValue: existing?.visionBaseURL ?? "")
    }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var alias = ""
    @State private var type = "openai"
    @State private var baseURL = ""
    @State private var modelOrTool = ""
    @State private var apiKey = ""
    @State private var visionModel = ""
    @State private var visionBaseURL = ""
    @FocusState private var nameFocused: Bool

    private var aliasClean: String {
        alias.trimmingCharacters(in: .whitespaces).lowercased()
    }
    /// Aliases become the "<trigger>alias" prefix, so they can't contain
    /// whitespace; use _ to separate words.
    private var aliasHasSpace: Bool {
        aliasClean.contains(where: { $0 == " " || $0 == "\t" })
    }
    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !aliasClean.isEmpty
            && !aliasHasSpace
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !takenAliases.contains(aliasClean)
    }
    private var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty && aliasClean.isEmpty { return nil }
        if takenAliases.contains(aliasClean) { return "That alias is already used" }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name is required" }
        if aliasClean.isEmpty { return "Alias is required" }
        if aliasHasSpace { return "Alias cannot contain spaces — use _ instead" }
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
            Text(existing == nil ? "Add Agent" : "Edit Agent").font(.headline)

            field("Name") {
                TextField("e.g. Hermes", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
            }
            field("Alias — typed after the assistant trigger (default \"/\") in the search bar (no spaces, use _)") {
                HStack(spacing: 4) {
                    Text("@").foregroundStyle(.secondary)
                    TextField("hermes_assistant", text: $alias)
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
                SecureField(existing?.apiKey != nil ? "Saved — leave empty to keep it" : "Bearer token",
                            text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }
            field("Vision model — optional, used when a screenshot is attached") {
                TextField("e.g. glm-4.6v, gpt-4o (must support images)", text: $visionModel)
                    .textFieldStyle(.roundedBorder)
            }
            field("Vision base URL — optional, if vision lives on another endpoint") {
                TextField("e.g. https://api.z.ai/api/paas/v4", text: $visionBaseURL)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                if let problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Add" : "Save") {
                    var base = baseURL.trimmingCharacters(in: .whitespaces)
                    if type == "anthropic", base.isEmpty { base = "https://api.anthropic.com" }
                    onSave(AgentConfig(
                        name: name.trimmingCharacters(in: .whitespaces),
                        alias: aliasClean,
                        type: type,
                        baseURL: base,
                        model: (type == "mcp" || modelOrTool.isEmpty) ? nil : modelOrTool,
                        tool: (type == "mcp" && !modelOrTool.isEmpty) ? modelOrTool : nil,
                        // Empty key field keeps the stored one (masked fields
                        // can't echo secrets back).
                        apiKey: apiKey.isEmpty ? existing?.apiKey : apiKey,
                        visionModel: visionModel.isEmpty ? existing?.visionModel : visionModel,
                        visionBaseURL: visionBaseURL.isEmpty ? existing?.visionBaseURL : visionBaseURL))
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
                Toggle("Liquid Glass background", isOn: $draft.theme.liquidGlass)
                    .disabled(!liquidGlassSupported)
                    .onChange(of: draft.theme.liquidGlass) { _ in persist() }
                if !liquidGlassSupported {
                    Text("Liquid Glass requires macOS 26 or later — the vibrancy background is used instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
        .scrollContentBackground(.hidden)
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
        .scrollContentBackground(.hidden)
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
