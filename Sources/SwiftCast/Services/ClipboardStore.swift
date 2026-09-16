import AppKit
import SQLite3

/// One clipboard history entry. Images are stored as PNG data.
struct ClipboardEntry: Identifiable, Equatable {
    enum Kind: String { case text, url, image }

    let id: Int64
    let kind: Kind
    let text: String?   // text/url content; "image" literal for image rows
    let imageData: Data?
    let createdAt: Date

    var preview: String {
        switch kind {
        case .image: return "Image"
        case .url: return text ?? ""
        case .text:
            let t = text ?? ""
            return t.count > 40 ? String(t.prefix(40)) + "…" : t
        }
    }
}

/// SQLite persistence for clipboard history (system libsqlite3, mirroring
/// RustCast's clipboard.db schema).
final class ClipboardStore {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.swiftcast.clipboard-db")

    init() {
        let url = Config.directory.appendingPathComponent("clipboard.db")
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            NSLog("SwiftCast: failed to open clipboard db at \(url.path)")
            db = nil
            return
        }
        _ = execute("""
        CREATE TABLE IF NOT EXISTS clipboard_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content_type TEXT NOT NULL CHECK(content_type IN ('text','url','image')),
            text_content TEXT,
            blob_content BLOB,
            created_at INTEGER NOT NULL,
            size_bytes INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_created_at ON clipboard_entries(created_at DESC);
        """)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func execute(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func insert(kind: ClipboardEntry.Kind, text: String?, imageData: Data?) {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            let sql = "INSERT INTO clipboard_entries (content_type, text_content, blob_content, created_at, size_bytes) VALUES (?,?,?,?,?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let size = imageData?.count ?? text?.utf8.count ?? 0
            sqlite3_bind_text(stmt, 1, kind.rawValue, -1, SQLITE_TRANSIENT)
            if let text {
                sqlite3_bind_text(stmt, 2, text, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let imageData {
                _ = imageData.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, 3, buf.baseAddress, Int32(buf.count), nil)
                }
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_int64(stmt, 4, now)
            sqlite3_bind_int64(stmt, 5, Int64(size))
            _ = sqlite3_step(stmt)
        }
    }

    func load(limit: Int) -> [ClipboardEntry] {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return [] }
            var stmt: OpaquePointer?
            let sql = "SELECT id, content_type, text_content, blob_content, created_at FROM clipboard_entries ORDER BY created_at DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(limit))

            var entries: [ClipboardEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let kindRaw = String(cString: sqlite3_column_text(stmt, 1))
                let kind = ClipboardEntry.Kind(rawValue: kindRaw) ?? .text
                let text: String? = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                var imageData: Data? = nil
                if let blob = sqlite3_column_blob(stmt, 3) {
                    let count = Int(sqlite3_column_bytes(stmt, 3))
                    imageData = Data(bytes: blob, count: count)
                }
                let created = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4)) / 1000)
                if kind != .image && (text ?? "").isEmpty { continue }
                if kind == .image && imageData == nil { continue }
                entries.append(ClipboardEntry(id: id, kind: kind, text: text, imageData: imageData, createdAt: created))
            }
            return entries
        }
    }

    func delete(id: Int64) {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM clipboard_entries WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, id)
            _ = sqlite3_step(stmt)
        }
    }

    func deleteAll() {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            _ = sqlite3_exec(db, "DELETE FROM clipboard_entries", nil, nil, nil)
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
