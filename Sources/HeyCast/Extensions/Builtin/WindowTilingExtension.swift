import Foundation

/// "Left Half", "Maximize", … as root commands.
struct WindowTilingExtension: HeyCastExtension {
    let id = "window-tiling"
    let title = "Window Tiling"

    func commands(_ ctx: ExtensionContext) -> [ResultItem] {
        TilingPosition.allCases.map { tile in
            ResultItem(id: "tile-\(tile.rawValue)",
                       title: tile.displayName,
                       subtitle: "Window Tiling",
                       icon: .symbol(tile.symbolName),
                       action: .tile(tile))
        }
    }
}
