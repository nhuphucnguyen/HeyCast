import Foundation

struct WindowTilingExtension: HeyCastExtension {
    let id = "window-tiling"
    let title = "Window Tiling"

    func commands(_ ctx: ExtensionContext) -> [ResultItem] {
        TilingPosition.allCases.map { tile in
            ResultItem(id: "tile-\(tile.rawValue)",
                       title: tile.displayName,
                       subtitle: "Window Tiling",
                       icon: .symbol(tile.symbolName),
                       searchName: "tile:\(tile.rawValue)",
                       action: .extension(id: id, key: "tile", payload: tile.rawValue))
        }
    }

    func perform(_ key: String, payload: String, ctx: ExtensionContext) {
        guard key == "tile", let position = TilingPosition(rawValue: payload) else { return }
        let ok = ctx.targetApplication.flatMap { TilingService.tile(application: $0, position: position) } ?? false
        if !ok { ctx.signalFailure() }
        ctx.hide()
    }
}
