import SwiftUI
import AppKit

/// Root SwiftUI view hosted in the launcher panel: search field, results /
/// emoji grid / clipboard page, and the footer bar.
struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.top, 10)
                .padding(.horizontal, 14)

            content
                .padding(.top, 6)

            if showFooter {
                footer
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.swiftcastTheme, model.theme)
        .onReceive(model.$panelIsVisible) { visible in
            searchFocused = visible
        }
    }

    private var showFooter: Bool {
        switch model.page {
        case .main, .files: return true
        case .emoji: return true
        case .clipboard: return true
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: pageIcon)
                .foregroundStyle(model.theme.textColor.alpha(0.5))
                .font(.system(size: 15))
            TextField(model.config.placeholder, text: $model.query)
                .focused($searchFocused)
                .textFieldStyle(.plain)
                .font(Font(model.theme.uiFont(size: 19)))
                .foregroundStyle(model.theme.textColor)
                .onSubmit { model.openFocused() }
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(model.theme.textColor.alpha(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(model.theme.secondaryBackground.alpha(0.7))
        )
    }

    private var pageIcon: String {
        switch model.page {
        case .main: return "magnifyingglass"
        case .files: return "folder"
        case .clipboard: return "clipboard"
        case .emoji: return "face.smiling"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.page {
        case .main: resultList
        case .files: fileList
        case .emoji: EmojiGridView(model: model)
        case .clipboard: ClipboardPageView(model: model)
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.results) { item in
                        ResultRow(model: model, item: item)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 10)
            }
            .onChange(of: model.selectedIndex) { _ in
                guard model.results.indices.contains(model.selectedIndex) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(model.results[model.selectedIndex].id, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var fileList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.fileResults.enumerated()), id: \.offset) { index, hit in
                        FileRow(model: model, hit: hit, isSelected: index == model.selectedIndex)
                            .id(hit.path)
                            .onTapGesture {
                                model.selectedIndex = index
                                model.openFocused()
                            }
                    }
                }
                .padding(.horizontal, 10)
            }
            .onChange(of: model.selectedIndex) { _ in
                guard model.fileResults.indices.contains(model.selectedIndex) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(model.fileResults[model.selectedIndex].path, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(model.footerText)
                .font(.system(size: 12))
                .foregroundStyle(model.theme.textColor.alpha(0.6))
            Spacer()
            Text(pageLabel)
                .font(.system(size: 12))
                .foregroundStyle(model.theme.textColor.alpha(0.6))
        }
        .padding(.vertical, 3)
    }

    private var pageLabel: String {
        switch model.page {
        case .main: return "SwiftCast"
        case .files: return "File search"
        case .clipboard: return "Clipboard"
        case .emoji: return "Emoji"
        }
    }
}

// MARK: - result rows

struct ResultRow: View {
    @ObservedObject var model: LauncherModel
    let item: ResultItem

    private var isSelected: Bool {
        model.results.indices.contains(model.selectedIndex)
            && model.results[model.selectedIndex].id == item.id
    }

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: 28, height: 28)
            Text(item.title)
                .font(Font(model.theme.uiFont(size: 15)))
                .foregroundStyle(model.theme.textColor)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(model.theme.textColor.alpha(0.5))
                .lineLimit(1)
            favoriteButton
        }
        .padding(.horizontal, 10)
        .frame(height: LauncherModel.rowHeight - 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? model.theme.focusedRow : model.theme.unfocusedRow.alpha(0.001))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            if let index = model.results.firstIndex(where: { $0.id == item.id }) {
                model.selectedIndex = index
            }
            model.openResult(item)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch item.icon {
        case .app(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 15))
                .foregroundStyle(model.theme.textColor.alpha(0.85))
                .frame(width: 26, height: 26)
        case .emoji(let text):
            Text(text)
                .font(.system(size: 20))
                .frame(width: 26, height: 26)
        case .none:
            Color.clear.frame(width: 26, height: 26)
        }
    }

    private var favoriteButton: some View {
        Group {
            if item.searchName != nil {
                Button {
                    model.toggleFavorite(item)
                } label: {
                    Text("♥")
                        .font(.system(size: 14))
                        .foregroundStyle(model.theme.textColor.alpha(item.favorite ? 1.0 : 0.18))
                }
                .buttonStyle(.plain)
                .highPriorityGesture(TapGesture().onEnded {
                    model.toggleFavorite(item)
                })
            }
        }
        .frame(width: 18)
    }
}

struct FileRow: View {
    @ObservedObject var model: LauncherModel
    let hit: FileSearchService.FileHit
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 15))
                .foregroundStyle(model.theme.textColor.alpha(0.85))
                .frame(width: 26, height: 26)
            Text(hit.name)
                .font(Font(model.theme.uiFont(size: 15)))
                .foregroundStyle(model.theme.textColor)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(FileSearchService.displayPath(hit.path))
                .font(.system(size: 12))
                .foregroundStyle(model.theme.textColor.alpha(0.5))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: LauncherModel.rowHeight - 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? model.theme.focusedRow : model.theme.unfocusedRow.alpha(0.001))
        )
    }
}

// MARK: - theme environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

extension EnvironmentValues {
    var swiftcastTheme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
