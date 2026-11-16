import Foundation
import SQLite3
#if canImport(notify)
import notify
#endif

/// Uploads that haven't reached the server yet, kept by the extension in the App Group so the app can list
/// them. File Provider's own pending set leaves out a new file's first upload, which is exactly the one
/// that must never get stuck unnoticed.
///
/// A row is written when an upload starts, updated when it fails, and removed when the file is in place.
/// Every change posts `changedNotification` (a Darwin notification), so the app refreshes right away.
public final class TransferJournal: @unchecked Sendable {
    public struct Entry: Hashable, Sendable {
        /// The upload's key (see `DomainConnection.uploadKey`).
        public var key: String
        /// The item's ID when it's an edit of a known item; nil for a new file.
        public var itemID: String?
        public var name: String
        /// Where it goes on the server: "Share/folder".
        public var folder: String
        public var size: Int64
        /// Why the last attempt failed; nil while it's running or waiting for its first attempt.
        public var error: String?
        public var updated: Date
    }

    public static let changedNotification = "com.rlx.fang.transfers-changed"

    /// Rows not updated for this long belong to uploads the system gave up on (the file was deleted
    /// locally before it ever arrived), and are dropped.
    static let abandonedAge: TimeInterval = 7 * 24 * 3600

    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw POSIXError(.EIO)
        }
        sqlite3_busy_timeout(db, 2000)  // The app and the extension share the file.
        guard sqlite3_exec(db, """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS uploads (
                key TEXT PRIMARY KEY, item TEXT, name TEXT NOT NULL, folder TEXT NOT NULL,
                size INTEGER NOT NULL, error TEXT, updated REAL NOT NULL);
            """, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
        // Added later; fails harmlessly when the column already exists.
        sqlite3_exec(db, "ALTER TABLE uploads ADD COLUMN busy_since REAL", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE uploads ADD COLUMN temp TEXT", nil, nil, nil)
    }

    /// The journal of the domain whose files live in `domainFolder` (the App Group's "Domains/<id>").
    public convenience init(domainFolder: URL) throws {
        try self.init(url: domainFolder.appending(path: "transfers.sqlite"))
    }

    deinit {
        sqlite3_close(db)
    }

    public func started(key: String, itemID: String?, name: String, folder: String, size: Int64) {
        run("""
            INSERT INTO uploads (key, item, name, folder, size, error, updated) VALUES (?, ?, ?, ?, ?, NULL, ?)
            ON CONFLICT(key) DO UPDATE SET error = NULL, updated = excluded.updated
            """, [.text(key), itemID.map { .text($0) } ?? .null, .text(name), .text(folder), .int(size), .real(Date().timeIntervalSince1970)])
    }

    public func failed(key: String, error: String) {
        run("UPDATE uploads SET error = ?, updated = ? WHERE key = ?", [.text(error), .real(Date().timeIntervalSince1970), .text(key)])
    }

    public func finished(key: String) {
        run("DELETE FROM uploads WHERE key = ?", [.text(key)])
    }

    /// Drops older entries for the same file once an upload of it succeeded: earlier attempts of an edit
    /// (another key, since the key follows the contents) or of a new file with that name and folder.
    func superseded(by key: String, itemID: String?, name: String, folder: String) {
        if let itemID {
            run("DELETE FROM uploads WHERE key <> ? AND item = ?", [.text(key), .text(itemID)])
        }
        run("DELETE FROM uploads WHERE key <> ? AND item IS NULL AND name = ? AND folder = ?", [.text(key), .text(name), .text(folder)])
    }

    /// Drops entries for new files that a listing shows are on the server now.
    func arrived(names: Set<String>, in folder: String) {
        let waiting = lock.withLock {
            var names: [String] = []
            query("SELECT name FROM uploads WHERE item IS NULL AND folder = ?", [.text(folder)]) { statement in
                names.append(String(cString: sqlite3_column_text(statement, 0)))
            }
            return names
        }
        for name in waiting where names.contains(name) {
            run("DELETE FROM uploads WHERE item IS NULL AND folder = ? AND name = ?", [.text(folder), .text(name)])
        }
    }

    // MARK: Busy uploads

    /// The temp file name an upload uses, when it moved off its default one (see `startedFresh`).
    func temp(for key: String) -> String? {
        lock.withLock {
            var temp: String?
            query("SELECT temp FROM uploads WHERE key = ?", [.text(key)]) { statement in
                temp = sqlite3_column_text(statement, 0).map { String(cString: $0) }
            }
            return temp
        }
    }

    /// Since when the server has refused the upload as busy, without a success or another failure since.
    func busySince(_ key: String) -> Date? {
        lock.withLock {
            var since: Date?
            query("SELECT busy_since FROM uploads WHERE key = ? AND busy_since IS NOT NULL", [.text(key)]) { statement in
                since = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            }
            return since
        }
    }

    /// Records that the server refused the upload as busy; the first refusal's time is kept.
    func markBusy(_ key: String, at date: Date = Date()) {
        lock.withLock {
            query("UPDATE uploads SET busy_since = COALESCE(busy_since, ?) WHERE key = ?", [.real(date.timeIntervalSince1970), .text(key)]) { _ in }
        }
    }

    /// Records that the upload moved to the temp file `temp`, and starts its busy clock over.
    func startedFresh(_ key: String, temp: String) {
        lock.withLock {
            query("UPDATE uploads SET temp = ?, busy_since = NULL WHERE key = ?", [.text(temp), .text(key)]) { _ in }
        }
    }

    /// Ends a busy stretch after an attempt failed for another reason.
    func clearBusy(_ key: String) {
        lock.withLock {
            query("UPDATE uploads SET busy_since = NULL WHERE key = ?", [.text(key)]) { _ in }
        }
    }

    public func entries() -> [Entry] {
        lock.withLock {
            var entries: [Entry] = []
            query("DELETE FROM uploads WHERE updated < ?", [.real(Date().timeIntervalSince1970 - Self.abandonedAge)]) { _ in }
            query("SELECT key, item, name, folder, size, error, updated FROM uploads ORDER BY name", []) { statement in
                entries.append(Entry(
                    key: String(cString: sqlite3_column_text(statement, 0)),
                    itemID: sqlite3_column_text(statement, 1).map { String(cString: $0) },
                    name: String(cString: sqlite3_column_text(statement, 2)),
                    folder: String(cString: sqlite3_column_text(statement, 3)),
                    size: sqlite3_column_int64(statement, 4),
                    error: sqlite3_column_text(statement, 5).map { String(cString: $0) },
                    updated: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
                ))
            }
            return entries
        }
    }

    // MARK: SQLite

    private enum Value {
        case text(String), int(Int64), real(Double), null
    }

    private func run(_ sql: String, _ values: [Value]) {
        lock.withLock { query(sql, values) { _ in } }
        notify_post(Self.changedNotification)
    }

    private func query(_ sql: String, _ values: [Value], row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, transient)
            case .int(let int): sqlite3_bind_int64(statement, position, int)
            case .real(let real): sqlite3_bind_double(statement, position, real)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement)
        }
    }
}

extension Error {
    /// A short, plain explanation for the "Not Synced" list.
    public var transferProblem: String {
        if isServerBusy { return "The server is still busy with this file. Retrying." }
        if let posix = self as? POSIXError {
            switch posix.code {
            case .ETIMEDOUT: return "The server stopped responding. Retrying."
            case .ECONNREFUSED, .EHOSTUNREACH, .EHOSTDOWN, .ENETUNREACH, .ENETDOWN:
                return "Can't reach the server. Retrying when it's back."
            // libsmb2's code both for a failed connect and for any server answer it has no other code for (a
            // name the server refused showed here as "can't reach" while the server was fine).
            case .EIO: return "Couldn't reach the server, or it refused this change. Retrying."
            case .ECONNRESET, .ECONNABORTED, .ENOTCONN, .ENETRESET, .EPIPE:
                return "The connection to the server was lost. Retrying."
            case .ENOSPC, .EDQUOT: return "There's no space left on the server."
            case .EACCES, .EPERM: return "You don't have permission to save here."
            case .EEXIST: return "A file with this name already exists."
            default: break
            }
        }
        return (self as NSError).localizedDescription
    }
}
