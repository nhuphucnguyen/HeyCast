import SwiftUI
import AppKit

/// Clipboard history page: filterable list on the left, live preview on the
/// right. Enter/click copies the entry back to the clipboard (and optionally
/// pastes it into the previously frontmost app).
struct ClipboardPageView: View {
    @ObservedObject var model: LauncherModel

    private var items: [ClipboardEntry] { model.filteredClipboardItems }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                if items.isEmpty {
                    Text("Copy something to use the clipboard history")
                        .font(.system(size: 13))
                        .foregroundStyle(model.theme.textColor.alpha(0.5))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                                    ClipboardRow(model: model, entry: entry, isSelected: index == model.selectedIndex)
                                        .id(entry.id)
                                        .onTapGesture {
                                            model.selectedIndex = index
                                            model.openFocused()
                                        }
                                }
                            }
                        }
                        .onChange(of: model.selectedIndex) { newIndex in
                            guard items.indices.contains(newIndex) else { return }
                            withAnimation(.easeOut(duration: 0.1)) {
                                proxy.scrollTo(items[newIndex].id, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(width: 210)

            Divider()
                .overlay(model.theme.textColor.alpha(0.15))

            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .frame(height: 330)
    }

    @ViewBuilder
    private var previewPane: some View {
        let selected = items.indices.contains(model.selectedIndex) ? items[model.selectedIndex] : nil
        VStack(alignment: .leading, spacing: 8) {
            if let selected {
                ScrollView {
                    Group {
                        switch selected.kind {
                        case .image:
                            if let data = selected.imageData, let image = NSImage(data: data) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Unreadable image")
                                    .foregroundStyle(model.theme.textColor.alpha(0.5))
                            }
                        case .text, .url:
                            Text(selected.text ?? "")
                                .font(.system(size: 14))
                                .foregroundStyle(model.theme.textColor)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                HStack {
                    if selected.kind == .url, let text = selected.text, let url = URL(string: text) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "safari")
                        }
                        .buttonStyle(.plain)
                        .help("Open URL")
                    }
                    Button {
                        model.toggleClipboardPin(selected)
                    } label: {
                        Image(systemName: selected.isPinned ? "pin.slash" : "pin")
                    }
                    .buttonStyle(.plain)
                    .help(selected.isPinned ? "Unpin entry (⌘P)" : "Pin entry to top (⌘P)")
                    Button {
                        model.deleteClipboardEntry(selected)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Delete entry")
                    Spacer()
                    Button("Clear") {
                        model.clearClipboard()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .help("Clear history (pinned entries are kept)")
                }
                Text(metaLine(for: selected))
                    .font(.system(size: 11))
                    .foregroundStyle(model.theme.textColor.alpha(0.5))
                    .lineLimit(1)
            } else {
                Spacer()
            }
        }
        .padding(.leading, 10)
    }

    /// "Copied from Safari · copied 3 times · 14:32" — parts are omitted
    /// when unknown (entries predating source tracking have neither).
    private func metaLine(for entry: ClipboardEntry) -> String {
        var parts: [String] = []
        if let name = entry.sourceName { parts.append("Copied from \(name)") }
        if entry.copies > 1 { parts.append("copied \(entry.copies) times") }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        parts.append(formatter.string(from: entry.createdAt))
        return parts.joined(separator: " · ")
    }
}

private struct ClipboardRow: View {
    @ObservedObject var model: LauncherModel
    let entry: ClipboardEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            rowIcon
                .frame(width: 16, height: 16)
            Text(entry.preview)
                .font(.system(size: 13))
                .foregroundStyle(model.theme.textColor)
                .lineLimit(1)
            Spacer(minLength: 0)
            if entry.copies > 1 {
                Text("×\(entry.copies)")
                    .font(.system(size: 11))
                    .foregroundStyle(model.theme.textColor.alpha(0.45))
            }
            if entry.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(model.theme.textColor.alpha(0.55))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? model.theme.focusedRow : model.theme.unfocusedRow.alpha(0.001))
        )
    }

    // Show the app the copy came from (Maccy-style) when known; fall back
    // to a content-kind symbol for entries copied before source tracking.
    @ViewBuilder
    private var rowIcon: some View {
        if let icon = ClipboardSourceIcons.icon(for: entry.sourceBundleID) {
            Image(nsImage: icon)
                .resizable()
        } else {
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundStyle(model.theme.textColor.alpha(0.8))
        }
    }

    private var iconName: String {
        switch entry.kind {
        case .text: return "doc.plaintext"
        case .url: return "link"
        case .image: return "photo"
        }
    }
}

/// Resolves bundle ids to small app icons, cached by bundle id.
enum ClipboardSourceIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let hit = cache.object(forKey: bundleID as NSString) { return hit }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = (NSWorkspace.shared.icon(forFile: appURL.path).copy() as? NSImage) ?? NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 15, height: 15)
        cache.setObject(icon, forKey: bundleID as NSString)
        return icon
    }
}
