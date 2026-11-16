import Foundation
import Security

/// Passwords in the data protection keychain, shared with the extension through the App Group access group.
public enum CredentialStore {
    public enum Failure: Error, LocalizedError {
        case keychain(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    private static let service = "com.rlx.fang.smb"

    private static func query(for account: ServerAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.id.uuidString,
            kSecAttrAccessGroup as String: FaNGKit.appGroupIdentifier,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public static func setPassword(_ password: String, for account: ServerAccount) throws {
        let query = query(for: account)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(password.utf8)
        // The extension must be able to read it while the device is locked, after the first unlock.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    public static func password(for account: ServerAccount) throws -> String? {
        var query = query(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.keychain(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public static func removePassword(for account: ServerAccount) {
        SecItemDelete(query(for: account) as CFDictionary)
        removeDeviceToken(for: account)
    }

    // MARK: FaNG device tokens

    private static let tokenService = "com.rlx.fang.device-token"

    private static func tokenQuery(for account: ServerAccount) -> [String: Any] {
        var query = query(for: account)
        query[kSecAttrService as String] = tokenService
        return query
    }

    /// The token this device signs in to a FaNG server's API with (see `FangSignIn`).
    public static func setDeviceToken(_ token: String, for account: ServerAccount) throws {
        let query = tokenQuery(for: account)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    public static func deviceToken(for account: ServerAccount) throws -> String? {
        var query = tokenQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.keychain(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public static func removeDeviceToken(for account: ServerAccount) {
        SecItemDelete(tokenQuery(for: account) as CFDictionary)
    }
}
