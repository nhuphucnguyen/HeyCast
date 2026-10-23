import Foundation

/// A self-contained feature that plugs into the launcher without touching
/// LauncherModel. Modelled on Raycast's extensions: an extension declares
/// static commands (like a Raycast manifest) and/or dynamic result providers,
/// and only talks to the host through `ExtensionContext`.
@MainActor
protocol HeyCastExtension {
    var id: String { get }
    var title: String { get }

    /// Static rows: listed on the blank main page and fuzzy-matched by title
    /// in root search by the host.
    func commands(_ ctx: ExtensionContext) -> [ResultItem]

    /// Dynamic rows computed from the query.
    var providers: [ResultProvider] { get }
}

extension HeyCastExtension {
    func commands(_ ctx: ExtensionContext) -> [ResultItem] { [] }
    var providers: [ResultProvider] { [] }
}

/// When a provider's rows appear in root search.
enum ResultPhase {
    /// Shown alongside app matches for every query.
    case search
    /// Shown only when nothing in `.search` matched (URL, calculator, …).
    case instantAnswer
    /// Appended after instant answers when nothing matched (web search).
    case fallback
}

@MainActor
protocol ResultProvider {
    var phase: ResultPhase { get }
    func results(for query: String, ctx: ExtensionContext) -> [ResultItem]
}

/// The host API an extension may use. Kept deliberately narrow — new host
/// capabilities are added here rather than extensions reaching into
/// LauncherModel.
@MainActor
protocol ExtensionContext: AnyObject {
    var config: Config { get }
}
