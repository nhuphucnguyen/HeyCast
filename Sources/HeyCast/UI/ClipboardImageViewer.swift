import AppKit
import SwiftUI

/// Quick Look-style full-size preview for clipboard screenshots. A borderless
/// NON-KEY child panel of the launcher panel: it never takes key status
/// (arrow keys / hover keep driving the list and the viewer mirrors the
/// selection live), it moves with the panel and hides with it.
@MainActor
final class ClipboardImageViewerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

@MainActor
final class ClipboardImageViewerController {
    private var panel: ClipboardImageViewerPanel?
    private weak var parentPanel: NSPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Opens the viewer for the selected clipboard image, or closes it when
    /// already open (clicking the preview or the magnifier button toggles).
    func toggle(model: LauncherModel, parent: NSPanel) {
        if isVisible {
            close(reason: "toggle")
        } else {
            open(model: model, parent: parent)
        }
    }

    private func open(model: LauncherModel, parent: NSPanel) {
        // Decode here only to reject broken image data before showing the
        // window; the view decodes the entry itself for rendering.
        guard let entry = model.selectedClipboardEntry,
              entry.kind == .image,
              let data = entry.imageData,
              NSImage(data: data) != nil else { return }

        let screenFrame = parent.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = NSSize(width: screenFrame.width * 0.85, height: screenFrame.height * 0.85)
        let frame = NSRect(x: screenFrame.midX - size.width / 2,
                           y: screenFrame.midY - size.height / 2,
                           width: size.width, height: size.height)

        let panel = ClipboardImageViewerPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = parent.level
        panel.contentView = NSHostingView(
            rootView: ClipboardImageViewerView(model: model, viewport: size,
                                               onClose: { [weak self] in self?.close(reason: "view") })
        )
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.panel = panel
        self.parentPanel = parent
        NSLog("%@", "HeyCast: image viewer shown (frame: \(panel.frame), number: \(panel.windowNumber), visible: \(panel.isVisible))")
    }

    func close(reason: String = "unspecified") {
        guard let panel else { return }
        NSLog("%@", "HeyCast: image viewer close (\(reason))")
        parentPanel?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }
}

/// Zoomable, scrollable image surface. The image starts fitted to the
/// viewport; pinch (or scroll-zoom) enlarges it up to 8×, after which the
/// scroll view pans. Click anywhere dismisses.
private struct ClipboardImageViewerView: View {
    @ObservedObject var model: LauncherModel
    let viewport: NSSize
    let onClose: () -> Void

    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        Group {
            if let image = currentImage {
                content(image: image)
            } else {
                // Selection is on a non-image entry (arrow keys / hover keep
                // moving it). Stay open on a placeholder — closing here would
                // make the viewer flap shut whenever a background clipboard
                // capture re-sorts the list under the selection.
                Text("Select an image entry")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { onClose() }
            }
        }
    }

    private var currentImage: NSImage? {
        // Deliberately pure: the first body evaluation happens while the
        // hosting view initializes, where @State writes are rejected — a
        // decode cache kept in @State silently returned nil there and the
        // window showed (or closed!) instead of showing the image.
        guard let entry = model.selectedClipboardEntry, entry.kind == .image,
              let data = entry.imageData else { return nil }
        return NSImage(data: data)
    }

    private func content(image: NSImage) -> some View {
        let scale = max(1, min(8, zoom * pinch))
        return ScrollView([.horizontal, .vertical]) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: viewport.width * scale, height: viewport.height * scale)
                .frame(minWidth: viewport.width, minHeight: viewport.height)
        }
        .background(Color.black.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottom) {
            Text("Esc or click to close · pinch to zoom, up to 8×")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.bottom, 10)
        }
        .onTapGesture { onClose() }
        .gesture(
            MagnificationGesture()
                .onEnded { value in
                    zoom = max(1, min(8, zoom * value))
                }
        )
        .onExitCommand { onClose() }
    }
}
