import AppKit

@MainActor
protocol HeyCastExtension {
    var id: String { get }
    var title: String { get }

    func commands(_ ctx: ExtensionContext) -> [ResultItem]

    var providers: [ResultProvider] { get }

    var page: ExtensionPage? { get }

    func perform(_ key: String, payload: String, ctx: ExtensionContext)
}

extension HeyCastExtension {
    func commands(_ ctx: ExtensionContext) -> [ResultItem] { [] }
    var providers: [ResultProvider] { [] }
    var page: ExtensionPage? { nil }
    func perform(_ key: String, payload: String, ctx: ExtensionContext) {}
}

enum ResultPhase {
    // Takes over the main page (e.g. a capture prefix): when any provider
    // returns rows here, they are the only rows shown.
    case claim
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
    func copy(_ text: String, keepOpen: Bool)
    func paste(_ text: String, keepOpen: Bool)
    func signalFailure()
    func store(for extensionID: String) -> ExtensionStore
    func reloadPage()
    func clearQuery()
    /// Re-runs main-page result assembly — extensions call this when data a
    /// .claim provider shows (e.g. a network feed) has arrived asynchronously.
    func refreshMainResults()
    /// Opens an extension page from the main page (e.g. "/tc" jumping
    /// straight into its reader instead of listing rows inline).
    func openPage(_ extensionID: String)
}

extension ExtensionContext {
    func refreshMainResults() {}
    func openPage(_ extensionID: String) {}
}
