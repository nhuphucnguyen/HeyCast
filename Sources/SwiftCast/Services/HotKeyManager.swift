import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut like "ALT+SPACE" or "SUPER+SHIFT+C" parsed into
/// Carbon modifier flags + a virtual keycode, mirroring RustCast's syntax
/// (SUPER == Command on macOS).
struct Shortcut {
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags
    var hasMods: Bool

    init?(string: String) {
        var mods: NSEvent.ModifierFlags = []
        var hasMods = false
        var keyName: String?

        for rawToken in string.split(separator: "+") {
            let token = rawToken.trimmingCharacters(in: .whitespaces).lowercased()
            switch token {
            case "cmd", "command", "super": mods.insert(.command); hasMods = true
            case "opt", "option", "alt": mods.insert(.option); hasMods = true
            case "ctrl", "control": mods.insert(.control); hasMods = true
            case "shift": mods.insert(.shift); hasMods = true
            case "fn", "function": mods.insert(.function); hasMods = true
            default:
                if keyName == nil { keyName = token } else { return nil }
            }
        }
        guard let name = keyName, let code = Shortcut.keyCode(for: name) else { return nil }
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

    private var registrations: [Registration] = []
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerUPP?
    private var installed = false
    var onHotKey: ((Shortcut) -> Void)?

    func update(shortcuts: [Shortcut]) {
        unregisterAll()
        for shortcut in shortcuts {
            register(shortcut)
        }
    }

    private func register(_ shortcut: Shortcut) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x53574353) /* SWCS */, id: id)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers.carbonFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr else {
            NSLog("SwiftCast: failed to register hotkey %@ (%d)", shortcut.displayString, status)
            return
        }
        registrations.append(Registration(shortcut: shortcut, id: id, hotKeyRef: ref))
    }

    private func unregisterAll() {
        for reg in registrations {
            if let ref = reg.hotKeyRef {
                UnregisterEventHotKey(ref)
            }
        }
        registrations.removeAll()
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
