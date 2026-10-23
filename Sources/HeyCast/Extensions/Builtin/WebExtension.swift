import Foundation

/// Opening URL-like queries and searching the web. Two extensions so the
/// registry can rank web search after every other instant answer.
enum WebExtension {
    struct Website: HeyCastExtension, ResultProvider {
        let id = "website"
        let title = "Open Website"
        let phase = ResultPhase.instantAnswer
        var providers: [ResultProvider] { [self] }

        func results(for query: String, ctx: ExtensionContext) -> [ResultItem] {
            guard Self.isURLLike(query) else { return [] }
            let urlString = query.hasPrefix("http://") || query.hasPrefix("https://") ? query : "https://" + query
            guard let url = URL(string: urlString) else { return [] }
            return [ResultItem(id: "url-\(query)",
                               title: "Open \(url.host ?? query)",
                               subtitle: "Website",
                               icon: .symbol("globe"),
                               action: .openURL(url))]
        }

        static func isURLLike(_ query: String) -> Bool {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            if trimmed.contains(where: { $0.isWhitespace }) { return false }
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return true }
            // crude reversed-TLD heuristic: something.tld
            guard let dotRange = trimmed.range(of: ".", options: .backwards) else { return false }
            let tld = trimmed[dotRange.upperBound...]
            let host = trimmed[..<dotRange.lowerBound]
            return tld.count >= 2 && tld.allSatisfy(\.isLetter) && !host.isEmpty
        }
    }

    struct Search: HeyCastExtension, ResultProvider {
        let id = "web-search"
        let title = "Web Search"
        let phase = ResultPhase.fallback
        var providers: [ResultProvider] { [self] }

        /// Questions ("…?") and multi-word queries.
        func results(for query: String, ctx: ExtensionContext) -> [ResultItem] {
            let wordCount = query.split(separator: " ").count
            guard query.hasSuffix("?") || wordCount >= 3 else { return [] }
            let searchTerms = query.hasSuffix("?") ? String(query.dropLast()) : query
            guard let url = searchURL(for: searchTerms, template: ctx.config.searchURL) else { return [] }
            return [ResultItem(id: "web-\(query)",
                               title: "Search for: \(searchTerms)",
                               subtitle: "Web Search",
                               icon: .symbol("magnifyingglass"),
                               action: .openURL(url))]
        }

        private func searchURL(for terms: String, template: String) -> URL? {
            let encoded = terms.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
                .replacingOccurrences(of: " ", with: "+") ?? terms
            return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
        }
    }
}
