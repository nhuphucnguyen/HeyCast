import AppKit
import UniformTypeIdentifiers

/// Discovers installed applications via LaunchServices and provides icon
/// caching. Uses the public NSWorkspace API first, with a filesystem scan of
/// the standard app directories as fallback.
final class AppIndex {
    struct Entry {
        let name: String
        let searchName: String
        let path: String
        let icon: NSImage
    }

    private(set) var apps: [Entry] = []
    private let iconCache = NSCache<NSString, NSImage>()

    var searchNames: [String] { apps.map(\.searchName) }

    func load(blacklist: [String], completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let discovered = Self.discoverApps()
            let blocked = Set(blacklist.map { $0.lowercased() })
            let entries: [Entry] = discovered.compactMap { path in
                guard let name = Self.displayName(forAppPath: path) else { return nil }
                let lower = name.lowercased()
                if blocked.contains(lower) { return nil }
                guard Self.shouldIncludeApp(path) else { return nil }
                return Entry(name: name, searchName: lower, path: path, icon: Self.icon(for: path))
            }
            entries.forEach { $0.icon.size = NSSize(width: 32, height: 32) }
            DispatchQueue.main.async {
                self?.apps = entries.sorted { $0.name < $1.name }
                completion?()
            }
        }
    }

    /// Returns matching entries with a score for the given query.
    func search(_ query: String) -> [(entry: Entry, score: Int)] {
        guard !query.isEmpty else { return [] }
        var out: [(Entry, Int)] = []
        for app in apps {
            if let s = FuzzyMatch.score(query, app.searchName) {
                out.append((app, s))
            }
        }
        out.sort { $0.1 > $1.1 }
        return out
    }

    func entry(named name: String) -> Entry? {
        apps.first { $0.searchName == name.lowercased() }
    }

    // MARK: discovery

    static func discoverApps() -> [String] {
        var paths = Set<String>()
        if let appType = UTType("com.apple.application-bundle") {
            for url in NSWorkspace.shared.urlsForApplications(toOpen: appType)
            where url.pathExtension == "app" {
                paths.insert(url.path)
            }
        }
        if paths.count < 10 {
            // Fallback: scan standard locations.
            let scanRoots = ["/Applications", "/System/Applications",
                             NSString(string: "~/Applications").expandingTildeInPath]
            for root in scanRoots {
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
                for item in contents where item.hasSuffix(".app") {
                    paths.insert(root + "/" + item)
                }
            }
        }
        return paths.sorted()
    }

    static func shouldIncludeApp(_ path: String) -> Bool {
        // Exclude nested bundles (helpers inside another .app).
        if path.dropLast(4).contains(".app/") { return false }
        let excluded = ["/Contents/Library/LoginItems/", "/Contents/XPCServices/",
                        "/Contents/Helpers/", "/Contents/Frameworks/",
                        "/Library/PrivilegedHelperTools/"]
        if excluded.contains(where: { path.contains($0) }) { return false }
        let bundle = Bundle(path: path)
        if bundle?.object(forInfoDictionaryKey: "LSBackgroundOnly") != nil { return false }
        let roots = ["/Applications/", "/System/Applications/",
                     NSString(string: "~/Applications").expandingTildeInPath + "/"]
        if roots.contains(where: { path.hasPrefix($0) }) { return true }
        return bundle?.object(forInfoDictionaryKey: "LSApplicationCategoryType") != nil
    }

    static func displayName(forAppPath path: String) -> String? {
        // Prefer the filename stem ("Safari" from Safari.app).
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        if !stem.isEmpty { return stem }
        return nil
    }

    static func icon(for path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }

    // MARK: running apps (for "quit …")

    static func runningAppNames() -> [(name: String, path: String?)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleURL != nil || $0.activationPolicy == .regular }
            .compactMap { app -> (String, String?)? in
                guard let name = app.localizedName else { return nil }
                return (name, app.bundleURL?.path)
            }
    }

    @discardableResult
    static func terminateApp(named name: String) -> Bool {
        let app = NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular && $0.localizedName?.lowercased() == name.lowercased()
        }
        guard let app else { return false }
        return app.terminate()
    }

    static func terminateAllApps() {
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.terminate()
        }
    }
}
