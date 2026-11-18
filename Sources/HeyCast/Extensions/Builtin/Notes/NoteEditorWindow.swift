import AppKit
import NotesCore
import SwiftUI

/// One small editor window per note. Edits save as you type (debounced) and
/// on close; the launcher stays out of the way.
@MainActor
final class NoteEditorWindows {
    private var windows: [String: NSWindow] = [:]
    private var delegates: [String: CloseDelegate] = [:]
    private let store: NotesStore
    private let onChange: () -> Void

    init(store: NotesStore, onChange: @escaping () -> Void) {
        self.store = store
        self.onChange = onChange
    }

    func open(_ item: NoteItem) {
        if let window = windows[item.id] {
            show(window)
            return
        }
        let model = NoteEditorModel(item: item, store: store, onChange: onChange)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = item.displayTitle
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: NoteEditorView(model: model) { [weak window] in
            window?.performClose(nil)
        })
        window.setFrameAutosaveName("HeyCastNoteEditor")
        if windows.isEmpty { window.center() } else { window.cascadeTopLeft(from: NSPoint(x: 40, y: 40)) }
        let delegate = CloseDelegate { [weak self] in
            model.flush()
            self?.windows[item.id] = nil
            self?.delegates[item.id] = nil
        }
        model.onTitleChange = { [weak window] title in window?.title = title }
        window.delegate = delegate
        windows[item.id] = window
        delegates[item.id] = delegate
        show(window)
    }

    func close(id: String) {
        windows[id]?.performClose(nil)
    }

    private func show(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private final class CloseDelegate: NSObject, NSWindowDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
    }
}

@MainActor
final class NoteEditorModel: ObservableObject {
    @Published var title: String { didSet { scheduleSave() } }
    @Published var body: String { didSet { scheduleSave() } }
    @Published private(set) var item: NoteItem

    var onTitleChange: ((String) -> Void)?

    private let store: NotesStore
    private let onChange: () -> Void
    private var saveTask: Task<Void, Never>?

    init(item: NoteItem, store: NotesStore, onChange: @escaping () -> Void) {
        self.item = item
        self.title = item.title ?? ""
        self.body = item.body
        self.store = store
        self.onChange = onChange
    }

    var isResolved: Bool { item.status == .resolved }

    func toggleResolved() {
        flush()
        store.setStatus(id: item.id, isResolved ? .open : .resolved)
        reload()
    }

    func setKind(_ kind: NoteItem.Kind) {
        flush()
        store.setKind(id: item.id, kind)
        reload()
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        let newTitle = title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title
        guard newTitle != item.title || body != item.body else { return }
        store.update(id: item.id, title: newTitle, body: body)
        reload()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func reload() {
        if let fresh = store.item(id: item.id) { item = fresh }
        onTitleChange?(item.displayTitle)
        onChange()
    }
}

struct NoteEditorView: View {
    @ObservedObject var model: NoteEditorModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(placeholder, text: $model.title)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
            if let example = model.item.context?.example, model.item.kind == .word {
                Text("“\(example)”")
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                    .textSelection(.enabled)
            }
            Divider()
            TextEditor(text: $model.body)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
            Divider()
            footer
        }
        .frame(minWidth: 360, minHeight: 240)
        .background(Color(nsColor: .textBackgroundColor))
        .onExitCommand(perform: close)
    }

    private var placeholder: String {
        switch model.item.kind {
        case .word: return "Word or phrase"
        case .inbox, .note: return "Title"
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { model.item.kind }, set: { model.setKind($0) })) {
                Text("Inbox").tag(NoteItem.Kind.inbox)
                Text("Note").tag(NoteItem.Kind.note)
                Text("Word").tag(NoteItem.Kind.word)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if let source = sourceText {
                if let url = model.item.context?.url.flatMap(URL.init(string:)) {
                    Link(destination: url) {
                        Label(source, systemImage: "link").lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 11))
                } else {
                    Label(source, systemImage: "app")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            Button(model.isResolved ? "Reopen" : "Resolve") { model.toggleResolved() }
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var sourceText: String? {
        guard let context = model.item.context else { return nil }
        if let url = context.url { return url }
        let parts = [context.appName, context.windowTitle].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }
}
