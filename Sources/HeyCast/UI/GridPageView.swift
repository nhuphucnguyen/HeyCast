import SwiftUI

struct GridPageView: View {
    @ObservedObject var model: LauncherModel
    let content: GridContent

    private let spacing: CGFloat = 8

    var body: some View {
        if content.items.isEmpty {
            Text("No results")
                .font(model.theme.font(.body))
                .foregroundStyle(model.theme.textColor.alpha(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            grid
        }
    }

    private var grid: some View {
        let starts = content.sectionStartIndices()
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: content.columns)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(content.sections.enumerated()), id: \.offset) { sectionIndex, section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(model.theme.font(.subheadlineEmphasized))
                                .foregroundStyle(model.theme.textColor.alpha(0.5))
                                .padding(.leading, 2)
                            LazyVGrid(columns: columns, spacing: spacing) {
                                // One identity per cell — the flat index — shared with scrollTo;
                                // a second .id() on lazy grid children leaves cells stale.
                                let start = starts[sectionIndex]
                                ForEach(start ..< start + section.items.count, id: \.self) { index in
                                    GridCell(model: model, item: section.items[index - start], index: index)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            .onChange(of: model.selectedIndex) { index in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
            .onChange(of: model.query) { _ in
                proxy.scrollTo(0, anchor: .top)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct GridCell: View {
    @ObservedObject var model: LauncherModel
    let item: ResultItem
    let index: Int
    @State private var hovering = false

    private var isSelected: Bool { model.selectedIndex == index }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(background)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(model.theme.textColor.alpha(isSelected ? 0.35 : 0), lineWidth: 1.5)
            )
            .overlay(glyph)
            .aspectRatio(1, contentMode: .fit)
            .help(item.title)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onHover { hovering = $0 }
            .onTapGesture {
                model.selectedIndex = index
                model.openResult(item)
            }
            .overlay(RightClickCatcher {
                model.selectedIndex = index
                model.openActionPanel()
            })
    }

    private var background: Color {
        if isSelected { return model.theme.focusedRow }
        return model.theme.textColor.alpha(hovering ? 0.1 : 0.05)
    }

    @ViewBuilder
    private var glyph: some View {
        switch item.icon {
        case .emoji(let text):
            Text(text).font(.system(size: 34)).foregroundStyle(model.theme.textColor)
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 26))
        case .app(let image):
            Image(nsImage: image).resizable().interpolation(.high).padding(12)
        case .none:
            EmptyView()
        }
    }
}
