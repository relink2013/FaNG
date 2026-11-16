// fang-storaged: FaNG's privileged storage daemon. It scans the shares, gives every file and folder a
// FaNG ID (the `user.fang.id` xattr), and follows changes with fanotify, keeping the items table and
// its change numbers current. It has no network listener; fang-api reads what it records.

#if os(Linux)
import CLinuxFS
import FaNGCore
import Foundation
import Glibc
import Logging
import PostgresNIO

/// One thing to look at, from fanotify.
enum Hint: Hashable {
    case path(String, isNewDirectory: Bool)
    case rename(from: String?, to: String?, isDirectory: Bool)
    case overflow
}

/// Reads fanotify on a thread of its own (the read blocks) and collects hints. A big copy reports the same
/// paths over and over (create, writes, close); while hints wait to be taken, repeats collapse into one.
final class Watcher: @unchecked Sendable {
    private let fan: Int32
    private var mounts: [Int32] = []
    /// Fires when hints are waiting; `take()` gets them.
    let ready: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var pending: [Hint] = []
    private var pendingSet: Set<Hint> = []

    private var fsids: [UInt64] = []
    /// How many filesystems are watched (shares on several pools, and ZFS datasets inside a share).
    var filesystemCount: Int { mounts.count }

    init(paths: [String]) throws {
        (ready, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        fan = fang_fanotify_open()
        guard fan >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Every filesystem a share spans: its own, and any mounted below it (on ZFS every child dataset is a
        // filesystem of its own, and a filesystem mark only covers one).
        for path in paths + Self.mountPoints(below: paths) {
            let fd = fang_fanotify_watch(fan, path)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var fsid: UInt64 = 0
            guard fang_fsid(fd, &fsid) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if fsids.contains(fsid) {
                close(fd)
                continue
            }
            mounts.append(fd)
            fsids.append(fsid)
        }
    }

    /// Mount points strictly below any of `paths`, from /proc/self/mountinfo (spaces and such come escaped).
    static func mountPoints(below paths: [String]) -> [String] {
        guard let info = readSystemFile("/proc/self/mountinfo") else { return [] }
        var found: [String] = []
        for line in info.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count > 4 else { continue }
            var point = String(fields[4])
            for (escaped, plain) in [("\\040", " "), ("\\011", "\t"), ("\\012", "\n"), ("\\134", "\\")] {
                point = point.replacingOccurrences(of: escaped, with: plain)
            }
            if paths.contains(where: { point.hasPrefix($0 + "/") }) { found.append(point) }
        }
        return found
    }

    func start() {
        let thread = Thread { [self] in
            let context = Unmanaged.passUnretained(self).toOpaque()
            let mounts = self.mounts, fsids = self.fsids
            while true {
                _ = fang_fanotify_read(fan, mounts, fsids, Int32(mounts.count), 1000, { event, context in
                    guard let event, let context else { return }
                    Unmanaged<Watcher>.fromOpaque(context).takeUnretainedValue().handle(event.pointee)
                }, context)
            }
        }
        thread.name = "fanotify"
        thread.start()
    }

    /// The waiting hints, in arrival order, each once.
    func take() -> [Hint] {
        lock.withLock {
            defer {
                pending = []
                pendingSet = []
            }
            return pending
        }
    }

    private func add(_ hint: Hint) {
        lock.withLock {
            if pendingSet.insert(hint).inserted {
                pending.append(hint)
            }
        }
        continuation.yield(())
    }

    private func handle(_ event: fang_event) {
        let mask = event.mask
        if mask & FANG_EV_OVERFLOW != 0 {
            add(.overflow)
            return
        }
        func join(_ dir: UnsafePointer<CChar>?, _ name: UnsafePointer<CChar>?) -> String? {
            guard let dir else { return nil }
            let directory = String(cString: dir)
            guard let name else { return directory }
            return directory + "/" + String(cString: name)
        }
        let isDirectory = mask & FANG_EV_ONDIR != 0
        if mask & FANG_EV_RENAME != 0 {
            let from = join(event.old_dir, event.old_name), to = join(event.dir, event.name)
            // Within FaNG's own folders (an upload's temp file renamed, a copy being made): nothing to record.
            if let from, let to, Tracker.isInternal(path: from), Tracker.isInternal(path: to) { return }
            add(.rename(from: from, to: to, isDirectory: isDirectory))
        } else if let path = join(event.dir, event.name) {
            // FaNG's own files (upload temp files, copies being made, versions, the trash) are never recorded
            // from events: a big copy makes several events per file, and they'd queue up in front of real changes.
            if Tracker.isInternal(path: path) { return }
            let appeared = mask & (FANG_EV_CREATE | FANG_EV_MOVED_TO) != 0
            add(.path(path, isNewDirectory: isDirectory && appeared))
        }
    }
}

/// When the tracker last answered the self-watchdog.
final class Heartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func beat() {
        lock.withLock { last = Date() }
    }

    var silence: TimeInterval {
        lock.withLock { Date().timeIntervalSince(last) }
    }
}

let config = try Config.fromEnvironment()
private extension String {
    /// An octal mask as the shares file writes it ("0664").
    var leftPadded: String { count >= 4 ? self : String(repeating: "0", count: 4 - count) + self }
}

let logger = {
    var logger = Logger(label: "fang-storaged")
    logger.logLevel = config.logLevel
    return logger
}()
let configuredShares = try Share.parse(String(contentsOfFile: config.sharesFile, encoding: .utf8))
// A share that can't be served (its folder missing, not writable, or an Unraid root) is left out, so the rest,
// and the admin page where it can be fixed, keep working.
let fileShares = configuredShares.filter { share in
    guard let problem = share.problem else { return true }
    FileHandle.standardError.write(Data("fang-storaged: not serving share \(share.name): \(problem)\n".utf8))
    return false
}
let client = PostgresClient(configuration: config.postgres, backgroundLogger: logger)

try await withThrowingDiscardingTaskGroup { group in
    group.addTask { await client.run() }
    try await Migrations.apply(on: client, logger: logger)
    let store = ItemStore(client: client, logger: logger)
    // The address set in the admin page, for the app (start.sh wrote only the certificate's fingerprint).
    do { try Admin.publish(try await store.serverAddress()) } catch { logger.error("Server address not published: \(error)") }
    // Home folders first (a user added since the last start gets theirs), so their shares are served now.
    do {
        let (_, problem) = try await Homes.sync(shares: fileShares, store: store)
        if let problem { logger.error("Home folders aren't served: \(problem)") }
    } catch { logger.error("Home folders: \(error)") }
    let homeShares = ((try? Share.parse(String(contentsOfFile: Share.homeSharesFile, encoding: .utf8))) ?? []).filter { share in
        guard share.homeOwner != nil else { return false }
        guard let problem = share.problem else { return true }
        logger.error("Not serving \(share.name)'s home: \(problem)")
        return false
    }
    let shares = fileShares + homeShares
    // For fang-thumbs (which sees only this folder of the config): exactly the shares served now.
    do {
        let served = (ProcessInfo.processInfo.environment["FANG_SERVED_SHARES_FILE"] ?? "/config/served/shares.conf")
        let text = "# The shares fang-storaged serves now (written at each start)\n" + shares.map {
            [$0.name, $0.path, String($0.createMask, radix: 8).leftPadded, String($0.directoryMask, radix: 8).leftPadded, $0.versions ? "versions" : ""]
                .joined(separator: "|")
        }.joined(separator: "\n") + "\n"
        if (try? String(contentsOfFile: served, encoding: .utf8)) != text {
            try text.write(toFile: served, atomically: true, encoding: .utf8)
            chmod(served, 0o644)
        }
    } catch { logger.error("Couldn't write the served shares for fang-thumbs: \(error)") }
    // Shares taken out of the shares file: their records are kept a while, then removed (upkeep below). One whose
    // folder is now (part of) another share's goes at once: its records describe the same files, under IDs the
    // new share's scan takes back from the files.
    try await store.noteRemovedShares(current: configuredShares.map(\.name) + homeShares.map(\.name))
    for name in try await store.purgeOverlappingRemovedShares(current: shares) {
        logger.info("Removed the records of share \(name): its folder is now served as part of another share")
    }
    // Permissions are closed by default; the users there were before that keep what they had, once.
    try await store.seedOpenAccess(shares: fileShares.map(\.name), users: Admin.userList().map(\.name))
    let tracker = Tracker(shares: shares, store: store, logger: logger)
    let access = AccessCache(store: store)
    await access.refresh()
    group.addTask { await access.run() }
    let acl = AclService(path: ProcessInfo.processInfo.environment["FANG_ACL_SOCKET"] ?? "/run/fang/acl.sock", cache: access,
                         usersFile: ProcessInfo.processInfo.environment["FANG_USERS_FILE"] ?? "/config/users")
    try acl.start()
    // Shares a user has nothing in are hidden from them (Samba's valid users), kept in step from here on.
    let visibility = ShareVisibility(shares: shares, cache: access, acl: acl)
    visibility.update()
    group.addTask { await visibility.run() }
    // A user added with fang-user gets their home folder within seconds too.
    group.addTask {
        var users = Admin.userList().map(\.name)
        while true {
            try await Task.sleep(for: .seconds(5))
            let now = Admin.userList().map(\.name)
            if now != users {
                users = now
                do { try await Homes.sync(shares: fileShares, store: store) } catch { logger.error("Home folders: \(error)") }
            }
        }
    }
    let control = Control(path: ProcessInfo.processInfo.environment["FANG_STORAGED_SOCKET"] ?? "/run/fang/storaged.sock",
                          tracker: tracker, store: store)
    try control.start()

    // Copies that were running when the server stopped are over: their items show as failed.
    if let failed = try? await store.failInterruptedCopies(), failed > 0 {
        logger.warning("\(failed) copies were cut off by the restart; their items are marked failed")
    }
    // Watch first, then scan, so nothing that changes during the scan is missed. The scan runs alongside
    // the changes (it takes minutes on a big share, and live changes mustn't wait for it).
    let watcher = try Watcher(paths: shares.map(\.path))
    watcher.start()
    control.watcherCount = watcher.filesystemCount
    logger.info("Watching \(watcher.filesystemCount) filesystems for \(shares.count) shares")
    logger.info("Resources: \(Resources.summary); scans use \(Tracker.scanThreads) threads, copies \(Copier.workers)")
    group.addTask {
        for share in shares {
            await tracker.fullScan(share, startup: true)
        }
    }
    // Self-watchdog: if the tracker stops answering for two minutes (a deadlock), exit, so the container
    // restarts instead of hanging silently. A full scan doesn't block this: the tracker answers between
    // its steps.
    let alive = Heartbeat()
    group.addTask {
        while true {
            try await Task.sleep(for: .seconds(30))
            _ = await tracker.ping()
            alive.beat()
        }
    }
    // The same for the database: once its client stopped getting connections (no error, every query just
    // waited), and the tracker kept answering pings while every request hung.
    let database = Heartbeat()
    group.addTask {
        while true {
            try await Task.sleep(for: .seconds(30))
            if (try? await client.query("SELECT 1", logger: logger)) != nil {
                database.beat()
            }
        }
    }
    Thread.detachNewThread {
        while true {
            Thread.sleep(forTimeInterval: 30)
            if alive.silence > 120 {
                logger.critical("The tracker hasn't answered for \(Int(alive.silence)) s; exiting so the container restarts")
                exit(1)
            }
            if database.silence > 120 {
                logger.critical("The database hasn't answered for \(Int(database.silence)) s; exiting so the container restarts")
                exit(1)
            }
        }
    }

    // Upkeep, so nothing grows quietly: the trash's and versions' retention and old deleted records a few
    // times a day, and once a day a scan that checks the records against the disk (and removes abandoned
    // uploads).
    group.addTask {
        var lastCheck = Date()
        try await Task.sleep(for: .seconds(600))  // After the startup scan settles.
        while true {
            await tracker.purgeExpired()
            await tracker.pruneVersions()
            await tracker.pruneDeletedRecords()
            do {
                for name in try await store.purgeExpiredRemovedShares() {
                    logger.info("Removed the records of share \(name), removed from the shares file over \(ItemStore.removedShareDays) days ago")
                }
            } catch { logger.error("Removed shares: \(error)") }
            if Date().timeIntervalSince(lastCheck) > 23 * 3600 {
                lastCheck = Date()
                for share in shares {
                    await tracker.fullScan(share)
                }
            }
            try await Task.sleep(for: .seconds(6 * 3600))
        }
    }

    for await _ in watcher.ready {
        for hint in watcher.take() {
            switch hint {
            case .overflow:
                logger.warning("fanotify queue overflowed; rescanning")
                for share in shares {
                    await tracker.fullScan(share)
                }
            case .rename(let from, let to, let isDirectory):
                // Into the trash (an SMB client deleted it, through vfs_fang): the item moves to the trash.
                if let to, let (share, path) = tracker.locate(to), Tracker.isTrash(path: path) {
                    var originalPath: String?
                    if let from { originalPath = tracker.locate(from)?.1 }
                    await tracker.noticeTrashed(share, trashPath: path, from: originalPath)
                    continue
                }
                // The new place first: the moved entry keeps its ID, so the old place then finds nothing to delete.
                if let to, let (share, path) = tracker.locate(to) {
                    // A finished copy put in place: the copy records it and everything below it itself, and
                    // only then clears its "copying" mark.
                    if await tracker.wasPlacedByCopy(share, path, consume: true) { continue }
                    if isDirectory {
                        await tracker.scan(share, from: path)
                    } else {
                        await tracker.reconcile(share, path)
                    }
                }
                if let from, let (share, path) = tracker.locate(from) {
                    await tracker.reconcile(share, path)
                }
            case .path(let absolute, let isNewDirectory):
                guard let (share, path) = tracker.locate(absolute) else { continue }  // Elsewhere on the filesystem.
                // Only a folder appearing at a place a copy, move or put back just filled is skipped (that operation
                // records what's in it). A file changing there is always recorded: skipping those too left edits by
                // SMB clients or the host unrecorded for ten minutes after the item was moved.
                if isNewDirectory, await tracker.wasPlacedByCopy(share, path) { continue }
                if isNewDirectory {
                    await tracker.scan(share, from: path)
                } else {
                    await tracker.reconcile(share, path)
                }
            }
        }
    }
}
#else
print("fang-storaged needs Linux (fanotify).")
#endif
