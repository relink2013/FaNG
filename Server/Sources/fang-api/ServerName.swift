import FaNGCore
import Foundation
import Hummingbird
import HTTPTypes
import Logging
import NIOCore
import NIOSSL

/// The server's address settings, kept in memory (read on every TLS handshake and sign-in) and saved in the
/// database when an admin changes them.
final class ServerAddressHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var address = ServerAddress()

    var current: ServerAddress {
        get { lock.withLock { address } }
        set { lock.withLock { address = newValue } }
    }
}

let serverAddress = ServerAddressHolder()

/// A certificate for the server's public name, next to its own. The server's own certificate stays the one
/// clients see when they connect by address: installed apps pin it. A browser, or an app that connects by
/// name, asks for the name (SNI) and gets this one, when its files exist. The files are read again when they
/// change, so a renewed certificate needs no restart.
final class PublicCertificate: @unchecked Sendable {
    struct Pair {
        var chain: [NIOSSLCertificateSource]
        var key: NIOSSLPrivateKeySource
    }

    private let certificateFile: String
    private let keyFile: String
    private let logger: Logger
    private let lock = NSLock()
    private var loaded: (stamp: String, pair: Pair?)?

    init(certificateFile: String, keyFile: String, logger: Logger) {
        (self.certificateFile, self.keyFile, self.logger) = (certificateFile, keyFile, logger)
    }

    private func stamp() -> String? {
        let manager = FileManager.default
        guard let certificate = try? manager.attributesOfItem(atPath: certificateFile),
              let key = try? manager.attributesOfItem(atPath: keyFile)
        else { return nil }
        return "\(certificate[.modificationDate] ?? "")|\(certificate[.size] ?? "")|\(key[.modificationDate] ?? "")|\(key[.size] ?? "")"
    }

    /// The certificate and key, or nil when there are none or they can't be read (said once in the log).
    func current() -> Pair? {
        guard let stamp = stamp() else { return nil }
        return lock.withLock {
            if let loaded, loaded.stamp == stamp { return loaded.pair }
            var pair: Pair?
            do {
                let chain = try NIOSSLCertificate.fromPEMFile(certificateFile).map { NIOSSLCertificateSource.certificate($0) }
                let key = try NIOSSLPrivateKey(file: keyFile, format: .pem)
                if !chain.isEmpty { pair = Pair(chain: chain, key: .privateKey(key)) }
                logger.info("Certificate for the public name loaded (\(chain.count) in the chain).")
            } catch {
                logger.error("The certificate for the public name can't be used: \(error)")
            }
            loaded = (stamp, pair)
            return pair
        }
    }

    /// Whether a certificate is in place, for the admin page.
    var isAvailable: Bool { current() != nil }

    /// For `TLSConfiguration.sslContextCallback`: the public certificate for the public name, the server's own
    /// for everything else.
    func choose(_ values: NIOSSLClientExtensionValues, _ promise: EventLoopPromise<NIOSSLContextConfigurationOverride>) {
        var override = NIOSSLContextConfigurationOverride()
        if let asked = values.serverHostname?.lowercased(), asked == serverAddress.current.host, let pair = current() {
            override.certificateChain = pair.chain
            override.privateKey = pair.key
        }
        promise.succeed(override)
    }
}

/// The address a request came from: the client's own behind a listed reverse proxy, otherwise the connection's.
func clientAddress(_ request: Request, _ context: Context) -> String {
    let remote = context.remoteAddress?.ipAddress ?? "?"
    return serverAddress.current.clientAddress(remote: remote, forwardedFor: request.headers[values: .init("X-Forwarded-For")!].joined(separator: ","))
}

/// What `GET /v1/server` answers: how this server is reached, for a signed-in device.
struct ServerInfo: ResponseEncodable {
    var version: String
    var url: String?
    var smb: String?
}

struct AddressSettings: Codable {
    var url: String?
    var smb: String?
    var proxies: [String]?
}

func registerServerName(api: RouterGroup<Context>, admin: RouterGroup<Context>, publicCertificate: PublicCertificate) {
    api.get("server") { _, _ in
        let address = serverAddress.current
        return ServerInfo(version: version, url: address.url, smb: address.smb)
    }

    @Sendable func answer() throws -> Response {
        let address = serverAddress.current
        return try json(["url": address.url ?? "", "smb": address.smb ?? "", "proxies": address.proxies,
                         "certificate": publicCertificate.isAvailable] as [String: Any])
    }
    admin.get("address") { _, _ in try answer() }
    admin.put("address") { request, context in
        let body = try await request.decode(as: AddressSettings.self, context: context)
        let address: ServerAddress
        do {
            address = try ServerAddress(url: body.url, smb: body.smb, proxies: body.proxies ?? []).validated()
        } catch let invalid as ServerAddress.Invalid {
            throw HTTPError(.badRequest, message: invalid.description)
        }
        try await store.setServerAddress(address)
        serverAddress.current = address
        // For the app: fang$/server.json (fang-storaged writes it; this process may not).
        do {
            let published = try JSONEncoder().encode(address)
            _ = try await storaged.admin(["ADDRESS", published.base64EncodedString()])
        } catch { throw adminFailure(error) }
        context.logger.info("Server address changed by \(context.user ?? "?").")
        return try answer()
    }
}
