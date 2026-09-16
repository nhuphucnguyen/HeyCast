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
    var copies: Int = 1
    var sourceBundleID: String? = nil  // app that was frontmost at copy time
    var sourceName: String? = nil
    var isPinned: Bool = false

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
/// RustCast's clipboard.db schema, plus Maccy-style columns for source app
/// and copy count).
final class ClipboardStore {
    static let historyLimit = 200  // Maccy's default history size

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.heycast.clipboard-db")

    init() {
        let url = Config.directory.appendingPathComponent("clipboard.db")
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            NSLog("HeyCast: failed to open clipboard db at \(url.path)")
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
        // Columns added after the RustCast-compatible schema; duplicate-column
        // errors on already-migrated databases are expected and ignored.
        _ = execute("ALTER TABLE clipboard_entries ADD COLUMN copies INTEGER NOT NULL DEFAULT 1")
        _ = execute("ALTER TABLE clipboard_entries ADD COLUMN source_bundle TEXT")
        _ = execute("ALTER TABLE clipboard_entries ADD COLUMN source_name TEXT")
        _ = execute("ALTER TABLE clipboard_entries ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func execute(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Inserts an entry and returns the new row id (nil if the write failed).
    @discardableResult
    func insert(kind: ClipboardEntry.Kind, text: String?, imageData: Data?,
                sourceBundleID: String? = nil, sourceName: String? = nil) -> Int64? {
        var rowID: Int64?
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO clipboard_entries (content_type, text_content, blob_content, created_at, size_bytes,
                                           copies, source_bundle, source_name)
            VALUES (?,?,?,?,?,1,?,?)
            """
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
                    // TRANSIENT: SQLite copies immediately; the buffer leaves
                    // scope before sqlite3_step runs.
                    sqlite3_bind_blob(stmt, 3, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
                }
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_int64(stmt, 4, now)
            sqlite3_bind_int64(stmt, 5, Int64(size))
            if let sourceBundleID {
                sqlite3_bind_text(stmt, 6, sourceBundleID, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            if let sourceName {
                sqlite3_bind_text(stmt, 7, sourceName, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            if sqlite3_step(stmt) == SQLITE_DONE {
                rowID = sqlite3_last_insert_rowid(db)
            }
        }
        return rowID
    }

    /// Maccy-style dedup: finds an entry with byte-identical content and
    /// promotes it instead of adding a row — refreshes created_at (so it
    /// sorts first again after a restart) and bumps its copy count. Returns
    /// the updated entry, or nil when the content is new.
    func touchExisting(kind: ClipboardEntry.Kind, text: String?, imageData: Data?) -> ClipboardEntry? {
        var promoted: ClipboardEntry?
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            // `IS ?` is SQLite's null-safe equality, so rows with NULL text
            // or blob columns still match correctly.
            var stmt: OpaquePointer?
            let find = """
            SELECT id FROM clipboard_entries
            WHERE content_type = ? AND text_content IS ? AND blob_content IS ?
            ORDER BY created_at DESC LIMIT 1
            """
            guard sqlite3_prepare_v2(db, find, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, kind.rawValue, -1, SQLITE_TRANSIENT)
            if let text {
                sqlite3_bind_text(stmt, 2, text, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            if let imageData {
                _ = imageData.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, 3, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
                }
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            var id: Int64?
            if sqlite3_step(stmt) == SQLITE_ROW {
                id = sqlite3_column_int64(stmt, 0)
            }
            sqlite3_finalize(stmt)
            guard let id else { return }

            var update: OpaquePointer?
            let sql = "UPDATE clipboard_entries SET created_at = ?, copies = copies + 1 WHERE id = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &update, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(update) }
            sqlite3_bind_int64(update, 1, Int64(Date().timeIntervalSince1970 * 1000))
            sqlite3_bind_int64(update, 2, id)
            guard sqlite3_step(update) == SQLITE_DONE else { return }
            promoted = Self.entry(id: id, db: db)
        }
        return promoted
    }

    /// Drops the oldest unpinned rows beyond `keep` (Maccy caps its history
    /// size the same way); pinned entries are exempt from the cap.
    func prune(keep: Int = ClipboardStore.historyLimit) {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            let sql = """
            DELETE FROM clipboard_entries WHERE is_pinned = 0 AND id NOT IN
                (SELECT id FROM clipboard_entries WHERE is_pinned = 0 ORDER BY created_at DESC LIMIT ?)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(keep))
            _ = sqlite3_step(stmt)
        }
    }

    func load(limit: Int) -> [ClipboardEntry] {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return [] }
            var stmt: OpaquePointer?
            let sql = """
            SELECT id, content_type, text_content, blob_content, created_at, copies, source_bundle, source_name, is_pinned
            FROM clipboard_entries ORDER BY is_pinned DESC, created_at DESC LIMIT ?
            """
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
                let copies = Int(sqlite3_column_int64(stmt, 5))
                let sourceBundle = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                let sourceName = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
                let isPinned = sqlite3_column_int64(stmt, 8) != 0
                if kind != .image && (text ?? "").isEmpty { continue }
                if kind == .image && imageData == nil { continue }
                entries.append(ClipboardEntry(id: id, kind: kind, text: text, imageData: imageData,
                                              createdAt: created, copies: max(1, copies),
                                              sourceBundleID: sourceBundle, sourceName: sourceName,
                                              isPinned: isPinned))
            }
            return entries
        }
    }

    /// Pins or unpins an entry (Maccy's ⌘P). Pinned entries stay at the top
    /// of the list and are exempt from Clear and history-size pruning.
    func setPinned(id: Int64, isPinned: Bool) {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            let sql = "UPDATE clipboard_entries SET is_pinned = ? WHERE id = ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, isPinned ? 1 : 0)
            sqlite3_bind_int64(stmt, 2, id)
            _ = sqlite3_step(stmt)
        }
    }

    /// Deletes unpinned entries; pinned ones survive (Maccy's Clear behavior).
    func deleteAll(keepingPinned: Bool = true) {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = keepingPinned ? "DELETE FROM clipboard_entries WHERE is_pinned = 0" : "DELETE FROM clipboard_entries"
            _ = sqlite3_exec(db, sql, nil, nil, nil)
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

    private static func entry(id: Int64, db: OpaquePointer) -> ClipboardEntry? {
        var stmt: OpaquePointer?
        let sql = """
        SELECT content_type, text_content, blob_content, created_at, copies, source_bundle, source_name, is_pinned
        FROM clipboard_entries WHERE id = ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let kindRaw = String(cString: sqlite3_column_text(stmt, 0))
        let text: String? = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
        var imageData: Data? = nil
        if let blob = sqlite3_column_blob(stmt, 2) {
            imageData = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
        }
        let created = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3)) / 1000)
        let copies = max(1, Int(sqlite3_column_int64(stmt, 4)))
        let sourceBundle = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        let sourceName = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let isPinned = sqlite3_column_int64(stmt, 7) != 0
        return ClipboardEntry(id: id, kind: ClipboardEntry.Kind(rawValue: kindRaw) ?? .text,
                              text: text, imageData: imageData, createdAt: created, copies: copies,
                              sourceBundleID: sourceBundle, sourceName: sourceName, isPinned: isPinned)
    }
}

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
