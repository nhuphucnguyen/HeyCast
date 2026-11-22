import SwiftUI

struct ListPageView: View {
    @ObservedObject var model: LauncherModel
    let content: PageContent

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(content.sections.enumerated()), id: \.offset) { _, section in
                        if !section.title.isEmpty {
                            Text(section.title)
                                .font(model.theme.font(.subheadlineEmphasized))
                                .foregroundStyle(model.theme.textColor.alpha(0.5))
                                .padding(.leading, 10)
                                .padding(.top, 4)
                        }
                        // Rows are identified by their item id, not by flat
                        // index: filters rebuild the sections and a row that
                        // moves must not leave a ghost of itself behind.
                        ForEach(section.items, id: \.id) { item in
                            ResultRow(model: model, item: item, index: flatIndex(of: item))
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .onChange(of: model.selectedIndex) { index in
                guard content.items.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(content.items[index].id, anchor: .center)
                }
            }
            .onAppear {
                // Landing on the page must show the selection (top of the
                // list) — without this the viewport can sit mid-list while
                // the selection is a row above the fold.
                if content.items.indices.contains(model.selectedIndex) {
                    proxy.scrollTo(content.items[model.selectedIndex].id, anchor: .top)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func flatIndex(of item: ResultItem) -> Int {
        content.items.firstIndex { $0.id == item.id } ?? 0
    }
}
