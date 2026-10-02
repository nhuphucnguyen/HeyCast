import AppKit

/// Discovers installed applications by scanning the standard app
/// directories and provides icon caching. Cheap enough (~10ms warm) to rerun
/// every time the panel opens, so newly installed apps show up without a
/// manual reload.
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

    /// Rescans on a background queue. `completion` runs on the main queue,
    /// and only when the app list actually changed — an unchanged rescan
    /// leaves `apps` alone so results the user is typing into don't refresh.
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
            let sorted = entries.sorted { $0.name < $1.name }
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = sorted.map(\.path) != self.apps.map(\.path)
                    || sorted.map(\.name) != self.apps.map(\.name)
                guard changed else { return }
                self.apps = sorted
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

    /// Apps directly in the standard app directories, plus one folder level
    /// down (/Applications/Utilities, vendor folders like
    /// /Applications/Bitdefender). Reads the filesystem directly rather than
    /// LaunchServices or Spotlight, which can lag behind a fresh install.
    static func discoverApps() -> [String] {
        let fm = FileManager.default
        var paths = Set<String>()
        let scanRoots = ["/Applications", "/System/Applications",
                         NSString(string: "~/Applications").expandingTildeInPath]
        for root in scanRoots {
            for item in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let path = root + "/" + item
                if item.hasSuffix(".app") {
                    paths.insert(path)
                    continue
                }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                for sub in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where sub.hasSuffix(".app") {
                    paths.insert(path + "/" + sub)
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
