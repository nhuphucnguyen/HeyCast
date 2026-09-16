import SwiftUI

/// 6-wide emoji grid with hover tooltips; selection follows the model index.
/// Click or Enter copies the emoji.
struct EmojiGridView: View {
    @ObservedObject var model: LauncherModel

    private let columns = Array(repeating: GridItem(.fixed(64), spacing: 6), count: 6)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(model.emojiResults.enumerated()), id: \.element.id) { index, entry in
                        EmojiCell(model: model, entry: entry, isSelected: index == model.selectedIndex)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onChange(of: model.selectedIndex) { newIndex in
                guard model.emojiResults.indices.contains(newIndex) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(model.emojiResults[newIndex].id, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct EmojiCell: View {
    @ObservedObject var model: LauncherModel
    let entry: EmojiEntry
    let isSelected: Bool

    var body: some View {
        Text(entry.character)
            .font(.system(size: 28))
            .frame(width: 60, height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? model.theme.focusedRow : model.theme.unfocusedRow.alpha(0.001))
            )
            .help(entry.name)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture {
                if let index = model.emojiResults.firstIndex(where: { $0.id == entry.id }) {
                    model.selectedIndex = index
                }
                model.openFocused()
            }
    }
}
