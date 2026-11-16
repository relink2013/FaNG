import FaNGCore
import Foundation
import Hummingbird
import HummingbirdTLS
import HummingbirdWebSocket
import Logging
import NIOCore
import NIOSSL
import PostgresNIO

let version = "0.2.0-m2"

/// What `GET /.well-known/fang` answers, so a client can tell a FaNG server from plain SMB.
struct Detection: ResponseEncodable {
    var server = "FaNG"
    var version: String
    var api = "/v1"
    var epoch: UUID
    var capabilities = ["items", "changes", "xattrs", "delta", "storage"]
    /// The server's public address, when one is set.
    var url: String?
}

struct Health: ResponseEncodable {
    var status: String
    var database: String
    var samba: String
    var shares: [String]
}

struct ShareInfo: ResponseEncodable {
    var name: String
    var root: Item?
}

struct ChildrenPage: ResponseEncodable {
    var items: [Item]
    /// Pass as `after` for the next page; nil on the last one.
    var next: String?
}

struct ChangesPage: ResponseEncodable {
    var epoch: UUID
    var items: [Item]
    /// The change number to ask from next time.
    var anchor: Int64
    var more: Bool
    /// The share's latest change number, so a new client can start from now.
    var latest: Int64
}

extension Item: ResponseEncodable {}

struct Context: RequestContext {
    var coreContext: CoreRequestContextStorage
    /// The signed-in FaNG user and device, set by `DeviceAuthentication`.
    var user: String?
    var device: String?
    var remoteAddress: SocketAddress?

    init(source: Source) {
        coreContext = .init(source: source)
        remoteAddress = source.channel.remoteAddress
    }
}

struct DeviceAuthentication: RouterMiddleware {
    let devices: Devices

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer "),
              let user = devices.user(forToken: header.dropFirst(7))
        else { throw HTTPError(.unauthorized) }
        var context = context
        context.user = user
        context.device = Devices.device(forToken: header.dropFirst(7))
        // Items going out name this user's home share "Home" (the response is made inside this scope).
        return try await SharePresentation.$user.withValue(user) {
            try await next(request, context)
        }
    }
}

let environment = ProcessInfo.processInfo.environment
let config = try Config.fromEnvironment()
let logger = {
    var logger = Logger(label: "fang-api")
    logger.logLevel = config.logLevel
    return logger
}()

// Only the shares fang-storaged serves (one whose folder is missing, not writable or an Unraid root is left out).
// Home shares (each user's home folder, "~name", which that user sees as "Home") included.
let shares = try Share.loadAll(sharesFile: config.sharesFile).filter { $0.problem == nil }

/// The share a request names, as FaNG knows it: "Home" is the user's own home share.
func requestedShare(_ request: Request, _ context: Context) -> String? {
    request.uri.queryParameters.get("share").map { Share.meant(String($0), by: context.user) }
}
let database = PostgresClient(configuration: config.postgres, backgroundLogger: logger)
let store = ItemStore(client: database, logger: logger)
let devices = Devices(
    folder: environment["FANG_DEVICES_FOLDER"] ?? "/config/fang-share/devices",
    usersFile: environment["FANG_USERS_FILE"] ?? "/config/users"
)
let pageLimit = 200
let publicCertificate = PublicCertificate(
    certificateFile: environment["FANG_PUBLIC_TLS_CERT"] ?? "/config/tls/public/cert.pem",
    keyFile: environment["FANG_PUBLIC_TLS_KEY"] ?? "/config/tls/public/key.pem",
    logger: logger
)

/// Every request the server couldn't carry out, in the log with its reason: the route (IDs only, never a query,
/// which can hold a path) and the error. Without it a device only ever saw "500".
struct FailureLog: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            let response = try await next(request, context)
            if response.status.code >= 500 { context.logger.error("\(request.method) \(request.uri.path) answered \(response.status.code)") }
            return response
        } catch {
            let status = (error as? HTTPError)?.status.code ?? 500
            if status >= 500 { context.logger.error("\(request.method) \(request.uri.path) failed (\(status)): \(error)") }
            throw error
        }
    }
}

let router = Router(context: Context.self)
router.add(middleware: FailureLog())
router.get("/.well-known/fang") { _, _ in
    Detection(version: version, epoch: try await store.epoch(), url: serverAddress.current.url)
}
router.get("/health") { _, context in
    let databaseOK = await (try? database.query("SELECT 1", logger: context.logger)) != nil
    let sambaOK = sambaIsRunning(pidFile: config.sambaPIDFile)
    return Health(
        status: databaseOK && sambaOK ? "ok" : "degraded",
        database: databaseOK ? "ok" : "unreachable",
        samba: sambaOK ? "ok" : "not running",
        shares: shares.map(\.name)
    )
}

let api = router.group("v1").add(middleware: DeviceAuthentication(devices: devices))
api.get("whoami") { _, context in
    ["user": context.user ?? ""]
}
api.get("shares") { _, context in
    var infos: [ShareInfo] = []
    for share in shares {
        guard let root = try await store.root(of: share.name), let shown = visible(root, context) else { continue }
        infos.append(ShareInfo(name: Share.presented(share.name, to: context.user), root: shown))
    }
    return infos
}
api.get("items/:id") { _, context in
    guard let id = context.parameters.get("id", as: UUID.self), let item = try await store.item(id) else {
        throw HTTPError(.notFound)
    }
    // A deleted item answers as it is (a device learns it's gone); otherwise only what this user may see.
    if item.deleted { return item }
    guard let shown = visible(item, context) else { throw HTTPError(.notFound) }
    return shown
}
api.get("items/:id/children") { request, context in
    guard let id = context.parameters.get("id", as: UUID.self) else { throw HTTPError(.notFound) }
    try await require(id, .read, context)
    let after = request.uri.queryParameters.get("after")
    let all = try await store.children(of: id, after: after, limit: pageLimit)
    let items = all.compactMap { visible($0, context) }
    // A folder being opened: its media go to the front of the thumbnail queue, so they're ready by the time
    // the system asks (one statement; nothing happens for files that have theirs).
    let media = items.filter { !$0.isDirectory && Thumbnails.allExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }.map(\.id)
    if !media.isEmpty { try? await store.wantThumbnails(media) }
    return ChildrenPage(items: items, next: all.count == pageLimit ? all.last?.name : nil)
}
api.get("changes") { request, context in
    guard let share = requestedShare(request, context), shares.contains(where: { $0.name == share }) else {
        throw HTTPError(.badRequest, message: "Unknown share.")
    }
    let since = request.uri.queryParameters.get("since", as: Int64.self) ?? 0
    // Records of items deleted longer ago than the retention are gone: an anchor from before then can't be
    // brought up to date, and the client lists everything again (File Provider's "sync anchor expired").
    if since > 0, since < (try await store.prunedBelow()) {
        throw HTTPError(.gone, message: "anchor expired")
    }
    // Up to 1,000 a page: catching up after a big copy shouldn't take hundreds of round trips.
    let limit = min(max(request.uri.queryParameters.get("limit", as: Int.self) ?? pageLimit, 1), 5000)
    let found = try await store.changes(share: share, since: since, limit: limit)
    // What this user may not see arrives as deleted: a device that had it removes it.
    let items = found.map { item -> Item in
        if item.deleted { return item }
        if let shown = visible(item, context) { return shown }
        var hidden = item
        hidden.deleted = true
        return hidden
    }
    return ChangesPage(
        epoch: try await store.epoch(),
        items: items,
        anchor: found.last?.seq ?? since,
        more: found.count == limit,
        latest: try await store.latestChange(share: share)
    )
}

let storaged = Storaged(socketPath: environment["FANG_STORAGED_SOCKET"] ?? "/run/fang/storaged.sock")
let changeFeed = ChangeFeed(store: store)
let accessCache = AccessCache(store: store)

/// What the signed-in user may do with an item.
func access(_ item: Item, _ context: Context) -> Access {
    accessCache.rules.access(user: context.user ?? "", share: item.share, path: item.permissionPath)
}

/// The item as this user may see it (with what they may do), or nil if they may not see it.
func visible(_ item: Item, _ context: Context) -> Item? {
    let level = access(item, context)
    guard level != .none else { return nil }
    var item = item
    item.access = level.rawValue
    return item
}

/// The item, if the user has at least `needed` on it: 404 if they may not see it, 403 if they may only read.
@discardableResult
func require(_ id: UUID, _ needed: Access, _ context: Context) async throws -> Item {
    guard let item = try await store.item(id), !item.deleted || needed == .read else { throw HTTPError(.notFound) }
    let level = access(item, context)
    guard level != .none else { throw HTTPError(.notFound) }
    guard level >= needed else { throw HTTPError(.forbidden, message: "read only") }
    return item
}

/// The item at a path, looked at on disk right now: how a client learns the ID of a file it just wrote
/// over SMB. Query: share, path (inside the share).
api.get("resolve") { request, context in
    guard let share = requestedShare(request, context), shares.contains(where: { $0.name == share }),
          let path = request.uri.queryParameters.get("path")
    else { throw HTTPError(.badRequest) }
    guard let id = try await storaged.resolve(share: share, path: path), let item = try await store.item(id),
          let shown = visible(item, context) else {
        throw HTTPError(.notFound)
    }
    return shown
}

struct CommitRequest: Decodable {
    /// The upload temp file's name, in the item's folder.
    var temp: String
    /// The content version the edit started from.
    var baseVersion: Int64
    /// When the edit was saved, in nanoseconds since 1970 (decides which side of a conflict stays).
    var modifiedNS: Int64
    /// Where the client sees the file, inside the share (it may know of a rename the server hasn't seen yet).
    var path: String?
}

struct CommitResponse: ResponseEncodable {
    var item: Item
    var conflict: Bool
    /// Whether the edit became the file. If not (it lost a conflict and was kept as a branch), the client's
    /// copy isn't the file any more, and it must fetch the file again.
    var editWon: Bool
}

extension Version: ResponseEncodable {}
extension StorageReport: ResponseEncodable {}

/// Puts new contents uploaded over SMB in place, checking the base version and keeping the old contents.
api.post("items/:id/commit") { request, context in
    guard let id = context.parameters.get("id", as: UUID.self) else { throw HTTPError(.notFound) }
    let item = try await require(id, .write, context)
    let body = try await request.decode(as: CommitRequest.self, context: context)
    do {
        let (committed, conflict, editWon) = try await storaged.commit(share: item.share, id: id, temp: body.temp, base: body.baseVersion,
                                                              modifiedNS: body.modifiedNS, device: context.device ?? "unknown", path: body.path)
        guard let result = try await store.item(committed) else { throw HTTPError(.notFound) }
        return CommitResponse(item: result, conflict: conflict, editWon: editWon)
    } catch let error as Storaged.StoragedError {
        throw HTTPError(error.reason == "notfound" || error.reason == "notemp" ? .notFound : .internalServerError, message: error.reason)
    }
}
api.get("items/:id/versions") { _, context in
    guard let id = context.parameters.get("id", as: UUID.self) else { throw HTTPError(.notFound) }
    try await require(id, .read, context)
    return try await store.versions(of: id)
}
/// A version's contents, streamed from the share's version store, for previews in the versions view.
/// (Every FaNG user can read everything until FaNG's own ACLs exist; see the share's default ACL.)
let fileIO = FileIO(threadPool: .singleton)
api.get("versions/:id/content") { _, context -> Response in
    guard let id = context.parameters.get("id", as: Int64.self), let version = try await store.version(id),
          let share = shares.first(where: { $0.name == version.share })
    else { throw HTTPError(.notFound) }
    try await require(version.item, .read, context)
    let path = share.path + "/" + version.path
    guard FileManager.default.fileExists(atPath: path) else { throw HTTPError(.notFound) }
    let body = try await fileIO.loadFile(path: path, context: context)
    return Response(status: .ok, headers: [.contentType: "application/octet-stream"], body: body)
}
api.post("versions/:id/restore") { _, context in
    guard let version = context.parameters.get("id", as: Int64.self), let found = try await store.version(version) else { throw HTTPError(.notFound) }
    try await require(found.item, .write, context)
    let id = try await storaged.restore(version: version)
    guard let item = try await store.item(id) else { throw HTTPError(.notFound) }
    return item
}

struct UntrashRequest: Decodable {
    /// The folder to put it in; where it was if missing.
    var parent: UUID?
}

/// What's in a share's trash (the items that were deleted; what was below them stays below them).
api.get("trash") { request, context in
    guard let share = requestedShare(request, context), shares.contains(where: { $0.name == share }) else {
        throw HTTPError(.badRequest)
    }
    return try await store.trash(share: share).compactMap { visible($0, context) }
}
api.post("items/:id/trash") { _, context in
    guard let id = context.parameters.get("id", as: UUID.self) else { throw HTTPError(.notFound) }
    try await require(id, .write, context)
    return try await trashCommand("TRASH", id)
}
api.post("items/:id/untrash") { request, context in
    guard let id = context.parameters.get("id", as: UUID.self) else { throw HTTPError(.notFound) }
    try await require(id, .write, context)
    let body = (try? await request.decode(as: UntrashRequest.self, context: context)) ?? UntrashRequest()
    if let parent = body.parent { try await require(parent, .write, context) }
    return try await trashCommand("UNTRASH", id, parent: body.parent)
}
/// Deletes an item: into the trash, or for good if it's already there.
api.delete("items/:id") { _, context in
    guard let id = context.parameters.get("id", as: UUID.self) else { throw HTTPError(.notFound) }
    let item = try await require(id, .write, context)
    return try await trashCommand(item.trashed ? "PURGE" : "TRASH", id)
}

struct ChangeSignal: ResponseEncodable {
    /// The latest change number in any share.
    var latest: Int64
}

/// Long poll: answers as soon as anything changed after change number `since` (or after `timeout`
/// seconds, at most 55), so an active client learns of changes without push notifications.
api.get("changes/wait") { request, _ in
    let since = request.uri.queryParameters.get("since", as: Int64.self) ?? 0
    let timeout = min(request.uri.queryParameters.get("timeout", as: Int.self) ?? 25, 55)
    let latest = try await store.latestChange()
    if latest > since { return ChangeSignal(latest: latest) }
    // Waits on the shared feed (no query of its own) until something changes or the time is up.
    let changed = await withTaskGroup(of: Int64?.self) { group in
        group.addTask {
            for await value in changeFeed.subscribe() where value > since { return value }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(timeout))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
    return ChangeSignal(latest: changed ?? latest)
}

struct TagsRequest: Decodable {
    /// Finder tags, "name\ncolor" each.
    var tags: [String]
}

struct ResolveRequest: Decodable {
    /// keep, use or copy (see the server's resolve).
    var action: String
    var version: Int64?
}

/// An open conflict: the item as it is, and the edits that didn't become it.
struct Conflict: ResponseEncodable {
    var item: Item
    var branches: [Version]
    /// Conflicts from the same device within the same ten minutes share a group.
    var group: String
}

api.put("items/:id/tags") { request, context in
    guard let id = context.parameters.get("id", as: UUID.self) else { throw HTTPError(.notFound) }
    try await require(id, .write, context)
    let body = try await request.decode(as: TagsRequest.self, context: context)
    let json = String(decoding: try JSONEncoder().encode(body.tags), as: UTF8.self)
    return try await itemCommand("TAGS", id, [json])
}
api.get("conflicts") { _, context in
    var conflicts: [UUID: Conflict] = [:]
    var order: [UUID] = []
    for branch in try await store.openBranches() {
        if conflicts[branch.item] == nil, let found = try await store.item(branch.item), let item = visible(found, context) {
            let bucket = Int(branch.created.timeIntervalSince1970 / 600)
            conflicts[branch.item] = Conflict(item: item, branches: [], group: "\(branch.device ?? "unknown")-\(bucket)")
            order.append(branch.item)
        }
        conflicts[branch.item]?.branches.append(branch)
    }
    return order.compactMap { conflicts[$0] }
}
api.post("items/:id/resolve") { request, context in
    guard let id = context.parameters.get("id", as: UUID.self) else { throw HTTPError(.notFound) }
    try await require(id, .write, context)
    let body = try await request.decode(as: ResolveRequest.self, context: context)
    return try await itemCommand("SETTLE", id, [body.action] + (body.version.map { [String($0)] } ?? []))
}

struct TransferRequest: Decodable {
    /// The folder to copy or move into (in any share).
    var parent: UUID
    /// The name there; the item's own by default. A taken name gets " 2" (" copy" for a copy in the same folder).
    var name: String?
}

/// Copies an item (a folder with everything in it) into a folder on the server: reflinks where the
/// filesystem can, so nothing travels through the client. Answers the new item.
api.post("items/:id/copy") { request, context in
    guard let id = context.parameters.get("id", as: UUID.self) else { throw HTTPError(.notFound) }
    let body = try await request.decode(as: TransferRequest.self, context: context)
    try await require(id, .read, context)
    try await require(body.parent, .write, context)
    return try await transfer("COPY", id, body)
}
/// Moves an item into a folder on the server, in the same share or another. It keeps its ID. Answers the item.
api.post("items/:id/move") { request, context in
    guard let id = context.parameters.get("id", as: UUID.self) else { throw HTTPError(.notFound) }
    let body = try await request.decode(as: TransferRequest.self, context: context)
    try await require(id, .write, context)
    try await require(body.parent, .write, context)
    return try await transfer("MOVE", id, body)
}

/// One copy in the app's list: running (with what it's doing, entries and bytes, the file it's on) or
/// failed (with why). A copy leaves the list on its own only when it succeeds; a failed one stays until
/// its item is deleted.
struct CopyJob: Codable {
    var item: Item
    var state: String
    var phase: String?
    var entriesDone: Int?
    var entriesTotal: Int?
    var bytesDone: Int64?
    var bytesTotal: Int64?
    var current: String?
    var started: Date?
    var error: String?
}

struct RunningCopy: Decodable {
    var id: UUID
    var phase: String
    var entriesDone: Int
    var entriesTotal: Int
    var bytesDone: Int64
    var bytesTotal: Int64
    var current: String?
    var started: Date
}

struct CopyJobs: ResponseEncodable {
    var jobs: [CopyJob]
}

api.get("jobs") { _, context in
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let running = (try? decoder.decode([RunningCopy].self, from: try await storaged.jobs())) ?? []
    var jobs: [CopyJob] = []
    for copy in running {
        guard let found = try await store.item(copy.id), found.jobState == "copying", let item = visible(found, context) else { continue }
        jobs.append(CopyJob(item: item, state: "copying", phase: copy.phase, entriesDone: copy.entriesDone, entriesTotal: copy.entriesTotal,
                            bytesDone: copy.bytesDone, bytesTotal: copy.bytesTotal, current: copy.current, started: copy.started))
    }
    for (item, reason) in try await store.failedCopies() where visible(item, context) != nil {
        jobs.append(CopyJob(item: item, state: "failed", error: reason ?? "The copy failed."))
    }
    return CopyJobs(jobs: jobs)
}

func transfer(_ command: String, _ id: UUID, _ body: TransferRequest) async throws -> Item {
    do {
        let result = try await storaged.transfer(command, id, into: body.parent, name: body.name)
        guard let item = try await store.item(result) else { throw HTTPError(.notFound) }
        return item
    } catch let error as Storaged.StoragedError {
        switch error.reason {
        case "notfound": throw HTTPError(.notFound, message: error.reason)
        case "badname", "badrequest": throw HTTPError(.badRequest, message: error.reason)
        case "intoitself", "changed", "busy": throw HTTPError(.conflict, message: error.reason)
        default: throw HTTPError(.internalServerError, message: error.reason)
        }
    }
}

func itemCommand(_ command: String, _ id: UUID, _ arguments: [String]) async throws -> Item {
    do {
        let result = try await storaged.itemCommand(command, id, arguments)
        guard let item = try await store.item(result) else { throw HTTPError(.notFound) }
        return item
    } catch let error as Storaged.StoragedError {
        throw HTTPError(error.reason == "notfound" ? .notFound : .internalServerError, message: error.reason)
    }
}

func trashCommand(_ command: String, _ id: UUID, parent: UUID? = nil) async throws -> Item {
    do {
        let result = try await storaged.trashCommand(command, id, parent: parent)
        guard let item = try await store.item(result) else { throw HTTPError(.notFound) }
        return item
    } catch let error as Storaged.StoragedError {
        throw HTTPError(error.reason == "notfound" ? .notFound : error.reason == "busy" ? .conflict : .internalServerError, message: error.reason)
    }
}

let thumbnailsFolder = environment["FANG_THUMBNAILS"] ?? "/thumbnails"

/// An item's thumbnail (WebP). One that isn't made yet goes to the front of the queue, and the request
/// waits a few seconds for it, so a folder being browsed fills in at once.
api.get("items/:id/thumbnail") { _, context -> Response in
    // A copy still being made has nothing to make a thumbnail from yet.
    guard let id = context.parameters.get("id", as: UUID.self), let item = try await store.item(id), !item.isDirectory, item.jobState == nil,
          access(item, context) != .none else {
        throw HTTPError(.notFound)
    }
    var ready = try await store.thumbnailReady(id)
    if !ready, !(try await store.thumbnailFailed(id)),
       Thumbnails.allExtensions.contains((item.name as NSString).pathExtension.lowercased()) {
        try await store.wantThumbnail(id)
        for _ in 0..<40 where !ready {
            try await Task.sleep(for: .milliseconds(250))
            ready = try await store.thumbnailReady(id)
            if !ready, try await store.thumbnailFailed(id) { break }
        }
    }
    guard ready, let file = try await store.thumbnailFile(id),
          let data = FileManager.default.contents(atPath: thumbnailsFolder + "/" + file) else {
        throw HTTPError(.notFound)
    }
    return Response(
        status: .ok,
        headers: [.contentType: "image/webp", .cacheControl: "private, max-age=86400"],
        body: .init(byteBuffer: ByteBuffer(bytes: data))
    )
}

/// A version's thumbnail (WebP), made when first asked for: the request waits a few seconds for it.
api.get("versions/:id/thumbnail") { _, context -> Response in
    guard let id = context.parameters.get("id", as: Int64.self), let version = try await store.version(id),
          Thumbnails.allExtensions.contains((version.path as NSString).pathExtension.lowercased())
    else { throw HTTPError(.notFound) }
    try await require(version.item, .read, context)
    var status = try await store.versionThumbnailStatus(id)
    if status == nil {
        try await store.wantVersionThumbnail(id)
        for _ in 0..<40 where status == nil {
            try await Task.sleep(for: .milliseconds(250))
            status = try await store.versionThumbnailStatus(id)
        }
    }
    guard status == "ready", let file = try await store.versionThumbnailFile(id),
          let data = FileManager.default.contents(atPath: thumbnailsFolder + "/" + file) else {
        throw HTTPError(.notFound)
    }
    return Response(
        status: .ok,
        headers: [.contentType: "image/webp", .cacheControl: "private, max-age=86400"],
        body: .init(byteBuffer: ByteBuffer(bytes: data))
    )
}

struct MetadataRequest: Decodable {
    /// Extended attribute name → value (base64 in JSON).
    var xattrs: [String: Data]
}

/// Sets an item's client metadata: the extended attributes File Provider syncs (folder symbols and emoji, …).
api.put("items/:id/xattrs") { request, context in
    guard let id = context.parameters.get("id", as: UUID.self) else { throw HTTPError(.notFound) }
    try await require(id, .write, context)
    let body = try await request.decode(as: MetadataRequest.self, context: context)
    let json = String(decoding: try JSONEncoder().encode(body.xattrs.mapValues { $0.base64EncodedString() }), as: UTF8.self)
    return try await itemCommand("XATTRS", id, [json])
}

struct StageRequest: Decodable {
    /// The upload temp name (".fang-upload-…") in the item's folder.
    var temp: String
}

struct Blocks: ResponseEncodable {
    var item: Item
    var size: Int64
    var blockSize: Int
    /// SHA-256 of each block, concatenated, in base64.
    var hashes: String
}

/// A delta upload's first step: the file's contents cloned to the temp name, with a hash of every block, so
/// the client only sends the blocks that differ (then commits as usual).
api.post("items/:id/stage") { request, context in
    guard let id = context.parameters.get("id", as: UUID.self) else { throw HTTPError(.notFound) }
    try await require(id, .write, context)
    let body = try await request.decode(as: StageRequest.self, context: context)
    do {
        _ = try await storaged.itemCommand("STAGE", id, [body.temp])
    } catch let error as Storaged.StoragedError {
        throw HTTPError(error.reason == "notfound" ? .notFound : error.reason == "badtemp" ? .badRequest : .internalServerError, message: error.reason)
    }
    guard let item = try await store.item(id), let share = shares.first(where: { $0.name == item.share }) else { throw HTTPError(.notFound) }
    let folder = item.path.split(separator: "/").dropLast().joined(separator: "/")
    let (size, blockSize, hashes) = try await storaged.blocks(share: share.name, path: folder.isEmpty ? body.temp : folder + "/" + body.temp)
    return Blocks(item: item, size: size, blockSize: blockSize, hashes: hashes.base64EncodedString())
}

/// Block hashes of a file's current contents, for a delta download (the client keeps the blocks it has).
api.get("items/:id/blocks") { _, context in
    guard let id = context.parameters.get("id", as: UUID.self), let before = try await store.item(id), !before.isDirectory,
          access(before, context) != .none,
          let share = shares.first(where: { $0.name == before.share })
    else { throw HTTPError(.notFound) }
    let (size, blockSize, hashes) = try await storaged.blocks(share: share.name, path: before.path)
    // Changed while it was read: the hashes don't describe one version.
    guard let after = try await store.item(id), after.contentVersion == before.contentVersion, after.path == before.path else {
        throw HTTPError(.conflict, message: "changed")
    }
    return Blocks(item: after, size: size, blockSize: blockSize, hashes: hashes.base64EncodedString())
}

/// Where the server's own storage goes (trash, versions, thumbnails, database), with the retention rules,
/// so space never grows without an explanation.
api.get("storage") { _, _ in
    try await store.storageReport()
}

func sambaIsRunning(pidFile: String) -> Bool {
    guard let text = try? String(contentsOfFile: pidFile, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return false }
    // fang-api runs as nobody: "not permitted" still means the process is there.
    return kill(pid, 0) == 0 || errno == EPERM
}

var tls = try TLSConfiguration.makeServerConfiguration(
    certificateChain: NIOSSLCertificate.fromPEMFile(environment["FANG_TLS_CERT"] ?? "/config/tls/cert.pem").map { .certificate($0) },
    privateKey: .privateKey(try NIOSSLPrivateKey(file: environment["FANG_TLS_KEY"] ?? "/config/tls/key.pem", format: .pem))
)
// A connection that asks for the public name gets that name's certificate (see PublicCertificate).
tls.sslContextCallback = { values, promise in publicCertificate.choose(values, promise) }
/// Live changes for active clients, instead of push notifications (which need a paid developer account)
/// or polling (which costs battery): one WebSocket, signed in with the device token. The server sends
/// {"latest": N} on connect and whenever the latest change number moves; the client just listens.
let webSocketRouter = Router(context: BasicWebSocketRequestContext.self)
webSocketRouter.ws("v1/events") { request, _ in
    guard let header = request.headers[.authorization], header.hasPrefix("Bearer "),
          devices.user(forToken: header.dropFirst(7)) != nil
    else { return .dontUpgrade }
    return .upgrade([:])
} onUpgrade: { inbound, outbound, _ in
    try await withThrowingTaskGroup(of: Void.self) { group in
        // Ends when the client goes away.
        group.addTask {
            for try await _ in inbound {}
        }
        group.addTask {
            var sent = try await store.latestChange()
            try await outbound.write(.text("{\"latest\":\(sent)}"))
            // Every change from the shared feed (one query for all clients), as it happens.
            for await latest in changeFeed.subscribe() where latest != sent {
                try await outbound.write(.text("{\"latest\":\(latest)}"))
                sent = latest
            }
        }
        try await group.next()
        group.cancelAll()
    }
}

registerAdmin(router)
registerServerName(api: api, admin: router.group("admin/api/settings").add(middleware: AdminSession()), publicCertificate: publicCertificate)

var app = Application(
    router: router,
    server: try .tls(.http1WebSocketUpgrade(webSocketRouter: webSocketRouter), tlsConfiguration: tls),
    configuration: .init(address: .hostname("0.0.0.0", port: config.httpPort), serverName: "FaNG"),
    services: [database],
    logger: logger
)
app.beforeServerStarts {
    try await Migrations.apply(on: database, logger: logger)
    try await Share.sync(shares, on: database, logger: logger)
    serverAddress.current = try await store.serverAddress()
    await syncAccounts()
    logger.info("Serving shares: \(shares.map(\.name).joined(separator: ", "))")
}
Task { await changeFeed.run() }
Task { await accessCache.run() }
try await app.runService()
