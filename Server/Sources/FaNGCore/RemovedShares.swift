import Foundation
import Logging
import PostgresNIO

/// A share taken out of the shares file leaves its records behind: its items, versions, permission rules and,
/// through them, thumbnails. They're kept for a while (`removedShareDays`) in case the share comes back (adding
/// it again keeps everything), then removed; the admin page can remove them sooner. Only FaNG's own records
/// go: the share's files, and its .fang-trash and .fang-versions folders on disk, are never touched.
public struct RemovedShare: Codable, Sendable {
    public var name: String
    public var since: Date
    public var items: Int64
    public var versions: Int64
}

extension ItemStore {
    public static let removedShareDays = Int(ProcessInfo.processInfo.environment["FANG_REMOVED_SHARE_DAYS"] ?? "") ?? 7

    /// Notes the shares that have records but aren't served any more, and forgets those that came back.
    public func noteRemovedShares(current: [String]) async throws {
        try await client.withTransaction(logger: logger) { connection in
            try await connection.query("DELETE FROM removed_shares WHERE name = ANY(\(current))", logger: logger)
            try await connection.query("""
                INSERT INTO removed_shares (name)
                SELECT name FROM (
                    SELECT DISTINCT share AS name FROM items
                    UNION SELECT DISTINCT share FROM versions
                    UNION SELECT DISTINCT share FROM acl_rules
                ) s WHERE NOT (name = ANY(\(current)))
                ON CONFLICT (name) DO NOTHING
                """, logger: logger)
        }
    }

    public func removedShares() async throws -> [RemovedShare] {
        var list: [RemovedShare] = []
        let rows = try await client.query("""
            SELECT r.name, r.since,
                   (SELECT count(*) FROM items i WHERE i.share = r.name),
                   (SELECT count(*) FROM versions v WHERE v.share = r.name)
            FROM removed_shares r ORDER BY r.since
            """, logger: logger)
        for try await (name, since, items, versions) in rows.decode((String, Date, Int64, Int64).self) {
            list.append(RemovedShare(name: name, since: since, items: items, versions: versions))
        }
        return list
    }

    /// Removes a removed share's records (only one that's noted as removed: a served share is refused).
    /// Thumbnails follow within the hour (fang-thumbs removes those whose items are gone).
    @discardableResult
    public func purgeRemovedShare(_ name: String) async throws -> Bool {
        try await client.withTransaction(logger: logger) { connection in
            var noted = false
            for try await _ in try await connection.query("SELECT 1 FROM removed_shares WHERE name = \(name) FOR UPDATE", logger: logger).decode(Int.self) {
                noted = true
            }
            guard noted else { return false }
            try await connection.query("DELETE FROM items WHERE share = \(name)", logger: logger)
            try await connection.query("DELETE FROM versions WHERE share = \(name)", logger: logger)
            try await connection.query("DELETE FROM acl_rules WHERE share = \(name)", logger: logger)
            try await connection.query("""
                DELETE FROM thumbnail_copies c WHERE NOT EXISTS (SELECT 1 FROM items i WHERE i.id = c.item)
                """, logger: logger)
            try await connection.query("DELETE FROM removed_shares WHERE name = \(name)", logger: logger)
            try await connection.query("UPDATE server SET acl_version = acl_version + 1", logger: logger)
            return true
        }
    }

    /// Removes at once the records of removed shares whose folder overlaps a share served now (homes
    /// becoming each user's Home, say), and remembers where every served share is for next time.
    public func purgeOverlappingRemovedShares(current: [Share]) async throws -> [String] {
        var known: [String: String] = [:]
        for try await (name, path) in try await client.query("SELECT name, path FROM share_paths", logger: logger).decode((String, String).self) {
            known[name] = path
        }
        var purged: [String] = []
        for removed in try await removedShares() {
            guard let old = known[removed.name] else { continue }
            if current.contains(where: { $0.path == old || $0.path.hasPrefix(old + "/") || old.hasPrefix($0.path + "/") }),
               try await purgeRemovedShare(removed.name) {
                purged.append(removed.name)
            }
        }
        for share in current {
            try await client.query("""
                INSERT INTO share_paths (name, path) VALUES (\(share.name), \(share.path))
                ON CONFLICT (name) DO UPDATE SET path = excluded.path
                """, logger: logger)
        }
        return purged
    }

    /// Removes the records of shares removed longer ago than the retention. Returns their names.
    public func purgeExpiredRemovedShares() async throws -> [String] {
        var names: [String] = []
        let rows = try await client.query("""
            SELECT name FROM removed_shares WHERE since < now() - make_interval(days => \(Self.removedShareDays)::int)
            """, logger: logger)
        for try await name in rows.decode(String.self) { names.append(name) }
        for name in names { try await purgeRemovedShare(name) }
        return names
    }
}
