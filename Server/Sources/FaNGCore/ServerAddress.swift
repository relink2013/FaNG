import Foundation
import PostgresNIO

/// How the server is reached by name, set in the admin page. All of it is optional: with nothing set, clients
/// keep using the address they were given and the server's own pinned certificate.
public struct ServerAddress: Codable, Sendable, Equatable {
    /// The API's public address, "https://name[:port]". Used for links, sign-in pages and by the app.
    public var url: String?
    /// Where SMB is reached, "name-or-address[:port]". Given separately from `url`: behind a reverse proxy the
    /// API's name can lead to the proxy, while SMB has to reach FaNG's own address.
    public var smb: String?
    /// Reverse proxies in front of the API. Only from these is `X-Forwarded-For` believed.
    public var proxies: [String]

    public init(url: String? = nil, smb: String? = nil, proxies: [String] = []) {
        (self.url, self.smb, self.proxies) = (url, smb, proxies)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        smb = try container.decodeIfPresent(String.self, forKey: .smb)
        proxies = try container.decodeIfPresent([String].self, forKey: .proxies) ?? []
    }

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// The host name in `url`, lowercased.
    public var host: String? {
        url.flatMap { URLComponents(string: $0)?.host?.lowercased() }
    }

    /// The same settings tidied up (empty fields dropped, the URL reduced to scheme, host and port), or why
    /// they can't be used.
    public func validated() throws -> ServerAddress {
        var result = ServerAddress()
        if let url = url?.trimmingCharacters(in: .whitespaces), !url.isEmpty {
            guard let parts = URLComponents(string: url), parts.scheme?.lowercased() == "https" else {
                throw Invalid(description: "The public address has to start with https://.")
            }
            guard let host = parts.host?.lowercased(), !host.isEmpty, parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/"
            else { throw Invalid(description: "The public address is only a name, like https://files.example.com.") }
            if let port = parts.port, !(1...65535).contains(port) {
                throw Invalid(description: "The public address has a port that doesn't exist.")
            }
            let bracketed = host.contains(":") ? "[\(host)]" : host
            result.url = "https://" + bracketed + (parts.port.map { $0 == 443 ? "" : ":\($0)" } ?? "")
        }
        if let smb = smb?.trimmingCharacters(in: .whitespaces), !smb.isEmpty {
            guard smb.count <= 260, smb.range(of: "^[A-Za-z0-9._\\-:\\[\\]]+$", options: .regularExpression) != nil else {
                throw Invalid(description: "The SMB address is a name or an address, with a port if it isn't 445.")
            }
            result.smb = smb.lowercased()
        }
        for proxy in proxies {
            let proxy = proxy.trimmingCharacters(in: .whitespaces)
            guard !proxy.isEmpty else { continue }
            guard proxy.count <= 45, proxy.range(of: "^[0-9A-Fa-f.:]+$", options: .regularExpression) != nil else {
                throw Invalid(description: "A reverse proxy is given by its address, like 192.0.2.5.")
            }
            result.proxies.append(proxy.lowercased())
        }
        return result
    }

    /// The client's address for a request that arrived from `remote`: the last address in `X-Forwarded-For`
    /// that isn't one of the proxies, when `remote` is one of them. Anyone else's header is ignored.
    public func clientAddress(remote: String, forwardedFor: String?) -> String {
        guard proxies.contains(remote.lowercased()), let forwardedFor else { return remote }
        let chain = forwardedFor.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return chain.last { !$0.isEmpty && !proxies.contains($0) } ?? remote
    }
}

extension ItemStore {
    static let addressKey = "address"

    public func serverAddress() async throws -> ServerAddress {
        let rows = try await client.query("SELECT value FROM settings WHERE key = \(Self.addressKey)", logger: logger)
        for try await value in rows.decode(String.self) {
            return (try? JSONDecoder().decode(ServerAddress.self, from: Data(value.utf8))) ?? ServerAddress()
        }
        return ServerAddress()
    }

    public func setServerAddress(_ address: ServerAddress) async throws {
        let value = String(decoding: try JSONEncoder().encode(address), as: UTF8.self)
        try await client.query("""
            INSERT INTO settings (key, value) VALUES (\(Self.addressKey), \(value))
            ON CONFLICT (key) DO UPDATE SET value = excluded.value, updated = now()
            """, logger: logger)
    }
}
