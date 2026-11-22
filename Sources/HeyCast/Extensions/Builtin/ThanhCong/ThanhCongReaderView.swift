import SwiftUI

/// Thanh Cong TC reader: compact day-grouped list on the left, the selected
/// post's content on the right — enough text to decide whether the post is
/// worth opening in the browser (↵ / ⌘C act on it as usual).
struct ThanhCongReaderView: View {
    @ObservedObject var model: LauncherModel
    let container: ThanhCongExtension
    @Environment(\.heycastTheme) private var theme
    @State private var webButtonHovering = false

    private var content: PageContent { container.content }
    private var items: [ResultItem] { content.items }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(content.sections.enumerated()), id: \.offset) { _, section in
                            if !section.title.isEmpty {
                                Text(section.title)
                                    .font(theme.font(.subheadlineEmphasized))
                                    .foregroundStyle(theme.textColor.alpha(0.5))
                                    .padding(.leading, 10)
                                    .padding(.top, 4)
                            }
                            // Item-id identity — filters reshuffle the
                            // sections and rows must not leave ghosts.
                            ForEach(section.items, id: \.id) { item in
                                ResultRow(model: model, item: item, index: flatIndex(of: item))
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .onChange(of: model.selectedIndex) { index in
                    guard items.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(items[index].id, anchor: .center)
                    }
                }
                .onAppear {
                    if items.indices.contains(model.selectedIndex) {
                        proxy.scrollTo(items[model.selectedIndex].id, anchor: .top)
                    }
                }
            }
            .frame(width: 340)

            Divider()
                .overlay(theme.textColor.alpha(0.15))

            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func flatIndex(of item: ResultItem) -> Int {
        items.firstIndex { $0.id == item.id } ?? 0
    }

    private var selectedItem: ResultItem? {
        items.indices.contains(model.selectedIndex) ? items[model.selectedIndex] : nil
    }

    @ViewBuilder
    private var preview: some View {
        let item = selectedItem
        if let post = container.post(for: item) {
            postPreview(post)
        } else if let item {
            // Control rows (refresh / author filter) and status rows.
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(theme.font(.bodyEmphasized))
                    .foregroundStyle(theme.textColor)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(theme.font(.callout))
                        .foregroundStyle(theme.textColor.alpha(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text("Nothing selected")
                .font(theme.font(.callout))
                .foregroundStyle(theme.textColor.alpha(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func postPreview(_ post: MightyNetworksService.Post) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: post.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textColor.alpha(0.55))
                Text("\(post.author) · \(post.spaceName)")
                    .font(theme.font(.footnote))
                    .foregroundStyle(theme.textColor.alpha(0.55))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(ThanhCongExtension.ago(post.createdAt))
                    .font(theme.font(.footnote))
                    .foregroundStyle(theme.textColor.alpha(0.45))
                // Reading happens here; the browser is an explicit click.
                Button {
                    if let url = URL(string: post.url) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Web")
                            .font(theme.font(.footnoteEmphasized))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(webButtonHovering ? 0.28 : 0.14))
                    )
                }
                .buttonStyle(.plain)
                .onHover { webButtonHovering = $0 }
                .help("Open in web browser (⌘O)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Text(ThanhCongExtension.displayTitle(post))
                .font(theme.font(.bodyEmphasized))
                .foregroundStyle(theme.textColor)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 6)

            if !ThanhCongExtension.statsLabel(post).isEmpty {
                Text(ThanhCongExtension.statsLabel(post))
                    .font(theme.font(.footnote))
                    .foregroundStyle(theme.textColor.alpha(0.5))
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }

            Rectangle()
                .fill(theme.textColor.alpha(0.12))
                .frame(height: 1)
                .padding(.top, 10)

            if post.bodyHTML.isEmpty {
                Text("(no text content — open the post to see it)")
                    .font(theme.font(.callout))
                    .foregroundStyle(theme.textColor.alpha(0.45))
                    .italic()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(16)
            } else {
                // The web view scrolls its own content and must not sit
                // inside a SwiftUI ScrollView; the CSS body padding keeps the
                // text off the pane edges.
                HTMLPreview(html: post.bodyHTML, theme: theme,
                            baseURL: URL(string: "https://thanhcongtc.mn.co/"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if !post.bodyComplete {
                Text("Preview truncated — press ⌘O to read the full post on the web")
                    .font(theme.font(.footnote))
                    .foregroundStyle(theme.textColor.alpha(0.45))
                    .italic()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

            Divider()
                .overlay(theme.textColor.alpha(0.12))

            HStack(spacing: 14) {
                Text("⌘O Open in Browser")
                Text("⌘C Copy Link")
                Text("⌘K All actions")
                Spacer(minLength: 0)
            }
            .font(theme.font(.footnote))
            .foregroundStyle(theme.textColor.alpha(0.4))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }
}
