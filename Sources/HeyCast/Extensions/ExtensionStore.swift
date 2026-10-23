import Foundation

struct ExtensionStore {
    let url: URL

    init(extensionID: String) {
        url = Config.directory
            .appendingPathComponent("extensions", isDirectory: true)
            .appendingPathComponent("\(extensionID).json")
    }

    func load<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func save<T: Encodable>(_ value: T) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
