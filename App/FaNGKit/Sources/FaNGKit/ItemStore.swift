import Foundation
import SQLite3

/// What the extension knows about one item. `id` is a stable identifier assigned on this device,
/// so renames, moves and content replacement (which gives the file a new inode) keep the same identity.
public struct ItemRecord: Hashable, Sendable {
    public var id: String
    public var parentID: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
    public var created: Date
    public var fileID: UInt64
    /// The FaNG server's content version, in FaNG-server mode; nil against plain SMB.
    public var serverVersion: Int64?
    /// Finder tags, "name\ncolor" each (FaNG-server mode).
    public var tags: [String] = []
    /// A server copy making this item: "copying" (with `progress` in percent) or "failed"; nil otherwise.
    public var job: String?
    public var progress: Int?
    /// Extended attributes the system syncs (folder symbols and emoji, "Where from", …): name → value
    /// (FaNG-server mode).
    public var xattrs: [String: Data] = [:]
    /// The server's permissions let this user read but not change it (FaNG-server mode).
    public var readOnly = false

    public init(id: String, parentID: String, remote: RemoteItem) {
        self.id = id
        self.parentID = parentID
        name = remote.name
        isDirectory = remote.isDirectory
        size = remote.size
        modified = remote.modified
        created = remote.created
        fileID = remote.fileID
    }

    /// Changes when the file's bytes change: the server's content version, or against plain SMB the size
    /// and modification time.
    public var contentVersion: Data {
        if let serverVersion { return Data("v\(serverVersion)".utf8) }
        return Data("\(size):\(modified.timeIntervalSince1970)".utf8)
    }

    /// Changes when the name, location or tags change, or when FaNG starts describing items differently
    /// (`itemFormat`): the system keeps an item's capabilities and `userInfo` until its version changes.
    public var metadataVersion: Data {
        Data("\(Self.itemFormat):\(parentID)/\(name)\(tags.isEmpty ? "" : "|" + tags.joined(separator: "|"))\(job.map { "|job:\($0):\(progress ?? 0)" } ?? "")\(xattrs.isEmpty ? "" : "|x:" + Self.digest(xattrs))\(readOnly ? "|ro" : "")".utf8)
    }

    /// A short stable digest of the extended attributes (for the metadata version).
    static func digest(_ xattrs: [String: Data]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a over names and values, in name order
        for name in xattrs.keys.sorted() {
            for byte in Array(name.utf8) + [0] + Array(xattrs[name] ?? Data()) + [0] {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
        }
        return String(hash, radix: 36)
    }

    /// The extended attributes as the store keeps them (JSON, values in base64).
    var xattrsText: String? {
        guard !xattrs.isEmpty, let data = try? JSONEncoder().encode(xattrs.mapValues { $0.base64EncodedString() }) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func xattrs(fromText text: String) -> [String: Data] {
        (try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)))?.compactMapValues { Data(base64Encoded: $0) } ?? [:]
    }

    /// Raise when item capabilities or `userInfo` change meaning. 2: eviction allowed; FaNG and conflict flags.
    /// 3: the transfer flag (Copy To / Move To), on folders too. 4: extended attributes (folder customization)
    /// and the content capabilities of a domain with a trash. 5 (iOS and iPadOS only): everything again, once,
    /// while chasing Files not offering FaNG's actions on iPhone and iPad (that turned out to be Files' cache of
    /// extensions, stale after reinstalls while it was open; see CLAUDE.md). Kept so devices don't resend again.
    /// A Mac stays on 4 (resending its 500,000 items would keep it busy for an hour).
    #if os(macOS)
    public static let itemFormat = 4
    #else
    public static let itemFormat = 5
    #endif

    /// Item formats whose items only differ from `itemFormat` for items with extended attributes: a device
    /// coming from one resends just those (resending everything kept a Mac that knows 500,000 items busy for
    /// an hour, and the system held back large downloads meanwhile). On iOS every earlier format resends all.
    #if os(macOS)
    public static let xattrOnlyRefreshFrom: Set<Int> = [3]
    #else
    public static let xattrOnlyRefreshFrom: Set<Int> = []
    #endif
}

/// Plain-SMB identity map in SQLite: stable item IDs to (parent, name), plus the last listing of each
/// folder, which `reconcile` diffs against to find changes. Thread-safe.
///
/// Matching a listed item to a known one tries the server's file index number first (so a rename or
/// move made by another client keeps its identity), then the parent and name.
public final class ItemStore: @unchecked Sendable {
    public struct Reconciliation: Sendable {
        /// Every item in the folder now.
        public var items: [ItemRecord]
        /// Items that are new or changed since the last listing.
        public var changed: [ItemRecord]
        /// IDs of items that are gone (their descendants are removed from the store too).
        public var deleted: [String]
        /// IDs of known files whose contents changed (not just their name, place or tags).
        public var contentChanged: Set<String> = []
    }

    public let rootID: String
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL, rootID: String) throws {
        self.rootID = rootID
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw POSIXError(.EIO)
        }
        try execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY, parent TEXT NOT NULL, name TEXT NOT NULL, dir INTEGER NOT NULL,
                size INTEGER NOT NULL, modified REAL NOT NULL, created REAL NOT NULL, file_id INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS items_parent ON items(parent, name);
            CREATE INDEX IF NOT EXISTS items_file_id ON items(file_id);
            CREATE TABLE IF NOT EXISTS folders (id TEXT PRIMARY KEY, listed REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS unlisted (id TEXT PRIMARY KEY);
            """)
        // Added later; fails harmlessly when the column already exists.
        sqlite3_exec(db, "ALTER TABLE items ADD COLUMN version INTEGER", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE items ADD COLUMN tags TEXT", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE items ADD COLUMN job TEXT", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE items ADD COLUMN progress INTEGER", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE items ADD COLUMN xattrs TEXT", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE items ADD COLUMN readonly INTEGER", nil, nil, nil)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: Queries

    public func record(_ id: String) -> ItemRecord? {
        lock.withLock { fetch("SELECT * FROM items WHERE id = ?", [.text(id)]).first }
    }

    /// Every known item but the root, a page at a time in ID order, starting after `id`.
    public func records(after id: String, limit: Int, withXattrsOnly: Bool = false) -> [ItemRecord] {
        lock.withLock {
            fetch("SELECT * FROM items WHERE id > ? AND id <> ?\(withXattrsOnly ? " AND xattrs IS NOT NULL" : "") ORDER BY id LIMIT ?",
                  [.text(id), .text(rootID), .int(Int64(limit))])
        }
    }

    /// The files in a folder (no folders), in Finder's name order.
    public func files(in parentID: String) -> [ItemRecord] {
        lock.withLock { fetch("SELECT * FROM items WHERE parent = ? AND dir = 0", [.text(parentID)]) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// How many items this device knows.
    public func count() -> Int {
        lock.withLock {
            var count = 0
            query("SELECT count(*) FROM items", []) { count = Int(sqlite3_column_int64($0, 0)) }
            return count
        }
    }

    /// Everything directly in a folder.
    public func children(of parentID: String) -> [ItemRecord] {
        lock.withLock { fetch("SELECT * FROM items WHERE parent = ?", [.text(parentID)]) }
    }

    /// The item's path relative to the share root ("" for the root), or nil if the ID is unknown.
    public func path(of id: String) -> String? {
        lock.withLock {
            var components: [String] = []
            var current = id
            while current != rootID {
                guard components.count < 512,
                      let record = fetch("SELECT * FROM items WHERE id = ?", [.text(current)]).first
                else { return nil }
                components.append(record.name)
                current = record.parentID
            }
            return components.reversed().joined(separator: "/")
        }
    }

    /// The most recently listed folders, newest first.
    public func recentFolders(limit: Int) -> [String] {
        lock.withLock {
            var ids: [String] = []
            query("SELECT id FROM folders ORDER BY listed DESC LIMIT ?", [.int(Int64(limit))]) { statement in
                ids.append(String(cString: sqlite3_column_text(statement, 0)))
            }
            return ids
        }
    }

    /// Which of `ids` are known items.
    public func known(_ ids: some Collection<String>) -> Set<String> {
        matching(Array(ids), in: "items")
    }

    /// Which of `ids` are folders that first reached this device through the server's change feed and
    /// haven't been listed since: the system has never asked for their contents.
    public func unlisted(_ ids: some Collection<String>) -> Set<String> {
        matching(Array(ids), in: "unlisted")
    }

    /// Marks new folders from the change feed as never listed (see `unlisted`).
    public func markUnlisted(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            execute("BEGIN", [])
            for id in ids { execute("INSERT OR IGNORE INTO unlisted (id) VALUES (?)", [.text(id)]) }
            execute("COMMIT", [])
        }
    }

    private func matching(_ ids: [String], in table: String) -> Set<String> {
        lock.withLock {
            var found = Set<String>()
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = ids[start..<min(start + 500, ids.count)]
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                query("SELECT id FROM \(table) WHERE id IN (\(marks))", chunk.map { .text($0) }) { statement in
                    found.insert(String(cString: sqlite3_column_text(statement, 0)))
                }
            }
            return found
        }
    }

    // MARK: Updates

    /// Records a fresh listing of a folder and returns what changed since the last one.
    public func reconcile(parentID: String, listing: [RemoteItem]) -> Reconciliation {
        lock.withLock {
            let known = fetch("SELECT * FROM items WHERE parent = ?", [.text(parentID)])
            let knownByName = Dictionary(known.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            var result = Reconciliation(items: [], changed: [], deleted: [])
            var kept = Set<String>()

            for remote in listing {
                let existing = matchByFileID(remote.fileID, excluding: kept) ?? knownByName[remote.name].flatMap {
                    kept.contains($0.id) ? nil : $0
                }
                let record = ItemRecord(id: existing?.id ?? UUID().uuidString, parentID: parentID, remote: remote)
                kept.insert(record.id)
                result.items.append(record)
                if record != existing {
                    write(record)
                    result.changed.append(record)
                    if let existing, !record.isDirectory, existing.contentVersion != record.contentVersion {
                        result.contentChanged.insert(record.id)
                    }
                }
            }

            for record in known where !kept.contains(record.id) {
                delete(record.id)
                result.deleted.append(record.id)
            }
            execute("INSERT OR REPLACE INTO folders (id, listed) VALUES (?, ?)", [.text(parentID), .real(Date().timeIntervalSince1970)])
            execute("DELETE FROM unlisted WHERE id = ?", [.text(parentID)])
            return result
        }
    }

    /// Makes a folder's children exactly `records` (FaNG-server mode, where the server assigns the IDs)
    /// and reports what changed since the last time.
    public func replace(children records: [ItemRecord], of parentID: String) -> Reconciliation {
        lock.withLock {
            let known = Dictionary(fetch("SELECT * FROM items WHERE parent = ?", [.text(parentID)]).map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
            var result = Reconciliation(items: records, changed: [], deleted: [])
            let ids = Set(records.map(\.id))
            for record in records where known[record.id] != record {
                write(record)
                result.changed.append(record)
                if let existing = known[record.id], !record.isDirectory, existing.contentVersion != record.contentVersion {
                    result.contentChanged.insert(record.id)
                }
            }
            for id in known.keys where !ids.contains(id) {
                delete(id)
                result.deleted.append(id)
            }
            execute("INSERT OR REPLACE INTO folders (id, listed) VALUES (?, ?)", [.text(parentID), .real(Date().timeIntervalSince1970)])
            execute("DELETE FROM unlisted WHERE id = ?", [.text(parentID)])
            return result
        }
    }

    /// Records an item whose ID the server assigned, replacing whatever was known at its place.
    public func adopt(_ record: ItemRecord) {
        lock.withLock {
            for other in fetch("SELECT * FROM items WHERE parent = ? AND name = ?", [.text(record.parentID), .text(record.name)])
            where other.id != record.id {
                delete(other.id)
            }
            write(record)
        }
    }

    /// Saves many records in one transaction (a batch of changes from the server).
    public func save(_ records: [ItemRecord]) {
        lock.withLock {
            execute("BEGIN", [])
            records.forEach(write)
            execute("COMMIT", [])
        }
    }

    /// Removes many items (and what's below them) in one transaction.
    public func remove(_ ids: [String]) {
        lock.withLock {
            execute("BEGIN", [])
            ids.forEach(delete)
            execute("COMMIT", [])
        }
    }

    public func save(_ record: ItemRecord) {
        lock.withLock { write(record) }
    }

    /// Records an item that this device just created or found at a known place.
    /// With `reuseExisting`, a known item with the same parent and name keeps its ID;
    /// otherwise it is replaced by a new item with a new ID.
    public func adopt(_ remote: RemoteItem, parentID: String, reuseExisting: Bool) -> ItemRecord {
        lock.withLock {
            let existing = fetch("SELECT * FROM items WHERE parent = ? AND name = ?", [.text(parentID), .text(remote.name)])
            if !reuseExisting {
                existing.forEach { delete($0.id) }
            }
            let id = reuseExisting ? existing.first?.id : nil
            let record = ItemRecord(id: id ?? UUID().uuidString, parentID: parentID, remote: remote)
            write(record)
            return record
        }
    }

    /// Removes an item and everything below it.
    public func remove(_ id: String) {
        lock.withLock { delete(id) }
    }

    // MARK: SQLite

    private enum Value {
        case text(String), int(Int64), real(Double), null
    }

    private func matchByFileID(_ fileID: UInt64, excluding kept: Set<String>) -> ItemRecord? {
        guard fileID != 0 else { return nil }
        return fetch("SELECT * FROM items WHERE file_id = ?", [.int(Int64(bitPattern: fileID))])
            .first { !kept.contains($0.id) }
    }

    private func write(_ record: ItemRecord) {
        execute(
            "INSERT OR REPLACE INTO items (id, parent, name, dir, size, modified, created, file_id, version, tags, job, progress, xattrs, readonly) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .text(record.id), .text(record.parentID), .text(record.name), .int(record.isDirectory ? 1 : 0),
                .int(record.size), .real(record.modified.timeIntervalSince1970),
                .real(record.created.timeIntervalSince1970), .int(Int64(bitPattern: record.fileID)),
                record.serverVersion.map { .int($0) } ?? .null,
                record.tags.isEmpty ? .null : .text(record.tags.joined(separator: "\u{1F}")),
                record.job.map { .text($0) } ?? .null,
                record.progress.map { .int(Int64($0)) } ?? .null,
                record.xattrsText.map { .text($0) } ?? .null,
                record.readOnly ? .int(1) : .null,
            ]
        )
    }

    private func delete(_ id: String) {
        let sql = """
            WITH RECURSIVE tree(id) AS (SELECT ? UNION SELECT items.id FROM items JOIN tree ON items.parent = tree.id)
            DELETE FROM %@ WHERE id IN tree
            """
        execute(sql.replacingOccurrences(of: "%@", with: "folders"), [.text(id)])
        execute(sql.replacingOccurrences(of: "%@", with: "unlisted"), [.text(id)])
        execute(sql.replacingOccurrences(of: "%@", with: "items"), [.text(id)])
    }

    private func fetch(_ sql: String, _ values: [Value]) -> [ItemRecord] {
        var records: [ItemRecord] = []
        query(sql, values) { statement in
            let remote = RemoteItem(
                path: "",
                name: String(cString: sqlite3_column_text(statement, 2)),
                isDirectory: sqlite3_column_int(statement, 3) != 0,
                size: sqlite3_column_int64(statement, 4),
                modified: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                created: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                fileID: UInt64(bitPattern: sqlite3_column_int64(statement, 7))
            )
            var record = ItemRecord(
                id: String(cString: sqlite3_column_text(statement, 0)),
                parentID: String(cString: sqlite3_column_text(statement, 1)),
                remote: remote
            )
            if sqlite3_column_type(statement, 8) != SQLITE_NULL {
                record.serverVersion = sqlite3_column_int64(statement, 8)
            }
            if sqlite3_column_type(statement, 9) != SQLITE_NULL {
                record.tags = String(cString: sqlite3_column_text(statement, 9)).split(separator: "\u{1F}").map(String.init)
            }
            if sqlite3_column_type(statement, 10) == SQLITE_TEXT {
                record.job = String(cString: sqlite3_column_text(statement, 10))
                record.progress = sqlite3_column_type(statement, 11) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 11))
            }
            if sqlite3_column_count(statement) > 12, sqlite3_column_type(statement, 12) == SQLITE_TEXT {
                record.xattrs = ItemRecord.xattrs(fromText: String(cString: sqlite3_column_text(statement, 12)))
            }
            if sqlite3_column_count(statement) > 13, sqlite3_column_type(statement, 13) == SQLITE_INTEGER {
                record.readOnly = sqlite3_column_int64(statement, 13) != 0
            }
            records.append(record)
        }
        return records
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
    }

    private func execute(_ sql: String, _ values: [Value]) {
        query(sql, values) { _ in }
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
