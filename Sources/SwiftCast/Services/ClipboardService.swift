import AppKit

/// Watches the system pasteboard and reports new clipboard content.
/// Polls `changeCount` (like RustCast's 100 ms arboard loop) and classifies
/// content as image, URL or text.
final class ClipboardService {
    enum Content: Equatable {
        case text(String)
        case url(String)
        case image(Data)
    }

    struct Capture: Equatable {
        var content: Content
    }

    var onCapture: ((Capture) -> Void)?

    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastContent: Content?

    init() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start(interval: TimeInterval = 0.1) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        let content = classify(pasteboard: pb)
        guard let content, content != lastContent else { return }
        lastContent = content
        onCapture?(Capture(content: content))
    }

    private func classify(pasteboard: NSPasteboard) -> Content? {
        // Images first (screenshots etc.)
        if let png = pasteboard.data(forType: .png) {
            return .image(png)
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiff),
           let tiff2 = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff2),
           let png = rep.representation(using: .png, properties: [:]) {
            return .image(png)
        }
        guard let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let url = URL(string: text), url.host != nil || (url.scheme != nil && text.contains(".")) {
            return .url(text)
        }
        return .text(text)
    }

    /// Write an entry back to the system clipboard.
    static func copy(entry: ClipboardEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch entry.kind {
        case .image:
            if let data = entry.imageData {
                pb.setData(data, forType: .png)
            }
        case .url, .text:
            pb.setString(entry.text ?? "", forType: .string)
        }
    }

    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Posts a synthetic Cmd+V to the previously-frontmost app so selecting a
    /// clipboard entry pastes it in place (paste-on-select).
    static func simulatePaste(toPid pid: pid_t) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9 /* V */, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }
}
