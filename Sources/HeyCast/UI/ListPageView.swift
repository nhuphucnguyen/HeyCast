import SwiftUI

struct ListPageView: View {
    @ObservedObject var model: LauncherModel
    let content: PageContent

    var body: some View {
        let starts = content.sectionStartIndices()
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(content.sections.enumerated()), id: \.offset) { sectionIndex, section in
                        if !section.title.isEmpty {
                            Text(section.title)
                                .font(model.theme.font(.subheadlineEmphasized))
                                .foregroundStyle(model.theme.textColor.alpha(0.5))
                                .padding(.leading, 10)
                                .padding(.top, sectionIndex == 0 ? 0 : 8)
                        }
                        let start = starts[sectionIndex]
                        ForEach(start ..< start + section.items.count, id: \.self) { index in
                            ResultRow(model: model, item: section.items[index - start], index: index)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .onChange(of: model.selectedIndex) { index in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}
