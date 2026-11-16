import Foundation
import Logging
import PostgresNIO

/// An earlier contents of a file. `path` is the version file inside the share (under `.fang-versions`).
public struct Version: Sendable, Equatable, Codable {
    public var id: Int64
    public var item: UUID
    public var share: String
    public var path: String
    public var size: Int64
    public var mtimeNS: Int64
    public var contentVersion: Int64
    /// "version": the file's contents before a change; "branch": a conflicting edit that didn't become the file.
    public var kind: String
    public var created: Date
    /// A branch stays open until its conflict is resolved.
    public var resolved: Bool
    /// The device whose edit it was (a short form of its token), for grouping related conflicts.
    public var device: String?

    static let columns = "id, item, share, path, size, mtime_ns, content_version, kind, created, resolved, device"

    init(row: PostgresRow) throws {
        (id, item, share, path, size, mtimeNS, contentVersion, kind, created, resolved, device) =
            try row.decode((Int64, UUID, String, String, Int64, Int64, Int64, String, Date, Bool, String?).self)
    }
}

extension ItemStore {
    public func versions(of item: UUID) async throws -> [Version] {
        var versions: [Version] = []
        let rows = try await client.query(PostgresQuery(
            unsafeSQL: "SELECT \(Version.columns) FROM versions WHERE item = $1 ORDER BY id DESC",
            binds: { var b = PostgresBindings(); b.append(item); return b }()), logger: logger)
        for try await row in rows {
            versions.append(try Version(row: row))
        }
        return versions
    }

    /// Open conflicts: unresolved branches with their items, newest first.
    public func openBranches() async throws -> [Version] {
        var versions: [Version] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: """
            SELECT \(Version.columns.split(separator: ",").map { "v." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", "))
            FROM versions v JOIN items i ON i.id = v.item
            WHERE v.kind = 'branch' AND NOT v.resolved AND NOT i.deleted ORDER BY v.id DESC
            """), logger: logger)
        for try await row in rows {
            versions.append(try Version(row: row))
        }
        return versions
    }

    /// Marks an item's open branches resolved (they stay in its history).
    public func resolveBranches(of item: UUID, only version: Int64? = nil) async throws {
        if let version {
            try await client.query("UPDATE versions SET resolved = true WHERE id = \(version)", logger: logger)
        } else {
            try await client.query("UPDATE versions SET resolved = true WHERE item = \(item) AND kind = 'branch'", logger: logger)
        }
    }

    public func hasOpenBranches(_ item: UUID) async throws -> Bool {
        let rows = try await client.query("SELECT 1 FROM versions WHERE item = \(item) AND kind = 'branch' AND NOT resolved", logger: logger)
        for try await _ in rows { return true }
        return false
    }

    /// The versions of these items (an item and what's below it).
    public func versions(ofItems ids: [UUID]) async throws -> [Version] {
        var result: [Version] = []
        for start in stride(from: 0, to: ids.count, by: 10_000) {
            let batch = Array(ids[start..<min(start + 10_000, ids.count)])
            let rows = try await client.query(PostgresQuery(
                unsafeSQL: "SELECT \(Version.columns) FROM versions WHERE item = ANY($1)",
                binds: { var b = PostgresBindings(); b.append(batch); return b }()), logger: logger)
            for try await row in rows { result.append(try Version(row: row)) }
        }
        return result
    }

    /// A version file now lives at `path` in `share` (it followed its item there).
    public func moveVersion(_ id: Int64, share: String, path: String) async throws {
        try await client.query("UPDATE versions SET share = \(share), path = \(path) WHERE id = \(id)", logger: logger)
    }

    /// Every version, for the retention pass (oldest decisions are made per item).
    public func allVersions() async throws -> [Version] {
        var result: [Version] = []
        let rows = try await client.query(PostgresQuery(unsafeSQL: "SELECT \(Version.columns) FROM versions"), logger: logger)
        for try await row in rows { result.append(try Version(row: row)) }
        return result
    }

    /// Forgets these versions (their files are deleted by the caller).
    public func removeVersions(ids: [Int64]) async throws {
        for start in stride(from: 0, to: ids.count, by: 10_000) {
            let batch = Array(ids[start..<min(start + 10_000, ids.count)])
            try await client.query("DELETE FROM versions WHERE id = ANY(\(batch))", logger: logger)
        }
    }

    public func version(_ id: Int64) async throws -> Version? {
        let rows = try await client.query(PostgresQuery(
            unsafeSQL: "SELECT \(Version.columns) FROM versions WHERE id = $1",
            binds: { var b = PostgresBindings(); b.append(id); return b }()), logger: logger)
        for try await row in rows {
            return try Version(row: row)
        }
        return nil
    }

    @discardableResult
    public func addVersion(item: UUID, share: String, path: String, size: Int64, mtimeNS: Int64, contentVersion: Int64, kind: String, device: String? = nil) async throws -> Int64 {
        let rows = try await client.query("""
            INSERT INTO versions (item, share, path, size, mtime_ns, content_version, kind, device)
            VALUES (\(item), \(share), \(path), \(size), \(mtimeNS), \(contentVersion), \(kind), \(device)) RETURNING id
            """, logger: logger)
        for try await id in rows.decode(Int64.self) {
            return id
        }
        throw PostgresError.protocol("no version id")
    }
}

/// Where an item's versions are kept. A version is made by renaming the old contents aside, and restored by
/// cloning them back, so it has to be on the same filesystem as the file. A share can hold other filesystems
/// (a ZFS child dataset mounted inside it): each has its own hidden version folder at its top.
public enum VersionPlace {
    public static let folderName = ".fang-versions"

    /// The folder for the versions of the item at `itemPath`, both relative to the share. `filesystemRoot` is
    /// the top folder of the filesystem the item is on ("" when that's the share's own).
    public static func folder(itemPath: String, filesystemRoot: String) -> String {
        guard !filesystemRoot.isEmpty, itemPath.hasPrefix(filesystemRoot + "/") else { return folderName + "/" + itemPath }
        return filesystemRoot + "/" + folderName + "/" + itemPath.dropFirst(filesystemRoot.count + 1)
    }

    /// The top folder, relative to the share, of the filesystem the item's folder is on: the highest folder
    /// above the item that is still on the same device. `device` gives a folder's device number (nil if it
    /// can't be read).
    public static func filesystemRoot(itemPath: String, device: (String) -> UInt64?) -> String {
        var parts = itemPath.split(separator: "/").dropLast()
        guard let own = device(parts.joined(separator: "/")) else { return "" }
        while !parts.isEmpty {
            let above = parts.dropLast().joined(separator: "/")
            guard device(above) == own else { break }
            parts = parts.dropLast()
        }
        return parts.joined(separator: "/")
    }
}
