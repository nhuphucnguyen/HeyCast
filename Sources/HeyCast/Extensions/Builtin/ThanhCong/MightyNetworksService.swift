import Foundation

/// Read-only data access for the Thanh Cong TC community on Mighty Networks
/// (`thanhcongtc.mn.co`). Implements exactly what the reverse-engineering
/// notes in the `thanhcongtc` repo document
/// (`docs/mighty-networks-data-access.md`):
///
/// - Authentication reuses the member's browser session cookies
///   (`mn_browser_key` + `_session_id`) from a Netscape cookie jar — the
///   platform has no public API token and no scripted login.
/// - Posts come from `GET /spaces/{id}/posts`: newest first, `per_page`
///   capped at 100, pagination stops on a short or empty batch. There is no
///   server-side author filter, so author filtering happens client-side.
/// - Space ids and names come from `GET /spaces/{root}/my/navigation_menu`
///   so newly created spaces need no code change.
/// - Read only: every call here is a GET — no writes are ever automated.
///
/// Raw responses are heavy (each post embeds comments/cheers/reactions), so
/// they are trimmed to the small `Post` value right after decoding.
enum MightyNetworksService {

    static let baseURL = URL(string: "https://thanhcongtc.mn.co/api/web/v1")!

    /// Not required by the JSON API (§2.2 of the notes) but kept identical to
    /// the working reference implementation anyway.
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0 Safari/537.36"

    // MARK: - models

    struct Post: Codable, Equatable, Identifiable {
        var id: Int
        var url: String
        var title: String        // may be empty (image/poll posts)
        var excerpt: String      // plain text, used for search + row fallbacks
        var body: String         // plain text with paragraph breaks (search)
        var bodyHTML: String     // raw HTML, capped at a paragraph (preview)
        var bodyComplete: Bool   // false → bodyHTML was truncated at the cap
        var spaceID: Int
        var spaceName: String
        var author: String
        var createdAt: Date
        var symbol: String       // SF Symbol for the row icon
        var kindLabel: String    // "article" / "poll" / "photo post" / "post"
        var comments: Int
        var cheers: Int
        var isAuthor: Bool       // author matches Config.tcAuthor
    }

    struct Feed: Codable, Equatable {
        var fetchedAt: Date
        var posts: [Post]        // newest first
    }

    enum FeedError: Error, CustomStringConvertible, LocalizedError {
        case cookiesMissing(String)
        case unauthorized
        case http(Int)
        case transport(String)

        var description: String {
            switch self {
            case .cookiesMissing(let path):
                return "Cookie jar not found at \(path)"
            case .unauthorized:
                return "session expired (401)"
            case .http(let code):
                return "HTTP \(code)"
            case .transport(let message):
                return message
            }
        }

        var errorDescription: String? { description }
    }

    // MARK: - fetching

    static func fetchFeed(cookiePath: String, rootSpaceID: Int,
                          spaceIDs: [Int], author: String) async throws -> Feed {
        let cookies = try cookieHeader(cookiePath: cookiePath)

        // Space names are resolved from the navigation menu (§4: never
        // hard-code the list — new spaces can appear at any time). Best
        // effort: a failed menu call only degrades names to "space {id}".
        var spaceNames = [Int: String]()
        if let menu: MenuResponse = try? await getJSON("spaces/\(rootSpaceID)/my/navigation_menu", cookies: cookies) {
            for space in menu.spaces ?? [] {
                guard let id = space.id else { continue }
                let title = space.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                spaceNames[id] = title?.isEmpty == false ? title! : "space \(id)"
            }
        }

        var posts = [Post]()
        var seenIDs = Set<Int>()
        var seenTitles = Set<String>()
        for spaceID in spaceIDs {
            for raw in try await fetchPosts(spaceID: spaceID, cookies: cookies) {
                guard let id = raw.id, !seenIDs.contains(id) else { continue }
                seenIDs.insert(id)
                // Cross-posts (the same article shared to several spaces)
                // carry different ids — collapse them by title + hour.
                // Titleless posts (images) are never collapsed: two
                // different screenshots can easily share an hour.
                let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !title.isEmpty {
                    let created = parseDate(raw.published_at) ?? parseDate(raw.created_at)
                    let hour = created.map { Int($0.timeIntervalSince1970 / 3600) } ?? 0
                    if !seenTitles.insert("\(title)|\(hour)").inserted { continue }
                }
                let postSpaceID = raw.space_id ?? spaceID
                posts.append(trim(raw, id: id,
                                  spaceName: spaceNames[postSpaceID] ?? "space \(postSpaceID)",
                                  author: author))
            }
        }
        // §6.4: after merging spaces, sort again — newest first.
        posts.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
        return Feed(fetchedAt: Date(), posts: posts)
    }

    /// §3.1 — the server already sorts newest first; pages stop early (§6.4).
    private static func fetchPosts(spaceID: Int, cookies: String, perPage: Int = 100,
                                   maxPages: Int = 3) async throws -> [RawPost] {
        var all = [RawPost]()
        for page in 1...maxPages {
            let batch: [RawPost] = try await getJSON(
                "spaces/\(spaceID)/posts", cookies: cookies,
                query: [URLQueryItem(name: "page", value: String(page)),
                        URLQueryItem(name: "per_page", value: String(perPage))])
            all.append(contentsOf: batch)
            if batch.count < perPage { break }
        }
        return all
    }

    private static func getJSON<T: Decodable>(_ path: String, cookies: String,
                                              query: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookies, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FeedError.transport(error.localizedDescription)
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200:
            break
        case 401:
            // §2.4: the session died — the user has to re-export the jar.
            throw FeedError.unauthorized
        case let code:
            throw FeedError.http(code)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - cookie jar (Netscape format, §6.1)

    /// Builds a Cookie header from the Netscape jar. Tolerates the known
    /// exporter trap: httpOnly lines must start `#HttpOnly_<domain>` with no
    /// space — some tools write `#HttpOnly_ <domain>`, which curl would read
    /// as a comment and silently drop the auth cookie.
    static func cookieHeader(cookiePath: String) throws -> String {
        let expanded = NSString(string: cookiePath).expandingTildeInPath
        guard let raw = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            throw FeedError.cookiesMissing(cookiePath)
        }
        var pairs = [String]()
        for line in raw.split(whereSeparator: \.isNewline) {
            var body = line
            if body.hasPrefix("#") {
                body = body.dropFirst()
                if body.hasPrefix("HttpOnly_") {
                    body = body.dropFirst("HttpOnly_".count)
                    while body.first == " " || body.first == "\t" { body = body.dropFirst() }
                } else {
                    continue  // a real comment
                }
            }
            let fields = body.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 7 else { continue }
            let name = fields[5].trimmingCharacters(in: .whitespaces)
            let value = fields[6].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            pairs.append("\(name)=\(value)")
        }
        guard !pairs.isEmpty else { throw FeedError.cookiesMissing(cookiePath) }
        return pairs.joined(separator: "; ")
    }

    // MARK: - raw response decoding (fail-soft: §8, schema may change)

    private struct RawUser: Decodable {
        var id: Int?
        var name: String?
    }

    private struct RawPost: Decodable {
        var id: Int?
        var title: String?
        var description: String?
        var creator_id: Int?
        var user: RawUser?
        var space_id: Int?
        var created_at: String?
        var published_at: String?
        var kind: String?
        var post_type: String?
        var comment_count: Int?
        var cheer_count: Int?
    }

    private struct MenuResponse: Decodable {
        var spaces: [MenuSpace]?
    }

    private struct MenuSpace: Decodable {
        var id: Int?
        var title: String?
    }

    private static func trim(_ raw: RawPost, id: Int, spaceName: String, author: String) -> Post {
        let name = raw.user?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorName = name?.isEmpty == false ? name! : "unknown"
        let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawHTML = raw.description ?? ""
        let (previewHTML, previewComplete) = cappedHTML(rawHTML)
        let fullBody = plainText(rawHTML, preservingBreaks: true)
        return Post(id: id,
                    url: "https://thanhcongtc.mn.co/posts/\(id)",  // §7: verified format
                    title: title,
                    excerpt: String(fullBody
                        .replacingOccurrences(of: "\n", with: " ")
                        .split(whereSeparator: \.isWhitespace)
                        .joined(separator: " ")
                        .prefix(300)),
                    body: String(fullBody.prefix(bodyCharacterCap)),
                    bodyHTML: previewHTML,
                    bodyComplete: previewComplete,
                    spaceID: raw.space_id ?? 0,
                    spaceName: spaceName,
                    author: authorName,
                    createdAt: parseDate(raw.published_at) ?? parseDate(raw.created_at) ?? Date(),
                    symbol: symbol(kind: raw.kind, postType: raw.post_type),
                    kindLabel: kindLabel(kind: raw.kind, postType: raw.post_type),
                    comments: raw.comment_count ?? 0,
                    cheers: raw.cheer_count ?? 0,
                    isAuthor: authorName.caseInsensitiveCompare(author) == .orderedSame)
    }

    /// Preview caps — enough to judge (and usually read) a post without
    /// opening the browser, while keeping the disk cache small (§8).
    static let bodyCharacterCap = 4_000
    static let htmlCharacterCap = 16_000

    /// Cuts the raw HTML at the last complete paragraph before the cap so the
    /// preview never ends inside a tag.
    private static func cappedHTML(_ html: String) -> (String, Bool) {
        guard html.count > htmlCharacterCap else { return (html, true) }
        let cut = String(html.prefix(htmlCharacterCap))
        if let range = cut.range(of: "</p>", options: .backwards) {
            return (String(cut[..<range.upperBound]), false)
        }
        return (cut, false)
    }

    private static func symbol(kind: String?, postType: String?) -> String {
        switch postType ?? kind ?? "" {
        case "article": return "doc.text"
        case "poll": return "chart.bar"
        case "image_file": return "photo"
        case "event": return "calendar"
        case "video": return "play.rectangle"
        default: return "doc.plaintext"
        }
    }

    private static func kindLabel(kind: String?, postType: String?) -> String {
        switch postType ?? kind ?? "" {
        case "article": return "article"
        case "poll": return "poll"
        case "image_file": return "photo post"
        case "event": return "event"
        case "video": return "video"
        default: return "post"
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return isoFormatter.date(from: string) ?? isoFractionalFormatter.date(from: string)
    }

    // MARK: - HTML → plain text (excerpt + preview body)

    static func htmlToText(_ html: String?) -> String {
        plainText(html, preservingBreaks: false)
    }

    static func plainText(_ html: String?, preservingBreaks: Bool) -> String {
        guard var text = html, !text.isEmpty else { return "" }
        // Block boundaries become separators so words don't fuse together;
        // with breaks preserved they become paragraph/line breaks.
        for tag in ["</p>", "</div>", "</li>"] {
            text = text.replacingOccurrences(of: tag, with: preservingBreaks ? "\n" : " ")
        }
        for tag in ["<br>", "<br/>", "<br />"] {
            text = text.replacingOccurrences(of: tag, with: preservingBreaks ? "\n" : " ")
        }
        while let range = text.range(of: "<[^>]+>", options: .regularExpression) {
            text.replaceSubrange(range, with: " ")
        }
        text = text.htmlUnescaped
        if preservingBreaks {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            var out = lines.joined(separator: "\n")
            while out.contains("\n\n\n") {
                out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - cache (§8: cache results, poll rarely)

    enum FeedCache {
        static var fileURL: URL { Config.directory.appendingPathComponent("thanhcongtc-feed.json") }

        static func load() -> Feed? {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            return try? JSONDecoder().decode(Feed.self, from: data)
        }

        static func save(_ feed: Feed) {
            try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(feed) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
}

private extension String {
    /// Minimal HTML entity decoding — enough for community post bodies.
    var htmlUnescaped: String {
        var text = self
        text = text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            // &amp; must be decoded last so "&amp;lt;" can't become "<".
            .replacingOccurrences(of: "&amp;", with: "&")
        while let range = text.range(of: "&#x?[0-9a-fA-F]+;", options: .regularExpression) {
            let digits = text[range].dropFirst(2).dropLast()
            let value: Int?
            if digits.first == "x" || digits.first == "X" {
                value = Int(digits.dropFirst(), radix: 16)
            } else {
                value = Int(digits)
            }
            if let value, value > 0, let uint = UInt32(exactly: value),
               let scalar = Unicode.Scalar(uint) {
                text.replaceSubrange(range, with: String(Character(scalar)))
            } else {
                text.replaceSubrange(range, with: " ")
            }
        }
        return text
    }
}
