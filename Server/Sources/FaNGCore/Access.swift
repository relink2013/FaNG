import Foundation
import Logging
import PostgresNIO

/// What a user may do with an item.
public enum Access: String, Codable, Sendable, Comparable {
    case none, read, write

    private var rank: Int { self == .none ? 0 : self == .read ? 1 : 2 }
    public static func < (a: Access, b: Access) -> Bool { a.rank < b.rank }
}

/// One permission rule: `principal` ("everyone", "group:<name>" or "user:<name>") gets `access` on `path` in `share` ("" is the
/// share's root) and everything below it, unless a rule further down says otherwise.
public struct AccessRule: Codable, Sendable, Hashable {
    public var share: String
    public var path: String
    public var principal: String
    public var access: Access

    public init(share: String, path: String, principal: String, access: Access) {
        (self.share, self.path, self.principal, self.access) = (share, path, principal, access)
    }
}

/// FaNG's permissions, evaluated in memory (Samba asks for every file it opens).
///
/// The closest rule wins: looking from the item up to its share's root, the first folder (or the item itself)
/// with a rule for the user decides. At the same place a rule for the user beats one for a group they're in,
/// which beats one for everyone; when several of their groups have a rule there, "no access" from any of them
/// wins, otherwise the most any of them gives. With no
/// rule anywhere on the way, the user has no access: a new user sees nothing until given something (their home
/// folder, when home folders are on). A folder on the way to something the user may open is passed through:
/// it shows read only, with only what leads there in it, so a share where a user has nothing at all is hidden
/// from them entirely. Nothing is ever written to the files: Samba gets the result as the item's ACL, and the
/// API checks the same rules.
public struct AccessRules: Sendable {
    /// share → path → principal → access
    private var rules: [String: [String: [String: Access]]] = [:]
    /// share → principal → every folder above a path where that principal is given read or write.
    private var throughPaths: [String: [String: Set<String>]] = [:]
    public private(set) var all: [AccessRule] = []
    /// Rules that come from home folders (shown as such, and kept in step with the users by fang-storaged).
    public private(set) var homes: Set<AccessRule> = []
    /// user → the principals of the groups they're in.
    private var groups: [String: [String]] = [:]

    public init(_ list: [AccessRule] = [], homes: Set<AccessRule> = [], memberships: [String: Set<String>] = [:]) {
        all = list
        self.homes = homes
        groups = memberships.mapValues { $0.sorted().map { "group:" + $0 } }
        for rule in list {
            rules[rule.share, default: [:]][rule.path, default: [:]][rule.principal] = rule.access
            guard rule.access != .none, !rule.path.isEmpty else { continue }
            var parts = rule.path.split(separator: "/").dropLast()
            while true {
                throughPaths[rule.share, default: [:]][rule.principal, default: []].insert(parts.joined(separator: "/"))
                if parts.isEmpty { break }
                parts = parts.dropLast()
            }
        }
    }

    public var isEmpty: Bool { all.isEmpty }

    /// What `user` may do at `path`, including passing through folders on the way to what they may open.
    public func access(user: String, share: String, path: String) -> Access {
        let own = ruled(user: user, share: share, path: path)
        if own == .none, isPassedThrough(user: user, share: share, path: path) { return .read }
        return own
    }

    /// Whether `path` only shows because something below it is open to `user` (read only, the rest hidden).
    public func isPassedThrough(user: String, share: String, path: String) -> Bool {
        guard let byPrincipal = throughPaths[share] else { return false }
        if byPrincipal["user:" + user]?.contains(path) == true || byPrincipal["everyone"]?.contains(path) == true { return true }
        return groups[user]?.contains { byPrincipal[$0]?.contains(path) == true } ?? false
    }

    /// What the closest rule says, without passing through.
    public func ruled(user: String, share: String, path: String) -> Access {
        guard let byPath = rules[share] else { return .none }
        var current = path
        while true {
            if let here = byPath[current] {
                if let own = here["user:" + user] { return own }
                if let mine = groups[user] {
                    var fromGroups: Access?
                    for group in mine {
                        guard let access = here[group] else { continue }
                        fromGroups = fromGroups.map { $0 == .none || access == .none ? .none : max($0, access) } ?? access
                    }
                    if let fromGroups { return fromGroups }
                }
                if let everyone = here["everyone"] { return everyone }
            }
            if current.isEmpty { return .none }
            current = current.split(separator: "/").dropLast().joined(separator: "/")
        }
    }

    /// The rules set exactly at `path` (not inherited).
    public func rules(share: String, path: String) -> [String: Access] {
        rules[share]?[path] ?? [:]
    }
}

extension ItemStore {
    public func accessRules() async throws -> AccessRules {
        var list: [AccessRule] = []
        var homes: Set<AccessRule> = []
        let rows = try await client.query("SELECT share, path, principal, access, origin FROM acl_rules", logger: logger)
        for try await (share, path, principal, access, origin) in rows.decode((String, String, String, String, String).self) {
            if let access = Access(rawValue: access) {
                let rule = AccessRule(share: share, path: path, principal: principal, access: access)
                list.append(rule)
                if origin == "home" { homes.insert(rule) }
            }
        }
        return AccessRules(list, homes: homes, memberships: try await memberships())
    }

    /// Changes when any rule changes (caches reload then).
    public func accessVersion() async throws -> Int64 {
        for try await version in try await client.query("SELECT acl_version FROM server", logger: logger).decode(Int64.self) {
            return version
        }
        return 0
    }

    /// Sets (or with nil, removes) a rule, and gives everything below `path` a new change number, so devices
    /// receive those items again with what they may do now (or as gone, if they may no longer see them).
    public func setAccessRule(share: String, path: String, principal: String, access: Access?) async throws {
        try await client.withTransaction(logger: logger) { connection in
            if let access {
                try await connection.query("""
                    INSERT INTO acl_rules (share, path, principal, access) VALUES (\(share), \(path), \(principal), \(access.rawValue))
                    ON CONFLICT (share, path, principal) DO UPDATE SET access = excluded.access, updated = now()
                    """, logger: logger)
            } else {
                try await connection.query("DELETE FROM acl_rules WHERE share = \(share) AND path = \(path) AND principal = \(principal)", logger: logger)
            }
            try await connection.query("UPDATE server SET acl_version = acl_version + 1", logger: logger)
        }
        // Devices learn of it as the items get new change numbers: in the background (a rule at a share's root
        // touches every item in it, 670,000 in one share, which took minutes inside the request).
        await Renumbering.shared(for: self).enqueue(share: share, path: path)
    }

    /// Gives a new change number to `path`, everything below it, and the folders above it (which may start or
    /// stop being passed through), so devices receive them again with what they may do now. In batches of 20,000,
    /// each its own statement, so tracker updates to those items never wait long. Items that already got a newer
    /// number (changed meanwhile) are skipped.
    func renumberInBatches(share: String, path: String) async throws {
        let prefix = path.isEmpty ? "%" : Self.likePrefix(path + "/")
        var above: [String] = []
        var parts = path.split(separator: "/").dropLast()
        while !path.isEmpty {
            above.append(parts.joined(separator: "/"))
            if parts.isEmpty { break }
            parts = parts.dropLast()
        }
        var marker: Int64 = 0
        for try await value in try await client.query("SELECT last_value FROM change_seq", logger: logger).decode(Int64.self) { marker = value }
        while true {
            var count = 0
            let rows = try await client.query("""
                UPDATE items SET seq = nextval('change_seq') WHERE id IN (
                    SELECT id FROM items WHERE share = \(share) AND NOT deleted AND seq <= \(marker)
                    AND (path = \(path) OR path LIKE \(prefix) OR \(path) = '' OR path = ANY(\(above))) LIMIT 20000)
                RETURNING 1
                """, logger: logger)
            for try await _ in rows.decode(Int.self) { count += 1 }
            if count == 0 { return }
        }
    }

    /// Makes the home-folder rules exactly `homes` (share, path in it, user name): each user may read and write
    /// their own. A rule an admin set at the same place for the same user stays as the admin set it. Everything
    /// under a home that gains or loses its rule gets a new change number, so devices learn of it.
    public func setHomeRules(_ homes: [(share: String, path: String, user: String)]) async throws {
        struct Rule: Hashable { var share: String; var path: String; var principal: String }
        let wanted = Set(homes.map { Rule(share: $0.share, path: $0.path, principal: "user:" + $0.user) })
        var changed: [(String, String)] = []
        try await client.withTransaction(logger: logger) { connection in
            var existing = Set<Rule>()
            let rows = try await connection.query("SELECT share, path, principal FROM acl_rules WHERE origin = 'home' FOR UPDATE", logger: logger)
            for try await (share, path, principal) in rows.decode((String, String, String).self) {
                existing.insert(Rule(share: share, path: path, principal: principal))
            }
            // Asked for every time the admin page shows the users: nothing changes unless a home came or went.
            // (Rewriting them all renumbered every item in every home, so each device fetched them all again.)
            let gone = existing.subtracting(wanted), added = wanted.subtracting(existing)
            guard !gone.isEmpty || !added.isEmpty else { return }
            for rule in gone {
                try await connection.query("""
                    DELETE FROM acl_rules WHERE origin = 'home' AND share = \(rule.share) AND path = \(rule.path) AND principal = \(rule.principal)
                    """, logger: logger)
            }
            for rule in added {
                try await connection.query("""
                    INSERT INTO acl_rules (share, path, principal, access, origin) VALUES (\(rule.share), \(rule.path), \(rule.principal), 'write', 'home')
                    ON CONFLICT (share, path, principal) DO NOTHING
                    """, logger: logger)
            }
            try await connection.query("UPDATE server SET acl_version = acl_version + 1", logger: logger)
            changed = gone.union(added).map { ($0.share, $0.path) }
        }
        for (share, path) in changed { await Renumbering.shared(for: self).enqueue(share: share, path: path) }
    }

    /// Once, when permissions became closed by default: on a server that already tracked files, everyone who
    /// was a user then keeps read and write on every share (as before), so only users added later start with
    /// nothing. A new or wiped database starts closed for everyone.
    public func seedOpenAccess(shares: [String], users: [String]) async throws {
        try await client.withTransaction(logger: logger) { connection in
            var seeded = true
            for try await value in try await connection.query("SELECT access_seeded FROM server FOR UPDATE", logger: logger).decode(Bool.self) {
                seeded = value
            }
            guard !seeded else { return }
            // A new (or wiped) database tracks nothing yet: nobody had anything to keep.
            var tracked = false
            for try await value in try await connection.query("SELECT EXISTS (SELECT 1 FROM items)", logger: logger).decode(Bool.self) {
                tracked = value
            }
            for share in shares where tracked {
                for user in users {
                    try await connection.query("""
                        INSERT INTO acl_rules (share, path, principal, access) VALUES (\(share), '', \("user:" + user), 'write')
                        ON CONFLICT (share, path, principal) DO NOTHING
                        """, logger: logger)
                }
            }
            try await connection.query("UPDATE server SET access_seeded = true, acl_version = acl_version + 1", logger: logger)
        }
    }

    /// Removes every rule naming a principal (a user that was deleted).
    public func removeAccessRules(principal: String) async throws {
        try await client.query("DELETE FROM acl_rules WHERE principal = \(principal)", logger: logger)
        try await client.query("UPDATE server SET acl_version = acl_version + 1", logger: logger)
    }
}

/// The rules, kept current for a process: reloaded when their version changes (checked every two seconds).
public final class AccessCache: @unchecked Sendable {
    private let store: ItemStore
    private let lock = NSLock()
    private var current = AccessRules()
    private var version: Int64 = -1

    public init(store: ItemStore) {
        self.store = store
    }

    public var rules: AccessRules { lock.withLock { current } }

    public func refresh() async {
        guard let now = try? await store.accessVersion() else { return }
        if now == lock.withLock({ version }) { return }
        if let rules = try? await store.accessRules() {
            lock.withLock {
                current = rules
                version = now
            }
        }
    }

    /// Keeps reloading for the life of the process.
    public func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

/// Renumbering after permission changes, one at a time per process, in the background. A place already waiting
/// (or a folder above it) covers a new one, and a new folder above waiting places replaces them.
public actor Renumbering {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var instances: [ObjectIdentifier: Renumbering] = [:]

    public static func shared(for store: ItemStore) -> Renumbering {
        lock.withLock {
            if let existing = instances[ObjectIdentifier(store.client)] { return existing }
            let made = Renumbering(store: store)
            instances[ObjectIdentifier(store.client)] = made
            return made
        }
    }

    private let store: ItemStore
    private var waiting: [(share: String, path: String)] = []
    private var running = false

    init(store: ItemStore) {
        self.store = store
    }

    private static func covers(_ outer: String, _ inner: String) -> Bool {
        outer.isEmpty || inner == outer || inner.hasPrefix(outer + "/")
    }

    public func enqueue(share: String, path: String) {
        if waiting.contains(where: { $0.share == share && Self.covers($0.path, path) }) { return }
        waiting.removeAll { $0.share == share && Self.covers(path, $0.path) }
        waiting.append((share, path))
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    private func drain() async {
        while !waiting.isEmpty {
            let next = waiting.removeFirst()
            do {
                try await store.renumberInBatches(share: next.share, path: next.path)
            } catch {
                store.logger.error("Renumbering \(next.share) after a permission change: \(error)")
            }
        }
        running = false
    }
}
