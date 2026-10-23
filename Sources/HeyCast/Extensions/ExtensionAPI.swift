import AppKit

@MainActor
protocol HeyCastExtension {
    var id: String { get }
    var title: String { get }

    func commands(_ ctx: ExtensionContext) -> [ResultItem]

    var providers: [ResultProvider] { get }

    func perform(_ key: String, payload: String, ctx: ExtensionContext)
}

extension HeyCastExtension {
    func commands(_ ctx: ExtensionContext) -> [ResultItem] { [] }
    var providers: [ResultProvider] { [] }
    func perform(_ key: String, payload: String, ctx: ExtensionContext) {}
}

enum ResultPhase {
    case search
    // Only when no .search row matched.
    case instantAnswer
    // After instant answers, when no .search row matched.
    case fallback
}

@MainActor
protocol ResultProvider {
    var phase: ResultPhase { get }
    func results(for query: String, ctx: ExtensionContext) -> [ResultItem]
}

@MainActor
protocol ExtensionContext: AnyObject {
    var config: Config { get }
    // Frontmost before the launcher opened.
    var targetApplication: NSRunningApplication? { get }
    func hide()
    func open(_ url: URL)
    func copyText(_ text: String)
    func signalFailure()
}
