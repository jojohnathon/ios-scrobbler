import Foundation
import SQLite3

struct OutboxPlay: Sendable {
    let id: String
    let artist: String
    let title: String
    let durationSeconds: Double?
    let timestamp: Int64
    let attempts: Int
    let needsReconciliation: Bool
}

final class ScrobbleStore {
    private let database: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    convenience init() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent("Scrobbler", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try self.init(url: directory.appendingPathComponent("scrobbles.sqlite"))
    }

    convenience init(url: URL) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw StoreError(message: "Could not open the local scrobble database")
        }
        self.init(database: handle)
        try execute("""
            CREATE TABLE IF NOT EXISTS scrobbles (
                id TEXT PRIMARY KEY,
                account TEXT NOT NULL COLLATE NOCASE,
                artist TEXT NOT NULL,
                title TEXT NOT NULL,
                duration REAL,
                started_at INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                needs_reconciliation INTEGER NOT NULL DEFAULT 0,
                retry_after REAL NOT NULL DEFAULT 0,
                outcome TEXT
            )
            """)
        try execute("""
            CREATE INDEX IF NOT EXISTS scrobbles_pending
            ON scrobbles (account, retry_after, started_at) WHERE outcome IS NULL
            """)
    }

    private init(database: OpaquePointer) { self.database = database }

    deinit { sqlite3_close_v2(database) }

    func enqueue(_ track: RecognizedTrack, startedAt: Date, id: UUID, account: String?) throws {
        try execute("""
            INSERT INTO scrobbles (id, account, artist, title, duration, started_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """, [.text(id.uuidString), .text(account ?? ""), .text(track.artist), .text(track.title),
                  track.durationSeconds.map(Value.real) ?? .null,
                  .integer(Int64(startedAt.timeIntervalSince1970.rounded(.down)))])
    }

    func bindUnassigned(to account: String) throws {
        try execute("UPDATE scrobbles SET account = ? WHERE account = '' AND outcome IS NULL", [.text(account)])
    }

    func nextPlay(for account: String) throws -> OutboxPlay? {
        try withStatement("""
            SELECT id, artist, title, duration, started_at, attempts, needs_reconciliation
            FROM scrobbles
            WHERE account = ? AND outcome IS NULL AND retry_after <= ?
            ORDER BY started_at, rowid LIMIT 1
            """, [.text(account), .real(Date().timeIntervalSince1970)]) { statement in
            guard try hasRow(statement) else { return nil }
            let duration = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3)
            return OutboxPlay(
                id: string(statement, 0), artist: string(statement, 1), title: string(statement, 2),
                durationSeconds: duration, timestamp: sqlite3_column_int64(statement, 4),
                attempts: Int(sqlite3_column_int(statement, 5)), needsReconciliation: sqlite3_column_int(statement, 6) != 0
            )
        }
    }

    func nextRetry(for account: String) throws -> Date? {
        try withStatement("""
            SELECT MIN(retry_after) FROM scrobbles WHERE account = ? AND outcome IS NULL
            """, [.text(account)]) { statement in
            guard try hasRow(statement), sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
    }

    func markAttempt(_ play: OutboxPlay, retryAfter: Date) throws {
        // Persist uncertainty before the request so interrupted submissions are checked before a retry.
        try execute("""
            UPDATE scrobbles SET attempts = attempts + 1, needs_reconciliation = 1, retry_after = ?
            WHERE id = ? AND outcome IS NULL
            """, [.real(retryAfter.timeIntervalSince1970), .text(play.id)])
    }

    func deferRetry(_ play: OutboxPlay, until date: Date) throws {
        try execute("UPDATE scrobbles SET retry_after = ? WHERE id = ?", [.real(date.timeIntervalSince1970), .text(play.id)])
    }

    func finish(_ play: OutboxPlay, outcome: String) throws {
        try execute("UPDATE scrobbles SET outcome = ? WHERE id = ?", [.text(outcome), .text(play.id)])
    }

    private enum Value {
        case text(String), real(Double), integer(Int64), null
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        try withStatement(sql, values) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        }
    }

    private func withStatement<T>(_ sql: String, _ values: [Value], _ run: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let value): result = sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case .real(let value): result = sqlite3_bind_double(statement, index, value)
            case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw databaseError() }
        }
        return try run(statement)
    }

    private func hasRow(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw databaseError()
        }
    }

    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        let length = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }

    private func databaseError() -> StoreError {
        StoreError(message: String(cString: sqlite3_errmsg(database)))
    }

    private struct StoreError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
