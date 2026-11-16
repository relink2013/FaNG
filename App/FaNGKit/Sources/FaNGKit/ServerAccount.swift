import Foundation

/// One server login. Each account is one File Provider domain, identified by `id`, whose top level
/// holds every share the user can open. The password is not stored here; it lives in the shared
/// keychain (see `CredentialStore`).
public struct ServerAccount: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Name of the location in Files and Finder.
    public var displayName: String
    public var host: String
    public var port: Int
    public var username: String
    /// Ask for SMB3 encryption. Connecting fails if the server doesn't support it.
    public var encrypted: Bool
    /// Set when the server is a FaNG server (found when the account was added); nil for plain SMB.
    public var fang: FangServer?

    public init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        port: Int = 445,
        username: String,
        encrypted: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.encrypted = encrypted
    }

    /// File Provider domain identifier for this account.
    public var domainIdentifier: String { id.uuidString }

    /// `smb://host:port`, with IPv6 hosts bracketed.
    public var serverURL: URL? {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        components.port = port == 445 ? nil : port
        return components.url
    }

    /// The SMB address a FaNG server names for itself ("name-or-address[:port]"), as a URL. Nil when it names
    /// none or it can't be read.
    public var advertisedSMBURL: URL? {
        guard let text = fang?.smb, !text.isEmpty, let parts = URLComponents(string: "smb://" + text),
              let host = parts.host, !host.isEmpty
        else { return nil }
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        components.port = parts.port == 445 ? nil : parts.port
        return components.url
    }

    /// Takes in how the server says it is reached. True when something changed.
    public mutating func take(_ info: FangAPI.ServerInfo) -> Bool {
        guard var server = fang else { return false }
        server.url = info.url?.isEmpty == false ? info.url : nil
        server.smb = info.smb?.isEmpty == false ? info.smb : nil
        guard server != fang else { return false }
        fang = server
        return true
    }
}

/// Accounts saved in the App Group, readable by the app and the extension.
/// Settings stay on this device; they are not synced.
public enum AccountStore {
    private static let key = "accounts"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: FaNGKit.appGroupIdentifier) ?? .standard
    }

    public static func all() -> [ServerAccount] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ServerAccount].self, from: data)) ?? []
    }

    public static func account(domainIdentifier: String) -> ServerAccount? {
        all().first { $0.domainIdentifier == domainIdentifier }
    }

    public static func save(_ account: ServerAccount) {
        var accounts = all().filter { $0.id != account.id }
        accounts.append(account)
        write(accounts)
    }

    public static func remove(_ account: ServerAccount) {
        write(all().filter { $0.id != account.id })
    }

    private static func write(_ accounts: [ServerAccount]) {
        if let data = try? JSONEncoder().encode(accounts) {
            defaults.set(data, forKey: key)
        }
    }
}
