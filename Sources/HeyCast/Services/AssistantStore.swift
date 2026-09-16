import AppKit
import SQLite3

/// One assistant exchange. Requests are fire-and-forget: the row is created
/// as soon as the user hits Enter (status "pending"), and the response (or
/// error) is filled in when the agent answers — even across app restarts.
struct AssistantMessage: Identifiable, Equatable {
    enum Status: String { case pending, done, failed }

    let id: Int64
    let agent: String       // display name at send time
    let request: String
    var response: String?
    var error: String?
    var status: Status
    let createdAt: Date
    var doneAt: Date?
    var viewedAt: Date?

    var isUnread: Bool { status != .pending && viewedAt == nil }
}

/// SQLite persistence for the assistant inbox (same system-libsqlite3
/// pattern as ClipboardStore).
final class AssistantStore {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.heycast.assistant-db")

    init() {
        let url = Config.directory.appendingPathComponent("assistant.db")
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            NSLog("HeyCast: failed to open assistant db at \(url.path)")
            db = nil
            return
        }
        _ = execute("""
        CREATE TABLE IF NOT EXISTS assistant_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            agent TEXT NOT NULL,
            request TEXT NOT NULL,
            response TEXT,
            error TEXT,
            status TEXT NOT NULL CHECK(status IN ('pending','done','failed')),
            created_at INTEGER NOT NULL,
            done_at INTEGER,
            viewed_at INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_assistant_created ON assistant_messages(created_at DESC);
        """)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func execute(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    func insert(agent: String, request: String) -> Int64? {
        var rowID: Int64?
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return }
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO assistant_messages (agent, request, status, created_at) VALUES (?,?, 'pending', ?)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, agent, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, request, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970 * 1000))
            if sqlite3_step(stmt) == SQLITE_DONE {
                rowID = sqlite3_last_insert_rowid(db)
            }
        }
        return rowID
    }

    func updateResponse(id: Int64, response: String) {
        queue.sync { [weak self] in
            guard let self else { return }
            exec("UPDATE assistant_messages SET response = ?, error = NULL, status = 'done', done_at = ? WHERE id = ?",
                 [response, String(Int64(Date().timeIntervalSince1970 * 1000)), String(id)])
        }
    }

    func updateError(id: Int64, error: String) {
        queue.sync { [weak self] in
            guard let self else { return }
            exec("UPDATE assistant_messages SET error = ?, status = 'failed', done_at = ? WHERE id = ?",
                 [String(error.prefix(500)), String(Int64(Date().timeIntervalSince1970 * 1000)), String(id)])
        }
    }

    /// Puts a row back into the send queue (Retry).
    func reset(id: Int64) {
        queue.sync { [weak self] in
            guard let self else { return }
            exec("UPDATE assistant_messages SET response = NULL, error = NULL, status = 'pending', done_at = NULL WHERE id = ?",
                 [String(id)])
        }
    }

    func markViewed(id: Int64) {
        queue.sync { [weak self] in
            guard let self else { return }
            exec("UPDATE assistant_messages SET viewed_at = ? WHERE id = ? AND viewed_at IS NULL",
                 [String(Int64(Date().timeIntervalSince1970 * 1000)), String(id)])
        }
    }

    func delete(id: Int64) {
        queue.sync { [weak self] in
            guard let self else { return }
            exec("DELETE FROM assistant_messages WHERE id = ?", [String(id)])
        }
    }

    func load(limit: Int = 100) -> [AssistantMessage] {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return [] }
            var stmt: OpaquePointer?
            let sql = """
            SELECT id, agent, request, response, error, status, created_at, done_at, viewed_at
            FROM assistant_messages ORDER BY created_at DESC LIMIT ?
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(limit))

            var messages: [AssistantMessage] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let agent = String(cString: sqlite3_column_text(stmt, 1))
                let request = String(cString: sqlite3_column_text(stmt, 2))
                let response = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let error = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let status = AssistantMessage.Status(rawValue: String(cString: sqlite3_column_text(stmt, 5))) ?? .failed
                let created = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 6)) / 1000)
                let doneAt = sqlite3_column_type(stmt, 7) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 7)) / 1000)
                let viewedAt = sqlite3_column_type(stmt, 8) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 8)) / 1000)
                messages.append(AssistantMessage(id: id, agent: agent, request: request, response: response,
                                                 error: error, status: status, createdAt: created,
                                                 doneAt: doneAt, viewedAt: viewedAt))
            }
            return messages
        }
    }

    func unreadCount() -> Int {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM assistant_messages WHERE status != 'pending' AND viewed_at IS NULL",
                                     -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func exec(_ sql: String, _ args: [String]) {
        var stmt: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (index, arg) in args.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), arg, -1, SQLITE_TRANSIENT)
        }
        _ = sqlite3_step(stmt)
    }
}
