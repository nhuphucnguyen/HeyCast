import AppKit

@MainActor
final class FilesExtension: HeyCastExtension, ExtensionPage {
    let id = "files"
    let title = "File Search"
    let symbolName = "folder"
    let searchPlaceholder = "Search files…"
    private(set) var content = PageContent(layout: .list, sections: [])

    var page: ExtensionPage? { self }

    private let service = FileSearchService()
    private var searchTask: Task<Void, Never>?
    private var icons: [String: NSImage] = [:]
    private weak var ctx: ExtensionContext?

    func commands(_ ctx: ExtensionContext) -> [ResultItem] {
        [ResultItem(id: "builtin-files", title: "Search for a file", subtitle: "File search",
                    icon: .symbol(symbolName), searchName: "file search", action: .switchPage(.extension(id)))]
    }

    func didAppear(ctx: ExtensionContext) {
        self.ctx = ctx
        service.onUpdate = { [weak self] in
            guard let self else { return }
            self.show(self.service.results)
        }
        content.sections = []
    }

    func didDisappear() {
        searchTask?.cancel()
        service.cancel()
        icons = [:]
    }

    func queryChanged(_ query: String, ctx: ExtensionContext) {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            service.cancel()
            content.sections = []
            return
        }
        let delay = UInt64(ctx.config.debounceDelayMS) * 1_000_000
        let searchDirs = ctx.config.searchDirs
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.service.search(text, searchDirs: searchDirs)
        }
    }

    private func show(_ hits: [FileSearchService.FileHit]) {
        content.sections = hits.isEmpty ? [] : [ItemSection(title: "", items: hits.map(item))]
        ctx?.reloadPage()
    }

    private func item(for hit: FileSearchService.FileHit) -> ResultItem {
        let url = URL(fileURLWithPath: hit.path)
        return ResultItem(
            id: hit.path, title: hit.name, subtitle: FileSearchService.displayPath(hit.path),
            icon: .app(icon(for: hit.path)),
            actions: [
                ItemAction("Open", symbolName: "arrow.up.forward.square", kind: .openURL(url)),
                ItemAction(symbolName: "folder",
                           shortcut: ActionShortcut(key: ActionShortcut.returnKey, modifiers: [.command]),
                           kind: .showInFinder(url)),
                ItemAction("Copy Path", symbolName: "doc.on.doc",
                           shortcut: ActionShortcut(key: "c", modifiers: [.command, .shift]),
                           kind: .copyText(hit.path)),
            ])
    }

    private func icon(for path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }
}
