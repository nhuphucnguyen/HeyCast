import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Raycast-style shortcut capture field for the settings window: click it,
/// press the combo, done — no Return needed, no syntax to remember. Esc
/// cancels, ⌫ clears the hotkey (empty string = disabled), clicking outside
/// the field cancels. The binding holds the canonical config spelling
/// ("ALT+SPACE"); capture persists immediately via `onChange`.
///
/// Capture runs through local event monitors rather than first-responder
/// keyDown — inside a SwiftUI Form there is no reliable way to keep an
/// embedded AppKit field key, and monitors see every keypress in the app
/// (before menu shortcuts) regardless of focus. The button only ever *arms*:
/// cancel/disarm decisions belong to the monitors, so a canceling click can
/// never be followed by an accidental re-arm from the same click's tap event.
struct HotkeyRecorder: View {
    @Binding var value: String
    var onChange: () -> Void

    @State private var recording = false
    @State private var preview = ""
    @State private var keyMonitor: Any?
    @State private var flagsMonitor: Any?
    @State private var clickMonitor: Any?
    @State private var recorderID = UUID()

    var body: some View {
        Button {
            if !recording { arm() }
        } label: {
            field
        }
        .buttonStyle(.plain)
        .background(RecorderMarker(recorderID: recorderID))
        .onDisappear { disarm() }
        .help("Click, then press the shortcut. Esc cancels, ⌫ clears.")
    }

    // MARK: display

    private var displayText: String {
        if recording { return preview.isEmpty ? "Press keys…" : preview }
        return trimmedValue.flatMap { Shortcut(string: $0)?.displayString }
            ?? (trimmedValue == nil ? "None" : "\(trimmedValue!) — invalid")
    }

    private var trimmedValue: String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var field: some View {
        Text(displayText)
            .font(.system(size: 13, weight: .medium).monospaced())
            .lineLimit(1)
            .truncationMode(.head)
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(recording
                          ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
                          : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(recording ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: recording ? 2 : 1)
            )
    }

    private var textColor: Color {
        if recording { return .primary }
        if trimmedValue == nil { return .secondary }
        return Shortcut(string: trimmedValue!) != nil ? .primary : .red
    }

    // MARK: recording

    private func arm() {
        recording = true
        preview = ""
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKey(event)
            return nil   // recording owns the keyboard — menu shortcuts included
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            updatePreview(event.modifierFlags)
            return event
        }
        // Clicking outside the field means "never mind". Clicks on the field
        // itself are left alone (the button action no-ops while recording) so
        // one physical click can never cancel and then re-arm.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if !RecorderMarkers.isInsideRecorder(event, id: recorderID) {
                disarm()
            }
            return event
        }
    }

    private func disarm() {
        recording = false
        preview = ""
        for monitor in [keyMonitor, flagsMonitor, clickMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        keyMonitor = nil
        flagsMonitor = nil
        clickMonitor = nil
    }

    private func updatePreview(_ rawFlags: NSEvent.ModifierFlags) {
        let mods = rawFlags.intersection([.command, .option, .control, .shift])
        var out = ""
        if mods.contains(.control) { out += "⌃" }
        if mods.contains(.option) { out += "⌥" }
        if mods.contains(.shift) { out += "⇧" }
        if mods.contains(.command) { out += "⌘" }
        preview = out
    }

    private func handleKey(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            disarm()
            return
        case kVK_Delete:
            value = ""
            onChange()
            disarm()
            return
        default:
            break
        }
        let code = UInt32(event.keyCode)
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard Shortcut.keyName(for: code) != nil else {
            preview = "That key can’t be used"
            return
        }
        guard !mods.isEmpty || Shortcut.isFunctionKey(code) else {
            preview = "Add ⌘ ⌥ ⌃ or ⇧…"
            return
        }
        value = Shortcut(keyCode: code, modifiers: mods).canonicalString
        onChange()
        disarm()
    }
}

/// A marker view planted behind each recorder field so the outside-click
/// monitor can tell whether a click landed on *this* field — by frame
/// containment in window coordinates, since SwiftUI hosts siblings side by
/// side and the clicked view's responder chain never crosses into the marker.
private struct RecorderMarker: NSViewRepresentable {
    let recorderID: UUID

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        RecorderMarkers.register(view, id: recorderID)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        RecorderMarkers.register(view, id: recorderID)
    }

    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        RecorderMarkers.unregister(view)
    }
}

private enum RecorderMarkers {
    private struct Entry {
        weak var view: NSView?
        let id: UUID
    }

    private static var entries: [Entry] = []

    static func register(_ view: NSView, id: UUID) {
        entries.removeAll { $0.view === view || $0.view == nil }
        entries.append(Entry(view: view, id: id))
    }

    static func unregister(_ view: NSView) {
        entries.removeAll { $0.view === view || $0.view == nil }
    }

    static func isInsideRecorder(_ event: NSEvent, id: UUID) -> Bool {
        entries.removeAll { $0.view == nil }
        for entry in entries where entry.id == id {
            guard let view = entry.view, view.window === event.window else { continue }
            let frameInWindow = view.convert(view.bounds, to: nil)
            if frameInWindow.contains(event.locationInWindow) { return true }
        }
        return false
    }
}
