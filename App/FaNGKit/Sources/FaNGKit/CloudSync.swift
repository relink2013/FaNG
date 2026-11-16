import Foundation
import Security

/// Optional sync of servers and logins between a user's devices, through iCloud Keychain: the list of
/// servers (address, port, user name, encryption, FaNG server details) and each login's password are kept as
/// synchronizable keychain items, which iCloud Keychain encrypts end to end. A new device that turns it on
/// finds the servers and adds them itself; each device still signs in to a FaNG server with its own device
/// token, which never leaves the device. Storage settings stay per device (they describe the device).
///
/// iCloud Keychain needs no iCloud entitlement (unlike the iCloud key-value store, which a free developer
/// team can't use), so this works on every account.
public enum CloudSync {
    /// One server as the synced list keeps it. A server removed on one device stays listed as removed, so the
    /// others can offer to remove it too instead of adding it back.
    public struct Server: Codable, Hashable, Sendable {
        public var account: ServerAccount
        public var updated: Date
        public var removed: Date?
    }

    private static let service = "com.rlx.fang.sync"
    private static let listAccount = "servers"
    private static let enabledKey = "cloudSync"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: FaNGKit.appGroupIdentifier) ?? .standard
    }

    /// Whether this device syncs (a per-device choice; off until turned on).
    public static var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// The synced list (empty if nothing is synced or iCloud Keychain is off).
    public static func servers() -> [Server] {
        guard let data = read(listAccount) else { return [] }
        return (try? JSONDecoder().decode([Server].self, from: data)) ?? []
    }

    /// The synced password of a server, if there is one.
    public static func password(for account: ServerAccount) -> String? {
        read("password:" + account.id.uuidString).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Puts this device's servers (and their passwords) into the synced list, keeping the servers other devices
    /// added. A server this device has wins over the listed copy, unless another device removed it.
    public static func publish(_ accounts: [ServerAccount], password: (ServerAccount) -> String?) throws {
        var list = Dictionary(servers().map { ($0.account.id, $0) }, uniquingKeysWith: { a, _ in a })
        for account in accounts {
            // Removed on another device: left removed (this device offers to remove it too); publishing it again
            // would make every other device add it back.
            if list[account.id]?.removed != nil { continue }
            if list[account.id]?.account != account {
                list[account.id] = Server(account: account, updated: Date(), removed: nil)
            }
            if let secret = password(account), Self.password(for: account) != secret {
                try write("password:" + account.id.uuidString, Data(secret.utf8))
            }
        }
        try write(listAccount, try JSONEncoder().encode(list.values.sorted { $0.account.displayName < $1.account.displayName }))
    }

    /// Marks a server removed in the synced list and forgets its synced password.
    public static func markRemoved(_ account: ServerAccount) throws {
        var list = servers()
        guard let index = list.firstIndex(where: { $0.account.id == account.id }) else { return }
        list[index].removed = Date()
        list[index].updated = Date()
        try write(listAccount, try JSONEncoder().encode(list))
        delete("password:" + account.id.uuidString)
    }

    /// Removes everything FaNG keeps in iCloud Keychain (other devices keep their servers).
    public static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: FaNGKit.appGroupIdentifier,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Keychain

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: FaNGKit.appGroupIdentifier,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func read(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ account: String, _ data: Data) throws {
        let query = query(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            // Synchronizable items can't be "this device only"; after the first unlock, like the local ones.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialStore.Failure.keychain(added) }
        } else if status != errSecSuccess {
            throw CredentialStore.Failure.keychain(status)
        }
    }

    private static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
