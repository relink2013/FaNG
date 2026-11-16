import Crypto
import FaNGCore
import Foundation
import Hummingbird
import Logging
import NIOCore
import PostgresNIO

/// FaNG's admin page: users and their devices, shares, permissions, a file browser with thumbnails, and where
/// the server's own storage goes. Signed in with a FaNG admin's SMB password (checked against Samba's
/// database by fang-storaged); the session is a random token in an HttpOnly, Secure, SameSite=Strict cookie.
final class AdminSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: (user: String, expires: Date)] = [:]
    private var failures: [String: [Date]] = [:]
    static let lifetime: TimeInterval = 12 * 3600

    func create(user: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        lock.withLock {
            sessions = sessions.filter { $0.value.expires > Date() }
            sessions[token] = (user, Date().addingTimeInterval(Self.lifetime))
        }
        return token
    }

    func user(for token: String) -> String? {
        lock.withLock {
            guard let session = sessions[token], session.expires > Date() else { return nil }
            return session.user
        }
    }

    func end(_ token: String) {
        _ = lock.withLock { sessions.removeValue(forKey: token) }
    }

    /// At most 5 failed sign-ins a minute from one address.
    func allowAttempt(from address: String) -> Bool {
        lock.withLock { (failures[address] ?? []).filter { Date().timeIntervalSince($0) < 60 }.count < 5 }
    }

    func failed(from address: String) {
        lock.withLock { failures[address, default: []].append(Date()) }
    }
}

let adminSessions = AdminSessions()

struct AdminSession: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let token = cookie(request, "fang_admin"), let user = adminSessions.user(for: token) else {
            throw HTTPError(.unauthorized)
        }
        // Still an admin? (Rights can be taken away while a session is open.)
        let users = try JSONSerialization.jsonObject(with: try await storaged.admin(["USERS"])) as? [[String: Any]] ?? []
        guard users.contains(where: { $0["name"] as? String == user && $0["admin"] as? Bool == true }) else {
            adminSessions.end(token)
            throw HTTPError(.unauthorized)
        }
        var context = context
        context.user = user
        return try await next(request, context)
    }
}

func cookie(_ request: Request, _ name: String) -> String? {
    for header in request.headers[values: .cookie] {
        for part in header.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0] == name { return String(pair[1]) }
        }
    }
    return nil
}

func json(_ data: Data, status: HTTPResponse.Status = .ok) -> Response {
    Response(status: status, headers: [.contentType: "application/json", .cacheControl: "no-store"], body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

func json(_ object: Any) throws -> Response {
    json(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

func adminFailure(_ error: Error) -> HTTPError {
    if let error = error as? Storaged.StoragedError { return HTTPError(.badRequest, message: error.reason) }
    if let error = error as? HTTPError { return error }
    return HTTPError(.internalServerError, message: String(describing: error))
}

struct LoginRequest: Decodable { var user: String; var password: String }
struct NewUser: Decodable { var name: String; var password: String; var admin: Bool? }
struct PasswordChange: Decodable { var password: String }
struct AdminFlag: Decodable { var admin: Bool }
struct NewGroup: Decodable { var name: String }
struct Members: Decodable { var members: [String] }

/// FaNG's user names, from the users file.
func userNames() -> [String] {
    ((try? String(contentsOfFile: devices.usersFile, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
        let fields = line.split(separator: ":")
        return fields.count == 2 ? String(fields[0]) : nil
    }
}

/// Brings the accounts in step with the users file (a user added or removed since, by this page or `fang-user`).
func syncAccounts() async {
    do {
        if try await store.syncAccounts(names: userNames()) { await accessCache.refresh() }
    } catch {
        logger.error("Accounts not brought in step with the users: \(error)")
    }
}

struct AccessChange: Decodable { var share: String; var path: String; var principal: String; var access: String? }

func registerAdmin(_ router: Router<Context>) {
    router.get("admin") { _, _ -> Response in
        Response(status: .ok, headers: [.contentType: "text/html; charset=utf-8", .cacheControl: "no-store",
                                        .init("Content-Security-Policy")!: "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'"],
                 body: .init(byteBuffer: ByteBuffer(string: AdminPage.page)))
    }
    // The icon, public (browsers ask for it before signing in; Unraid can show it for the container).
    router.get("admin/icon.png") { _, _ -> Response in
        Response(status: .ok, headers: [.contentType: "image/png", .cacheControl: "public, max-age=86400"],
                 body: .init(byteBuffer: ByteBuffer(bytes: Data(base64Encoded: AdminAssets.icon) ?? Data())))
    }
    router.post("admin/login") { request, context -> Response in
        let address = clientAddress(request, context)
        guard adminSessions.allowAttempt(from: address) else { throw HTTPError(.tooManyRequests, message: "Too many attempts; wait a minute.") }
        let body = try await request.decode(as: LoginRequest.self, context: context)
        let answer: [String: Any]
        do {
            answer = try JSONSerialization.jsonObject(with: try await storaged.admin(["AUTH", body.user, Data(body.password.utf8).base64EncodedString()])) as? [String: Any] ?? [:]
        } catch {
            adminSessions.failed(from: address)
            throw HTTPError(.unauthorized, message: "Wrong name or password.")
        }
        guard answer["admin"] as? Bool == true else {
            adminSessions.failed(from: address)
            throw HTTPError(.forbidden, message: "This user isn't an admin.")
        }
        let token = adminSessions.create(user: body.user)
        var response = try json(["user": body.user])
        response.headers[.setCookie] = "fang_admin=\(token); Path=/admin; HttpOnly; Secure; SameSite=Strict; Max-Age=\(Int(AdminSessions.lifetime))"
        return response
    }
    router.post("admin/logout") { request, _ -> Response in
        if let token = cookie(request, "fang_admin") { adminSessions.end(token) }
        var response = try json(["ok": true])
        response.headers[.setCookie] = "fang_admin=; Path=/admin; HttpOnly; Secure; SameSite=Strict; Max-Age=0"
        return response
    }

    let admin = router.group("admin/api").add(middleware: AdminSession())
    admin.get("me") { _, context in try json(["user": context.user ?? ""]) }

    admin.get("overview") { _, _ in
        let report = try await store.storageReport()
        let sys = (try? JSONSerialization.jsonObject(with: try await storaged.admin(["SYSINFO"]))) ?? [:]
        let extra = try await store.adminCounts()
        let encoder = JSONEncoder()
        let storage = try JSONSerialization.jsonObject(with: try encoder.encode(report))
        let removed = try await store.removedShares().map {
            ["name": $0.name, "since": $0.since.timeIntervalSince1970, "items": $0.items, "versions": $0.versions,
             "until": $0.since.addingTimeInterval(Double(ItemStore.removedShareDays) * 86400).timeIntervalSince1970] as [String: Any]
        }
        return try json(["storage": storage, "system": sys, "counts": extra, "shares": shares.map { ["name": $0.name, "path": $0.path] },
                         "removedShares": removed])
    }

    admin.get("users") { _, _ in
        await syncAccounts()
        do { return json(try await storaged.admin(["USERS"])) } catch { throw adminFailure(error) }
    }

    // Groups of users, for permission rules.
    @Sendable func groupsAnswer() async throws -> Response {
        try json(try await store.groups().map { ["name": $0.name, "members": $0.members] as [String: Any] })
    }
    @Sendable func groupFailure(_ error: Error) -> HTTPError {
        if let error = error as? AccountFailure { return HTTPError(.badRequest, message: error.description) }
        return adminFailure(error)
    }
    admin.get("groups") { _, _ in
        await syncAccounts()
        return try await groupsAnswer()
    }
    admin.post("groups") { request, context in
        let body = try await request.decode(as: NewGroup.self, context: context)
        do { try await store.createGroup(body.name.trimmingCharacters(in: .whitespaces)) } catch { throw groupFailure(error) }
        context.logger.info("Group added by \(context.user ?? "?").")
        return try await groupsAnswer()
    }
    admin.put("groups/:name/members") { request, context in
        guard let name = context.parameters.get("name") else { throw HTTPError(.notFound) }
        let body = try await request.decode(as: Members.self, context: context)
        await syncAccounts()
        let known = Set(userNames())
        guard body.members.allSatisfy(known.contains) else { throw HTTPError(.badRequest, message: "One of those users doesn't exist.") }
        do { try await store.setMembers(of: name, to: body.members) } catch { throw groupFailure(error) }
        await accessCache.refresh()
        context.logger.info("Group members changed by \(context.user ?? "?").")
        return try await groupsAnswer()
    }
    admin.delete("groups/:name") { _, context in
        guard let name = context.parameters.get("name") else { throw HTTPError(.notFound) }
        do { try await store.deleteGroup(name) } catch { throw groupFailure(error) }
        await accessCache.refresh()
        context.logger.info("Group removed by \(context.user ?? "?").")
        return try await groupsAnswer()
    }
    admin.post("users") { request, context in
        let body = try await request.decode(as: NewUser.self, context: context)
        do {
            let answer = try await storaged.admin(["USERADD", body.name, Data(body.password.utf8).base64EncodedString(), body.admin == true ? "1" : "0"])
            await syncAccounts()
            return json(answer)
        } catch { throw adminFailure(error) }
    }
    admin.post("users/:name/password") { request, context in
        guard let name = context.parameters.get("name") else { throw HTTPError(.notFound) }
        let body = try await request.decode(as: PasswordChange.self, context: context)
        do { return json(try await storaged.admin(["PASSWD", name, Data(body.password.utf8).base64EncodedString()])) } catch { throw adminFailure(error) }
    }
    admin.put("users/:name/admin") { request, context in
        guard let name = context.parameters.get("name") else { throw HTTPError(.notFound) }
        let body = try await request.decode(as: AdminFlag.self, context: context)
        do { return json(try await storaged.admin(["ADMIN", name, body.admin ? "1" : "0"])) } catch { throw adminFailure(error) }
    }
    admin.delete("users/:name") { _, context in
        guard let name = context.parameters.get("name") else { throw HTTPError(.notFound) }
        guard name != context.user else { throw HTTPError(.badRequest, message: "You can't remove yourself.") }
        do {
            let answer = try await storaged.admin(["USERDEL", name])
            try await store.removeAccessRules(principal: "user:" + name)
            await syncAccounts()
            return json(answer)
        } catch { throw adminFailure(error) }
    }
    admin.delete("devices/:id") { _, context in
        guard let id = context.parameters.get("id") else { throw HTTPError(.notFound) }
        do { return json(try await storaged.admin(["DEVREVOKE", id])) } catch { throw adminFailure(error) }
    }

    admin.get("shares") { _, _ in
        do {
            var answer = try JSONSerialization.jsonObject(with: try await storaged.admin(["SHARES"])) as? [String: Any] ?? [:]
            answer["active"] = shares.map { ["name": $0.name, "path": $0.path] }
            return try json(answer)
        } catch { throw adminFailure(error) }
    }
    admin.put("shares") { request, _ in
        let body = try await request.body.collect(upTo: 1 << 20)
        do { return json(try await storaged.admin(["SHARESET", Data(buffer: body).base64EncodedString()])) } catch { throw adminFailure(error) }
    }
    admin.post("removed-shares/:name/purge") { _, context in
        guard let name = context.parameters.get("name") else { throw HTTPError(.notFound) }
        guard !shares.contains(where: { $0.name == name }) else { throw HTTPError(.badRequest, message: "That share is served.") }
        guard try await store.purgeRemovedShare(name) else { throw HTTPError(.notFound) }
        await accessCache.refresh()
        return try json(["ok": true])
    }
    admin.get("homes") { _, _ in
        do { return json(try await storaged.admin(["HOMES"])) } catch { throw adminFailure(error) }
    }
    admin.put("homes") { request, _ in
        let body = try await request.body.collect(upTo: 1 << 16)
        do {
            let answer = try await storaged.admin(["HOMESET", Data(buffer: body).base64EncodedString()])
            await accessCache.refresh()
            return json(answer)
        } catch { throw adminFailure(error) }
    }
    admin.post("apply") { _, _ in
        do { return json(try await storaged.admin(["APPLY"])) } catch { throw adminFailure(error) }
    }

    /// A folder's entries, with FaNG's view where it's inside a share: each entry's item (for thumbnails),
    /// and the folder's permissions.
    admin.get("browse") { request, _ in
        let path = request.uri.queryParameters.get("path") ?? ""
        do {
            var listing = try JSONSerialization.jsonObject(with: try await storaged.admin(["BROWSE", Data(path.utf8).base64EncodedString()])) as? [String: Any] ?? [:]
            let folder = listing["path"] as? String ?? path
            if let (share, inner) = shareLocation(folder) {
                listing["share"] = share.name
                listing["sharePath"] = inner
                if let item = try await store.liveItem(share: share.name, path: inner) {
                    var byName: [String: Item] = [:]
                    var after: String?
                    repeat {
                        let page = try await store.children(of: item.id, after: after, limit: 2000)
                        for child in page { byName[child.name] = child }
                        after = page.count == 2000 ? page.last?.name : nil
                    } while after != nil
                    let ready = try await store.readyThumbnails(Array(byName.values.map(\.id)))
                    if var entries = listing["entries"] as? [[String: Any]] {
                        for index in entries.indices {
                            guard let name = entries[index]["name"] as? String, let child = byName[name] else { continue }
                            entries[index]["id"] = child.id.uuidString
                            entries[index]["thumb"] = ready.contains(child.id)
                            entries[index]["tracked"] = true
                        }
                        listing["entries"] = entries
                    }
                }
                listing["permissions"] = try await permissions(share: share.name, path: inner)
            } else if let root = shares.first(where: { $0.path.hasPrefix(folder + "/") }) {
                listing["containsShare"] = root.name
            }
            return try json(listing)
        } catch { throw adminFailure(error) }
    }

    admin.get("acl") { request, _ in
        guard let share = request.uri.queryParameters.get("share"), shares.contains(where: { $0.name == share }) else { throw HTTPError(.badRequest) }
        return try json(try await permissions(share: share, path: request.uri.queryParameters.get("path") ?? ""))
    }
    admin.put("acl") { request, context in
        let body = try await request.decode(as: AccessChange.self, context: context)
        guard shares.contains(where: { $0.name == body.share }) else { throw HTTPError(.badRequest) }
        if body.principal.hasPrefix("group:") {
            // Taking a rule away is always allowed; giving one needs the group to exist.
            guard try await store.groupExists(String(body.principal.dropFirst(6))) || body.access == nil else {
                throw HTTPError(.badRequest, message: "No such group.")
            }
        } else if body.principal.hasPrefix("user:") {
            guard userNames().contains(String(body.principal.dropFirst(5))) || body.access == nil else {
                throw HTTPError(.badRequest, message: "No such user.")
            }
        } else if body.principal != "everyone" {
            throw HTTPError(.badRequest)
        }
        let level = try body.access.map { value -> Access in
            guard let level = Access(rawValue: value) else { throw HTTPError(.badRequest) }
            return level
        }
        try await store.setAccessRule(share: body.share, path: body.path, principal: body.principal, access: level)
        await accessCache.refresh()
        return try json(try await permissions(share: body.share, path: body.path))
    }

    admin.get("thumb/:id") { _, context -> Response in
        guard let id = context.parameters.get("id", as: UUID.self), let file = try await store.thumbnailFile(id),
              let data = FileManager.default.contents(atPath: thumbnailsFolder + "/" + file) else { throw HTTPError(.notFound) }
        return Response(status: .ok, headers: [.contentType: "image/webp", .cacheControl: "private, max-age=3600"],
                        body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}

/// The share a container path is in, and the path inside it.
func shareLocation(_ path: String) -> (Share, String)? {
    for share in shares.sorted(by: { $0.path.count > $1.path.count }) {
        if path == share.path { return (share, "") }
        if path.hasPrefix(share.path + "/") { return (share, String(path.dropFirst(share.path.count + 1))) }
    }
    return nil
}

/// The rules set on a path, and what every user may do there in the end (and from where it comes).
func permissions(share: String, path: String) async throws -> [String: Any] {
    await accessCache.refresh()
    let rules = accessCache.rules
    let users = (try JSONSerialization.jsonObject(with: try await storaged.admin(["USERS"])) as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    var effective: [[String: Any]] = []
    for user in users.sorted() {
        let ruled = rules.ruled(user: user, share: share, path: path)
        effective.append(["user": user, "access": rules.access(user: user, share: share, path: path).rawValue,
                          "through": ruled == .none && rules.isPassedThrough(user: user, share: share, path: path)])
    }
    let here = rules.rules(share: share, path: path).map { principal, access in
        ["principal": principal, "access": access.rawValue,
         "home": rules.homes.contains(AccessRule(share: share, path: path, principal: principal, access: access))] as [String: Any]
    }
    return ["share": share, "path": path, "rules": here, "effective": effective]
}

extension ItemStore {
    /// Items among these whose thumbnail is ready for their current contents.
    func readyThumbnails(_ ids: [UUID]) async throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        var ready = Set<UUID>()
        let rows = try await client.query("""
            SELECT t.item FROM thumbnails t JOIN items i ON i.id = t.item
            WHERE t.item = ANY(\(ids)) AND t.status = 'ready' AND t.content_version = i.content_version
            """, logger: logger)
        for try await id in rows.decode(UUID.self) { ready.insert(id) }
        return ready
    }

    /// Figures for the admin overview.
    func adminCounts() async throws -> [String: Any] {
        func number(_ sql: String) async throws -> Int64 {
            for try await value in try await client.query(PostgresQuery(unsafeSQL: sql), logger: logger).decode(Int64.self) { return value }
            return 0
        }
        func date(_ sql: String) async throws -> Double? {
            for try await value in try await client.query(PostgresQuery(unsafeSQL: sql), logger: logger).decode(Date?.self) { return value?.timeIntervalSince1970 }
            return nil
        }
        let extensions = Thumbnails.allExtensions.map { "'\($0)'" }.joined(separator: ",")
        return [
            "items": try await number("SELECT count(*) FROM items WHERE NOT deleted AND NOT trashed AND left(path, 6) <> '.fang-'"),
            "folders": try await number("SELECT count(*) FROM items WHERE NOT deleted AND is_dir"),
            "mediaWithoutThumbnail": try await number("""
                SELECT count(*) FROM items i LEFT JOIN thumbnails t ON t.item = i.id AND t.content_version = i.content_version
                WHERE NOT i.deleted AND NOT i.trashed AND NOT i.is_dir AND i.job_state IS NULL AND i.ext IN (\(extensions)) AND t.item IS NULL
                """),
            "thumbnailsFailed": try await number("SELECT count(*) FROM thumbnails WHERE status = 'failed'"),
            "sharedThumbnails": try await number("SELECT count(*) FROM thumbnail_blobs"),
            "versionThumbnails": try await number("SELECT count(*) FROM version_thumbnails"),
            "copyJobs": try await number("SELECT count(*) FROM items WHERE job_state = 'copying'"),
            "failedCopies": try await number("SELECT count(*) FROM items WHERE job_state = 'failed' AND NOT deleted"),
            "openConflicts": try await number("SELECT count(DISTINCT item) FROM versions WHERE kind = 'branch' AND NOT resolved"),
            "latestChange": try await number("SELECT coalesce(max(seq), 0) FROM items"),
            "prunedBelow": try await number("SELECT pruned_below FROM server"),
            "accessRules": try await number("SELECT count(*) FROM acl_rules"),
            "oldestTrash": try await date("SELECT min(trashed_at) FROM items WHERE trashed AND NOT deleted") as Any,
            "oldestVersion": try await date("SELECT min(created) FROM versions") as Any,
            "tables": try await tableSizes(),
        ]
    }

    private func tableSizes() async throws -> [[String: Any]] {
        var result: [[String: Any]] = []
        let rows = try await client.query("""
            SELECT relname::text, pg_total_relation_size(c.oid) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = 'public' AND c.relkind = 'r' ORDER BY 2 DESC LIMIT 12
            """, logger: logger)
        for try await (name, bytes) in rows.decode((String, Int64).self) { result.append(["name": name, "bytes": bytes]) }
        return result
    }
}
