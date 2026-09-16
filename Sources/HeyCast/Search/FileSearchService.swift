import AppKit
import CoreServices

/// Live Spotlight file search via NSMetadataQuery (replaces RustCast's
/// mdfind subprocess). Results stream in batches as Spotlight finds them.
final class FileSearchService: NSObject, NSMetadataQueryDelegate {
    static let maxResults = 400

    private var query: NSMetadataQuery?
    var onUpdate: (() -> Void)?
    var results: [FileHit] = []
    private var targetQuery = ""

    struct FileHit {
        let name: String
        let path: String
    }

    func search(_ text: String, searchDirs: [String]) {
        cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            results = []
            onUpdate?()
            return
        }
        targetQuery = q
        let mdQuery = NSMetadataQuery()
        let scopes = searchDirs.isEmpty
            ? [NSMetadataQueryLocalComputerScope]
            : searchDirs.map { ($0 as NSString).expandingTildeInPath }
        mdQuery.searchScopes = scopes
        NSLog("HeyCast: mdquery scopes: \(scopes)")
        // Escape quotes/wildcards for the LIKE pattern, then pass the whole
        // pattern as the predicate argument (embedding %@ inside quotes
        // breaks the pattern match).
        let escaped = q
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
        mdQuery.predicate = NSPredicate(
            format: "kMDItemDisplayName LIKE[c] %@",
            "*\(escaped)*"
        )
        mdQuery.delegate = self
        query = mdQuery

        NotificationCenter.default.addObserver(
            self, selector: #selector(queryUpdated),
            name: .NSMetadataQueryDidUpdate, object: mdQuery
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(queryFinished),
            name: .NSMetadataQueryDidFinishGathering, object: mdQuery
        )
        mdQuery.start()
    }

    func cancel() {
        if let query {
            query.stop()
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
        }
        query = nil
    }

    @objc private func queryUpdated() {
        collect()
    }

    @objc private func queryFinished() {
        collect()
    }

    private func collect() {
        guard let query else { return }
        query.disableUpdates()
        var hits: [FileHit] = []
        let count = min(query.resultCount, Self.maxResults)
        for i in 0..<count {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)
                ?? URL(fileURLWithPath: path).lastPathComponent
            guard !URL(fileURLWithPath: path).lastPathComponent.hasPrefix(".") else { continue }
            hits.append(FileHit(name: name, path: path))
        }
        query.enableUpdates()
        results = hits
        NSLog("HeyCast: file search collected \(hits.count) hits")
        onUpdate?()
    }

    static func displayPath(_ fullPath: String) -> String {
        let home = NSHomeDirectory()
        if fullPath.hasPrefix(home) {
            return "~" + fullPath.dropFirst(home.count)
        }
        return fullPath
    }
}
