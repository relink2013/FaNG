#if os(Linux)
import CLinuxFS
import FaNGCore
import Foundation
import Glibc
import Logging

/// Keeps the items table in step with the shares on disk. Every decision looks at the disk now; events
/// only say where to look.
actor Tracker {
    nonisolated let shares: [Share]
    let store: ItemStore
    let logger: Logger

    init(shares: [Share], store: ItemStore, logger: Logger) {
        self.shares = shares
        self.store = store
        self.logger = logger
    }

    /// FaNG's own files: upload temp files, version and trash folders, test scratch folders.
    static func isInternal(_ name: String) -> Bool {
        name.hasPrefix(".fang-")
    }

    /// True for a path inside (or naming) one of FaNG's own files or folders.
    static func isInternal(path: String) -> Bool {
        path.split(separator: "/").contains { isInternal(String($0)) }
    }

    static let versionsFolder = ".fang-versions"
    /// Copies and moves between filesystems are built under these names before they're put in place.
    static let copyPrefix = ".fang-copy-"
    static let movePrefix = ".fang-move-"
    static let trashFolder = ".fang-trash"
    /// How long the trash keeps things (iCloud Drive's Recently Deleted keeps 30 days).
    static let trashRetention: TimeInterval = 30 * 24 * 3600

    /// The share an absolute path is in, and the path inside it ("" for the root).
    nonisolated func locate(_ absolute: String) -> (Share, String)? {
        for share in shares.sorted(by: { $0.path.count > $1.path.count }) {
            if absolute == share.path { return (share, "") }
            if absolute.hasPrefix(share.path + "/") {
                return (share, String(absolute.dropFirst(share.path.count + 1)))
            }
        }
        return nil
    }

    // MARK: Scans

    /// Threads a scan reads the disk with: mostly waiting on metadata, so more than the CPUs help a little.
    static let scanThreads = Resources.workers(cpuShare: 1, memoryPerWorker: 64 << 20, limit: 32, setting: "FANG_SCAN_THREADS")
    /// Upload temp files untouched for this long are abandoned (a device resumes within days, not weeks).
    static let uploadAge: TimeInterval = 7 * 24 * 3600

    /// Brings the records of a whole share in line with the disk, and marks what's no longer there deleted.
    ///
    /// Why it runs at all: fang-storaged only hears of changes while it runs, and the share keeps changing
    /// without it (the host, other containers, Samba while this daemon restarts). So at startup, after a
    /// fanotify overflow, and once a day as a check, it compares the disk with the database. It's built to
    /// be cheap: the disk is read with many threads, the database in one query, the two are compared in
    /// memory, and only what differs is written (new entries in batches). `startup`: no copy or move runs
    /// yet, so their unfinished leftovers from before a restart are removed.
    func fullScan(_ share: Share, startup: Bool = false) async {
        await fastScan(share, from: "", findGone: true, startup: startup)
    }

    /// Records `path` and everything below it (a folder that appeared, or was moved in), the same way.
    func scan(_ share: Share, from path: String) async {
        await fastScan(share, from: path, findGone: false, startup: false)
    }

    /// The last full scan, for the admin page.
    struct ScanSummary: Sendable {
        var at: Date
        var seconds: Double
        var entries: Int
        var uploadTemps: Int
        var uploadBytes: Int64
    }
    private(set) var lastScan: ScanSummary?

    private func fastScan(_ share: Share, from start: String, findGone: Bool, startup: Bool) async {
        if Self.isInternal(path: start) { return }
        let started = Date()
        let threads = Self.scanThreads
        let walk = await Task.detached {
            Walker.walk(share, from: start, threads: threads, collectLeftovers: startup, uploadAge: Self.uploadAge)
        }.value
        let walked = Date()
        if !walk.leftovers.isEmpty || !walk.staleUploads.isEmpty {
            // Off the tracker: a big partial copy takes minutes to delete.
            let leftovers = walk.leftovers, stale = walk.staleUploads, logger = logger
            Task.detached {
                for path in leftovers { try? FileManager.default.removeItem(atPath: path) }
                for path in stale { unlink(path) }
                logger.info("Removed \(leftovers.count) unfinished copies or moves and \(stale.count) abandoned uploads")
            }
        }
        do {
            let recorded = try await store.recorded(share: share.name, under: start)
            var ids = recorded.mapValues(\.id)  // Path → ID, for parents; new entries are added as they get theirs.
            var new: [Observed] = []
            var slow: [[String]] = []
            var unchanged = 0
            for found in walk.found {
                let parentPath = found.path.split(separator: "/").dropLast().joined(separator: "/")
                let parent = found.path.isEmpty ? nil : ids[parentPath]
                if let known = recorded[found.path], let id = found.id, known.id == id, known.isDirectory == found.entry.isDirectory,
                   known.parent == parent, known.inode == found.entry.inode, known.tags == found.tags,
                   known.xattrs == Metadata.encode(found.xattrs),
                   found.entry.isDirectory || (known.size == found.entry.size && known.mtimeNS == found.entry.mtimeNS) {
                    unchanged += 1
                    continue
                }
                // Brand new (no ID, nothing recorded there) under a known folder: recorded in batches below.
                if found.id == nil, recorded[found.path] == nil, let parent, !found.path.isEmpty {
                    let id = UUID()
                    ids[found.path] = id
                    var observed = Observed(id: id, parent: parent, name: String(found.path.split(separator: "/").last ?? ""),
                                            path: found.path, isDirectory: found.entry.isDirectory,
                                            size: found.entry.isDirectory ? 0 : found.entry.size, mtimeNS: found.entry.mtimeNS,
                                            inode: found.entry.inode)
                    observed.tags = found.tags
                    observed.xattrs = found.xattrs
                    new.append(observed)
                    continue
                }
                // Everything else (changed, moved, carrying an ID from elsewhere) goes through the usual rules.
                let depth = found.path.isEmpty ? 0 : found.path.split(separator: "/").count
                while slow.count <= depth { slow.append([]) }
                slow[depth].append(found.path)
            }
            // New entries: their IDs onto the disk (in parallel; an entry that got one meanwhile goes the usual
            // way), then recorded in batches.
            let root = share.path
            let written = await Task.detached {
                Walker.parallelMap(new, threads: threads) { observed in
                    Disk.writeNewID(observed.id, to: root + "/" + observed.path)
                }
            }.value
            var batch: [Observed] = []
            var refused = Set<String>()
            for (observed, ok) in zip(new, written) {
                if ok && !refused.contains(observed.path.split(separator: "/").dropLast().joined(separator: "/")) {
                    batch.append(observed)
                } else {
                    refused.insert(observed.path)
                    let depth = observed.path.split(separator: "/").count
                    while slow.count <= depth { slow.append([]) }
                    slow[depth].append(observed.path)
                }
            }
            try await store.insertNew(batch, share: share.name)
            // The rest, parents first, several at a time (each waits on the database).
            var reconciled = 0
            for paths in slow where !paths.isEmpty {
                await withTaskGroup(of: Void.self) { group in
                    var running = 0
                    for path in paths {
                        if running == 16 {
                            await group.next()
                            running -= 1
                        }
                        group.addTask { await self.reconcile(share, path) }
                        running += 1
                    }
                }
                reconciled += paths.count
            }
            // What's recorded but wasn't found: gone, unless it's there now (made after its folder was read).
            var gone = 0
            if findGone {
                let seen = Set(walk.found.map(\.path))
                let missing = recorded.keys.filter { !seen.contains($0) }
                let absent = await Task.detached {
                    Walker.parallelMap(missing, threads: threads) { path in Disk.exists(root + "/" + path) ? nil : path }.compactMap { $0 }
                }.value
                gone = try await store.markDeleted(share: share.name, paths: absent)
            }
            if findGone {
                lastScan = ScanSummary(at: Date(), seconds: Date().timeIntervalSince(started), entries: walk.found.count,
                                       uploadTemps: walk.uploadCount, uploadBytes: walk.uploadBytes)
            }
            if findGone || walk.found.count > 1000 {
                logger.info("Scanned \(share.name)\(start.isEmpty ? "" : " (a folder)"): \(walk.found.count) entries (read in \(String(format: "%.1f", walked.timeIntervalSince(started))) s with \(threads) threads), \(unchanged) unchanged, \(batch.count) new, \(reconciled) checked one by one, \(gone) gone, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            }
        } catch {
            logger.error("Scan of \(share.name) failed: \(String(reflecting: error))")
        }
    }

    // MARK: Reconciling one entry

    enum Outcome {
        case file, directory, gone, skipped
    }

    /// Reconciles in progress, by share and path.
    private var reconciling: [String: Task<Outcome, Never>] = [:]

    /// Looks at one entry on disk and records it, giving it an ID if it has none. One at a time per path:
    /// the actor runs another call while this one waits on the database, and two calls for a new file (the
    /// watcher's and a command's, as when a conflict's copy is made) would both find no ID and give it two,
    /// the second marking the first deleted.
    @discardableResult
    func reconcile(_ share: Share, _ path: String) async -> Outcome {
        let key = share.name + "\u{0}" + path
        while let running = reconciling[key] {
            RequestTrace.step("reconcile: waiting for the same path")
            _ = await running.value
            // Done: cleared here too. Awaiting a finished task doesn't suspend, so if the call that started it
            // hadn't had its turn to clear it yet, this loop spun on the actor forever and that call never got
            // its turn (a tag change and the event it caused, on the same file, hung every later request).
            if reconciling[key] == running { reconciling[key] = nil }
        }
        let task = Task { await self.reconcileNow(share, path) }
        reconciling[key] = task
        RequestTrace.step("reconcile: running")
        let outcome = await task.value
        RequestTrace.step("reconcile: done")
        if reconciling[key] == task {  // a waiter may have started the next one already
            reconciling[key] = nil
        }
        return outcome
    }

    private func reconcileNow(_ share: Share, _ path: String) async -> Outcome {
        let name = path.isEmpty ? share.name : String(path.split(separator: "/").last!)
        if Self.isInternal(path: path) { return .skipped }
        let absolute = absolutePath(share, path)
        do {
            guard let entry = Disk.entry(absolute) else {
                try await store.markDeleted(share: share.name, path: path)
                return .gone
            }
            var parent: UUID?
            if !path.isEmpty {
                let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
                if let known = try await store.liveItem(share: share.name, path: parentPath) {
                    parent = known.id
                } else {
                    guard await reconcile(share, parentPath) == .directory,
                          let known = try await store.liveItem(share: share.name, path: parentPath)
                    else { return .skipped }
                    parent = known.id
                }
            }
            RequestTrace.step("reconcileNow: identify")
            let id = try await identify(share, path, absolute: absolute, isDirectory: entry.isDirectory)
            var observed = Observed(
                id: id, parent: parent, name: name, path: path, isDirectory: entry.isDirectory,
                size: entry.isDirectory ? 0 : entry.size, mtimeNS: entry.mtimeNS, inode: entry.inode
            )
            observed.tags = Disk.readTags(absolute)
            observed.xattrs = Disk.readMetadata(absolute)
            try await store.record(observed, share: share.name)
            return entry.isDirectory ? .directory : .file
        } catch {
            // Paths stay out of the log: names can be private.
            logger.error("Recording an item in \(share.name) failed: \(String(reflecting: error))")
            return .skipped
        }
    }

    /// The entry's FaNG ID (see `Identity` for the rules), written onto the entry when it changes.
    private func identify(_ share: Share, _ path: String, absolute: String, isDirectory: Bool) async throws -> UUID {
        let carried = Disk.readID(absolute)
        var facts = Identity.Facts(carried: carried, isDirectory: isDirectory)
        if let carried, let known = try await store.item(carried), !known.deleted,
           known.share != share.name || known.path != path {
            facts.recordedElsewhere = true
            if let other = shares.first(where: { $0.name == known.share }).map({ absolutePath($0, known.path) }) {
                facts.elsewhereStillCarries = Disk.readID(other) == carried && Disk.entry(other) != nil
            }
        }
        // What's recorded at this path only matters for an entry without an ID or with one from elsewhere
        // (a scan meets mostly neither, so it skips the query).
        if carried == nil || facts.recordedElsewhere, let here = try await store.liveItem(share: share.name, path: path) {
            facts.atThisPath = (here.id, here.isDirectory)
        }
        let id: UUID
        switch Identity.decide(facts) {
        case .keep(let kept):
            return kept
        case .adopt(let adopted):
            id = adopted
        case .new:
            id = UUID()
        }
        if !Disk.writeID(id, to: absolute) {
            // Usually a copy tool's temp file that was renamed away a moment ago.
            logger.debug("Couldn't write an ID in \(share.name): \(String(cString: strerror(errno)))")
        }
        return id
    }

    // MARK: Commits and versions

    struct CommitError: Error, CustomStringConvertible {
        var description: String
    }

    /// Puts new contents uploaded to `temp` (an upload temp file next to the item) in place of the item.
    ///
    /// The check against `base` (the content version the edit started from) runs against the disk now.
    /// Without a conflict, the new file is swapped in atomically with the item's ID, owner, mode and
    /// client metadata, and the old contents become a version (when the share keeps versions). With a
    /// conflict, the newer save (by `modifiedNS`, the edit's save time; a tie keeps the server's file)
    /// stays at the path and the other is kept as a branch. Returns the item, whether it conflicted, and
    /// whether the edit became the file (if not, the client's copy is the branch and it must fetch the file).
    func commit(_ share: Share, id: UUID, temp: String, base: Int64, modifiedNS: Int64, device: String? = nil, path clientPath: String? = nil) async throws -> (item: Item, conflict: Bool, editWon: Bool) {
        // The client says where it sees the file. Look there first: a rename it just made may not have
        // reached the database yet while fanotify events queue up behind a big copy.
        if let clientPath, !Self.isInternal(path: clientPath), Disk.readID(absolutePath(share, clientPath)) == id {
            await reconcile(share, clientPath)
        }
        guard let item = try await store.item(id), !item.deleted, item.share == share.name, !item.isDirectory else {
            throw CommitError(description: "notfound")
        }
        let folder = item.path.split(separator: "/").dropLast().joined(separator: "/")
        guard temp.hasPrefix(".fang-upload-"), !temp.contains("/") else { throw CommitError(description: "badtemp") }
        let tempPath = folder.isEmpty ? temp : folder + "/" + temp
        let tempAbsolute = absolutePath(share, tempPath), target = absolutePath(share, item.path)
        guard let uploaded = Disk.entry(tempAbsolute), !uploaded.isDirectory else { throw CommitError(description: "notemp") }

        await reconcile(share, item.path)  // What's on disk now decides, not what was last recorded.
        guard let current = try await store.item(id), !current.deleted, current.path == item.path else {
            // The file went away (or moved) meanwhile: the edit makes it again.
            guard rename(tempAbsolute, target) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            _ = Disk.writeID(id, to: target)
            await reconcile(share, item.path)
            guard let recreated = try await store.item(id) else { throw CommitError(description: "notfound") }
            return (recreated, false, true)
        }
        // The same save again (its first commit went through, but the answer never reached the device): the file
        // already has exactly these contents. Nothing to do, and above all no conflict with itself.
        if base != current.contentVersion, uploaded.size == current.size,
           let mine = try? await BlockHashes.of(tempAbsolute), let theirs = try? await BlockHashes.of(target), mine.2 == theirs.2 {
            unlink(tempAbsolute)
            logger.info("Commit of \(id.uuidString.lowercased()) repeated: already in place")
            return (current, false, true)
        }
        let rule = CommitRule.decide(base: base, current: current.contentVersion, editSavedNS: modifiedNS, currentSavedNS: current.mtimeNS)
        let (conflict, editWins) = (rule.conflict, rule.editWins)
        if editWins {
            try Disk.copyOwnership(from: target, to: tempAbsolute)
            _ = fang_copy_xattrs(target, tempAbsolute, Disk.idAttribute)
            _ = Disk.writeID(id, to: tempAbsolute)
            guard fang_exchange(tempAbsolute, target) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // The old contents are at the temp name now.
            if share.versions || conflict {
                do {
                    // The server's contents lost: they're the branch, the server's own (no device).
                    try await keepVersion(share, of: current, file: tempAbsolute, kind: conflict ? "branch" : "version",
                                          contentVersion: current.contentVersion, size: current.size, mtimeNS: current.mtimeNS,
                                          device: conflict ? "server" : device)
                } catch {
                    // The old contents couldn't be kept. Put everything back as it was (the file's old contents
                    // in place, the upload at its temp name), so the commit failed as a whole: left half done,
                    // the device's retry would take the old contents at the temp name for its own partial upload
                    // and build a mix of both on top of them.
                    if Disk.entry(tempAbsolute) != nil, fang_exchange(tempAbsolute, target) != 0 {
                        logger.error("Commit of \(id.uuidString.lowercased()): the version couldn't be kept and the swap couldn't be undone (errno \(errno))")
                    }
                    logger.error("Commit of \(id.uuidString.lowercased()) undone: the old contents couldn't be kept as a version: \(error)")
                    throw error
                }
            } else {
                unlink(tempAbsolute)
            }
        } else {
            try Disk.copyOwnership(from: target, to: tempAbsolute)
            try await keepVersion(share, of: current, file: tempAbsolute, kind: "branch",
                                  contentVersion: base, size: uploaded.size, mtimeNS: uploaded.mtimeNS, device: device)
        }
        if conflict {
            // Every client sees it: a red [CONFLICT] Finder tag on the file, until the conflict is resolved.
            var tags = Disk.readTags(target)
            if !tags.contains(Disk.conflictTag) {
                tags.append(Disk.conflictTag)
                try? Disk.writeTags(tags, to: target)
            }
        }
        await reconcile(share, item.path)
        guard let committed = try await store.item(id) else { throw CommitError(description: "notfound") }
        logger.info("Committed \(id.uuidString.lowercased())\(conflict ? " (conflict)" : "")")
        return (committed, conflict, editWins)
    }

    /// Moves `file` into the share's version store as a version of `item`, and records it.
    private func keepVersion(_ share: Share, of item: Item, file: String, kind: String, contentVersion: Int64, size: Int64, mtimeNS: Int64, device: String? = nil) async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        let ext = (item.name as NSString).pathExtension
        let name = formatter.string(from: Date()) + (kind == "branch" ? " branch" : "") + (ext.isEmpty ? "" : "." + ext)
        // On the file's own filesystem (a dataset mounted inside the share has its own version folder): the
        // old contents are renamed there, which can't cross filesystems.
        let root = VersionPlace.filesystemRoot(itemPath: item.path) { folder in
            var st = stat()
            return stat(self.absolutePath(share, folder), &st) == 0 ? UInt64(st.st_dev) : nil
        }
        let folder = VersionPlace.folder(itemPath: item.path, filesystemRoot: root)
        try Disk.makeFolders(absolutePath(share, folder), mode: mode_t(share.directoryMask))
        let path = folder + "/" + name
        let destination = absolutePath(share, path)
        if rename(file, destination) != 0 {
            // Another filesystem after all: copy, then remove. The version is never given up, because by now
            // the new contents are already in the file's place.
            guard errno == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let copied = await Task.detached { fang_clone(file, destination) == 0 }.value
            guard copied else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try? Disk.copyOwnership(from: file, to: destination)
            _ = fang_set_mtime(destination, mtimeNS)
            unlink(file)
        }
        Disk.removeID(from: absolutePath(share, path))  // A version isn't a copy of the file.
        try await store.addVersion(item: item.id, share: share.name, path: path, size: size, mtimeNS: mtimeNS,
                                   contentVersion: contentVersion, kind: kind, device: device)
    }

    /// Makes a version the file's contents again; the contents it replaces become a version themselves.
    func restore(version id: Int64) async throws -> Item {
        guard let version = try await store.version(id), let store_ = shares.first(where: { $0.name == version.share }),
              let item = try await store.item(version.item), !item.deleted,
              let share = shares.first(where: { $0.name == item.share })
        else { throw CommitError(description: "notfound") }
        // The version may still be in another share's store (its item moved and the versions are following).
        let folder = item.path.split(separator: "/").dropLast().joined(separator: "/")
        let temp = ".fang-upload-restore-\(UUID().uuidString.lowercased())"
        let tempAbsolute = absolutePath(share, folder.isEmpty ? temp : folder + "/" + temp)
        guard fang_clone(absolutePath(store_, version.path), tempAbsolute) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let restored = Share(name: share.name, path: share.path, createMask: share.createMask,
                             directoryMask: share.directoryMask, versions: true)
        return try await commit(restored, id: item.id, temp: temp, base: item.contentVersion, modifiedNS: .max).item
    }

    /// Answers once the tracker gets to it: the self-watchdog's proof of life.
    func ping() -> Bool { true }

    // MARK: Tags and conflicts

    /// Sets an item's Finder tags (the [CONFLICT] tag stays while the conflict is open).
    func setTags(_ id: UUID, _ tags: [String]) async throws -> Item {
        guard let item = try await store.item(id), !item.deleted, !item.trashed,
              let share = shares.first(where: { $0.name == item.share })
        else { throw CommitError(description: "notfound") }
        var tags = tags.filter { $0 != Disk.conflictTag }
        if try await store.hasOpenBranches(id) {
            tags.append(Disk.conflictTag)
        }
        try Disk.writeTags(tags, to: absolutePath(share, item.path))
        await reconcile(share, item.path)
        guard let updated = try await store.item(id) else { throw CommitError(description: "notfound") }
        return updated
    }

    /// Sets an item's client metadata (extended attributes File Provider syncs: folder symbols and emoji, …),
    /// kept as the named streams Samba gives SMB clients, so a Mac over plain SMB sees them too.
    func setMetadata(_ id: UUID, _ metadata: [String: Data]) async throws -> Item {
        guard let item = try await store.item(id), !item.deleted, item.jobState == nil,
              let share = shares.first(where: { $0.name == item.share })
        else { throw CommitError(description: "notfound") }
        try Disk.writeMetadata(metadata, to: absolutePath(share, item.path))
        await reconcile(share, item.path)
        guard let updated = try await store.item(id) else { throw CommitError(description: "notfound") }
        return updated
    }

    /// Prepares a delta upload: the file's current contents, cloned (instantly, sharing blocks) to the upload
    /// temp name `temp` next to it, owned like the file. The client then writes only the blocks it changed
    /// over SMB and commits as usual. Answers the item (its content version is the clone's base).
    func stage(_ id: UUID, temp: String) async throws -> Item {
        guard temp.hasPrefix(".fang-upload-"), !temp.contains("/") else { throw CommitError(description: "badtemp") }
        guard let item = try await store.item(id), !item.deleted, !item.isDirectory, item.jobState == nil,
              let share = shares.first(where: { $0.name == item.share })
        else { throw CommitError(description: "notfound") }
        let folder = item.path.split(separator: "/").dropLast().joined(separator: "/")
        let target = absolutePath(share, folder.isEmpty ? temp : folder + "/" + temp)
        let source = absolutePath(share, item.path)
        unlink(target)  // An earlier attempt's; a fresh clone replaces it.
        let cloned = await Task.detached { fang_clone(source, target) == 0 }.value
        guard cloned else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try Disk.copyOwnership(from: source, to: target)
        return item
    }

    /// Resolves an item's conflict:
    /// - keep: the file as it is wins; the branches stay in its history;
    /// - use: branch `version` becomes the file (what it replaces becomes a version);
    /// - copy: branch `version` is restored next to the file as "<name> (conflict).ext", and it's resolved.
    /// The [CONFLICT] tag goes once no branch is open.
    func resolve(_ id: UUID, action: String, version: Int64?) async throws -> Item {
        guard let item = try await store.item(id), !item.deleted,
              let share = shares.first(where: { $0.name == item.share })
        else { throw CommitError(description: "notfound") }
        switch action {
        case "keep":
            try await store.resolveBranches(of: id)
        case "use":
            guard let version, let branch = try await store.version(version), branch.item == id else { throw CommitError(description: "notfound") }
            _ = try await restore(version: branch.id)
            try await store.resolveBranches(of: id)
        case "copy":
            guard let version, let branch = try await store.version(version), branch.item == id else { throw CommitError(description: "notfound") }
            let folder = item.path.split(separator: "/").dropLast().joined(separator: "/")
            let base = (item.name as NSString).deletingPathExtension, ext = (item.name as NSString).pathExtension
            var name = "\(base) (conflict)" + (ext.isEmpty ? "" : ".\(ext)"), attempt = 1
            while Disk.entry(absolutePath(share, folder.isEmpty ? name : folder + "/" + name)) != nil {
                attempt += 1
                name = "\(base) (conflict \(attempt))" + (ext.isEmpty ? "" : ".\(ext)")
            }
            let copy = absolutePath(share, folder.isEmpty ? name : folder + "/" + name)
            guard fang_clone(absolutePath(share, branch.path), copy) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try Disk.copyOwnership(from: absolutePath(share, item.path), to: copy)
            await reconcile(share, folder.isEmpty ? name : folder + "/" + name)
            try await store.resolveBranches(of: id, only: branch.id)
        default:
            throw CommitError(description: "badrequest")
        }
        if !(try await store.hasOpenBranches(id)), let current = try await store.item(id) {
            let target = absolutePath(share, current.path)
            try? Disk.writeTags(Disk.readTags(target).filter { $0 != Disk.conflictTag }, to: target)
            await reconcile(share, current.path)
        }
        guard let resolved = try await store.item(id) else { throw CommitError(description: "notfound") }
        return resolved
    }

    // MARK: Copies and moves

    /// Starts copying an item (a folder with everything below it) into the folder `parentID`, possibly in
    /// another share, as `name` (the item's own name by default; a taken name gets Finder's " 2", or " copy"
    /// in the item's own folder), and answers at once with the copy's item: it exists in the database from
    /// the start, marked "copying" with its progress, so every client shows it while the server works.
    /// The copy itself runs in the background (`runCopy`). It's a new item: new IDs, the target share's owner
    /// and masks, the original's modification times, Finder tags and other client metadata (but no
    /// [CONFLICT] tag: its branches stay with the original).
    func copy(_ id: UUID, into parentID: UUID, name requested: String?) async throws -> Item {
        RequestTrace.step("copy: checking")
        let (item, share, parent, targetShare) = try await transferEnds(id, parentID, requested)
        let sameFolder = targetShare.name == share.name && parent.id == item.parent
        RequestTrace.step("copy: naming")
        let path = try await freeJobPath(targetShare, folder: parent.path, name: requested ?? item.name, isDirectory: item.isDirectory, sameFolder: sameFolder)
        RequestTrace.step("copy: recording the placeholder")
        let placeholder = try await store.insertPlaceholder(
            id: UUID(), share: targetShare.name, parent: parent.id, name: String(path.split(separator: "/").last ?? ""), path: path,
            isDirectory: item.isDirectory, size: item.isDirectory ? 0 : item.size, mtimeNS: item.mtimeNS,
            tags: item.tags.filter { $0 != Disk.conflictTag })
        let job = CopyJob(
            source: absolutePath(share, item.path), isDirectory: item.isDirectory, share: targetShare, path: path,
            folder: absolutePath(targetShare, parent.path), id: placeholder.id, parent: parent.id,
            modes: Modes(file: mode_t(targetShare.createMask), folder: mode_t(targetShare.directoryMask)))
        Task { await self.runCopy(job) }
        logger.info("Copying \(id.uuidString.lowercased()) to \(placeholder.id.uuidString.lowercased())")
        return placeholder
    }

    struct CopyJob: Sendable {
        var source: String
        var isDirectory: Bool
        var share: Share
        /// The copy's path in `share`, and the absolute path of the folder it goes into.
        var path: String
        var folder: String
        /// The copy's item (the placeholder) and its folder's.
        var id: UUID
        var parent: UUID
        var modes: Modes
    }

    /// Copies whose results are being put in place: the watcher records them itself, so the rename of
    /// their hidden folder into place isn't scanned again entry by entry (keyed by share and path, with when).
    private var placed: [String: Date] = [:]

    /// True if `path` was just put in place by a copy, move or put back, which records what's below it itself.
    /// `consume`: the operation's own rename event, seen once; the mark goes with it. Marks expire after two
    /// minutes either way.
    func wasPlacedByCopy(_ share: Share, _ path: String, consume: Bool = false) -> Bool {
        placed = placed.filter { Date().timeIntervalSince($0.value) < 120 }
        let key = share.name + "\u{0}" + path
        guard placed[key] != nil else { return false }
        if consume { placed[key] = nil }
        return true
    }

    /// Makes the copy under a hidden name next to its target (FaNG's own names aren't tracked, so nothing is
    /// recorded entry by entry meanwhile; several files at a time; progress reported every 2 s), puts it in
    /// place in one rename, records everything below it in batches, and finally turns the placeholder into
    /// the copy's top item. A copy that fails (or is cut off by a restart) leaves its item marked failed,
    /// and nothing visible on disk; the next start removes the hidden leftovers.
    private func runCopy(_ job: CopyJob) async {
        let started = Date()
        let temp = job.folder + "/" + Self.copyPrefix + UUID().uuidString.lowercased()
        let target = absolutePath(job.share, job.path)
        let progress = CopyProgress(id: job.id, name: String(job.path.split(separator: "/").last ?? ""))
        CopyProgress.register(progress)
        defer { CopyProgress.unregister(job.id) }
        let reporter = Task { [store] in
            var last = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let percent = progress.percent
                if percent != last, !Task.isCancelled {
                    try? await store.setProgress(job.id, percent)
                    last = percent
                }
            }
        }
        do {
            let (entries, sources) = try await Task.detached { try Copier.copy(job, to: temp, progress: progress) }.value
            reporter.cancel()
            progress.recording()
            placed[job.share.name + "\u{0}" + job.path] = Date()
            guard fang_rename_noreplace(temp, target) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // The originals' thumbnails, for fang-thumbs to link (a failure only means they're made again).
            do { try await store.recordThumbnailCopies(sources) } catch {
                logger.warning("Couldn't note the copy's thumbnails: \(String(describing: error))")
            }
            try await store.insertNew(entries, share: job.share.name)
            await reconcile(job.share, job.path)  // The placeholder becomes the copy's top item (same ID).
            logger.info("Copied to \(job.id.uuidString.lowercased()): \(entries.count + 1) entries in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        } catch {
            reporter.cancel()
            // Off the tracker: a big partial copy takes a while to delete, and requests mustn't wait for it.
            await Task.detached { try? FileManager.default.removeItem(atPath: temp) }.value
            try? await store.failCopy(job.id, reason: Self.reason(error))
            logger.error("Copy to \(job.id.uuidString.lowercased()) failed: \(String(describing: error))")
        }
    }

    /// Why a copy failed, in words for the app's list.
    private static func reason(_ error: Error) -> String {
        guard let posix = error as? POSIXError else { return "The copy failed: \(error.localizedDescription)" }
        switch posix.code {
        case .ENOSPC, .EDQUOT: return "The destination ran out of space."
        case .ENOENT: return "The original was moved or deleted during the copy."
        case .EACCES, .EPERM: return "The server isn't allowed to read the original or write the copy."
        case .EEXIST: return "Something else was put at the copy's place during the copy."
        default: return "The copy failed: \(String(cString: strerror(posix.code.rawValue)))."
        }
    }

    /// The first path for `name` in `folder` that's free on disk and in the database (copies record their
    /// item before anything is on disk), named the way Finder would.
    private func freeJobPath(_ share: Share, folder: String, name: String, isDirectory: Bool, sameFolder: Bool) async throws -> String {
        var attempt = 0
        while true {
            let candidate = CopyNames.candidate(name, isDirectory: isDirectory, sameFolder: sameFolder, attempt: attempt)
            let path = folder.isEmpty ? candidate : folder + "/" + candidate
            if !Disk.exists(absolutePath(share, path)), try await store.liveItem(share: share.name, path: path) == nil { return path }
            attempt += 1
        }
    }

    /// Moves an item into the folder `parentID`, possibly in another share, as `name` (its own name by
    /// default; a taken name gets " 2"). The item keeps its ID. On the same filesystem it's a rename;
    /// otherwise it's copied next to the target under a hidden name (keeping owner, mode and metadata), put
    /// in place, and only then is the original removed. Versions stay in the original share's version store.
    func move(_ id: UUID, into parentID: UUID, name requested: String?) async throws -> Item {
        RequestTrace.step("move: checking")
        let (item, share, parent, targetShare) = try await transferEnds(id, parentID, requested)
        RequestTrace.step("move: naming")
        let name = requested ?? item.name
        if targetShare.name == share.name, parent.id == item.parent, name == item.name { return item }
        let path = freePath(targetShare, folder: parent.path, name: name, isDirectory: item.isDirectory, sameFolder: false)
        let source = absolutePath(share, item.path), target = absolutePath(targetShare, path)
        RequestTrace.step("move: renaming")
        if fang_rename_noreplace(source, target) != 0 {
            guard errno == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let before = Disk.entry(source)
            let temp = absolutePath(targetShare, parent.path) + "/" + Self.movePrefix + UUID().uuidString.lowercased()
            do {
                let trace = RequestTrace.active
            try await Task.detached {
                trace?.mark("move: background copy started")
                try Self.copyTree(from: source, to: temp, keeping: true, modes: nil, trace: trace)
            }.value
            } catch {
                try? FileManager.default.removeItem(atPath: temp)
                throw error
            }
            // A file that changed while it was copied isn't removed: the move can be tried again.
            if !item.isDirectory, let before, let after = Disk.entry(source), after.size != before.size || after.mtimeNS != before.mtimeNS {
                try? FileManager.default.removeItem(atPath: temp)
                throw CommitError(description: "changed")
            }
            // From here on, no suspension until the original is gone, so nothing records the copy as a second item.
            guard fang_rename_noreplace(temp, target) == 0 else {
                let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                try? FileManager.default.removeItem(atPath: temp)
                throw failure
            }
            do {
                try FileManager.default.removeItem(atPath: source)
            } catch {
                logger.error("Moved \(id.uuidString.lowercased()) but couldn't remove the original: \(String(reflecting: error))")
            }
        }
        // Set before the next suspension, so the watcher doesn't scan it again entry by entry.
        placed[targetShare.name + "\u{0}" + path] = Date()
        // Everything below moved with it (by a rename, or a copy that kept the IDs): the records follow in one
        // update, and the top is checked on disk.
        RequestTrace.step("move: recording the new place")
        try await store.markMoved(id, from: share.name, item.path, to: targetShare.name, path, parent: parent.id,
                                  name: String(path.split(separator: "/").last ?? ""))
        await reconcile(targetShare, path)
        RequestTrace.step("move: recording the old place")
        await reconcile(share, item.path)
        // Into another share: the history follows (in the background; each version is recorded at its new
        // place as soon as it's there, so none is ever lost).
        if targetShare.name != share.name {
            Task { await self.moveVersions(below: path, from: share, to: targetShare) }
        }
        RequestTrace.step("move: reading the result")
        guard let moved = try await store.item(id), !moved.deleted else { throw CommitError(description: "notfound") }
        logger.info("Moved \(id.uuidString.lowercased())")
        return moved
    }

    /// Moves the version files of the item at `path` in `target` (and of what's below it) from `source`'s
    /// version store into `target`'s: renamed where both are on one filesystem, otherwise copied (reflinked
    /// where the pool allows, so the copy costs no space), recorded, and only then removed from the old place.
    private func moveVersions(below path: String, from source: Share, to target: Share) async {
        do {
            let items = try await store.ids(share: target.name, under: path)
            let paths = Dictionary(items.map { ($0.id, $0.path) }, uniquingKeysWith: { a, _ in a })
            let versions = try await store.versions(ofItems: items.map(\.id)).filter { $0.share == source.name }
            var moved = 0
            for version in versions {
                guard let itemPath = paths[version.item] else { continue }
                let name = String(version.path.split(separator: "/").last ?? "")
                let folder = Self.versionsFolder + "/" + itemPath
                let from = absolutePath(source, version.path), to = absolutePath(target, folder + "/" + name)
                try Disk.makeFolders(absolutePath(target, folder), mode: mode_t(target.directoryMask))
                if rename(from, to) != 0 {
                    guard errno == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    let copied = await Task.detached { fang_clone(from, to) == 0 }.value
                    guard copied else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    try? Disk.copyOwnership(from: from, to: to)
                    _ = fang_set_mtime(to, version.mtimeNS)
                    try await store.moveVersion(version.id, share: target.name, path: folder + "/" + name)
                    unlink(from)
                } else {
                    try await store.moveVersion(version.id, share: target.name, path: folder + "/" + name)
                }
                Self.pruneEmpty(below: [version.path], in: source.path)
                moved += 1
            }
            if moved > 0 { logger.info("Moved \(moved) versions to \(target.name) with their items") }
        } catch {
            logger.error("Moving versions to \(target.name) failed (they stay where they were, still recorded): \(String(describing: error))")
        }
    }

    // MARK: Retention

    /// How long versions are kept, thinned the way Time Machine does: every version for a day, the newest per
    /// hour for a week, per day for a month, per week up to `versionDays` (0: per month, forever). An item's
    /// newest version and open conflict branches are always kept.
    static let versionDays = Int(ProcessInfo.processInfo.environment["FANG_VERSION_DAYS"] ?? "") ?? 365
    /// How long records of deleted items are kept for devices that haven't synced (older anchors list again).
    static let deletedRecordDays = Int(ProcessInfo.processInfo.environment["FANG_DELETED_RECORD_DAYS"] ?? "") ?? 30

    func pruneVersions() async {
        do {
            let now = Date()
            var drop: [Version] = []
            for (_, versions) in Dictionary(grouping: try await store.allVersions(), by: \.item) {
                var buckets = Set<String>()
                for (index, version) in versions.sorted(by: { $0.created > $1.created }).enumerated() {
                    if index == 0 || (version.kind == "branch" && !version.resolved) { continue }
                    let age = now.timeIntervalSince(version.created)
                    let day = 86_400.0
                    let bucket: String?
                    switch age {
                    case ..<day: bucket = nil
                    case ..<(7 * day): bucket = "h\(Int(version.created.timeIntervalSince1970 / 3600))"
                    case ..<(30 * day): bucket = "d\(Int(version.created.timeIntervalSince1970 / day))"
                    case ..<(Double(Self.versionDays) * day) where Self.versionDays > 0: bucket = "w\(Int(version.created.timeIntervalSince1970 / (7 * day)))"
                    default: bucket = Self.versionDays > 0 ? "drop" : "m\(Int(version.created.timeIntervalSince1970 / (30 * day)))"
                    }
                    guard let bucket else { continue }
                    if bucket == "drop" || !buckets.insert(bucket).inserted { drop.append(version) }
                }
            }
            guard !drop.isEmpty else { return }
            try await store.removeVersions(ids: drop.map(\.id))
            let files = drop.compactMap { version in shares.first { $0.name == version.share }.map { ($0.path, version.path) } }
            Task.detached {
                for (root, path) in files {
                    unlink(root + "/" + path)
                    Self.pruneEmpty(below: [path], in: root)
                }
            }
            logger.info("Retention: removed \(drop.count) older versions")
        } catch {
            logger.error("Version retention failed: \(String(reflecting: error))")
        }
    }

    /// Records of deleted items older than `deletedRecordDays` go (with versions of items deleted outside the
    /// trash); anchors from before then make a device list everything again.
    func pruneDeletedRecords() async {
        do {
            try await store.seedChangeMarks(retentionDays: Self.deletedRecordDays)
            try await store.markChanges()
            guard let cutoff = try await store.changeMark(olderThanDays: Self.deletedRecordDays) else { return }
            var removed = 0
            while true {
                let ids = try await store.removeDeletedRecords(before: cutoff, limit: 10_000)
                if ids.isEmpty { break }
                removed += ids.count
                let versions = try await store.removeVersions(of: ids)
                let files = versions.compactMap { version in shares.first { $0.name == version.share }.map { ($0.path, version.path) } }
                if !files.isEmpty {
                    Task.detached { for (root, path) in files { unlink(root + "/" + path); Self.pruneEmpty(below: [path], in: root) } }
                }
                await Task.yield()
            }
            try await store.setPrunedBelow(cutoff)
            if removed > 0 {
                logger.info("Retention: removed \(removed) records of items deleted over \(Self.deletedRecordDays) days ago")
                if removed > 50_000 { _ = try? await store.client.query("VACUUM (ANALYZE) items", logger: logger) }
            }
        } catch {
            logger.error("Retention of deleted records failed: \(String(reflecting: error))")
        }
    }

    /// The item and the target folder of a copy or move, after checking them.
    private func transferEnds(_ id: UUID, _ parentID: UUID, _ requested: String?) async throws -> (Item, Share, Item, Share) {
        guard let item = try await store.item(id), !item.deleted, !item.trashed, !item.path.isEmpty,
              let share = shares.first(where: { $0.name == item.share }),
              let parent = try await store.item(parentID), !parent.deleted, !parent.trashed, parent.isDirectory,
              let targetShare = shares.first(where: { $0.name == parent.share })
        else { throw CommitError(description: "notfound") }
        // A copy still being made (or one that failed) can't be copied, moved or copied into.
        if item.jobState != nil || parent.jobState != nil { throw CommitError(description: "busy") }
        if let requested, !CopyNames.isAcceptable(requested) { throw CommitError(description: "badname") }
        if item.isDirectory, targetShare.name == share.name, parent.path == item.path || parent.path.hasPrefix(item.path + "/") {
            throw CommitError(description: "intoitself")
        }
        return (item, share, parent, targetShare)
    }

    /// The first free path for `name` in `folder`, named the way Finder would.
    private func freePath(_ share: Share, folder: String, name: String, isDirectory: Bool, sameFolder: Bool) -> String {
        var attempt = 0
        while true {
            let candidate = CopyNames.candidate(name, isDirectory: isDirectory, sameFolder: sameFolder, attempt: attempt)
            let path = folder.isEmpty ? candidate : folder + "/" + candidate
            if !Disk.exists(absolutePath(share, path)) { return path }
            attempt += 1
        }
    }

    struct Modes: Sendable {
        var file: mode_t
        var folder: mode_t
    }

    /// Copies `from` (a file, or a folder with everything below it) to the new path `to`. A copy (`keeping`
    /// false) gets the host owner (99:100) and `modes`, no FaNG ID and no [CONFLICT] tag; a move's copy
    /// (`keeping` true) keeps the owner, mode, ID and every tag. Both keep modification times and client
    /// metadata. Symbolic links, special files and FaNG's own files are left out.
    final class Counter: @unchecked Sendable {
        var value = 0
    }

    nonisolated static func copyTree(from: String, to: String, keeping: Bool, modes: Modes?, trace: RequestTrace? = nil, count: Counter = Counter()) throws {
        count.value += 1
        trace?.mark("copy: entry \(count.value)")
        guard let entry = Disk.entry(from) else { return }
        func fail() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // Each entry gets its owner and mode as soon as it exists, so a copy cut off midway never leaves
        // root-owned entries behind.
        func own() throws {
            if keeping {
                try Disk.copyOwnership(from: from, to: to)
            } else {
                guard lchown(to, 99, 100) == 0, chmod(to, entry.isDirectory ? modes?.folder ?? 0o775 : modes?.file ?? 0o664) == 0 else { throw fail() }
            }
        }
        if entry.isDirectory {
            guard mkdir(to, 0o700) == 0 else { throw fail() }
            try own()
            for name in Disk.names(in: from) where !isInternal(name) {
                try copyTree(from: from + "/" + name, to: to + "/" + name, keeping: keeping, modes: modes, trace: trace, count: count)
            }
        } else {
            guard fang_clone(from, to) == 0 else { throw fail() }
            try own()
        }
        _ = fang_copy_xattrs(from, to, keeping ? "" : Disk.idAttribute)
        if !keeping {
            let tags = Disk.readTags(to)
            if tags.contains(Disk.conflictTag) {
                try? Disk.writeTags(tags.filter { $0 != Disk.conflictTag }, to: to)
            }
        }
        _ = fang_set_mtime(to, entry.mtimeNS)  // Last: adding entries to a folder changes its time.
    }

    /// Moves a file or folder to another place in its share. Between filesystems (a file in a dataset mounted
    /// inside the share, with the trash at the share's top) a rename can't do it: a file is then copied (a clone
    /// where the pool can, with its ID, owner, mode, attributes and dates) and the original removed. A folder
    /// between filesystems is still refused: its entries would each be seen as deleted and made again.
    nonisolated static func relocate(from: String, to: String) throws {
        if rename(from, to) == 0 { return }
        guard errno == EXDEV else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let entry = Disk.entry(from), !entry.isDirectory else { throw POSIXError(.EXDEV) }
        do {
            try copyTree(from: from, to: to, keeping: true, modes: nil)
        } catch {
            unlink(to)
            throw error
        }
        guard unlink(from) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(to)
            throw failure
        }
    }

    // MARK: Trash

    /// Moves an item (and what's below it) into the share's trash.
    func trash(_ id: UUID) async throws -> Item {
        guard let item = try await store.item(id), !item.deleted, !item.trashed, !item.path.isEmpty,
              let share = shares.first(where: { $0.name == item.share })
        else { throw CommitError(description: "notfound") }
        // A copy's item: nothing is on disk yet. A failed one is just forgotten; a running one can't be deleted yet.
        if let state = item.jobState {
            guard state == "failed" else { throw CommitError(description: "busy") }
            try await store.markDeleted(share: share.name, path: item.path)
            guard let gone = try await store.item(id) else { throw CommitError(description: "notfound") }
            logger.info("Forgot the failed copy \(id.uuidString.lowercased())")
            return gone
        }
        // Marked while it's recorded: the watcher sees the rename into the trash too, and recording it a
        // second time waited for this one's transaction and then did the work again.
        trashing.insert(id)
        defer { trashing.remove(id) }
        // Recorded and renamed together: the rename runs inside the transaction, which commits only if it
        // worked. (Renamed first, a transaction that didn't finish left the folder in the trash on disk and at
        // its old place in the database.)
        let trashPath = try trashTarget(share, item.path)
        let from = absolutePath(share, item.path), to = absolutePath(share, trashPath)
        try await store.markTrashed(id, share: share.name, trashPath: trashPath, originalPath: item.path) {
            try Self.relocate(from: from, to: to)
        }
        guard let trashed = try await store.item(id) else { throw CommitError(description: "notfound") }
        logger.info("Trashed \(id.uuidString.lowercased())")
        return trashed
    }

    /// Items `trash` is moving into the trash right now.
    private var trashing: Set<UUID> = []

    /// Something was moved into the trash behind FaNG's back (vfs_fang does this for every SMB delete):
    /// the entry's ID says which item it was.
    func noticeTrashed(_ share: Share, trashPath: String, from originalPath: String?) async {
        guard let id = Disk.readID(absolutePath(share, trashPath)), !trashing.contains(id),
              let item = try? await store.item(id), !item.deleted, !item.trashed
        else { return }
        try? await store.markTrashed(id, share: share.name, trashPath: trashPath, originalPath: originalPath ?? item.path)
        logger.info("Trashed by an SMB client: \(id.uuidString.lowercased())")
    }

    /// Puts an item back where it was, or into `parent` if given (or the share's root if its old folder
    /// is gone). A name that's taken gets " (restored)".
    func untrash(_ id: UUID, into parent: UUID?) async throws -> Item {
        guard let item = try await store.item(id), item.trashed, !item.deleted,
              let share = shares.first(where: { $0.name == item.share })
        else { throw CommitError(description: "notfound") }
        let original = item.originalPath ?? item.name
        var folder = original.split(separator: "/").dropLast().joined(separator: "/")
        if let parent, let target = try await store.item(parent), target.isDirectory, !target.trashed {
            folder = target.path
        }
        if !folder.isEmpty, Disk.entry(absolutePath(share, folder))?.isDirectory != true {
            folder = ""
        }
        var name = item.name, attempt = 1
        while Disk.entry(absolutePath(share, folder.isEmpty ? name : folder + "/" + name)) != nil {
            attempt += 1
            let base = (item.name as NSString).deletingPathExtension, ext = (item.name as NSString).pathExtension
            name = "\(base) (restored\(attempt > 2 ? " \(attempt - 1)" : ""))" + (ext.isEmpty ? "" : ".\(ext)")
        }
        let target = folder.isEmpty ? name : folder + "/" + name
        try Self.relocate(from: absolutePath(share, item.path), to: absolutePath(share, target))
        placed[share.name + "\u{0}" + target] = Date()  // Before any suspension: the watcher skips it.
        pruneEmptyFolders(share, below: item.path)
        // Everything below moved with it in one rename: its records follow in one update, as for a move
        // (scanning a folder of 170,000 entries again took minutes). The top is then checked on disk.
        let parentID = try await store.liveItem(share: share.name, path: folder)?.id
        try await store.markMoved(id, from: share.name, item.path, to: share.name, target, parent: parentID, name: name)
        await reconcile(share, target)
        guard let restored = try await store.item(id) else { throw CommitError(description: "notfound") }
        logger.info("Put back \(id.uuidString.lowercased())")
        return restored
    }

    /// Deletes a trashed item, what's below it and their versions, for good.
    func purge(_ id: UUID) async throws {
        guard let item = try await store.item(id), item.trashed, !item.deleted,
              let share = shares.first(where: { $0.name == item.share })
        else { throw CommitError(description: "notfound") }
        let ids = try await store.subtree(item)
        let versions = try await store.removeVersions(of: ids)
        try await store.markDeleted(share: share.name, path: item.path)
        // The files go in the background, off the tracker: deleting a big folder takes minutes, and it's
        // already gone for every client (and hidden in the trash folder on disk).
        let paths = versions.map(\.path), top = item.path, logger = logger
        Task.detached {
            for path in paths { unlink(share.path + "/" + path) }
            do {
                try FileManager.default.removeItem(atPath: share.path + "/" + top)
            } catch {
                logger.error("Purged \(id.uuidString.lowercased()), but deleting its files failed: \(String(describing: error))")
            }
            Self.pruneEmpty(below: [top] + paths, in: share.path)
        }
        logger.info("Purged \(id.uuidString.lowercased()) (\(ids.count) items)")
    }

    /// Empties what's been in the trash longer than `trashRetention`.
    func purgeExpired() async {
        guard let expired = try? await store.expiredTrash(before: Date().addingTimeInterval(-Self.trashRetention)) else { return }
        for item in expired {
            try? await purge(item.id)
        }
    }

    /// Where `path` goes in the trash: ".fang-trash/<time>/<path>" (its folders made, the name free).
    private func trashTarget(_ share: Share, _ path: String) throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = Self.trashFolder + "/" + formatter.string(from: Date())
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        try Disk.makeFolders(absolutePath(share, parent.isEmpty ? folder : folder + "/" + parent), mode: mode_t(share.directoryMask))
        var target = folder + "/" + path, attempt = 1
        while Disk.entry(absolutePath(share, target)) != nil {
            attempt += 1
            target = folder + "/" + path + " (\(attempt))"
        }
        return target
    }

    /// Removes the folders above `path` that are empty now, up to (not including) the top one
    /// (`.fang-trash` or `.fang-versions`).
    private func pruneEmptyFolders(_ share: Share, below path: String) {
        var components = path.split(separator: "/").map(String.init)
        components.removeLast()
        while components.count > 1 {
            if rmdir(absolutePath(share, components.joined(separator: "/"))) != 0 { break }
            components.removeLast()
        }
    }

    /// Removes the folders left empty above `paths` (inside the share at `root`), keeping each path's top
    /// folder (the trash or versions folder), as `pruneEmptyFolders` does.
    nonisolated static func pruneEmpty(below paths: [String], in root: String) {
        for path in paths {
            var components = path.split(separator: "/").map(String.init)
            components.removeLast()
            while components.count > 1, rmdir(root + "/" + components.joined(separator: "/")) == 0 {
                components.removeLast()
            }
        }
    }

    /// True for a path inside a share's trash.
    static func isTrash(path: String) -> Bool {
        path == trashFolder || path.hasPrefix(trashFolder + "/")
    }

    private func absolutePath(_ share: Share, _ path: String) -> String {
        path.isEmpty ? share.path : share.path + "/" + path
    }
}
#endif
