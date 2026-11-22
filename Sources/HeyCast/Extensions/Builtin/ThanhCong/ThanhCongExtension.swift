import AppKit
import SwiftUI

/// News feed for the closed **Thanh Cong TC** community (Mighty Networks).
///
/// Type `/tc` in the main search: the claim provider takes over the page and
/// lists the latest posts right there — "/tc <text>" filters them live
/// (diacritics-insensitive). ↵ on the header row, or `heycast://page?name=tc`,
/// opens the full reader: a dedicated page grouped by day with a refresh row
/// and an author filter.
///
/// Everything data-related lives in `MightyNetworksService`, which follows
/// the notes in the `thanhcongtc` repo (`docs/mighty-networks-data-access.md`):
/// session cookies from a Netscape jar, read-only GETs only, client-side
/// author filter, results cached on disk and refreshed at most every
/// `tcRefreshMinutes` so the community API is polled gently.
@MainActor
final class ThanhCongExtension: HeyCastExtension, ExtensionPage {
    let id = "tc"
    let title = "Thanh Cong TC"
    let symbolName = "newspaper"
    var searchPlaceholder: String { "Filter the feed…" }
    let preferredSize: NSSize? = NSSize(width: 940, height: 540)
    private(set) var content = PageContent(layout: .list, sections: [])

    var page: ExtensionPage? { self }

    /// Custom reader layout: compact list on the left, the selected post's
    /// content on the right.
    func pageView(model: LauncherModel) -> AnyView? {
        AnyView(ThanhCongReaderView(model: model, container: self))
    }

    // MARK: - state

    private struct State: Codable {
        // TC's posts are the point of this feed (same default as the HTML
        // digest's "Chỉ bài của __AUTHOR__" checkbox) — toggle at the bottom
        // of the reader page when the whole community is wanted.
        var authorOnly: Bool = true
        var lastVisit: Date? = nil
    }

    private enum Status: Equatable {
        case idle          // nothing fetched yet
        case loading
        case ready
        case unauthorized  // 401 — the cookie jar needs a re-export (§2.4)
        case failed(String)
    }

    private var state = State()
    private var feed: MightyNetworksService.Feed?
    private var status: Status = .idle
    private var query = ""
    private weak var ctx: ExtensionContext?
    private var loadTask: Task<Void, Never>?
    private var lastConfig = Config()
    /// Posts newer than this get the 🆕 badge; moved to the previous visit
    /// timestamp whenever the feed is entered after a lull (see markFeedEntry).
    private var badgeReference: Date?

    init() {
        feed = MightyNetworksService.FeedCache.load()
        status = feed == nil ? .idle : .ready
        state = ExtensionStore(extensionID: id).load(State.self) ?? State()
        badgeReference = state.lastVisit
    }

    // MARK: - main page claim ("/tc")

    var providers: [ResultProvider] { [ClaimProvider(owner: self)] }

    func commands(_ ctx: ExtensionContext) -> [ResultItem] {
        [ResultItem(id: "builtin-thanhcong", title: "Thanh Cong TC Feed",
                    subtitle: "Community news · /tc", icon: .symbol(symbolName),
                    searchName: "thanh cong tc", action: .switchPage(.extension(id)))]
    }

    /// "<tcPrefix>" takes over the main page with the latest posts; appending
    /// text narrows them. Rows appear immediately from the disk cache, and a
    /// stale feed refreshes in the background.
    private struct ClaimProvider: ResultProvider {
        unowned let owner: ThanhCongExtension
        let phase = ResultPhase.claim

        func results(for query: String, ctx: ExtensionContext) -> [ResultItem] {
            let prefix = ctx.config.tcPrefix.trimmingCharacters(in: .whitespaces).lowercased()
            guard !prefix.isEmpty else { return [] }
            let lowered = query.lowercased()
            guard lowered == prefix || lowered.hasPrefix(prefix + " ") else { return [] }
            return owner.claimResults(rawQuery: query, ctx: ctx)
        }
    }

    fileprivate func claimResults(rawQuery: String, ctx: ExtensionContext) -> [ResultItem] {
        self.ctx = ctx
        lastConfig = ctx.config
        markFeedEntry()
        ensureFresh(ctx: ctx)
        // "<tcPrefix>" exists to open the reader — jump straight to the page.
        // The rows built below are only a fallback; once the page is up they
        // are never displayed.
        ctx.openPage(id)

        let prefix = ctx.config.tcPrefix.trimmingCharacters(in: .whitespaces)
        let filter = rawQuery.lowercased().hasPrefix((prefix + " ").lowercased())
            ? String(rawQuery.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let posts = filteredPosts(filter)
        var rows = posts.prefix(12).map { postRow($0) }
        if posts.isEmpty { rows.append(noMatchRow(filter)) }
        if let statusRow { rows.append(statusRow) }
        return rows
    }

    // MARK: - ExtensionPage (full reader)

    func didAppear(ctx: ExtensionContext) {
        self.ctx = ctx
        lastConfig = ctx.config
        query = ""
        markFeedEntry()
        ensureFresh(ctx: ctx)
        rebuild()
    }

    func didDisappear() {
        ctx = nil
    }

    func queryChanged(_ query: String, ctx: ExtensionContext) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastConfig = ctx.config
        rebuild()
        // content is a plain value, not @Published — force the page to
        // re-read it, otherwise rows can keep showing the previous filter.
        ctx.reloadPage()
    }

    // MARK: - actions

    func perform(_ key: String, payload: String, ctx: ExtensionContext) {
        switch key {
        case "refresh":
            ensureFresh(ctx: ctx, force: true)
            ctx.reloadPage()
            return
        case "copy-link", "copy-title":
            ctx.copy(payload, keepOpen: false)
            return
        case "toggle-author":
            state.authorOnly.toggle()
            ExtensionStore(extensionID: id).save(state)
        default:
            return
        }
        rebuild()
        ctx.reloadPage()
    }

    // MARK: - refresh

    private func refreshInterval(_ config: Config) -> TimeInterval {
        TimeInterval(max(5, config.tcRefreshMinutes) * 60)
    }

    /// Fetches unless a load is already running and (when not forced) the
    /// cached feed is younger than the refresh interval — the docs recommend
    /// gentle polling (§8). A failure never discards the cached feed.
    ///
    /// Without `force`, a failed/unauthorized state is left alone: the row
    /// in the feed explains the problem and its Retry action calls back with
    /// force — that keeps typing "/tc" from hot-looping the API after a 401.
    private func ensureFresh(ctx: ExtensionContext, force: Bool = false) {
        guard loadTask == nil, status != .loading else { return }
        if !force {
            if case .unauthorized = status { return }
            if case .failed = status { return }
            if let feed, Date().timeIntervalSince(feed.fetchedAt) < refreshInterval(ctx.config) { return }
        }

        lastConfig = ctx.config
        status = .loading
        rebuild()  // page content flips to the refreshing state

        let cookiePath = ctx.config.tcCookiePath
        let rootSpaceID = ctx.config.tcRootSpaceID
        let spaceIDs = ctx.config.tcSpaces
        let author = ctx.config.tcAuthor
        loadTask = Task { [weak self] in
            var fresh: MightyNetworksService.Feed?
            var failure: Error?
            do {
                // Parse off the main actor — a few hundred posts of JSON.
                fresh = try await Task.detached(priority: .utility) {
                    try await MightyNetworksService.fetchFeed(cookiePath: cookiePath, rootSpaceID: rootSpaceID,
                                                              spaceIDs: spaceIDs, author: author)
                }.value
            } catch {
                failure = error
            }
            guard let self else { return }
            self.loadTask = nil
            if let fresh {
                self.feed = fresh
                MightyNetworksService.FeedCache.save(fresh)
                self.status = .ready
            } else {
                switch failure {
                case .some(MightyNetworksService.FeedError.unauthorized):
                    self.status = .unauthorized
                case .some(let error):
                    self.status = .failed(error.localizedDescription)
                case .none:
                    self.status = .failed("unknown error")
                }
            }
            self.rebuild()
            self.ctx?.reloadPage()
            // The claim view on the main page must pick the new rows up too.
            self.ctx?.refreshMainResults()
        }
    }

    // MARK: - viewing sessions (🆕 badges)

    /// Entering the feed marks a viewing session: 🆕 badges then compare
    /// against the previous session. Keystrokes and quick page switches must
    /// not move the baseline, so a session stays open for 10 minutes of
    /// continuous viewing.
    private func markFeedEntry(now: Date = Date()) {
        if let last = state.lastVisit, now.timeIntervalSince(last) < 600 { return }
        badgeReference = state.lastVisit
        state.lastVisit = now
        ExtensionStore(extensionID: id).save(state)
    }

    // MARK: - filtering

    private func filteredPosts(_ filter: String) -> [MightyNetworksService.Post] {
        var posts = feed?.posts ?? []
        if state.authorOnly {
            posts = posts.filter(\.isAuthor)
        }
        let needle = Self.normalized(filter)
        if !needle.isEmpty {
            posts = posts.filter {
                Self.normalized("\($0.title) \($0.excerpt) \($0.body) \($0.author) \($0.spaceName)").contains(needle)
            }
        }
        return posts
    }

    /// Vietnamese-friendly matching: case-, diacritics- and width-insensitive
    /// (same behaviour as the search in the HTML digest).
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "vi_VN"))
    }

    // MARK: - rows

    private func postRow(_ post: MightyNetworksService.Post) -> ResultItem {
        let isNew = badgeReference.map { post.createdAt > $0 } ?? false
        let displayTitle = Self.displayTitle(post)
        // The list column is narrow — details live in the preview pane. The
        // primary action reads in place: the reader IS the destination, and
        // the browser only opens via its own action/button.
        var subtitle = Self.ago(post.createdAt)
        let stats = Self.statsLabel(post)
        if !stats.isEmpty { subtitle += " · " + stats }
        var actions = [ItemAction]()
        if let url = URL(string: post.url) {
            actions.append(ItemAction("Read Here", symbolName: "book", kind: .display))
            actions.append(ItemAction("Open in Browser", symbolName: "globe",
                                      shortcut: ActionShortcut(key: "o", modifiers: [.command]),
                                      kind: .openURL(url)))
        }
        actions.append(ItemAction("Copy Link", symbolName: "link",
                                  shortcut: ActionShortcut(key: "c", modifiers: [.command]),
                                  kind: .copyText(post.url)))
        actions.append(ItemAction("Copy Title", symbolName: "doc.on.doc",
                                  shortcut: ActionShortcut(key: "c", modifiers: [.command, .option]),
                                  kind: .copyText(displayTitle)))
        return ResultItem(id: "tc-post-\(post.id)",
                          title: isNew ? "🆕 \(displayTitle)" : displayTitle,
                          subtitle: subtitle,
                          icon: .symbol(post.symbol),
                          actions: actions)
    }

    private func noMatchRow(_ filter: String) -> ResultItem {
        var subtitle = "Try a shorter keyword"
        if filter.isEmpty && state.authorOnly {
            subtitle = "The author filter (\(lastConfig.tcAuthor)) is on — toggle it at the bottom of the reader"
        }
        return ResultItem(id: "tc-status-nomatch", title: "No posts match “\(filter)”",
                          subtitle: subtitle, icon: .symbol("magnifyingglass"), action: .display)
    }

    /// Loading / 401 / failure line — nil when everything is fine.
    private var statusRow: ResultItem? {
        switch status {
        case .loading:
            return ResultItem(id: "tc-status-loading", title: "Fetching the feed…",
                              subtitle: "thanhcongtc.mn.co", icon: .symbol("arrow.triangle.2.circlepath"),
                              action: .display)
        case .unauthorized:
            return ResultItem(id: "tc-status-unauthorized",
                              title: "Session expired — the community API answered 401",
                              subtitle: "Đăng nhập lại thanhcongtc.mn.co trong browser rồi xuất lại cookie "
                                      + "vào \(lastConfig.tcCookiePath) (mục 6.1 trong docs của repo thanhcongtc)",
                              icon: .symbol("key.fill"), action: .display)
        case .failed(let message):
            return ResultItem(id: "tc-status-failed", title: "Feed refresh failed — \(message)",
                              subtitle: "Fix the problem, then ↵ retries",
                              icon: .symbol("exclamationmark.triangle"), action: run("refresh", ""))
        default:
            return nil
        }
    }

    // MARK: - reader page content

    private func rebuild() {
        var sections = [ItemSection]()
        if case .unauthorized = status {
            sections.append(ItemSection(title: "", items: [statusRow].compactMap(\.self)))
        }
        if feed != nil {
            let posts = filteredPosts(query)
            if posts.isEmpty {
                sections.append(ItemSection(title: "", items: [noMatchRow(query)]))
            } else {
                sections.append(contentsOf: daySections(posts))
            }
        } else if status == .loading || loadTask != nil {
            sections.append(ItemSection(title: "", items: [statusRow].compactMap(\.self)))
        } else {
            sections.append(ItemSection(title: "", items: [firstRunRow]))
        }
        sections.append(ItemSection(title: "", items: [authorRow, refreshRow]))
        content.sections = sections
    }

    private func daySections(_ posts: [MightyNetworksService.Post]) -> [ItemSection] {
        var sections = [ItemSection]()
        for post in posts {
            let label = Self.dayLabel(post.createdAt)
            if let last = sections.last, last.title == label {
                sections[sections.count - 1].items.append(postRow(post))
            } else {
                sections.append(ItemSection(title: label, items: [postRow(post)]))
            }
        }
        return sections
    }

    private var authorRow: ResultItem {
        let author = lastConfig.tcAuthor
        if state.authorOnly {
            return ResultItem(id: "tc-author-filter", title: "Author filter: only \(author)",
                              subtitle: "↵ shows everyone again",
                              icon: .symbol("person.crop.circle.badge.checkmark"),
                              action: run("toggle-author", ""))
        }
        return ResultItem(id: "tc-author-filter", title: "Author filter: everyone",
                          subtitle: "↵ shows only \(author)’s posts",
                          icon: .symbol("person.crop.circle"),
                          action: run("toggle-author", ""))
    }

    private var refreshRow: ResultItem {
        if status == .loading {
            return ResultItem(id: "tc-refresh", title: "Refreshing…", subtitle: "talking to thanhcongtc.mn.co",
                              icon: .symbol("arrow.triangle.2.circlepath"), action: .display)
        }
        var subtitle = "Never fetched"
        if let feed { subtitle = "Updated \(Self.ago(feed.fetchedAt))" }
        if case .failed(let message) = status { subtitle += " · last attempt failed (\(message))" }
        return ResultItem(id: "tc-refresh", title: "Refresh Now", subtitle: subtitle,
                          icon: .symbol("arrow.clockwise"), action: run("refresh", ""))
    }

    private var firstRunRow: ResultItem {
        switch status {
        case .failed(let message):
            return ResultItem(id: "tc-first-run", title: "Couldn’t fetch the feed — \(message)",
                              subtitle: "↵ on “Refresh Now” below retries",
                              icon: .symbol("exclamationmark.triangle"), action: .display)
        default:
            return ResultItem(id: "tc-first-run", title: "No cached feed yet",
                              subtitle: "↵ on “Refresh Now” below fetches it",
                              icon: .symbol("newspaper"), action: .display)
        }
    }

    // MARK: - helpers

    private func run(_ key: String, _ payload: String) -> ResultAction {
        .extension(id: id, key: key, payload: payload)
    }

    /// The post a result row points at (rows carry "tc-post-<id>" ids).
    func post(for item: ResultItem?) -> MightyNetworksService.Post? {
        guard let item, item.id.hasPrefix("tc-post-"),
              let id = Int(item.id.dropFirst("tc-post-".count)) else { return nil }
        return feed?.posts.first { $0.id == id }
    }

    /// Row title: the post's own title, or the opening words of its content
    /// when the post has none (image/poll posts).
    static func displayTitle(_ post: MightyNetworksService.Post) -> String {
        if !post.title.isEmpty { return post.title }
        if !post.excerpt.isEmpty {
            return String(post.excerpt.prefix(72)) + (post.excerpt.count > 72 ? "…" : "")
        }
        return "(\(post.kindLabel))"
    }

    /// "💬 12 · 👏 34" — empty when the post has no interactions yet.
    static func statsLabel(_ post: MightyNetworksService.Post) -> String {
        var stats: [String] = []
        if post.comments > 0 { stats.append("💬 \(post.comments)") }
        if post.cheers > 0 { stats.append("👏 \(post.cheers)") }
        return stats.joined(separator: "  ")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    fileprivate static func dayLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return dayFormatter.string(from: date)
    }

    static func ago(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 45 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        if seconds < 7 * 86_400 { return "\(seconds / 86_400)d ago" }
        return shortDateFormatter.string(from: date)
    }
}
