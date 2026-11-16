import Foundation
import PostgresNIO

/// A group of users, for permissions.
public struct UserGroup: Codable, Sendable, Equatable {
    public var name: String
    public var members: [String]

    public init(name: String, members: [String]) {
        (self.name, self.members) = (name, members)
    }

    /// Group names: letters, digits, spaces, `-`, `_` and `.`, starting with a letter or digit, up to 64.
    public static func validName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$", options: .regularExpression) != nil && !name.hasSuffix(" ")
    }

    public static func principal(_ name: String) -> String { "group:" + name }
}

public struct AccountFailure: Error, Equatable, CustomStringConvertible {
    public var description: String
}

/// Accounts and groups. An account is a FaNG user with an ID that never changes; Samba keeps only the SMB
/// password, and /config/users the Unix number files are opened with. The accounts follow that file (users are
/// added and removed there, by the admin page or `fang-user`).
extension ItemStore {
    /// Makes the accounts exactly the users named: new ones get an ID, removed ones go (with their group
    /// memberships). True when anything changed.
    @discardableResult
    public func syncAccounts(names: [String]) async throws -> Bool {
        var existing = Set<String>()
        for try await name in try await client.query("SELECT name FROM accounts", logger: logger).decode(String.self) {
            existing.insert(name)
        }
        let wanted = Set(names)
        let added = wanted.subtracting(existing), gone = existing.subtracting(wanted)
        guard !added.isEmpty || !gone.isEmpty else { return false }
        try await client.withTransaction(logger: logger) { connection in
            for name in added.sorted() {
                try await connection.query("INSERT INTO accounts (id, name) VALUES (\(UUID()), \(name)) ON CONFLICT (name) DO NOTHING", logger: logger)
            }
            if !gone.isEmpty {
                try await connection.query("DELETE FROM accounts WHERE name = ANY(\(Array(gone)))", logger: logger)
                // Their memberships went with them: what they could reach through a group is gone too.
                try await connection.query("UPDATE server SET acl_version = acl_version + 1", logger: logger)
            }
        }
        return true
    }

    public func groups() async throws -> [UserGroup] {
        var groups: [String: [String]] = [:]
        let rows = try await client.query("""
            SELECT g.name, a.name FROM groups g LEFT JOIN group_members m ON m.group_id = g.id
            LEFT JOIN accounts a ON a.id = m.account_id ORDER BY g.name, a.name
            """, logger: logger)
        for try await (group, member) in rows.decode((String, String?).self) {
            groups[group, default: []].append(contentsOf: member.map { [$0] } ?? [])
        }
        return groups.map { UserGroup(name: $0.key, members: $0.value) }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    public func createGroup(_ name: String) async throws {
        guard UserGroup.validName(name) else {
            throw AccountFailure(description: "Group names are letters, digits, spaces, - _ and . (up to 64).")
        }
        let rows = try await client.query("""
            INSERT INTO groups (id, name) VALUES (\(UUID()), \(name)) ON CONFLICT DO NOTHING RETURNING 1
            """, logger: logger)
        var made = false
        for try await _ in rows.decode(Int.self) { made = true }
        guard made else { throw AccountFailure(description: "That group exists already.") }
    }

    /// Removes a group, its memberships and every rule naming it. Devices learn what its members can no longer
    /// reach.
    public func deleteGroup(_ name: String) async throws {
        let places = try await rulePlaces(principal: UserGroup.principal(name))
        try await client.withTransaction(logger: logger) { connection in
            try await connection.query("DELETE FROM groups WHERE name = \(name)", logger: logger)
            try await connection.query("DELETE FROM acl_rules WHERE principal = \(UserGroup.principal(name))", logger: logger)
            try await connection.query("UPDATE server SET acl_version = acl_version + 1", logger: logger)
        }
        for (share, path) in places { await Renumbering.shared(for: self).enqueue(share: share, path: path) }
    }

    /// Makes a group's members exactly these users. Devices learn what the members can reach now.
    public func setMembers(of group: String, to members: [String]) async throws {
        try await client.withTransaction(logger: logger) { connection in
            var id: UUID?
            for try await value in try await connection.query("SELECT id FROM groups WHERE name = \(group) FOR UPDATE", logger: logger).decode(UUID.self) {
                id = value
            }
            guard let id else { throw AccountFailure(description: "No such group.") }
            try await connection.query("DELETE FROM group_members WHERE group_id = \(id)", logger: logger)
            if !members.isEmpty {
                try await connection.query("""
                    INSERT INTO group_members (group_id, account_id) SELECT \(id), id FROM accounts WHERE name = ANY(\(members))
                    """, logger: logger)
            }
            try await connection.query("UPDATE server SET acl_version = acl_version + 1", logger: logger)
        }
        for (share, path) in try await rulePlaces(principal: UserGroup.principal(group)) {
            await Renumbering.shared(for: self).enqueue(share: share, path: path)
        }
    }

    public func groupExists(_ name: String) async throws -> Bool {
        for try await _ in try await client.query("SELECT 1 FROM groups WHERE name = \(name)", logger: logger).decode(Int.self) { return true }
        return false
    }

    /// Each user's groups, for evaluating rules.
    func memberships() async throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let rows = try await client.query("""
            SELECT a.name, g.name FROM group_members m JOIN accounts a ON a.id = m.account_id JOIN groups g ON g.id = m.group_id
            """, logger: logger)
        for try await (user, group) in rows.decode((String, String).self) { result[user, default: []].insert(group) }
        return result
    }

    private func rulePlaces(principal: String) async throws -> [(String, String)] {
        var places: [(String, String)] = []
        let rows = try await client.query("SELECT share, path FROM acl_rules WHERE principal = \(principal)", logger: logger)
        for try await place in rows.decode((String, String).self) { places.append(place) }
        return places
    }
}
