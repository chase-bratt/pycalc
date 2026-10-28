import Foundation
import SQLite3

public struct HistoryEntry: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let createdAt: Date
    public let code: String
    public let summary: String
    public let succeeded: Bool

    /// First meaningful line of the script, for list rows.
    public var title: String {
        code.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
            ?? code.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum HistoryStoreError: Error, LocalizedError {
    case sqlite(String)

    public var errorDescription: String? {
        switch self {
        case .sqlite(let message): return "History database error: \(message)"
        }
    }
}

/// Every script the user runs, kept for `retention` (30 days by default).
/// Re-running an identical script refreshes its timestamp instead of duplicating it.
public final class HistoryStore {
    public static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60

    private var db: OpaquePointer?
    private let retention: TimeInterval
    private let now: () -> Date

    public init(path: String, retention: TimeInterval = HistoryStore.defaultRetention, now: @escaping () -> Date = Date.init) throws {
        self.retention = retention
        self.now = now
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(db)
            throw HistoryStoreError.sqlite(message)
        }
        try execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS runs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                code TEXT NOT NULL,
                summary TEXT NOT NULL DEFAULT '',
                succeeded INTEGER NOT NULL DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS runs_created_at ON runs(created_at);
            CREATE UNIQUE INDEX IF NOT EXISTS runs_code ON runs(code);
            """)
        try purgeExpired()
        restrictPermissions(of: path)
    }

    /// History can contain anything the user typed, so keep the files owner-only (0600).
    private func restrictPermissions(of path: String) {
        for file in [path, path + "-wal", path + "-shm"] where FileManager.default.fileExists(atPath: file) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
        }
    }

    /// Default location: ~/Library/Application Support/PyCalc/history.sqlite
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("PyCalc", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history.sqlite")
    }

    deinit {
        sqlite3_close(db)
    }

    @discardableResult
    public func record(code: String, summary: String, succeeded: Bool) throws -> HistoryEntry? {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let timestamp = now()
        let statement = try prepare("""
            INSERT INTO runs (created_at, code, summary, succeeded) VALUES (?, ?, ?, ?)
            ON CONFLICT(code) DO UPDATE SET created_at = excluded.created_at,
                summary = excluded.summary, succeeded = excluded.succeeded
            RETURNING id
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, timestamp.timeIntervalSince1970)
        bindText(statement, 2, code)
        bindText(statement, 3, String(summary.prefix(500)))
        sqlite3_bind_int(statement, 4, succeeded ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        let id = sqlite3_column_int64(statement, 0)
        try purgeExpired()
        return HistoryEntry(id: id, createdAt: timestamp, code: code, summary: summary, succeeded: succeeded)
    }

    /// Most recent first, optionally filtered by a case-insensitive substring of the code.
    public func entries(matching query: String = "", limit: Int = 1000) throws -> [HistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let statement = try prepare("""
            SELECT id, created_at, code, summary, succeeded FROM runs
            WHERE (?1 = '' OR instr(lower(code), lower(?1)) > 0)
            ORDER BY created_at DESC LIMIT ?2
            """)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, trimmed)
        sqlite3_bind_int(statement, 2, Int32(limit))
        var rows: [HistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(HistoryEntry(
                id: sqlite3_column_int64(statement, 0),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                code: columnText(statement, 2),
                summary: columnText(statement, 3),
                succeeded: sqlite3_column_int(statement, 4) != 0))
        }
        return rows
    }

    public func delete(id: Int64) throws {
        let statement = try prepare("DELETE FROM runs WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    public func deleteAll() throws {
        try execute("DELETE FROM runs; VACUUM;")
    }

    public func purgeExpired() throws {
        let statement = try prepare("DELETE FROM runs WHERE created_at < ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now().addingTimeInterval(-retention).timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    // MARK: - SQLite helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Binds with an explicit byte length so text containing NUL isn't truncated.
    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { base in
                base.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                    _ = sqlite3_bind_text(statement, index, $0, Int32(bytes.count), Self.transient)
                }
            } ?? { _ = sqlite3_bind_text(statement, index, "", 0, Self.transient) }()
        }
    }

    /// Reads a text column, tolerating NULL and embedded NUL bytes.
    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_blob(statement, index) else { return "" }
        let count = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw lastError() }
    }

    private func lastError() -> HistoryStoreError {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}

/// Groups history rows under day headings ("Today", "Yesterday", "Mon 26 Oct").
public enum HistoryGrouping {
    public struct Section: Identifiable, Equatable {
        public let id: String
        public let title: String
        public let entries: [HistoryEntry]
    }

    public static func sections(for entries: [HistoryEntry], now: Date = Date(), calendar: Calendar = .current) -> [Section] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        var order: [String] = []
        var buckets: [String: [HistoryEntry]] = [:]
        var titles: [String: String] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.createdAt)
            let key = String(Int(day.timeIntervalSince1970))
            if buckets[key] == nil {
                order.append(key)
                titles[key] = calendar.isDate(day, inSameDayAs: now) ? "Today" :
                    calendar.isDate(day, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now) ?? now) ? "Yesterday" :
                    formatter.string(from: day)
            }
            buckets[key, default: []].append(entry)
        }
        return order.map { Section(id: $0, title: titles[$0] ?? $0, entries: buckets[$0] ?? []) }
    }
}
