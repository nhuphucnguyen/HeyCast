import AppKit
import SwiftUI

@MainActor
protocol ExtensionPage: AnyObject {
    var title: String { get }
    var symbolName: String { get }
    var searchPlaceholder: String { get }
    // nil sizes the window to the rows, like the main page.
    var preferredSize: NSSize? { get }
    var content: PageContent { get }

    func didAppear(ctx: ExtensionContext)
    func didDisappear()
    func queryChanged(_ query: String, ctx: ExtensionContext)
    // A protocol requirement (not just a default) so existential dispatch
    // reaches the concrete override — see pageView in the extension below.
    func pageView(model: LauncherModel) -> AnyView?
}

extension ExtensionPage {
    var preferredSize: NSSize? { nil }
    func didDisappear() {}
    /// Custom full-page SwiftUI rendering (a reader with a preview pane,
    /// say). nil → the page falls back to content.layout (list/grid).
    func pageView(model: LauncherModel) -> AnyView? { nil }
}

struct ItemSection {
    var title: String
    var items: [ResultItem]
}

struct PageContent {
    enum Layout {
        case list
        case grid(columns: Int)
    }

    var layout: Layout
    var sections: [ItemSection]

    var columns: Int {
        switch layout {
        case .list: return 1
        case .grid(let columns): return columns
        }
    }

    var items: [ResultItem] { sections.flatMap(\.items) }

    func sectionStartIndices() -> [Int] {
        var start = 0
        return sections.map { section in
            defer { start += section.items.count }
            return start
        }
    }

    // Each section starts a new row, so rows hold flat item indices.
    private var rows: [[Int]] {
        zip(sections, sectionStartIndices()).flatMap { section, start in
            stride(from: 0, to: section.items.count, by: columns).map { offset in
                Array(start + offset ..< start + min(offset + columns, section.items.count))
            }
        }
    }

    func index(movingVerticallyFrom index: Int, by delta: Int) -> Int {
        let rows = rows
        guard let row = rows.firstIndex(where: { $0.contains(index) }) else { return 0 }
        let column = index - rows[row][0]
        let target = rows[(row + delta + rows.count) % rows.count]
        return target[min(column, target.count - 1)]
    }
}
