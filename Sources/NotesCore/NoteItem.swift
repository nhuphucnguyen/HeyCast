import Foundation

/// One entry in the notes store. Three kinds share a table because the
/// difference is intent at capture time, and an item can move between them.
public struct NoteItem: Identifiable, Equatable {
    public enum Kind: String, CaseIterable {
        case inbox  // quick thought to resolve later
        case note   // longer markdown note
        case word   // vocabulary to review
    }

    public enum Status: String {
        case open, resolved, archived
    }

    public let id: String
    public var kind: Kind
    public var title: String?
    public var body: String
    public var context: NoteContext?
    public var status: Status
    public var tags: [String]
    public var pinned: Double?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: String, kind: Kind, title: String?, body: String, context: NoteContext?,
                status: Status, tags: [String], pinned: Double?, createdAt: Date, updatedAt: Date,
                deletedAt: Date?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.context = context
        self.status = status
        self.tags = tags
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var isPinned: Bool { pinned != nil }
    public var isDeleted: Bool { deletedAt != nil }

    /// Explicit title, else the first non-empty body line.
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespaces))
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// Text to copy or paste: the word itself for words, else the body.
    public var plainText: String {
        switch kind {
        case .word: return title ?? body
        case .inbox, .note: return body.isEmpty ? (title ?? "") : body
        }
    }
}

/// Where the item was captured: answers "what was I doing?" later.
public struct NoteContext: Codable, Equatable {
    public var appName: String?
    public var bundleID: String?
    public var windowTitle: String?
    public var url: String?
    public var example: String?  // words: the sentence it was seen in

    public init(appName: String? = nil, bundleID: String? = nil, windowTitle: String? = nil,
                url: String? = nil, example: String? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.url = url
        self.example = example
    }

    public var isEmpty: Bool {
        appName == nil && bundleID == nil && windowTitle == nil && url == nil && example == nil
    }
}

public enum NoteID {
    /// UUIDv7: time-ordered, so ids sort by creation and stay unique across
    /// devices once sync exists.
    public static func make(at date: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let ms = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * (5 - UInt64(i)))) & 0xff) }
        var rng = SystemRandomNumberGenerator()
        for i in 6..<16 { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        bytes[6] = (bytes[6] & 0x0f) | 0x70  // version 7
        bytes[8] = (bytes[8] & 0x3f) | 0x80  // RFC 4122 variant
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.joined(separator: "-")
    }
}
