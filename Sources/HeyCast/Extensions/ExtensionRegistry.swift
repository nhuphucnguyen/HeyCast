import Foundation

@MainActor
struct ExtensionRegistry {
    // Order matters: within a phase, rows appear in this order.
    let extensions: [HeyCastExtension] = [
        WindowTilingExtension(),
        WebExtension.Website(),
        CalculatorExtension(),
        WebExtension.Search(),
        FilesExtension(),
        EmojiExtension(),
        NotesExtension(),
        ThanhCongExtension(),
    ]

    func page(_ extensionID: String) -> ExtensionPage? {
        extensions.first { $0.id == extensionID }?.page
    }

    func commands(_ ctx: ExtensionContext) -> [ResultItem] {
        extensions.flatMap { $0.commands(ctx) }
    }

    func perform(extensionID: String, key: String, payload: String, ctx: ExtensionContext) {
        extensions.first { $0.id == extensionID }?.perform(key, payload: payload, ctx: ctx)
    }

    func results(for query: String, phase: ResultPhase, ctx: ExtensionContext) -> [ResultItem] {
        extensions
            .flatMap(\.providers)
            .filter { $0.phase == phase }
            .flatMap { $0.results(for: query, ctx: ctx) }
    }
}
