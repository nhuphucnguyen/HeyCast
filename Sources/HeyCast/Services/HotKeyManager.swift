import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut like "ALT+SPACE" or "SUPER+SHIFT+C" parsed into
/// Carbon modifier flags + a virtual keycode, mirroring RustCast's syntax
/// (SUPER == Command on macOS). The pretty modifier symbols (⌘⌥⌃⇧) are
/// accepted too, so "⌥Space" parses the same as "ALT+SPACE".
struct Shortcut {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags
    var hasMods: Bool

    init?(string: String) {
        var mods: NSEvent.ModifierFlags = []
        var hasMods = false
        var keyName: String?

        for rawToken in Shortcut.normalize(string).split(separator: "+") {
            let token = rawToken.trimmingCharacters(in: .whitespaces).lowercased()
            switch token {
            case "cmd", "command", "super": mods.insert(.command); hasMods = true
            case "opt", "option", "alt": mods.insert(.option); hasMods = true
            case "ctrl", "control": mods.insert(.control); hasMods = true
            case "shift": mods.insert(.shift); hasMods = true
            default:
                if keyName == nil { keyName = token } else { return nil }
            }
        }
        guard let name = keyName, let code = Shortcut.keyCode(for: name) else { return nil }
        // A bare letter/digit/space would be swallowed system-wide, and the
        // fn/globe key has no Carbon hotkey representation at all — only
        // F-keys may stand without modifiers.
        guard hasMods || Shortcut.isFunctionKey(code) else { return nil }
        keyCode = code
        modifiers = mods
        self.hasMods = hasMods
    }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.hasMods = !modifiers.isEmpty
    }

    var displayString: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        out += Shortcut.keyName(for: keyCode) ?? "?"
        return out
    }

    /// The config-file spelling, e.g. "CTRL+ALT+T" — the round trip through
    /// `init?(string:)` is guaranteed for shortcuts built from real events.
    var canonicalString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("CTRL") }
        if modifiers.contains(.option) { parts.append("ALT") }
        if modifiers.contains(.shift) { parts.append("SHIFT") }
        if modifiers.contains(.command) { parts.append("SUPER") }
        if let name = Shortcut.keyName(for: keyCode) { parts.append(name.uppercased()) }
        return parts.joined(separator: "+")
    }

    /// Expands pretty modifier glyphs so "⌥⌘K" becomes "alt+super+K" before
    /// the +/-split — users naturally type the symbols the UI shows.
    private static func normalize(_ string: String) -> String {
        var out = string
        for (symbol, word) in [("⌘", "super+"), ("⌥", "alt+"), ("⌃", "ctrl+"), ("⇧", "shift+")] {
            out = out.replacingOccurrences(of: symbol, with: word)
        }
        return out
    }

    /// nil = fine (empty means "hotkey disabled on purpose"); otherwise a
    /// short explanation for the settings UI / config log.
    static func validationMessage(for string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        var modifierCount = 0
        var usesFn = false
        var keys: [String] = []
        for rawToken in normalize(trimmed).split(separator: "+") {
            let token = rawToken.trimmingCharacters(in: .whitespaces).lowercased()
            switch token {
            case "cmd", "command", "super", "opt", "option", "alt", "ctrl", "control", "shift":
                modifierCount += 1
            case "fn", "function":
                usesFn = true
            default:
                keys.append(token)
            }
        }
        if usesFn { return "The fn/globe (🌐) key can't be part of a global hotkey." }
        if keys.count > 1 { return "Use exactly one non-modifier key, e.g. ALT+SPACE." }
        guard let key = keys.first else {
            return "Add the key itself — modifiers alone can't be a shortcut."
        }
        guard let code = keyCode(for: key) else {
            return "Unknown key “\(key)”. Write ALT+SPACE style (or ⌥Space); F1–F12, SPACE, TAB, … are understood."
        }
        if modifierCount == 0 && !isFunctionKey(code) {
            return "Add at least one modifier (CTRL, ALT, SHIFT or SUPER) — a bare key would be captured everywhere."
        }
        return nil
    }

    // MARK: key code mapping

    private static let letters: [String: UInt32] = [
        "a": UInt32(kVK_ANSI_A), "b": UInt32(kVK_ANSI_B), "c": UInt32(kVK_ANSI_C), "d": UInt32(kVK_ANSI_D),
        "e": UInt32(kVK_ANSI_E), "f": UInt32(kVK_ANSI_F), "g": UInt32(kVK_ANSI_G), "h": UInt32(kVK_ANSI_H),
        "i": UInt32(kVK_ANSI_I), "j": UInt32(kVK_ANSI_J), "k": UInt32(kVK_ANSI_K), "l": UInt32(kVK_ANSI_L),
        "m": UInt32(kVK_ANSI_M), "n": UInt32(kVK_ANSI_N), "o": UInt32(kVK_ANSI_O), "p": UInt32(kVK_ANSI_P),
        "q": UInt32(kVK_ANSI_Q), "r": UInt32(kVK_ANSI_R), "s": UInt32(kVK_ANSI_S), "t": UInt32(kVK_ANSI_T),
        "u": UInt32(kVK_ANSI_U), "v": UInt32(kVK_ANSI_V), "w": UInt32(kVK_ANSI_W), "x": UInt32(kVK_ANSI_X),
        "y": UInt32(kVK_ANSI_Y), "z": UInt32(kVK_ANSI_Z),
    ]
    private static let digits: [String: UInt32] = [
        "0": UInt32(kVK_ANSI_0), "1": UInt32(kVK_ANSI_1), "2": UInt32(kVK_ANSI_2), "3": UInt32(kVK_ANSI_3),
        "4": UInt32(kVK_ANSI_4), "5": UInt32(kVK_ANSI_5), "6": UInt32(kVK_ANSI_6), "7": UInt32(kVK_ANSI_7),
        "8": UInt32(kVK_ANSI_8), "9": UInt32(kVK_ANSI_9),
    ]
    private static let named: [String: UInt32] = [
        "space": UInt32(kVK_Space),
        "return": UInt32(kVK_Return), "enter": UInt32(kVK_Return),
        "escape": UInt32(kVK_Escape), "esc": UInt32(kVK_Escape),
        "tab": UInt32(kVK_Tab),
        "delete": UInt32(kVK_Delete), "backspace": UInt32(kVK_Delete),
        "up": UInt32(kVK_UpArrow), "down": UInt32(kVK_DownArrow), "left": UInt32(kVK_LeftArrow), "right": UInt32(kVK_RightArrow),
        "f1": UInt32(kVK_F1), "f2": UInt32(kVK_F2), "f3": UInt32(kVK_F3), "f4": UInt32(kVK_F4), "f5": UInt32(kVK_F5),
        "f6": UInt32(kVK_F6), "f7": UInt32(kVK_F7), "f8": UInt32(kVK_F8), "f9": UInt32(kVK_F9), "f10": UInt32(kVK_F10),
        "f11": UInt32(kVK_F11), "f12": UInt32(kVK_F12),
        "home": UInt32(kVK_Home), "end": UInt32(kVK_End), "pageup": UInt32(kVK_PageUp), "pagedown": UInt32(kVK_PageDown),
        "-": UInt32(kVK_ANSI_Minus), "=": UInt32(kVK_ANSI_Equal), "[": UInt32(kVK_ANSI_LeftBracket),
        "]": UInt32(kVK_ANSI_RightBracket), ";": UInt32(kVK_ANSI_Semicolon), "'": UInt32(kVK_ANSI_Quote),
        ",": UInt32(kVK_ANSI_Comma), ".": UInt32(kVK_ANSI_Period), "/": UInt32(kVK_ANSI_Slash),
        "\\": UInt32(kVK_ANSI_Backslash), "`": UInt32(kVK_ANSI_Grave),
    ]

    static func keyCode(for name: String) -> UInt32? {
        if let c = letters[name] { return c }
        if let d = digits[name] { return d }
        return named[name]
    }

    private static let functionKeyCodes: Set<UInt32> = [
        UInt32(kVK_F1), UInt32(kVK_F2), UInt32(kVK_F3), UInt32(kVK_F4), UInt32(kVK_F5), UInt32(kVK_F6),
        UInt32(kVK_F7), UInt32(kVK_F8), UInt32(kVK_F9), UInt32(kVK_F10), UInt32(kVK_F11), UInt32(kVK_F12),
    ]

    static func isFunctionKey(_ code: UInt32) -> Bool {
        functionKeyCodes.contains(code)
    }

    static func keyName(for code: UInt32) -> String? {
        if let entry = (letters.first { $0.value == code }) { return entry.key.uppercased() }
        if let entry = (digits.first { $0.value == code }) { return entry.key }
        if let entry = (named.first { $0.value == code }) {
            let display = ["space": "Space", "return": "↩", "enter": "↩", "escape": "⎋", "esc": "⎋",
                           "tab": "⇥", "delete": "⌫", "backspace": "⌫"]
            return display[entry.key] ?? entry.key.capitalized
        }
        return nil
    }
}

extension Shortcut: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    static func == (lhs: Shortcut, rhs: Shortcut) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
    }
}

/// Registers global hotkeys with Carbon's RegisterEventHotKey. Carbon hotkeys
/// are consumed system-wide before the foreground app sees them and require no
/// special permissions, unlike an event tap.
final class HotKeyManager {
    static let shared = HotKeyManager()

    struct Registration {
        let shortcut: Shortcut
        let id: UInt32
        var hotKeyRef: EventHotKeyRef?
    }

    struct RegistrationFailure {
        let shortcut: Shortcut
        let status: OSStatus
    }

    private var registrations: [Registration] = []
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerUPP?
    private var installed = false
    var onHotKey: ((Shortcut) -> Void)?

    /// Swaps the active hotkey set. Shortcuts already registered stay
    /// registered (re-registering a combo this process holds fails with
    /// eventHotKeyExistsErr, so any unrelated config change would otherwise
    /// drop every hotkey); removed ones are released before new ones are
    /// added. Each new shortcut registers independently: a combo another
    /// process refuses to release only drops that one hotkey — the rest
    /// (crucially the toggle) still go live, and every failure is reported
    /// back.
    @discardableResult
    func update(shortcuts: [Shortcut]) -> [RegistrationFailure] {
        installHandlerIfNeeded()
        let wanted = Set(shortcuts)
        for reg in registrations where !wanted.contains(reg.shortcut) {
            if let ref = reg.hotKeyRef {
                UnregisterEventHotKey(ref)
            }
        }
        var kept = registrations.filter { wanted.contains($0.shortcut) }
        var seen = Set(kept.map(\.shortcut))
        var failures: [RegistrationFailure] = []
        for shortcut in shortcuts where !seen.contains(shortcut) {
            seen.insert(shortcut)
            let id = nextID
            nextID += 1
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x48455943) /* HEYC */, id: id)
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers.carbonFlags,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            guard status == noErr, let ref else {
                NSLog("HeyCast: failed to register hotkey %@ (%d)", shortcut.displayString, status)
                failures.append(RegistrationFailure(shortcut: shortcut, status: status))
                continue
            }
            kept.append(Registration(shortcut: shortcut, id: id, hotKeyRef: ref))
        }
        registrations = kept
        NSLog("HeyCast: active hotkeys — %@", kept.map(\.shortcut.displayString).joined(separator: ", "))
        return failures
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard err == noErr else { return noErr }
            DispatchQueue.main.async {
                HotKeyManager.shared.dispatch(id: hotKeyID.id)
            }
            return noErr
        }
        eventHandler = callback
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, nil)
    }

    private func dispatch(id: UInt32) {
        guard let reg = registrations.first(where: { $0.id == id }) else { return }
        onHotKey?(reg.shortcut)
    }
}

extension NSEvent.ModifierFlags {
    var carbonFlags: UInt32 {
        var flags: UInt32 = 0
        if contains(.command) { flags |= UInt32(cmdKey) }
        if contains(.option) { flags |= UInt32(optionKey) }
        if contains(.control) { flags |= UInt32(controlKey) }
        if contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }
}
