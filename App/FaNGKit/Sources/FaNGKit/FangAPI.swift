import CryptoKit
import Foundation

/// How to reach a FaNG server's API: found in the hidden `fang$` share when the account is added.
public struct FangServer: Codable, Hashable, Sendable {
    public var port: Int
    /// SHA-256 of the API certificate (DER, hex). The certificate is self-signed; this pins it.
    public var fingerprint: String
    /// The server's public address ("https://name"), when its admin set one. Its certificate is checked the
    /// normal way. The address the account was added with, and the pinned certificate, keep working beside it.
    public var url: String?
    /// Where the server says SMB is reached ("name-or-address[:port]"), when that was set.
    public var smb: String?

    public init(port: Int, fingerprint: String, url: String? = nil, smb: String? = nil) {
        self.port = port
        self.fingerprint = fingerprint
        self.url = url
        self.smb = smb
    }
}

/// An item as the FaNG server reports it.
public struct FangItem: Codable, Hashable, Sendable {
    public var id: UUID
    public var share: String
    /// Nil for a share's root folder.
    public var parent: UUID?
    public var name: String
    /// Inside the share; "" for its root.
    public var path: String
    public var isDirectory: Bool
    public var size: Int64
    public var mtimeNS: Int64
    public var inode: Int64
    public var contentVersion: Int64
    public var metadataVersion: Int64
    public var deleted: Bool
    public var seq: Int64
    /// In the trash: `path` is then inside the trash, and `originalPath` is where it was.
    public var trashed: Bool?
    public var originalPath: String?
    /// Finder tags, "name\ncolor" each (color 0–7; 6 is red).
    public var tags: [String]?
    /// "copying" while a server copy makes this item (with `progress` in percent), "failed" if it failed;
    /// nil for every other item.
    public var jobState: String?
    public var progress: Int?
    /// Extended attributes the system syncs (name → value); nil when none, or from a server before them.
    public var xattrs: [String: Data]?
    /// What this user may do with it: "read" or "write" (nil from a server before permissions: write).
    public var access: String?

    /// The SMB path: "Share/inner/path".
    public var smbPath: String {
        path.isEmpty ? share : share + "/" + path
    }
}

/// The FaNG server's HTTPS API, signed in with this device's token.
///
/// The server is reached at the address the account was added with, where its own certificate is pinned, and
/// at its public address when it has one, where the certificate is checked the normal way. Requests go to the
/// one that last worked; when it can't be reached the other is tried, and remembered if it answers.
public final class FangAPI: NSObject, Sendable, URLSessionDelegate {
    /// How the server says it is reached (`GET /v1/server`).
    public struct ServerInfo: Codable, Sendable {
        public var version: String?
        public var url: String?
        public var smb: String?
    }

    public struct Share: Codable, Sendable {
        public var name: String
        public var root: FangItem?
    }

    public struct ChildrenPage: Codable, Sendable {
        public var items: [FangItem]
        public var next: String?
    }

    public struct ChangesPage: Codable, Sendable {
        public var epoch: UUID
        public var items: [FangItem]
        public var anchor: Int64
        public var more: Bool
        public var latest: Int64
    }

    public enum Failure: Error, LocalizedError {
        case status(Int)
        case notSignedIn

        public var errorDescription: String? {
            switch self {
            case .status(let code): "The FaNG server answered \(code)."
            case .notSignedIn: "This device isn't signed in to the FaNG server."
            }
        }
    }

    /// The address the account was added with first, then the public address.
    private let endpoints: [URL]
    private let preferenceKey: String
    private let token: String
    private let fingerprint: String
    private let timeout: TimeInterval
    nonisolated(unsafe) private var session: URLSession!

    public init(host: String, server: FangServer, token: String, timeout: TimeInterval = 30) throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        components.port = server.port == 443 ? nil : server.port
        guard let base = components.url else { throw SMBBackend.Failure.invalidServerAddress }
        var endpoints = [base]
        if let text = server.url, let url = URL(string: text), url.scheme == "https", url.host != nil, url != base {
            endpoints.append(url)
        }
        self.endpoints = endpoints
        self.preferenceKey = "api.endpoint." + base.absoluteString
        self.token = token
        self.fingerprint = server.fingerprint.lowercased()
        self.timeout = timeout
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = max(timeout, 60)  // The change long poll waits up to 55 s.
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    // MARK: Addresses

    private static var preferences: UserDefaults { UserDefaults(suiteName: FaNGKit.appGroupIdentifier) ?? .standard }

    /// The address requests go to now: the one that last worked (kept across launches, for the app and the
    /// extensions alike), the account's own until then.
    private var base: URL {
        if endpoints.count > 1, let text = Self.preferences.string(forKey: preferenceKey),
           let url = endpoints.first(where: { $0.absoluteString == text }) {
            return url
        }
        return endpoints[0]
    }

    /// Runs a request against the current address. If that address can't be reached and the server has
    /// another that answers, the other becomes current; the request is sent again there when that's safe
    /// (`resend`: it never arrived, or sending it twice does no harm).
    private func reaching<T>(resend: Bool, _ request: (URL) async throws -> T) async throws -> T {
        let used = base
        do {
            return try await request(used)
        } catch let error as URLError {
            guard endpoints.count > 1, error.isConnectionFailure else { throw error.posixEquivalent }
            guard error.neverArrived || resend else {
                Task { await self.leave(used) }
                throw error.posixEquivalent
            }
            guard let other = await leave(used) else { throw error.posixEquivalent }
            do {
                return try await request(other)
            } catch let error as URLError {
                throw error.posixEquivalent
            }
        }
    }

    /// Makes another address current if one answers. Returns it.
    @discardableResult
    private func leave(_ used: URL) async -> URL? {
        for candidate in endpoints where candidate != used {
            var probe = URLRequest(url: candidate.appending(path: ".well-known/fang"))
            probe.timeoutInterval = 6
            guard let (_, response) = try? await session.data(for: probe), (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            Self.preferences.set(candidate.absoluteString, forKey: preferenceKey)
            DiagnosticLog.note("API: \(used.host ?? "?") can't be reached, using \(candidate.host ?? "?")")
            return candidate
        }
        return nil
    }

    /// How the server says it is reached. Nil from a server that doesn't say (an older one).
    public func serverInfo() async throws -> ServerInfo? {
        do {
            return try await get("v1/server") as ServerInfo
        } catch Failure.status(404) {
            return nil
        }
    }

    public func shares() async throws -> [Share] {
        try await get("v1/shares")
    }

    public func item(_ id: UUID) async throws -> FangItem? {
        do {
            return try await get("v1/items/\(id.uuidString)")
        } catch Failure.status(404) {
            return nil
        }
    }

    /// Every live child of a folder, fetching page after page.
    public func children(of id: UUID) async throws -> [FangItem] {
        var items: [FangItem] = []
        var after: String?
        repeat {
            var query: [URLQueryItem] = []
            if let after { query.append(URLQueryItem(name: "after", value: after)) }
            let page: ChildrenPage = try await get("v1/items/\(id.uuidString)/children", query: query)
            items += page.items
            after = page.next
        } while after != nil
        return items
    }

    public func changes(share: String, since: Int64, limit: Int = 1000) async throws -> ChangesPage {
        try await get("v1/changes", query: [
            URLQueryItem(name: "share", value: share), URLQueryItem(name: "since", value: String(since)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    /// The item at a path as the server sees it right now (it looks at the disk), or nil if there's none.
    public func resolve(share: String, path: String) async throws -> FangItem? {
        do {
            return try await get("v1/resolve", query: [URLQueryItem(name: "share", value: share), URLQueryItem(name: "path", value: path)])
        } catch Failure.status(404) {
            return nil
        }
    }

    public struct Commit: Codable, Sendable {
        public var item: FangItem
        public var conflict: Bool
        /// Whether the edit became the file (nil from servers older than this field).
        public var editWon: Bool?
    }

    public struct VersionInfo: Codable, Hashable, Sendable {
        public var id: Int64
        public var item: UUID
        public var size: Int64
        public var mtimeNS: Int64
        /// "version" or "branch" (a conflicting edit that didn't become the file).
        public var kind: String
        public var created: Date
        /// A branch stays open until its conflict is resolved.
        public var resolved: Bool?
        /// The device whose edit it was (`FangAPI.device` of that device), "server" for the server's own
        /// side of a conflict, or nil.
        public var device: String?

        public var isOpenBranch: Bool { kind == "branch" && resolved != true }
    }

    /// Puts new contents, uploaded over SMB to `temp` in the item's folder, in place of the item. The server
    /// checks `baseVersion` against the file on disk and keeps the old contents as a version.
    /// `path` is where this device sees the file inside its share, so a rename the server hasn't seen yet
    /// can't send the new contents to the old name.
    public func commit(_ id: UUID, temp: String, baseVersion: Int64, modified: Date?, path: String? = nil) async throws -> Commit {
        struct Body: Encodable {
            var temp: String
            var baseVersion: Int64
            var modifiedNS: Int64
            var path: String?
        }
        let modifiedNS = Int64(((modified ?? Date()).timeIntervalSince1970 * 1_000_000_000).rounded())
        return try await send("v1/items/\(id.uuidString)/commit", method: "POST",
                              body: try JSONEncoder().encode(Body(temp: temp, baseVersion: baseVersion, modifiedNS: modifiedNS, path: path)))
    }

    /// Every share's trash (the items that were deleted; what was below them stays below them).
    public func trash(share: String) async throws -> [FangItem] {
        try await get("v1/trash", query: [URLQueryItem(name: "share", value: share)])
    }

    public func moveToTrash(_ id: UUID) async throws -> FangItem {
        try await send("v1/items/\(id.uuidString)/trash", method: "POST", body: nil, timeout: 150)
    }

    /// Puts an item back where it was, or into `parent`.
    public func putBack(_ id: UUID, into parent: UUID?) async throws -> FangItem {
        struct Body: Encodable { var parent: UUID? }
        return try await send("v1/items/\(id.uuidString)/untrash", method: "POST", body: try JSONEncoder().encode(Body(parent: parent)), timeout: 150)
    }

    /// Deletes an item: into the trash, or for good if it's there already.
    public func delete(_ id: UUID) async throws {
        let _: FangItem = try await send("v1/items/\(id.uuidString)", method: "DELETE", body: nil, timeout: 150)
    }

    /// Copies an item (a folder with everything in it) into `parent` on the server, as `name` if given;
    /// no bytes travel through this device. Returns the copy.
    public func copy(_ id: UUID, into parent: UUID, name: String? = nil) async throws -> FangItem {
        try await transfer("copy", id, parent, name)
    }

    /// Moves an item into `parent` on the server, in its share or another. It keeps its ID.
    public func move(_ id: UUID, into parent: UUID, name: String? = nil) async throws -> FangItem {
        try await transfer("move", id, parent, name)
    }

    private func transfer(_ operation: String, _ id: UUID, _ parent: UUID, _ name: String?) async throws -> FangItem {
        struct Body: Encodable { var parent: UUID; var name: String? }
        // Within one filesystem it's a reflink or rename, at once. A copy between filesystems moves every byte
        // on the server inside this request, so it gets 2 minutes (not the usual 30 s), never so long that a
        // dead connection leaves the user waiting.
        return try await send("v1/items/\(id.uuidString)/\(operation)", method: "POST",
                              body: try JSONEncoder().encode(Body(parent: parent, name: name)), timeout: 120)
    }

    /// The item's thumbnail (WebP, 512 px), or nil if it has none. The server makes a missing one first and
    /// waits a few seconds for it.
    public func thumbnail(_ id: UUID) async throws -> Data? {
        try await image("v1/items/\(id.uuidString)/thumbnail")
    }

    /// A version's thumbnail (WebP), made when first asked for; nil if there's none.
    public func thumbnail(version: Int64) async throws -> Data? {
        try await image("v1/versions/\(version)/thumbnail")
    }

    private func image(_ path: String) async throws -> Data? {
        let (data, response) = try await reaching(resend: true) { base in
            var request = URLRequest(url: base.appending(path: path))
            request.setValue("Bearer \(self.token)", forHTTPHeaderField: "Authorization")
            return try await self.session.data(for: request)
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: return data
        case 404: return nil
        case 401: throw Failure.notSignedIn
        case let status: throw Failure.status(status)
        }
    }

    /// Sets an item's extended attributes (the ones the system syncs: folder symbols and emoji, …).
    public func setXattrs(_ id: UUID, _ xattrs: [String: Data]) async throws -> FangItem {
        struct Body: Encodable { var xattrs: [String: Data] }
        return try await send("v1/items/\(id.uuidString)/xattrs", method: "PUT", body: try JSONEncoder().encode(Body(xattrs: xattrs)))
    }

    /// A file's contents as the server has them, block by block (SHA-256 each), for delta transfers.
    public struct Blocks: Codable, Sendable {
        public var item: FangItem
        public var size: Int64
        public var blockSize: Int
        /// 32 bytes per block, in order.
        public var hashes: Data
    }

    /// Delta upload, first step: the server clones the file's current contents to `temp` (an upload temp name
    /// in its folder) and answers each block's hash; the client then writes only the blocks that differ.
    public func stage(_ id: UUID, temp: String) async throws -> Blocks {
        struct Body: Encodable { var temp: String }
        // The server reads the whole file to hash it: a 20 GB file takes a while on spinning disks.
        return try await send("v1/items/\(id.uuidString)/stage", method: "POST", body: try JSONEncoder().encode(Body(temp: temp)), timeout: 600)
    }

    /// The block hashes of a file's current contents (delta download).
    public func blocks(of id: UUID) async throws -> Blocks {
        try await send("v1/items/\(id.uuidString)/blocks", method: "GET", body: nil, timeout: 600)
    }

    /// Where the server's own storage goes, with its retention rules.
    public struct StorageReport: Codable, Sendable {
        public struct Part: Codable, Sendable {
            public var items: Int64
            public var bytes: Int64
        }
        public var trash: Part
        public var versions: Part
        public var thumbnails: Part
        public var databaseBytes: Int64
        public var deletedRecords: Int64
        public var trashDays: Int
        public var versionDays: Int
        public var deletedRecordDays: Int
    }

    public func storage() async throws -> StorageReport {
        try await get("v1/storage")
    }

    public func setTags(_ id: UUID, _ tags: [String]) async throws -> FangItem {
        struct Body: Encodable { var tags: [String] }
        return try await send("v1/items/\(id.uuidString)/tags", method: "PUT", body: try JSONEncoder().encode(Body(tags: tags)))
    }

    /// An open conflict: the item as it is, and the edits that didn't become it.
    public struct Conflict: Codable, Sendable, Identifiable {
        public var item: FangItem
        public var branches: [VersionInfo]
        /// Conflicts from the same device within ten minutes share a group.
        public var group: String
        public var id: UUID { item.id }
    }

    public func conflicts() async throws -> [Conflict] {
        try await get("v1/conflicts")
    }

    /// A copy the server is making, or one that failed. A copy leaves the list only when it succeeds; a
    /// failed one stays until its item is deleted.
    public struct CopyJob: Codable, Sendable, Identifiable {
        public var item: FangItem
        /// "copying" or "failed".
        public var state: String
        /// While copying: "counting" (finding what to copy), "copying", "recording" (almost done).
        public var phase: String?
        public var entriesDone: Int?
        public var entriesTotal: Int?
        public var bytesDone: Int64?
        public var bytesTotal: Int64?
        /// The file being copied now, inside the copy.
        public var current: String?
        public var started: Date?
        public var error: String?
        public var id: UUID { item.id }
    }

    private struct CopyJobs: Codable {
        var jobs: [CopyJob]
    }

    public func copyJobs() async throws -> [CopyJob] {
        let page: CopyJobs = try await get("v1/jobs")
        return page.jobs
    }

    public enum Resolution: String, Sendable {
        /// The file as it is wins; the other edits stay in its versions.
        case keep
        /// The other edit becomes the file.
        case use
        /// The other edit is kept next to the file as a copy.
        case copy
    }

    public func resolve(_ id: UUID, _ resolution: Resolution, version: Int64? = nil) async throws -> FangItem {
        struct Body: Encodable { var action: String; var version: Int64? }
        return try await send("v1/items/\(id.uuidString)/resolve", method: "POST",
                              body: try JSONEncoder().encode(Body(action: resolution.rawValue, version: version)))
    }

    /// The server's latest change number, first on connect and then whenever it moves, over one WebSocket
    /// (pinned and signed in like every request). The stream ends when the connection does.
    public func events() -> AsyncThrowingStream<Int64, Error> {
        let used = base
        var components = URLComponents(url: used.appending(path: "v1/events"), resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        var request = URLRequest(url: components?.url ?? base)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        struct Event: Decodable { var latest: Int64 }
        return AsyncThrowingStream { continuation in
            task.resume()
            let reader = Task {
                do {
                    while true {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data(let bytes): data = bytes
                        @unknown default: continue
                        }
                        continuation.yield(try JSONDecoder().decode(Event.self, from: data).latest)
                    }
                } catch {
                    // The caller connects again; by then the address that answers is current.
                    if let error = error as? URLError, error.isConnectionFailure, self.endpoints.count > 1 {
                        await self.leave(used)
                    }
                    continuation.finish(throwing: error)
                }
            }
            // A ping every 30 s: the server only speaks when something changes, and an idle socket would otherwise
            // hit the session's timeout (or a NAT's) and reconnect for nothing.
            let pinger = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    task.sendPing { _ in }
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                pinger.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    /// Waits until anything changes after change number `since` (or `timeout` seconds) and returns the
    /// latest change number. (Clients that can keep a WebSocket open use `events()` instead.)
    public func waitForChanges(since: Int64, timeout: Int = 25) async throws -> Int64 {
        struct Signal: Decodable { var latest: Int64 }
        let signal: Signal = try await get("v1/changes/wait", query: [
            URLQueryItem(name: "since", value: String(since)), URLQueryItem(name: "timeout", value: String(timeout)),
        ])
        return signal.latest
    }

    public func versions(of id: UUID) async throws -> [VersionInfo] {
        try await get("v1/items/\(id.uuidString)/versions")
    }

    public func restore(version: Int64) async throws -> FangItem {
        try await send("v1/versions/\(version)/restore", method: "POST", body: nil)
    }

    /// Downloads a version's contents to `destination` (streamed to disk, never held in memory).
    public func download(version: Int64, to destination: URL) async throws {
        let (file, response) = try await reaching(resend: true) { base in
            var request = URLRequest(url: base.appending(path: "v1/versions/\(version)/content"))
            request.setValue("Bearer \(self.token)", forHTTPHeaderField: "Authorization")
            return try await self.session.download(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Failure.notSignedIn }
        guard status == 200 else { throw Failure.status(status) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
    }

    /// This device as the server names it in versions (the start of its token's SHA-256).
    public var device: String {
        String(SHA256.hash(data: Data(token.lowercased().utf8)).map { String(format: "%02x", $0) }.joined().prefix(12))
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(path, query: query, method: "GET", body: nil)
    }

    private func send<T: Decodable>(_ path: String, query: [URLQueryItem] = [], method: String, body: Data?, timeout: TimeInterval? = nil) async throws -> T {
        // Only a read is sent again after an answer that never came: a copy or a commit might have arrived.
        let (data, response) = try await reaching(resend: method == "GET") { base in
            var url = base.appending(path: path)
            if !query.isEmpty { url.append(queryItems: query) }
            var request = URLRequest(url: url)
            request.httpMethod = method
            if let timeout { request.timeoutInterval = timeout }
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            request.setValue("Bearer \(self.token)", forHTTPHeaderField: "Authorization")
            return try await self.session.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw Failure.notSignedIn }
        guard status == 200 else { throw Failure.status(status) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unreadable date \(text)")
        }
        return try decoder.decode(T.self, from: data)
    }

    // MARK: Trust

    /// The server's own certificate is trusted by its fingerprint, at any address. Any other certificate is
    /// checked the normal way (a public name with a certificate browsers accept), so a wrong one is refused.

    public func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        else { return completionHandler(.performDefaultHandling, nil) }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        guard digest == fingerprint else { return completionHandler(.performDefaultHandling, nil) }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

extension URLError {
    /// The request didn't reach the server at all, so nothing happened there.
    var neverArrived: Bool {
        switch code {
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
            true
        default:
            false
        }
    }

    /// The server couldn't be reached at this address, or stopped answering there.
    var isConnectionFailure: Bool {
        neverArrived || code == .timedOut || code == .networkConnectionLost
    }

    /// The POSIX error the rest of FaNGKit treats network failures as (see `isTransientNetworkError`).
    var posixEquivalent: Error {
        switch code {
        case .timedOut: POSIXError(.ETIMEDOUT)
        case .cannotConnectToHost, .cannotFindHost: POSIXError(.ECONNREFUSED)
        case .networkConnectionLost: POSIXError(.ECONNRESET)
        case .notConnectedToInternet: POSIXError(.ENETDOWN)
        case .cancelled: CancellationError()
        default: self
        }
    }
}
