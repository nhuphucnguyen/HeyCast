import AppKit
import NotesCore

/// Quick capture from the main search (";thought", "w word", "n title") plus
/// a Notes page to resolve, edit and review what was captured.
@MainActor
final class NotesExtension: HeyCastExtension, ExtensionPage {
    let id = "notes"
    let title = "Notes"
    let symbolName = "note.text"
    var searchPlaceholder: String { showingDeleted ? "Search recently deleted…" : "Search notes, or type to capture…" }
    let preferredSize: NSSize? = NSSize(width: 680, height: 460)
    private(set) var content = PageContent(layout: .list, sections: [])

    var page: ExtensionPage? { self }

    let store = NotesStore(url: Config.directory.appendingPathComponent("notes.db"))
    private lazy var editors = NoteEditorWindows(store: store) { [weak self] in self?.refreshIfVisible() }
    private weak var ctx: ExtensionContext?
    private var query = ""
    private var showingDeleted = false

    private static let resolvedLimit = 15
    private static let rootSearchLimit = 3

    // MARK: - main page

    func commands(_ ctx: ExtensionContext) -> [ResultItem] {
        [
            ResultItem(id: "builtin-notes", title: "Notes", subtitle: "Inbox, notes and words",
                       icon: .symbol(symbolName), searchName: "notes", action: .switchPage(.extension(id))),
            ResultItem(id: "builtin-notes-create", title: "Create Note", subtitle: "Notes",
                       icon: .symbol("square.and.pencil"), searchName: "create note",
                       action: run("new-note", "")),
        ]
    }

    var providers: [ResultProvider] { [CaptureProvider(owner: self), SearchProvider(owner: self)] }

    /// ";fix the flaky test" etc. Claims the main page so ↵ always saves.
    private struct CaptureProvider: ResultProvider {
        unowned let owner: NotesExtension
        let phase = ResultPhase.claim

        func results(for query: String, ctx: ExtensionContext) -> [ResultItem] {
            guard let parsed = NoteCapture.parse(query, config: ctx.config) else { return [] }
            return [owner.captureRow(parsed, source: "main")]
        }
    }

    /// Pinned items and open inbox items that match the query.
    private struct SearchProvider: ResultProvider {
        unowned let owner: NotesExtension
        let phase = ResultPhase.search

        func results(for query: String, ctx: ExtensionContext) -> [ResultItem] {
            let text = query.trimmingCharacters(in: .whitespaces)
            guard text.count >= 2 else { return [] }
            return owner.store.search(text, includeResolved: false, limit: 20)
                .filter { $0.isPinned || $0.kind == .inbox }
                .prefix(NotesExtension.rootSearchLimit)
                .map { owner.row(for: $0, section: "root") }
        }
    }

    // MARK: - page lifecycle

    func didAppear(ctx: ExtensionContext) {
        self.ctx = ctx
        query = ""
        showingDeleted = false
        rebuild()
    }

    func didDisappear() {
        ctx = nil
    }

    func queryChanged(_ query: String, ctx: ExtensionContext) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        rebuild()
    }

    private func refreshIfVisible() {
        guard let ctx else { return }
        rebuild()
        ctx.reloadPage()
    }

    // MARK: - actions

    func perform(_ key: String, payload: String, ctx: ExtensionContext) {
        switch key {
        case "capture-main", "capture-page":
            guard let parsed = Self.decodeCapture(payload), !parsed.text.isEmpty else {
                ctx.signalFailure()
                return
            }
            let item = capture(parsed, ctx: ctx)
            ctx.clearQuery()
            if key == "capture-main" {
                ctx.hide()
                if parsed.kind == .note, let item { editors.open(item) }
                return
            }
            if parsed.kind == .note, let item {
                ctx.hide()
                editors.open(item)
                return
            }
        case "new-note":
            guard let item = store.create(kind: .note, title: nil, body: "") else { return }
            ctx.hide()
            editors.open(item)
            return
        case "open":
            guard let item = store.item(id: payload) else { return }
            ctx.hide()
            editors.open(item)
            return
        case "toggle-resolved":
            guard let item = store.item(id: payload) else { return }
            store.setStatus(id: payload, item.status == .resolved ? .open : .resolved)
        case "copy":
            guard let item = store.item(id: payload) else { return }
            ctx.copy(item.plainText, keepOpen: false)
            return
        case "paste":
            guard let item = store.item(id: payload) else { return }
            ctx.paste(item.plainText, keepOpen: false)
            return
        case "toggle-pin":
            guard let item = store.item(id: payload) else { return }
            store.setPinned(id: payload, !item.isPinned)
        case "to-inbox", "to-note", "to-word":
            let kind = NoteItem.Kind(rawValue: String(key.dropFirst(3))) ?? .inbox
            store.setKind(id: payload, kind)
        case "delete":
            editors.close(id: payload)
            store.delete(id: payload)
        case "restore":
            store.restore(id: payload)
        case "purge":
            store.permanentlyDelete(id: payload)
        case "show-deleted":
            showingDeleted = true
            ctx.clearQuery()
        case "hide-deleted":
            showingDeleted = false
            ctx.clearQuery()
        default:
            return
        }
        rebuild()
        ctx.reloadPage()
    }

    @discardableResult
    private func capture(_ parsed: NoteCapture.Parsed, ctx: ExtensionContext) -> NoteItem? {
        var context = NoteCapture.immediateContext(for: ctx.targetApplication)
        let item: NoteItem?
        switch parsed.kind {
        case .word:
            let (word, example) = NoteCapture.splitWord(parsed.text)
            context.example = example
            item = store.create(kind: .word, title: word, body: "", context: context)
        case .note:
            item = store.create(kind: .note, title: parsed.text, body: "", context: context)
        case .inbox:
            item = store.create(kind: .inbox, title: nil, body: parsed.text, context: context)
        }
        if let item {
            NoteCapture.fetchBrowserURL(bundleID: context.bundleID) { [weak self] url in
                guard let self, let url else { return }
                var updated = context
                updated.url = url
                self.store.setContext(id: item.id, updated)
                self.refreshIfVisible()
            }
        }
        return item
    }

    // MARK: - content

    private func rebuild() {
        if showingDeleted {
            content.sections = deletedSections()
        } else if query.isEmpty {
            content.sections = browseSections()
        } else {
            content.sections = searchSections()
        }
    }

    private func browseSections() -> [ItemSection] {
        let pinned = store.list(pinnedOnly: true)
        let unpinned = { (items: [NoteItem]) in items.filter { !$0.isPinned } }
        var sections = [
            ItemSection(title: "Pinned", items: pinned.map { row(for: $0, section: "pinned") }),
            ItemSection(title: "Inbox", items: unpinned(store.list(kind: .inbox, status: .open))
                .map { row(for: $0, section: "inbox") }),
            ItemSection(title: "Words", items: unpinned(store.list(kind: .word, status: .open, limit: 50))
                .map { row(for: $0, section: "words") }),
            ItemSection(title: "Notes", items: unpinned(store.list(kind: .note, status: .open))
                .map { row(for: $0, section: "notes") }),
            ItemSection(title: "Resolved", items: unpinned(store.list(status: .resolved, limit: Self.resolvedLimit))
                .map { row(for: $0, section: "resolved") }),
        ]
        let deleted = store.deletedCount()
        if deleted > 0 {
            sections.append(ItemSection(title: "", items: [
                ResultItem(id: "notes-show-deleted", title: "Recently Deleted",
                           subtitle: "\(deleted) item\(deleted == 1 ? "" : "s") · kept for \(NotesStore.deletedRetentionDays) days",
                           icon: .symbol("trash"), action: run("show-deleted", "")),
            ]))
        }
        if sections.allSatisfy({ $0.items.isEmpty }) {
            sections.append(ItemSection(title: "", items: [emptyHint()]))
        }
        return sections.filter { !$0.items.isEmpty }
    }

    /// Matches first so ↵ opens an existing note; the capture rows follow.
    private func searchSections() -> [ItemSection] {
        let results = store.search(query).map { row(for: $0, section: "results") }
        let capture: [ResultItem]
        if let parsed = ctx.flatMap({ NoteCapture.parse(query, config: $0.config) }) {
            capture = [captureRow(parsed, source: "page")]
        } else {
            capture = [NoteItem.Kind.inbox, .word, .note].map {
                captureRow(NoteCapture.Parsed(kind: $0, text: query), source: "page")
            }
        }
        return [
            ItemSection(title: "Results", items: results),
            ItemSection(title: "Capture", items: capture),
        ].filter { !$0.items.isEmpty }
    }

    private func deletedSections() -> [ItemSection] {
        var items = store.listDeleted()
        if !query.isEmpty {
            let needle = query.lowercased()
            items = items.filter { "\($0.displayTitle) \($0.body)".lowercased().contains(needle) }
        }
        let back = ResultItem(id: "notes-hide-deleted", title: "Back to Notes", icon: .symbol("chevron.left"),
                              action: run("hide-deleted", ""))
        return [
            ItemSection(title: "", items: [back]),
            ItemSection(title: "Recently Deleted", items: items.map(deletedRow)),
        ].filter { !$0.items.isEmpty }
    }

    private func emptyHint() -> ResultItem {
        let config = ctx?.config ?? Config()
        return ResultItem(id: "notes-empty", title: "Nothing captured yet",
                          subtitle: "From the main search: \"\(config.notesInboxPrefix)thought\" · \"\(config.notesWordPrefix)word\" · \"\(config.notesNotePrefix)title\"",
                          icon: .symbol("lightbulb"), action: .display)
    }

    // MARK: - rows

    fileprivate func captureRow(_ parsed: NoteCapture.Parsed, source: String) -> ResultItem {
        let verb: String
        let icon: String
        switch parsed.kind {
        case .inbox: verb = "Add to Inbox"; icon = "tray.and.arrow.down"
        case .word: verb = "Save Word"; icon = "character.book.closed"
        case .note: verb = "Create Note"; icon = "square.and.pencil"
        }
        guard !parsed.text.isEmpty else {
            let hint: String
            switch parsed.kind {
            case .inbox: hint = "Type a thought to save it for later"
            case .word: hint = "Type a word — add an example after \" — \""
            case .note: hint = "Type a title, then ↵ to open the editor"
            }
            return ResultItem(id: "notes-capture-hint-\(parsed.kind.rawValue)", title: hint, subtitle: verb,
                              icon: .symbol(icon), action: .display)
        }
        var title = parsed.text
        if parsed.kind == .word {
            let (word, example) = NoteCapture.splitWord(parsed.text)
            title = example.map { "\(word)  ·  “\($0)”" } ?? word
        }
        // Rows compare by id, so the id must change with the text or the
        // list keeps showing the previous title.
        return ResultItem(id: "notes-capture-\(parsed.kind.rawValue)-\(parsed.text)", title: title,
                          subtitle: "\(verb) · ↵", icon: .symbol(icon),
                          actions: [ItemAction(verb, symbolName: icon,
                                               kind: run("capture-\(source)", Self.encodeCapture(parsed)))])
    }

    fileprivate func row(for item: NoteItem, section: String) -> ResultItem {
        let shortcut = { (key: String, mods: NSEvent.ModifierFlags) in ActionShortcut(key: key, modifiers: mods) }
        var actions = [
            ItemAction(item.kind == .word ? "Open Word" : "Open Note", symbolName: "square.and.pencil",
                       kind: run("open", item.id)),
            ItemAction(item.status == .resolved ? "Reopen" : "Mark as Resolved",
                       symbolName: item.status == .resolved ? "arrow.uturn.backward" : "checkmark.circle",
                       shortcut: shortcut(ActionShortcut.returnKey, [.command]),
                       kind: run("toggle-resolved", item.id)),
            ItemAction("Copy", symbolName: "doc.on.doc", shortcut: shortcut("c", [.command, .shift]),
                       kind: run("copy", item.id)),
            ItemAction("Paste to Frontmost App", symbolName: "doc.on.clipboard",
                       shortcut: shortcut(ActionShortcut.returnKey, [.option]), kind: run("paste", item.id)),
            ItemAction(item.isPinned ? "Unpin" : "Pin", symbolName: item.isPinned ? "pin.slash" : "pin",
                       shortcut: shortcut("p", [.command, .shift]), kind: run("toggle-pin", item.id)),
        ]
        if let url = item.context?.url.flatMap(URL.init(string:)) {
            actions.append(ItemAction("Open Source Page", symbolName: "safari",
                                      shortcut: shortcut("o", [.command, .shift]), kind: .openURL(url)))
        }
        let moves = NoteItem.Kind.allCases.filter { $0 != item.kind }.map { kind in
            ItemAction("Move to \(Self.label(kind))", symbolName: Self.symbol(kind, status: .open),
                       kind: run("to-\(kind.rawValue)", item.id))
        }
        actions.append(.submenu("Move to…", symbolName: "arrow.right.square", moves))
        actions.append(ItemAction("Delete", symbolName: "trash", shortcut: shortcut("x", [.control]),
                                  style: .destructive, kind: run("delete", item.id)))
        return ResultItem(id: "note-\(section)-\(item.id)", title: item.displayTitle,
                          subtitle: subtitle(for: item, inRoot: section == "root"),
                          icon: .symbol(item.isPinned && section != "pinned" ? "pin"
                                        : Self.symbol(item.kind, status: item.status)),
                          actions: actions)
    }

    private func deletedRow(_ item: NoteItem) -> ResultItem {
        ResultItem(id: "note-deleted-\(item.id)", title: item.displayTitle,
                   subtitle: "Deleted \(Self.relative(item.deletedAt ?? item.updatedAt)) · \(Self.label(item.kind))",
                   icon: .symbol("trash"),
                   actions: [
                       ItemAction("Restore", symbolName: "arrow.uturn.backward", kind: run("restore", item.id)),
                       ItemAction("Delete Permanently", symbolName: "trash.slash",
                                  shortcut: ActionShortcut(key: "x", modifiers: [.control]),
                                  style: .destructive, kind: run("purge", item.id)),
                   ])
    }

    private func subtitle(for item: NoteItem, inRoot: Bool) -> String {
        var parts: [String] = []
        if inRoot { parts.append(Self.label(item.kind)) }
        switch item.kind {
        case .word:
            if let example = item.context?.example { parts.append("“\(example)”") }
            else if !item.body.isEmpty { parts.append(Self.firstLine(item.body)) }
        case .note:
            let rest = item.title == nil ? "" : Self.firstLine(item.body)
            if !rest.isEmpty { parts.append(rest) }
        case .inbox:
            break
        }
        parts.append(Self.relative(item.createdAt))
        if let source = item.context?.appName { parts.append("from \(source)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - helpers

    private func run(_ key: String, _ payload: String) -> ResultAction {
        .extension(id: id, key: key, payload: payload)
    }

    private static func encodeCapture(_ parsed: NoteCapture.Parsed) -> String {
        "\(parsed.kind.rawValue)\n\(parsed.text)"
    }

    private static func decodeCapture(_ payload: String) -> NoteCapture.Parsed? {
        guard let newline = payload.firstIndex(of: "\n"),
              let kind = NoteItem.Kind(rawValue: String(payload[..<newline])) else { return nil }
        return NoteCapture.Parsed(kind: kind, text: String(payload[payload.index(after: newline)...]))
    }

    private static func label(_ kind: NoteItem.Kind) -> String {
        switch kind {
        case .inbox: return "Inbox"
        case .note: return "Notes"
        case .word: return "Words"
        }
    }

    private static func symbol(_ kind: NoteItem.Kind, status: NoteItem.Status) -> String {
        if status == .resolved { return "checkmark.circle" }
        switch kind {
        case .inbox: return "tray"
        case .note: return "note.text"
        case .word: return "character.book.closed"
        }
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relative(_ date: Date) -> String {
        if -date.timeIntervalSinceNow < 60 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
