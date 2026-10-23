import Foundation

/// The set of extensions compiled into HeyCast. Adding a feature means adding
/// a type under Extensions/ and listing it here.
@MainActor
struct ExtensionRegistry {
    /// Order matters: within a phase, rows appear in this order.
    let extensions: [HeyCastExtension] = [
        WindowTilingExtension(),
        WebExtension.Website(),
        CalculatorExtension(),
        WebExtension.Search(),
    ]

    func commands(_ ctx: ExtensionContext) -> [ResultItem] {
        extensions.flatMap { $0.commands(ctx) }
    }

    func results(for query: String, phase: ResultPhase, ctx: ExtensionContext) -> [ResultItem] {
        extensions
            .flatMap(\.providers)
            .filter { $0.phase == phase }
            .flatMap { $0.results(for: query, ctx: ctx) }
    }
}
