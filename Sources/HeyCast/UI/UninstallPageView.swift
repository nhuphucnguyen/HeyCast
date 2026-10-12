import SwiftUI
import AppKit

/// Uninstall page: the app bundle and its leftover files as a checklist.
/// ↵ or click toggles a row, ⌘↵ (or the button) asks to move the checked
/// items to the Trash, and the confirmation bar takes ↵ / Esc.
struct UninstallPageView: View {
    @ObservedObject var model: LauncherModel

    private var items: [AppUninstaller.Item] { model.filteredUninstallItems }

    var body: some View {
        VStack(spacing: 6) {
            if model.uninstallLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.6)
                    Text("Looking for files…")
                        .font(model.theme.font(.callout))
                        .foregroundStyle(model.theme.textColor.alpha(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.uninstallItems.isEmpty {
                Text(model.uninstallMessage ?? "Nothing to uninstall")
                    .font(model.theme.font(.body))
                    .foregroundStyle(model.theme.textColor.alpha(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
                actionBar
                    .padding(.horizontal, 18)
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        UninstallRow(model: model, item: item, isSelected: index == model.selectedIndex)
                            .id(item.id)
                            .onTapGesture {
                                model.selectedIndex = index
                                model.toggleUninstallItem(at: index)
                            }
                            .contextMenu {
                                Button(item.isSelected ? "Deselect" : "Select") {
                                    model.toggleUninstallItem(at: index)
                                }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                                }
                                Button("Copy Path") {
                                    ClipboardService.copy(text: item.path)
                                }
                            }
                    }
                }
                .padding(.horizontal, 10)
            }
            .onChange(of: model.selectedIndex) { newIndex in
                guard items.indices.contains(newIndex) else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(items[newIndex].id, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Status on the left, actions on the right — the same row shape as the
    /// clipboard and assistant pages. Shortcuts live in the tooltips.
    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 8) {
            if model.uninstallInProgress {
                ProgressView().scaleEffect(0.6)
                Text("Moving to Trash…")
                    .font(model.theme.font(.callout))
                    .foregroundStyle(model.theme.textColor.alpha(0.5))
                Spacer()
            } else if model.uninstallConfirming {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(confirmText)
                }
                .font(model.theme.font(.subheadline))
                .foregroundStyle(.orange.opacity(0.8))
                .lineLimit(2)
                Spacer(minLength: 8)
                Button("Cancel") { model.cancelUninstallConfirm() }
                    .buttonStyle(.bordered)
                    .font(model.theme.font(.callout))
                    .help("Keep everything (Esc)")
                Button(model.uninstallTargetIsRunning ? "Quit & Move to Trash" : "Move to Trash",
                       role: .destructive) {
                    model.confirmUninstall()
                }
                .buttonStyle(.bordered)
                .font(model.theme.font(.callout))
                .help("Move the checked items to the Trash (↵)")
            } else {
                if let message = model.uninstallMessage {
                    Text(message)
                        .font(model.theme.font(.subheadline))
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Uninstall…", role: .destructive) { model.requestUninstall() }
                    .buttonStyle(.bordered)
                    .font(model.theme.font(.callout))
                    .disabled(!model.uninstallItems.contains(where: \.isSelected))
                    .help("Move the checked items to the Trash (⌘↵) — ↵ checks or unchecks a row")
            }
        }
        .frame(minHeight: 28)
    }

    private var confirmText: String {
        let selected = model.uninstallItems.filter(\.isSelected)
        let size = selected.compactMap(\.size).reduce(0, +)
        let what = selected.count == 1 ? "1 item" : "\(selected.count) items"
        let sizeText = size > 0 ? " (\(AppUninstaller.formatSize(size)))" : ""
        let running = model.uninstallTargetIsRunning
            ? " \(model.uninstallTarget?.name ?? "The app") is open and will be quit first." : ""
        return "Move \(what)\(sizeText) to the Trash?\(running)"
    }
}

private struct UninstallRow: View {
    @ObservedObject var model: LauncherModel
    let item: AppUninstaller.Item
    let isSelected: Bool

    private static let iconCache = NSCache<NSString, NSImage>()

    private var icon: NSImage {
        if let cached = Self.iconCache.object(forKey: item.path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: item.path)
        image.size = NSSize(width: 20, height: 20)
        Self.iconCache.setObject(image, forKey: item.path as NSString)
        return image
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                .font(model.theme.font(.body))
                .foregroundStyle(item.isSelected ? Color.accentColor : model.theme.textColor.alpha(0.35))
                .frame(width: 16)
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(model.theme.font(.body))
                    .foregroundStyle(model.theme.textColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(FileSearchService.displayPath((item.path as NSString).deletingLastPathComponent))
                    .font(model.theme.font(.footnote))
                    .foregroundStyle(model.theme.textColor.alpha(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(item.size.map(AppUninstaller.formatSize) ?? "")
                .font(model.theme.font(.subheadline))
                .foregroundStyle(model.theme.textColor.alpha(0.45))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? model.theme.focusedRow : model.theme.unfocusedRow.alpha(0.001))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .opacity(model.uninstallInProgress ? 0.6 : 1)
    }
}
