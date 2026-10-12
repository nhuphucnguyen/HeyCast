import AppKit

/// Finds an app's leftover files (preferences, caches, containers, launch
/// agents, receipts…) and moves them to the Trash.
///
/// The search mirrors Raycast's uninstaller: list the top level of a fixed
/// set of Library folders and keep the entries whose name ties back to the
/// app's name or bundle identifier. No recursive crawling — leftovers live
/// at the top of these folders by convention, and a shallow scan keeps false
/// positives (and scan time) low.
enum AppUninstaller {
    struct Item: Identifiable, Equatable {
        var id: String { path }
        let path: String
        let name: String
        /// Allocated size in bytes; nil until measured (or unreadable).
        var size: Int64?
        var isSelected = true
    }

    struct Target {
        let appPath: String
        let name: String
        let bundleID: String?
        /// Names a leftover folder may carry (bundle name, display name,
        /// filename stem — deduplicated).
        let names: [String]

        init?(appPath: String) {
            let url = URL(fileURLWithPath: appPath)
            guard FileManager.default.fileExists(atPath: appPath) else { return nil }
            let bundle = Bundle(url: url)
            let stem = url.deletingPathExtension().lastPathComponent
            let candidates = [
                bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                stem,
            ]
            var seen = Set<String>()
            names = candidates.compactMap { $0?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            self.appPath = appPath
            self.name = stem
            self.bundleID = bundle?.bundleIdentifier
        }
    }

    enum UninstallError: LocalizedError {
        case protectedApp(String)
        case stillRunning(String)

        var errorDescription: String? {
            switch self {
            case .protectedApp(let name):
                return name == "HeyCast"
                    ? "HeyCast can't uninstall itself. Quit it, then drag it to the Trash."
                    : "\(name) is part of macOS and can't be uninstalled."
            case .stillRunning(let name): return "\(name) didn't quit. Quit it manually, then try again."
            }
        }
    }

    // MARK: search locations

    private static let userLibraryFolders = [
        "Application Scripts", "Application Support", "Caches", "Containers",
        "Cookies", "Group Containers", "HTTPStorages", "LaunchAgents", "Logs",
        "Mobile Documents", "Preferences", "Preferences/ByHost",
        "Saved Application State", "Services", "WebKit",
    ]

    private static let systemLibraryFolders = [
        "Apple/System/Library/Receipts", "Application Support", "Caches",
        "Extensions", "Frameworks", "Internet Plug-Ins", "LaunchAgents",
        "LaunchDaemons", "Logs", "Logs/DiagnosticReports", "PreferencePanes",
        "Preferences", "PrivilegedHelperTools", "Receipts", "StartupItems",
    ]

    private static let otherFolders = ["/usr/local/bin", "/usr/local/share", "/var/db/receipts"]

    static var searchFolders: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return userLibraryFolders.map { "\(home)/Library/\($0)" }
            + systemLibraryFolders.map { "/Library/\($0)" }
            + otherFolders
    }

    /// Apps that must never be offered for removal: anything SIP-protected
    /// under /System, Apple's preinstalled apps, and HeyCast itself.
    static func isProtected(_ target: Target) -> Bool {
        if target.appPath.hasPrefix("/System/") { return true }
        if target.appPath == Bundle.main.bundlePath { return true }
        if let id = target.bundleID?.lowercased() {
            if id == Bundle.main.bundleIdentifier?.lowercased() { return true }
            if id.hasPrefix("com.apple."), !target.appPath.hasPrefix("/Applications/") { return true }
        }
        return false
    }

    // MARK: discovery

    /// The app bundle followed by every matching leftover, sorted by path.
    /// Blocking — call off the main thread.
    static func findFiles(for target: Target) -> [Item] {
        let fm = FileManager.default
        var paths = Set<String>()
        for folder in searchFolders {
            guard let entries = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for entry in entries where matches(entry: entry, target: target) {
                let path = folder + "/" + entry
                // Never offer the folder that holds the app itself, or a
                // folder that contains it (e.g. a vendor folder).
                if target.appPath.hasPrefix(path + "/") { continue }
                paths.insert(path)
            }
        }
        paths.remove(target.appPath)
        let leftovers = paths.sorted().map { Item(path: $0, name: ($0 as NSString).lastPathComponent) }
        return [Item(path: target.appPath, name: (target.appPath as NSString).lastPathComponent)] + leftovers
    }

    /// Does a directory entry belong to the app? All comparisons ignore case.
    ///  1. the entry is named after the app ("Application Support/Slack")
    ///  2. the entry is the bundle id, or starts with "<bundle id>." or
    ///     "<bundle id>-" — after dropping a "group." or Team ID prefix
    ///     (com.foo.app.plist, group.com.foo.app, ABCDE12345.com.foo.app)
    ///  3. a plist whose name contains ".<app name>." (com.vendor.App.plist)
    static func matches(entry: String, target: Target) -> Bool {
        let lower = entry.lowercased()
        if target.names.contains(where: { $0.lowercased() == lower }) { return true }

        if let id = target.bundleID?.lowercased(), !id.isEmpty {
            let stripped = stripContainerPrefix(lower)
            if stripped == id || stripped.hasPrefix(id + ".") || stripped.hasPrefix(id + "-") {
                return true
            }
        }

        if lower.hasSuffix("plist") {
            for name in target.names where lower.contains("." + name.lowercased() + ".") {
                return true
            }
        }
        return false
    }

    /// Drops "group." and a 10-character Team ID prefix ("ABCDE12345.").
    private static func stripContainerPrefix(_ name: String) -> String {
        var s = Substring(name)
        if s.hasPrefix("group.") { s = s.dropFirst("group.".count) }
        let parts = s.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].count == 10,
           parts[0].allSatisfy({ $0.isNumber || ("a"..."z").contains($0) }),
           parts[0].contains(where: \.isNumber) {
            s = parts[1]
        }
        return String(s)
    }

    // MARK: sizes

    /// Total allocated size of a file or directory tree. Blocking.
    static func size(of path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        guard values.isDirectory == true else {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                        options: [], errorHandler: { _, _ in true })
        while let child = enumerator?.nextObject() as? URL {
            let v = try? child.resourceValues(forKeys: keys)
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: running app

    static func runningInstances(of target: Target) -> [NSRunningApplication] {
        let appURL = URL(fileURLWithPath: target.appPath).standardizedFileURL
        return NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL == appURL
                || (target.bundleID != nil && $0.bundleIdentifier == target.bundleID)
        }
    }

    /// Asks the app to quit (it may show a save prompt) and waits up to
    /// `timeout` seconds. Returns true once no instance is left.
    static func quit(_ target: Target, timeout: TimeInterval = 10) async -> Bool {
        let running = runningInstances(of: target)
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if running.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return running.allSatisfy(\.isTerminated)
    }

    // MARK: trash

    /// Moves the paths to the Trash. Items the user can't move (root-owned
    /// files in /Library, /usr/local) go through Finder, which asks for an
    /// administrator password and keeps "Put Back" working. Returns the paths
    /// that could not be removed. Blocking — call off the main thread.
    static func moveToTrash(_ paths: [String]) -> [String] {
        let fm = FileManager.default
        var needsFinder: [String] = []
        for path in paths where fm.fileExists(atPath: path) {
            do {
                try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            } catch {
                needsFinder.append(path)
            }
        }
        guard !needsFinder.isEmpty else { return [] }
        trashWithFinder(needsFinder)
        return needsFinder.filter { fm.fileExists(atPath: $0) }
    }

    /// `tell application "Finder" to move {…} to trash`, with the paths
    /// passed as arguments so nothing needs escaping.
    private static func trashWithFinder(_ paths: [String]) {
        let script = """
        on run argv
            set theFiles to {}
            repeat with p in argv
                set end of theFiles to (POSIX file (p as text)) as alias
            end repeat
            tell application "Finder" to move theFiles to trash
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + paths
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                NSLog("%@", "HeyCast: Finder trash failed (\(process.terminationStatus)): \(message)")
            }
        } catch {
            NSLog("%@", "HeyCast: couldn't run osascript: \(error.localizedDescription)")
        }
    }
}
