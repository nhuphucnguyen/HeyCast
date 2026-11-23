import AppKit
import ApplicationServices
import NotesCore

/// Parses capture text typed in the launcher and records where it came from.
enum NoteCapture {
    struct Parsed: Equatable {
        var kind: NoteItem.Kind
        var text: String  // after the prefix, trimmed
    }

    /// Matches the configured prefixes. Longer prefixes win so "w " is not
    /// shadowed by a shorter one. The note prefix additionally matches in its
    /// bare form — "/note" with nothing typed after — so it claims the search
    /// and ↵ can open the Notes view instead of falling through to a
    /// trigger suggestion.
    static func parse(_ query: String, config: Config) -> Parsed? {
        let prefixes: [(String, NoteItem.Kind)] = [
            (config.notesInboxPrefix, .inbox),
            (config.notesWordPrefix, .word),
            (config.notesNotePrefix, .note),
        ]
        .filter { !$0.0.isEmpty }
        .sorted { $0.0.count > $1.0.count }
        let lowered = query.lowercased()
        for (prefix, kind) in prefixes where lowered.hasPrefix(prefix.lowercased()) {
            let text = String(query.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return Parsed(kind: kind, text: text)
        }
        // Bare note prefix ("/note", no trailing space and nothing after).
        if let notePrefix = prefixes.first(where: { $0.1 == .note })?.0.trimmingCharacters(in: .whitespaces),
           !notePrefix.isEmpty, lowered == notePrefix.lowercased() {
            return Parsed(kind: .note, text: "")
        }
        return nil
    }

    /// "serendipity — it was pure serendipity" → word + example sentence.
    static func splitWord(_ text: String) -> (word: String, example: String?) {
        for separator in [" — ", " -- ", " | ", " - "] {
            if let range = text.range(of: separator) {
                let word = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let example = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
                return (word, example.isEmpty ? nil : example)
            }
        }
        return (text, nil)
    }

    /// App and focused window title, read synchronously (cheap). The window
    /// title needs Accessibility, which HeyCast already uses for pasting.
    static func immediateContext(for app: NSRunningApplication?) -> NoteContext {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return NoteContext() }
        var context = NoteContext(appName: app.localizedName, bundleID: app.bundleIdentifier)
        if AXIsProcessTrusted() {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window {
                var title: CFTypeRef?
                // swiftlint:disable:next force_cast
                if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
                   let title = title as? String, !title.isEmpty {
                    context.windowTitle = title
                }
            }
        }
        return context
    }

    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// The front tab's URL for known browsers, via osascript off the main
    /// thread (the first use triggers macOS's Automation permission prompt).
    static func fetchBrowserURL(bundleID: String?, completion: @escaping @MainActor (String?) -> Void) {
        guard let bundleID else { return }
        let script: String
        if bundleID == "com.apple.Safari" || bundleID == "com.apple.SafariTechnologyPreview" {
            script = "tell application id \"\(bundleID)\" to return URL of front document"
        } else if chromiumBrowsers.contains(bundleID) {
            script = "tell application id \"\(bundleID)\" to return URL of active tab of front window"
        } else {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var url: String?
            if (try? process.run()) != nil {
                let deadline = Date().addingTimeInterval(3)
                while process.isRunning && Date() < deadline { usleep(20_000) }
                if process.isRunning { process.terminate() }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.hasPrefix("http") { url = text }
            }
            Task { @MainActor in completion(url) }
        }
    }
}
