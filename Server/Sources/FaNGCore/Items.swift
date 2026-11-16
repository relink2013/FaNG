import Foundation
import Logging
import PostgresNIO

/// A file or folder FaNG tracks. `id` is FaNG's ID, also stored in the file's `user.fang.id` xattr.
/// `path` is relative to the share root ("" for the root, whose `parent` is nil).
public struct Item: Sendable, Equatable, Codable {
    public var id: UUID
    /// The share's name inside FaNG; a home share ("~name") is sent to its owner as "Home" (see `encode(to:)`).
    public var share: String
    public var parent: UUID?
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    /// Modification time in nanoseconds since 1970.
    public var mtimeNS: Int64
    public var inode: Int64
    /// Changes whenever the bytes change.
    public var contentVersion: Int64
    /// Changes whenever the name or location changes.
    public var metadataVersion: Int64
    public var deleted: Bool
    /// The change number of the item's last change.
    public var seq: Int64
    /// In the trash (only the item that was deleted; what's below it moved along). `path` is then under
    /// `.fang-trash`, and `originalPath` is where it was.
    public var trashed: Bool
    public var trashedAt: Date?
    public var originalPath: String?
    /// Finder tags, each "name\ncolor" (color 0–7; 6 is red).
    public var tags: [String]
    /// Set while a server copy makes this item ("copying", with `progress` in percent) or after it failed
    /// ("failed"); nil for every other item.
    public var jobState: String?
    public var progress: Int?
    /// Client metadata kept as extended attributes (folder symbols and emoji, …): name → value. Nil when none.
    public var xattrs: [String: Data]?
    /// What the asking user may do with it ("read" or "write"), set by the API per request.
    public var access: String?

    /// Where the item is (or was, for something in the trash) inside its share: what permissions apply to.
    public var permissionPath: String {
        if trashed, let originalPath { return originalPath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.first == ".fang-trash", parts.count > 2 { return parts.dropFirst(2).joined(separator: "/") }
        return path
    }

    static let columns = "id, share, parent, name, path, is_dir, size, mtime_ns, inode, content_version, metadata_version, deleted, seq, trashed, trashed_at, original_path, tags, job_state, progress, xattrs"

    /// As it's sent: to the user an API request is for (`SharePresentation`), their home share is "Home", and so
    /// is the name of its root folder (what Files and Finder show). Everything else as it is.
    public func encode(to encoder: Encoder) throws {
        let user = SharePresentation.user
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(Share.presented(share, to: user), forKey: .share)
        try container.encodeIfPresent(parent, forKey: .parent)
        try container.encode(path.isEmpty && name == share ? Share.presented(name, to: user) : name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(isDirectory, forKey: .isDirectory)
        try container.encode(size, forKey: .size)
        try container.encode(mtimeNS, forKey: .mtimeNS)
        try container.encode(inode, forKey: .inode)
        try container.encode(contentVersion, forKey: .contentVersion)
        try container.encode(metadataVersion, forKey: .metadataVersion)
        try container.encode(deleted, forKey: .deleted)
        try container.encode(seq, forKey: .seq)
        try container.encode(trashed, forKey: .trashed)
        try container.encodeIfPresent(trashedAt, forKey: .trashedAt)
        try container.encodeIfPresent(originalPath, forKey: .originalPath)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(jobState, forKey: .jobState)
        try container.encodeIfPresent(progress, forKey: .progress)
        try container.encodeIfPresent(xattrs, forKey: .xattrs)
        try container.encodeIfPresent(access, forKey: .access)
    }

    init(row: PostgresRow) throws {
        let cells = try row.decode((UUID, String, UUID?, String, String, Bool, Int64, Int64, Int64, Int64, Int64, Bool, Int64, Bool, Date?, String?, [String], String?, Int32?, String).self)
        (id, share, parent, name, path, isDirectory, size, mtimeNS, inode, contentVersion, metadataVersion, deleted, seq) =
            (cells.0, cells.1, cells.2, cells.3, cells.4, cells.5, cells.6, cells.7, cells.8, cells.9, cells.10, cells.11, cells.12)
        (trashed, trashedAt, originalPath, tags) = (cells.13, cells.14, cells.15, cells.16)
        (jobState, progress) = (cells.17, cells.18.map(Int.init))
        let metadata = Metadata.decode(cells.19)
        xattrs = metadata.isEmpty ? nil : metadata
    }
}

/// Client metadata (extended attributes) as the items table keeps it: JSON, names sorted, values in base64,
/// so equal metadata is an equal string. "" when there's none.
public enum Metadata {
    public static func encode(_ metadata: [String: Data]) -> String {
        guard !metadata.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(metadata.mapValues { $0.base64EncodedString() })).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    public static func decode(_ text: String) -> [String: Data] {
        guard !text.isEmpty, let strings = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) else { return [:] }
        return strings.compactMapValues { Data(base64Encoded: $0) }
    }
}

/// What the filesystem says about an entry right now.
public struct Observed: Sendable {
    public var id: UUID
    public var parent: UUID?
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var mtimeNS: Int64
    public var inode: Int64
    public var tags: [String] = []
    /// Client metadata (see `Item.xattrs`).
    public var xattrs: [String: Data] = [:]

    public init(id: UUID, parent: UUID?, name: String, path: String, isDirectory: Bool, size: Int64, mtimeNS: Int64, inode: Int64) {
        self.id = id
        self.parent = parent
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.mtimeNS = mtimeNS
        self.inode = inode
    }
}

/// Reads and writes items. Writes give every change the next change number.
public struct ItemStore: Sendable {
    public let client: PostgresClient
    public let logger: Logger

    public init(client: PostgresClient, logger: Logger) {
        self.client = client
        self.logger = logger
    }

    public func epoch() async throws -> UUID {
        for try await epoch in try await client.query("SELECT epoch FROM server", logger: logger).decode(UUID.self) {
            return epoch
        }
        throw PostgresError.protocol("no server epoch")
    }

    public func item(_ id: UUID) async throws -> Item? {
        try await first(PostgresQuery(unsafeSQL: "SELECT \(Item.columns) FROM items WHERE id = $1", binds: try binds(id)))
    }

    public func liveItem(share: String, path: String) async throws -> Item? {
        try await first(PostgresQuery(unsafeSQL: "SELECT \(Item.columns) FROM items WHERE share = $1 AND path = $2 AND NOT deleted", binds: try binds(share, path)))
    }

    /// Live children ordered by name, starting after `after` (a name), at most `limit`.
    public func children(of parent: UUID, after: String?, limit: Int) async throws -> [Item] {
        try await all(PostgresQuery(
            unsafeSQL: "SELECT \(Item.columns) FROM items WHERE parent = $1 AND NOT deleted AND NOT trashed AND name > $2 ORDER BY name LIMIT $3",
            binds: try binds(parent, after ?? "", limit)))
    }

    /// Items of `share` changed after change number `since`, in order, at most `limit` (deleted ones included).
    public func changes(share: String, since: Int64, limit: Int) async throws -> [Item] {
        try await all(PostgresQuery(
            unsafeSQL: "SELECT \(Item.columns) FROM items WHERE share = $1 AND seq > $2 ORDER BY seq LIMIT $3",
            binds: try binds(share, since, limit)))
    }

    /// The latest change number in any share.
    public func latestChange() async throws -> Int64 {
        for try await latest in try await client.query("SELECT coalesce(max(seq), 0) FROM items", logger: logger).decode(Int64.self) {
            return latest
        }
        return 0
    }

    /// The share's latest change number (0 before its first scan).
    public func latestChange(share: String) async throws -> Int64 {
        for try await latest in try await client.query("SELECT coalesce(max(seq), 0) FROM items WHERE share = \(share)", logger: logger).decode(Int64.self) {
            return latest
        }
        return 0
    }

    /// The share's root folder, or nil before its first scan.
    public func root(of share: String) async throws -> Item? {
        try await liveItem(share: share, path: "")
    }

    /// What's in a share's trash (the items that were deleted, not what's below them), oldest first.
    public func trash(share: String) async throws -> [Item] {
        try await all(PostgresQuery(
            unsafeSQL: "SELECT \(Item.columns) FROM items WHERE share = $1 AND trashed AND NOT deleted ORDER BY trashed_at",
            binds: try binds(share)))
    }

    /// Trashed items older than `cutoff`, every share.
    public func expiredTrash(before cutoff: Date) async throws -> [Item] {
        try await all(PostgresQuery(
            unsafeSQL: "SELECT \(Item.columns) FROM items WHERE trashed AND NOT deleted AND trashed_at < $1",
            binds: try binds(cutoff)))
    }

    /// Records that an item moved into the trash at `trashPath` (what's below it moves along).
    /// Records an item (and what's below it) as moved into the trash. `inside` runs last in the transaction
    /// (the rename on disk), and the transaction commits only if it succeeds.
    public func markTrashed(_ id: UUID, share: String, trashPath: String, originalPath: String,
                            inside: @Sendable () throws -> Void = {}) async throws {
        RequestTrace.step("db markTrashed")
        try await client.withTransaction(logger: logger) { connection in
            try await connection.query("""
                UPDATE items SET trashed = true, trashed_at = now(), original_path = \(originalPath),
                    path = \(trashPath), seq = nextval('change_seq')
                WHERE id = \(id)
                """, logger: logger)
            let oldPrefix = originalPath + "/"
            try await connection.query("""
                UPDATE items SET path = \(trashPath) || substr(path, \(oldPrefix.count)::integer), seq = nextval('change_seq')
                WHERE share = \(share) AND NOT deleted AND path LIKE \(Self.likePrefix(oldPrefix))
                """, logger: logger)
            try inside()
        }
    }

    /// The IDs of an item and everything below it.
    public func subtree(_ item: Item) async throws -> [UUID] {
        var ids: [UUID] = []
        let prefix = item.path + "/"
        let rows = try await client.query("""
            SELECT id FROM items WHERE share = \(item.share) AND NOT deleted
            AND (id = \(item.id) OR path LIKE \(Self.likePrefix(prefix)))
            """, logger: logger)
        for try await id in rows.decode(UUID.self) {
            ids.append(id)
        }
        return ids
    }

    /// Versions of these items (to delete with them), and forgets them.
    public func removeVersions(of ids: [UUID]) async throws -> [Version] {
        // One statement per 10,000 items (one per item made purging a folder of 170,000 take minutes).
        var removed: [Version] = []
        for start in stride(from: 0, to: ids.count, by: 10_000) {
            let batch = Array(ids[start..<min(start + 10_000, ids.count)])
            let rows = try await client.query(PostgresQuery(
                unsafeSQL: "DELETE FROM versions WHERE item = ANY($1) RETURNING \(Version.columns)",
                binds: { var b = PostgresBindings(); b.append(batch); return b }()), logger: logger)
            for try await row in rows {
                removed.append(try Version(row: row))
            }
        }
        return removed
    }

    /// An item moved by one rename (a move, or a put back from the trash), with everything below it: its
    /// records follow in two updates (scanning a folder of 170,000 entries again took minutes). It leaves
    /// the trash if it was in it.
    public func markMoved(_ id: UUID, from share: String, _ oldPath: String, to newShare: String, _ newPath: String,
                          parent: UUID?, name: String) async throws {
        RequestTrace.step("db markMoved")
        try await client.withTransaction(logger: logger) { connection in
            try await connection.query("""
                UPDATE items SET share = \(newShare), path = \(newPath), parent = \(parent), name = \(name),
                    trashed = false, trashed_at = NULL, original_path = NULL,
                    metadata_version = metadata_version + 1, seq = nextval('change_seq')
                WHERE id = \(id)
                """, logger: logger)
            let oldPrefix = oldPath + "/"
            try await connection.query("""
                UPDATE items SET share = \(newShare), path = \(newPath) || substr(path, \(oldPrefix.count)::integer),
                    seq = nextval('change_seq')
                WHERE share = \(share) AND NOT deleted AND path LIKE \(Self.likePrefix(oldPrefix))
                """, logger: logger)
        }
    }
    /// What a scan compares the disk with: each live item of a share (outside FaNG's own folders and the
    /// trash), keyed by path.
    public struct Recorded: Sendable {
        public var id: UUID
        public var parent: UUID?
        public var isDirectory: Bool
        public var size: Int64
        public var mtimeNS: Int64
        public var inode: Int64
        public var tags: [String]
        public var xattrs: String
    }

    /// Every live item of a share as the scan compares it, in one query (a scan of 500,000 entries asked
    /// the database three times per entry, one entry at a time, and took 23 minutes).
    public func recorded(share: String, under folder: String = "") async throws -> [String: Recorded] {
        var result: [String: Recorded] = [:]
        let prefix = folder.isEmpty ? "%" : Self.likePrefix(folder + "/")
        let rows = try await client.query("""
            SELECT path, id, parent, is_dir, size, mtime_ns, inode, tags, xattrs FROM items
            WHERE share = \(share) AND NOT deleted AND NOT trashed AND job_state IS NULL
                AND left(path, 6) <> '.fang-' AND position('/.fang-' in path) = 0
                AND (path = \(folder) OR path LIKE \(prefix) OR \(folder) = '')
            """, logger: logger)
        for try await (path, id, parent, isDirectory, size, mtime, inode, tags, xattrs) in rows.decode((String, UUID, UUID?, Bool, Int64, Int64, Int64, [String], String).self) {
            result[path] = Recorded(id: id, parent: parent, isDirectory: isDirectory, size: size, mtimeNS: mtime, inode: inode, tags: tags, xattrs: xattrs)
        }
        return result
    }

    /// Marks the live items at these paths deleted, in batches. Returns how many it marked.
    @discardableResult
    public func markDeleted(share: String, paths: [String]) async throws -> Int {
        var count = 0
        for start in stride(from: 0, to: paths.count, by: 10_000) {
            let batch = Array(paths[start..<min(start + 10_000, paths.count)])
            let rows = try await client.query("""
                UPDATE items SET deleted = true, seq = nextval('change_seq')
                WHERE share = \(share) AND NOT deleted AND path = ANY(\(batch)) RETURNING id
                """, logger: logger)
            for try await _ in rows { count += 1 }
        }
        return count
    }

    /// The live item IDs and paths of a share (outside FaNG's own folders), for a full rescan to find
    /// what's gone.
    public func livePaths(share: String) async throws -> [String: UUID] {
        var paths: [String: UUID] = [:]
        let rows = try await client.query("SELECT path, id FROM items WHERE share = \(share) AND NOT deleted AND NOT trashed AND job_state IS NULL AND left(path, 6) <> '.fang-' AND position('/.fang-' in path) = 0", logger: logger)
        for try await (path, id) in rows.decode((String, UUID).self) {
            paths[path] = id
        }
        return paths
    }

    /// Records what's on disk. A new ID is inserted; a known one is updated, and gets a new change number
    /// only if something changed. Moving a folder moves the paths below it. Another live item at the same
    /// path (an older file the new one replaced) is marked deleted. Returns true if anything changed.
    @discardableResult
    public func record(_ observed: Observed, share: String) async throws -> Bool {
        RequestTrace.step("db record: lease")
        defer { RequestTrace.step("db record: done") }
        return try await client.withTransaction(logger: logger) { connection in
            RequestTrace.step("db record: queries")
            // Something else living at this path is gone: it was replaced.
            try await connection.query("""
                UPDATE items SET deleted = true, seq = nextval('change_seq')
                WHERE share = \(share) AND path = \(observed.path) AND NOT deleted AND id <> \(observed.id)
                """, logger: logger)
            RequestTrace.step("db record: reading")
            var existing: Item?
            for try await row in try await connection.query(
                PostgresQuery(unsafeSQL: "SELECT \(Item.columns) FROM items WHERE id = $1 FOR UPDATE", binds: try binds(observed.id)), logger: logger) {
                existing = try Item(row: row)
            }
            guard let existing else {
                try await connection.query("""
                    INSERT INTO items (id, share, parent, name, path, is_dir, size, mtime_ns, inode, tags, xattrs, seq)
                    VALUES (\(observed.id), \(share), \(observed.parent), \(observed.name), \(observed.path),
                            \(observed.isDirectory), \(observed.size), \(observed.mtimeNS), \(observed.inode),
                            \(observed.tags), \(Metadata.encode(observed.xattrs)), nextval('change_seq'))
                    """, logger: logger)
                return true
            }
            // A copy that just finished: its item now exists on disk, and stops being a job.
            let moved = existing.share != share || existing.parent != observed.parent || existing.name != observed.name
                || existing.deleted || existing.trashed || existing.tags != observed.tags || existing.jobState != nil
                || (existing.xattrs ?? [:]) != observed.xattrs
            let changedContent = !observed.isDirectory && (existing.size != observed.size || existing.mtimeNS != observed.mtimeNS)
            let changedOther = existing.inode != observed.inode || existing.path != observed.path || existing.isDirectory != observed.isDirectory
            guard moved || changedContent || changedOther else { return false }
            RequestTrace.step("db record: updating")
            try await connection.query("""
                UPDATE items SET share = \(share), parent = \(observed.parent), name = \(observed.name),
                    path = \(observed.path), is_dir = \(observed.isDirectory), size = \(observed.size),
                    mtime_ns = \(observed.mtimeNS), inode = \(observed.inode), tags = \(observed.tags),
                    xattrs = \(Metadata.encode(observed.xattrs)),
                    content_version = content_version + \(changedContent ? 1 : 0),
                    metadata_version = metadata_version + \(moved ? 1 : 0),
                    deleted = false, trashed = false, trashed_at = NULL, original_path = NULL,
                    job_state = NULL, progress = NULL, job_error = NULL, seq = nextval('change_seq')
                WHERE id = \(observed.id)
                """, logger: logger)
            RequestTrace.step("db record: updated")
            if existing.isDirectory, existing.path != observed.path, !existing.deleted {
                // Paths below a moved folder change too; their parents and versions don't.
                let oldPrefix = existing.path + "/"
                try await connection.query("""
                    UPDATE items SET path = \(observed.path) || substr(path, \(oldPrefix.count)::integer),
                        seq = nextval('change_seq')
                    WHERE share = \(existing.share) AND NOT deleted AND path LIKE \(Self.likePrefix(oldPrefix))
                    """, logger: logger)
            }
            return true
        }
    }

    /// Marks the live item at `path` and everything below it deleted. Returns how many items it marked.
    @discardableResult
    public func markDeleted(share: String, path: String) async throws -> Int {
        let prefix = path + "/"
        RequestTrace.step("db markDeleted")
        let rows = try await client.query("""
            UPDATE items SET deleted = true, seq = nextval('change_seq')
            WHERE share = \(share) AND NOT deleted AND (path = \(path) OR path LIKE \(Self.likePrefix(prefix)))
            RETURNING id
            """, logger: logger)
        var count = 0
        for try await _ in rows { count += 1 }
        return count
    }

    // MARK: Retention of deleted records

    /// Notes the change number reached now, at most once a day: deleted records are kept for `days` after
    /// their change, measured with these marks.
    public func markChanges() async throws {
        try await client.query("""
            INSERT INTO change_marks (seq)
            SELECT coalesce(max(seq), 0) FROM items
            WHERE NOT EXISTS (SELECT 1 FROM change_marks WHERE at > now() - interval '20 hours')
            """, logger: logger)
    }

    /// Before the first mark exists, everything deleted until now counts as a day short of the retention:
    /// it goes a day later (a device that hasn't synced by then lists everything again, which is correct).
    public func seedChangeMarks(retentionDays: Int) async throws {
        try await client.query("""
            INSERT INTO change_marks (at, seq)
            SELECT now() - make_interval(days => \(retentionDays - 1)::int), coalesce(max(seq), 0) FROM items
            WHERE NOT EXISTS (SELECT 1 FROM change_marks)
            """, logger: logger)
    }

    /// The change number reached `days` ago (nil if no mark is that old).
    public func changeMark(olderThanDays days: Int) async throws -> Int64? {
        let rows = try await client.query("""
            SELECT seq FROM change_marks WHERE at < now() - make_interval(days => \(days)::int) ORDER BY at DESC LIMIT 1
            """, logger: logger)
        for try await seq in rows.decode(Int64.self) { return seq }
        return nil
    }

    /// Up to `limit` deleted records changed before `seq`: removed, with their IDs returned.
    public func removeDeletedRecords(before seq: Int64, limit: Int) async throws -> [UUID] {
        let rows = try await client.query("""
            DELETE FROM items WHERE id IN (SELECT id FROM items WHERE deleted AND seq < \(seq) LIMIT \(limit)) RETURNING id
            """, logger: logger)
        var ids: [UUID] = []
        for try await id in rows.decode(UUID.self) { ids.append(id) }
        return ids
    }

    /// Anchors before `seq` can't be served any more (the deletions they'd need are gone); older marks go.
    public func setPrunedBelow(_ seq: Int64) async throws {
        try await client.query("UPDATE server SET pruned_below = greatest(pruned_below, \(seq))", logger: logger)
        try await client.query("DELETE FROM change_marks WHERE seq < \(seq)", logger: logger)
    }

    /// The oldest change number an anchor may start from.
    public func prunedBelow() async throws -> Int64 {
        for try await seq in try await client.query("SELECT pruned_below FROM server", logger: logger).decode(Int64.self) { return seq }
        return 0
    }

    /// IDs of the live items below a folder (by path), for versions that follow a move.
    public func ids(share: String, under path: String) async throws -> [(id: UUID, path: String)] {
        var result: [(UUID, String)] = []
        let rows = try await client.query("""
            SELECT id, path FROM items WHERE share = \(share) AND NOT deleted
            AND (path = \(path) OR path LIKE \(Self.likePrefix(path + "/")))
            """, logger: logger)
        for try await (id, path) in rows.decode((UUID, String).self) { result.append((id, path)) }
        return result
    }

    // MARK: Copy jobs

    /// The item a copy makes, recorded before anything exists on disk: clients see it at once, at its final
    /// name, with the copy's progress.
    public func insertPlaceholder(id: UUID, share: String, parent: UUID, name: String, path: String, isDirectory: Bool,
                                  size: Int64, mtimeNS: Int64, tags: [String]) async throws -> Item {
        try await client.query("""
            INSERT INTO items (id, share, parent, name, path, is_dir, size, mtime_ns, inode, tags, job_state, progress, seq)
            VALUES (\(id), \(share), \(parent), \(name), \(path), \(isDirectory), \(size), \(mtimeNS), 0, \(tags),
                    'copying', 0, nextval('change_seq'))
            """, logger: logger)
        guard let item = try await item(id) else { throw PostgresError.protocol("placeholder missing") }
        return item
    }

    /// A running copy's progress (a new change number, so clients hear of it).
    public func setProgress(_ id: UUID, _ percent: Int) async throws {
        try await client.query("""
            UPDATE items SET progress = \(Int32(percent)), metadata_version = metadata_version + 1, seq = nextval('change_seq')
            WHERE id = \(id) AND job_state = 'copying'
            """, logger: logger)
    }

    /// Marks a copy failed, with the reason (shown until the item is deleted).
    public func failCopy(_ id: UUID, reason: String) async throws {
        try await client.query("""
            UPDATE items SET job_state = 'failed', progress = NULL, job_error = \(reason), metadata_version = metadata_version + 1,
                seq = nextval('change_seq')
            WHERE id = \(id) AND job_state = 'copying'
            """, logger: logger)
    }

    /// Copies that failed and haven't been deleted yet, with why.
    public func failedCopies() async throws -> [(item: Item, reason: String?)] {
        let rows = try await client.query("SELECT id, job_error FROM items WHERE job_state = 'failed' AND NOT deleted", logger: logger)
        var failed: [(UUID, String?)] = []
        for try await (id, reason) in rows.decode((UUID, String?).self) { failed.append((id, reason)) }
        var result: [(item: Item, reason: String?)] = []
        for (id, reason) in failed {
            if let item = try await item(id) { result.append((item, reason)) }
        }
        return result
    }

    /// At startup no copy runs: the ones that were running when the server stopped failed.
    @discardableResult
    public func failInterruptedCopies() async throws -> Int {
        let rows = try await client.query("""
            UPDATE items SET job_state = 'failed', progress = NULL, job_error = 'The server restarted while copying.',
                metadata_version = metadata_version + 1, seq = nextval('change_seq')
            WHERE job_state = 'copying' RETURNING id
            """, logger: logger)
        var count = 0
        for try await _ in rows { count += 1 }
        return count
    }

    /// Records new items in batches (a finished copy: every entry is new, with the ID written on it).
    public func insertNew(_ observed: [Observed], share: String) async throws {
        let columns = 11
        for start in stride(from: 0, to: observed.count, by: 500) {
            let batch = observed[start..<min(start + 500, observed.count)]
            var bindings = PostgresBindings()
            var rows: [String] = []
            for (index, item) in batch.enumerated() {
                let base = index * columns
                rows.append("(" + (1...columns).map { "$\(base + $0)" }.joined(separator: ", ") + ", nextval('change_seq'))")
                bindings.append(item.id)
                bindings.append(share)
                bindings.append(item.parent)
                bindings.append(item.name)
                bindings.append(item.path)
                bindings.append(item.isDirectory)
                bindings.append(item.size)
                bindings.append(item.mtimeNS)
                bindings.append(item.inode)
                bindings.append(item.tags)
                bindings.append(Metadata.encode(item.xattrs))
            }
            try await client.query(PostgresQuery(unsafeSQL: """
                INSERT INTO items (id, share, parent, name, path, is_dir, size, mtime_ns, inode, tags, xattrs, seq)
                VALUES \(rows.joined(separator: ", ")) ON CONFLICT DO NOTHING
                """, binds: bindings), logger: logger)
        }
    }

    // MARK: Helpers

    /// A LIKE pattern matching every path that starts with `prefix` (so an index can serve it).
    static func likePrefix(_ prefix: String) -> String {
        prefix.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    private func first(_ query: PostgresQuery) async throws -> Item? {
        RequestTrace.step("db first")
        for try await row in try await client.query(query, logger: logger) {
            return try Item(row: row)
        }
        return nil
    }

    private func all(_ query: PostgresQuery) async throws -> [Item] {
        var items: [Item] = []
        for try await row in try await client.query(query, logger: logger) {
            items.append(try Item(row: row))
        }
        return items
    }

    private func binds(_ values: any PostgresEncodable & Sendable...) throws -> PostgresBindings {
        var bindings = PostgresBindings()
        for value in values {
            try bindings.append(value)
        }
        return bindings
    }
}
