import Foundation
import SQLite3

/// SQLite persistence for notes (system libsqlite3). WAL mode so a second
/// process (the planned MCP server) can read and write the same file.
///
/// Every mutation bumps `updated_at` and `rev` and sets `dirty`, and deletes
/// are tombstones (`deleted_at`), so a sync layer can be added without a
/// schema change.
public final class NotesStore {
    public static let deletedRetentionDays = 30

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.heycast.notes-db")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            NSLog("%@", "HeyCast: failed to open notes db at \(url.path)")
            db = nil
            return
        }
        sqlite3_busy_timeout(db, 3000)
        exec("PRAGMA journal_mode=WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS items (
            seq INTEGER PRIMARY KEY,
            id TEXT NOT NULL UNIQUE,
            kind TEXT NOT NULL CHECK(kind IN ('inbox','note','word')),
            title TEXT,
            body TEXT NOT NULL DEFAULT '',
            context TEXT,
            status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved','archived')),
            tags TEXT NOT NULL DEFAULT '',
            pinned REAL,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            deleted_at INTEGER,
            due_at INTEGER,
            interval_days REAL,
            ease REAL,
            reviews INTEGER NOT NULL DEFAULT 0,
            rev INTEGER NOT NULL DEFAULT 0,
            dirty INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX IF NOT EXISTS idx_items_kind_status ON items(kind, status, updated_at DESC);
        CREATE INDEX IF NOT EXISTS idx_items_deleted ON items(deleted_at);
        CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
            title, body, example, tokenize='unicode61 remove_diacritics 2'
        );
        """)
        exec("PRAGMA user_version = 1")
        purgeDeleted()
    }

    deinit { sqlite3_close(db) }

    // MARK: - writes

    @discardableResult
    public func create(kind: NoteItem.Kind, title: String?, body: String,
                       context: NoteContext? = nil) -> NoteItem? {
        let now = Date()
        let item = NoteItem(id: NoteID.make(at: now), kind: kind, title: title, body: body,
                            context: context, status: .open, tags: [], pinned: nil,
                            createdAt: now, updatedAt: now, deletedAt: nil)
        let ok = queue.sync { () -> Bool in
            let done = run("""
                INSERT INTO items (id, kind, title, body, context, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'open', ?, ?)
                """, [item.id, kind.rawValue, title, body, Self.encode(context),
                      Self.ms(now), Self.ms(now)])
            if done { reindex(id: item.id) }
            return done
        }
        return ok ? item : nil
    }

    public func update(id: String, title: String?, body: String) {
        mutate(id, "title = ?, body = ?", [title, body])
    }

    public func setContext(id: String, _ context: NoteContext?) {
        // Context arrives asynchronously after capture; it is metadata, so it
        // does not move the item in "recently updated" ordering.
        queue.sync {
            _ = run("UPDATE items SET context = ?, rev = rev + 1, dirty = 1 WHERE id = ?",
                    [Self.encode(context), id])
            reindex(id: id)
        }
    }

    public func setStatus(id: String, _ status: NoteItem.Status) {
        mutate(id, "status = ?", [status.rawValue])
    }

    public func setKind(id: String, _ kind: NoteItem.Kind) {
        mutate(id, "kind = ?, status = 'open'", [kind.rawValue])
    }

    /// Pins at the end of the pinned list, or unpins.
    public func setPinned(id: String, _ pinned: Bool) {
        if pinned {
            let next = queue.sync { () -> Double in
                (doubleQuery("SELECT MAX(pinned) FROM items WHERE pinned IS NOT NULL") ?? 0) + 1
            }
            mutate(id, "pinned = ?", [next])
        } else {
            mutate(id, "pinned = NULL", [])
        }
    }

    public func delete(id: String) {
        mutate(id, "deleted_at = ?, pinned = NULL", [Self.ms(Date())])
    }

    public func restore(id: String) {
        mutate(id, "deleted_at = NULL", [])
    }

    public func permanentlyDelete(id: String) {
        queue.sync {
            unindex(id: id)
            _ = run("DELETE FROM items WHERE id = ?", [id])
        }
    }

    /// Drops tombstones older than the retention window.
    public func purgeDeleted(olderThanDays days: Int = NotesStore.deletedRetentionDays) {
        let cutoff = Self.ms(Date().addingTimeInterval(-Double(days) * 86_400))
        queue.sync {
            for id in strings("SELECT id FROM items WHERE deleted_at IS NOT NULL AND deleted_at < ?", [cutoff]) {
                unindex(id: id)
            }
            _ = run("DELETE FROM items WHERE deleted_at IS NOT NULL AND deleted_at < ?", [cutoff])
        }
    }

    // MARK: - reads

    public func item(id: String) -> NoteItem? {
        queue.sync { items("SELECT \(Self.columns) FROM items WHERE id = ?", [id]).first }
    }

    /// Live (not deleted) items, newest first.
    public func list(kind: NoteItem.Kind? = nil, status: NoteItem.Status? = nil,
                     pinnedOnly: Bool = false, limit: Int = 200) -> [NoteItem] {
        var clauses = ["deleted_at IS NULL"]
        var args: [Any?] = []
        if let kind { clauses.append("kind = ?"); args.append(kind.rawValue) }
        if let status { clauses.append("status = ?"); args.append(status.rawValue) }
        if pinnedOnly { clauses.append("pinned IS NOT NULL") }
        args.append(limit)
        let order = pinnedOnly ? "pinned ASC" : "updated_at DESC"
        return queue.sync {
            items("SELECT \(Self.columns) FROM items WHERE \(clauses.joined(separator: " AND ")) ORDER BY \(order) LIMIT ?", args)
        }
    }

    public func listDeleted(limit: Int = 200) -> [NoteItem] {
        queue.sync {
            items("SELECT \(Self.columns) FROM items WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC LIMIT ?", [limit])
        }
    }

    public func deletedCount() -> Int {
        queue.sync { Int(doubleQuery("SELECT COUNT(*) FROM items WHERE deleted_at IS NOT NULL") ?? 0) }
    }

    /// Full-text prefix search over title, body and example sentence.
    public func search(_ query: String, includeResolved: Bool = true, limit: Int = 50) -> [NoteItem] {
        let tokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"*" }.joined(separator: " ")
        let status = includeResolved ? "" : "AND items.status = 'open'"
        return queue.sync {
            items("""
                SELECT \(Self.columns.split(separator: ",").map { "items.\($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: ", "))
                FROM items_fts JOIN items ON items.seq = items_fts.rowid
                WHERE items_fts MATCH ? AND items.deleted_at IS NULL \(status)
                ORDER BY bm25(items_fts), items.updated_at DESC LIMIT ?
                """, [match, limit])
        }
    }

    // MARK: - internals (call on `queue`)

    private static let columns = "id, kind, title, body, context, status, tags, pinned, created_at, updated_at, deleted_at"

    private func mutate(_ id: String, _ assignments: String, _ args: [Any?]) {
        queue.sync {
            _ = run("UPDATE items SET \(assignments), updated_at = ?, rev = rev + 1, dirty = 1 WHERE id = ?",
                    args + [Self.ms(Date()), id])
            reindex(id: id)
        }
    }

    /// The FTS row shares the item's `seq` as its rowid; rewrite it after
    /// every change to the item.
    private func reindex(id: String) {
        unindex(id: id)
        guard let row = items("SELECT \(Self.columns) FROM items WHERE id = ?", [id]).first,
              let seq = seqFor(id) else { return }
        _ = run("INSERT INTO items_fts(rowid, title, body, example) VALUES (?, ?, ?, ?)",
                [seq, row.title ?? "", row.body, row.context?.example ?? ""])
    }

    private func unindex(id: String) {
        guard let seq = seqFor(id) else { return }
        _ = run("DELETE FROM items_fts WHERE rowid = ?", [seq])
    }

    private func seqFor(_ id: String) -> Int64? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT seq FROM items WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_text(stmt, 1, id, -1, Self.transient)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        var error: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK
        if let error {
            NSLog("%@", "HeyCast notes sql error: \(String(cString: error))")
            sqlite3_free(error)
        }
        return ok
    }

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("%@", "HeyCast notes prepare error: \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        for (offset, arg) in args.enumerated() {
            let index = Int32(offset + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, index)
            case let v as String: sqlite3_bind_text(stmt, index, v, -1, Self.transient)
            case let v as Int: sqlite3_bind_int64(stmt, index, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, index, v)
            case let v as Double: sqlite3_bind_double(stmt, index, v)
            default: sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ args: [Any?]) -> Bool {
        guard let stmt = prepare(sql, args) else { return false }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE, let db {
            NSLog("%@", "HeyCast notes step error: \(String(cString: sqlite3_errmsg(db)))")
        }
        return rc == SQLITE_DONE
    }

    private func doubleQuery(_ sql: String) -> Double? {
        guard let stmt = prepare(sql, []) else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, 0)
    }

    private func strings(_ sql: String, _ args: [Any?]) -> [String] {
        guard let stmt = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = Self.text(stmt, 0) { out.append(text) }
        }
        return out
    }

    private func items(_ sql: String, _ args: [Any?]) -> [NoteItem] {
        guard let stmt = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [NoteItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = Self.text(stmt, 0),
                  let kind = NoteItem.Kind(rawValue: Self.text(stmt, 1) ?? "") else { continue }
            let context = Self.text(stmt, 4).flatMap { try? JSONDecoder().decode(NoteContext.self, from: Data($0.utf8)) }
            let tags = (Self.text(stmt, 6) ?? "").split(separator: ",").map(String.init)
            out.append(NoteItem(
                id: id, kind: kind, title: Self.text(stmt, 2), body: Self.text(stmt, 3) ?? "",
                context: context, status: NoteItem.Status(rawValue: Self.text(stmt, 5) ?? "") ?? .open,
                tags: tags,
                pinned: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7),
                createdAt: Self.date(sqlite3_column_int64(stmt, 8)),
                updatedAt: Self.date(sqlite3_column_int64(stmt, 9)),
                deletedAt: sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Self.date(sqlite3_column_int64(stmt, 10))))
        }
        return out
    }

    private static func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: cString)
    }

    private static func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }
    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    private static func encode(_ context: NoteContext?) -> String? {
        guard let context, !context.isEmpty, let data = try? JSONEncoder().encode(context) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
