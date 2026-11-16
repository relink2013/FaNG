import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// The operations a File Provider domain performs, on top of a backend and the item store.
/// Independent of the File Provider framework, so it can be tested with a fake backend.
///
/// Two modes, with the same operations: against plain SMB, item IDs are assigned here and changes are
/// found by re-listing folders; against a FaNG server (`server` set), the server's IDs, listings and
/// change feed are used, and only the bytes go over SMB. The store then caches the server's items.
public struct DomainConnection: Sendable {
    public let backend: any FileBackend
    public let store: ItemStore
    /// Where uploads in progress are recorded for the app's "Not Synced" list.
    public let journal: TransferJournal?
    /// The FaNG server's API, in FaNG-server mode.
    public let server: FangAPI?
    /// The ID trashed items have as their parent (File Provider's trash container). Only a FaNG server
    /// has a trash; against plain SMB deletes are permanent.
    public let trashID: String

    /// Changes since an anchor, for `enumerateChanges`. With `moreComing`, the system asks again from
    /// `anchor` for the rest.
    public struct ChangeSet: Sendable {
        public var updated: [ItemRecord]
        public var deleted: [String]
        public var anchor: Data
        public var moreComing = false
        /// IDs of known files whose contents changed: a device that has one downloaded should fetch it now.
        public var contentChanged: Set<String> = []
    }

    /// Most changes handed to the system in one `enumerateChanges` call: a long backlog (a big copy on the
    /// server) goes in batches, so no call runs long enough to be cancelled.
    static let changesPerBatch = 2000
    /// Most changes read from the server feed in one call, and the longest it reads: changes this device
    /// skips (see `changes(since:)`) still have to be read, and a backlog of them goes in batches too.
    static let feedPerBatch = 50_000
    static let feedTimePerBatch: Duration = .seconds(20)
    /// The change-feed filter's version, kept in the anchor, and how far back a device reads the feed again
    /// the first time it runs a new one.
    static let feedFilter = 2
    static let feedRewind: Int64 = 250_000

    /// The anchor is from another server database, or unreadable: the system has to enumerate again.
    public struct AnchorExpired: Error {}

    /// An edit's outcome. With a conflict, the losing side was saved as a conflict copy next to the file;
    /// the next listing of the folder reports it.
    public struct ContentUpdate: Sendable {
        /// The item as it is on the server now.
        public var record: ItemRecord
        /// Plain SMB: the conflict copy's name.
        public var conflictCopyName: String?
        /// FaNG server: the edit conflicted, and the side that lost was kept as a branch version.
        public var conflict = false
        /// The edit lost a conflict: the other side stays at the path, and the edit is now the conflict copy
        /// or branch. The device's copy isn't the file any more, so it has to be fetched again.
        public var editLost = false
    }

    /// A delete was refused because the file changed on the server since the version that was deleted.
    public struct ChangedOnServer: Error {
        /// The item as it is on the server now.
        public var record: ItemRecord
    }

    /// How far before the end of an interrupted upload it resumes, since the last write before the
    /// interruption may not have fully reached the server's disk.
    static let resumeOverlap: Int64 = 8 << 20

    /// After the server has refused an upload as busy for this long, it starts over in a fresh temp file.
    /// The server holds a file open for a session that was cut off until it notices, which can take
    /// hours (TCP keepalive), and a plain SMB client can't make it let go.
    static let busyLimit: TimeInterval = 10 * 60

    public init(backend: any FileBackend, store: ItemStore, journal: TransferJournal? = nil, server: FangAPI? = nil, trashID: String = "trash") {
        self.backend = backend
        self.store = store
        self.journal = journal
        self.server = server
        self.trashID = trashID
    }

    /// True when deletes go into a trash (FaNG-server mode).
    public var hasTrash: Bool { server != nil }

    public func path(of id: String) throws -> String {
        guard let path = store.path(of: id) else { throw POSIXError(.ENOENT) }
        return path
    }

    /// Lists a folder on the server and records what changed since the last listing.
    public func relist(_ folderID: String) async throws -> ItemStore.Reconciliation {
        if let server {
            let items: [FangItem]
            if folderID == store.rootID {
                items = try await server.shares().compactMap(\.root)
            } else if folderID == trashID {
                var trashed: [FangItem] = []
                for share in try await server.shares() {
                    trashed += try await server.trash(share: share.name)
                }
                items = trashed
            } else {
                guard let id = UUID(uuidString: folderID) else { throw POSIXError(.ENOENT) }
                items = try await server.children(of: id)
            }
            let result = store.replace(children: items.map(record(from:)), of: folderID)
            if let folder = store.path(of: folderID) {
                journal?.arrived(names: Set(result.items.map(\.name)), in: folder)
            }
            return result
        }
        let folder = try path(of: folderID)
        let listing = try await backend.list(folder)
        journal?.arrived(names: Set(listing.map(\.name)), in: folder)
        return store.reconcile(parentID: folderID, listing: listing)
    }

    /// The item's current state on the server. Forgets the item if it's gone.
    public func refresh(_ id: String) async throws -> ItemRecord {
        if let server {
            guard let uuid = UUID(uuidString: id), let item = try await server.item(uuid), !item.deleted else {
                store.remove(id)
                throw POSIXError(.ENOENT)
            }
            let updated = record(from: item)
            if updated != store.record(id) {
                store.save(updated)
            }
            return updated
        }
        guard let record = store.record(id) else { throw POSIXError(.ENOENT) }
        do {
            let updated = ItemRecord(id: id, parentID: record.parentID, remote: try await backend.stat(try path(of: id)))
            if updated != record {
                store.save(updated)
            }
            return updated
        } catch let error as POSIXError where error.code == .ENOENT {
            store.remove(id)
            throw error
        }
    }

    public func download(_ id: String, to url: URL, progress: Progress) async throws -> ItemRecord {
        let record = try await refresh(id)
        try await backend.download(try path(of: id), to: url, progress: progress)
        return record
    }

    /// Creates a folder. If one with that name already exists, it's used as is.
    public func createFolder(named name: String, in parentID: String) async throws -> ItemRecord {
        let path = RemotePath.join(try self.path(of: parentID), name)
        do {
            try await backend.createDirectory(path)
        } catch let error as POSIXError where error.code == .EEXIST {
            // Merge with the existing folder (checked below).
        }
        let remote = try await backend.stat(path)
        guard remote.isDirectory else { throw POSIXError(.EEXIST) }
        return try await adoptWritten(remote, at: path, parentID: parentID, reuseExisting: true)
    }

    /// Uploads a new file. Fails with `EEXIST` if the name is taken, so the system can pick another.
    /// With `mayAlreadyExist` (the system re-importing), an existing file of the same size is taken as this one.
    public func createFile(
        named name: String, in parentID: String, contents url: URL?, mayAlreadyExist: Bool, progress: Progress
    ) async throws -> ItemRecord {
        let folder = try self.path(of: parentID)
        let path = RemotePath.join(folder, name)
        if mayAlreadyExist, let existing = try? await backend.stat(path), !existing.isDirectory,
           existing.size == Self.localSize(of: url) {
            return try await adoptWritten(existing, at: path, parentID: parentID, reuseExisting: true)
        }
        let source = try url ?? Self.emptyFile()
        let key = try Self.uploadKey(scope: "create:\(parentID)/\(name)", file: source)
        try await journaled(key: key, itemID: nil, name: name, folder: folder, source: source) {
            let temp = try await uploadToTemp(source, key: key, in: folder, progress: progress)
            await keepDates(of: source, on: temp)
            try await commit(removingOnFailure: temp) {
                try await backend.move(temp, to: path, replacing: false)
            }
        }
        return try await adoptWritten(try await backend.stat(path), at: path, parentID: parentID, reuseExisting: false)
    }

    /// Renames and/or moves an item. Fails with `EEXIST` if the destination name is taken.
    public func move(_ id: String, to name: String, in parentID: String) async throws -> ItemRecord {
        guard var record = store.record(id) else { throw POSIXError(.ENOENT) }
        if let server, let uuid = UUID(uuidString: id) {
            // The server moves it: a rename on its disk, or between shares (pools, datasets) a copy that keeps the
            // item's ID, its versions following. The top level holds the shares themselves.
            guard parentID != store.rootID, let parent = UUID(uuidString: parentID) else { throw POSIXError(.EPERM) }
            let moved = self.record(from: try await server.move(uuid, into: parent, name: name))
            store.save(moved)
            return moved
        }
        let source = try path(of: id)
        let destination = RemotePath.join(try path(of: parentID), name)
        if source != destination {
            try await backend.move(source, to: destination, replacing: false)
        }
        record.parentID = parentID
        record.name = name
        store.save(record)
        return record
    }

    /// Replaces a file's contents with an edit based on `baseVersion` (a `contentVersion`) and saved at
    /// `modified`. The item keeps its ID even though the server file is new.
    ///
    /// If the server's file still is the base version, the upload replaces it in one step. If it changed
    /// since (a conflict), the newer save stays at the path, as iCloud does, and the other is kept as one
    /// conflict copy next to it; on a tie, the server's file stays. If the file is gone from the server,
    /// the edit recreates it.
    public func replaceContents(
        of id: String, with url: URL, baseVersion: Data?, modified: Date?, progress: Progress
    ) async throws -> ContentUpdate {
        guard let record = store.record(id) else { throw POSIXError(.ENOENT) }
        let path = try path(of: id)
        let folder = RemotePath.parent(of: path)
        let key = try Self.uploadKey(scope: "update:\(id)", file: url)
        if let server {
            return try await commitThroughServer(server, record: record, key: key, folder: folder, url: url,
                                                 baseVersion: baseVersion, modified: modified, progress: progress)
        }
        var conflictCopyName: String?
        var editLost = false
        try await journaled(key: key, itemID: id, name: record.name, folder: folder, source: url) {
            let temp = try await uploadToTemp(url, key: key, in: folder, progress: progress)
            await keepDates(of: url, on: temp, modified: modified)
            try await commit(removingOnFailure: temp) {
                let current: RemoteItem?
                do {
                    current = try await backend.stat(path)
                } catch let error as POSIXError where error.code == .ENOENT {
                    current = nil
                }
                guard let current, let baseVersion,
                      ItemRecord(id: id, parentID: record.parentID, remote: current).contentVersion != baseVersion
                else {
                    try await backend.move(temp, to: path, replacing: true)
                    return
                }
                let name = try await conflictName(for: record.name, in: folder)
                let copy = RemotePath.join(folder, name)
                if let modified, modified > current.modified {
                    try await backend.move(path, to: copy, replacing: false)
                    try await backend.move(temp, to: path, replacing: true)
                } else {
                    try await backend.move(temp, to: copy, replacing: false)
                    editLost = true
                }
                conflictCopyName = name
            }
        }
        let updated = ItemRecord(id: id, parentID: record.parentID, remote: try await backend.stat(path))
        store.save(updated)
        return ContentUpdate(record: updated, conflictCopyName: conflictCopyName, editLost: editLost)
    }

    /// Deletes an item. A non-empty folder is only deleted with `recursive`. Already gone counts as deleted.
    /// A file that changed on the server since `baseVersion` (a `contentVersion`) isn't deleted: that throws
    /// `ChangedOnServer`, so another device's newer edit is never lost to a delete.
    public func delete(_ id: String, baseVersion: Data?, recursive: Bool) async throws {
        guard var record = store.record(id) else { return }
        if let server, let uuid = UUID(uuidString: id) {
            // The server decides: into the trash, or for good if it's there already. Nothing is lost to a
            // delete, so another device's newer edit survives in the trash.
            do {
                try await server.delete(uuid)
            } catch FangAPI.Failure.status(404) {
                // Already gone.
            }
            store.remove(id)
            return
        }
        if !record.isDirectory, let baseVersion {
            do {
                record = try await refresh(id)
            } catch let error as POSIXError where error.code == .ENOENT {
                return
            }
            if record.contentVersion != baseVersion {
                throw ChangedOnServer(record: record)
            }
        }
        let path = try path(of: id)
        do {
            if record.isDirectory, !recursive, !(try await backend.list(path)).isEmpty {
                throw POSIXError(.ENOTEMPTY)
            }
            try await backend.remove(path, isDirectory: record.isDirectory)
        } catch let error as POSIXError where error.code == .ENOENT {
            // Already gone.
        }
        store.remove(id)
    }

    /// The embedded preview of an image file, or nil if the file has none.
    public func thumbnail(of id: String, maxPixelSize: Int) async throws -> Data? {
        if let server {
            // The server keeps one thumbnail per file for every client, rebuilt when the file changes.
            guard let uuid = UUID(uuidString: id) else { return nil }
            return try await server.thumbnail(uuid)
        }
        guard let record = store.record(id), !record.isDirectory,
              let type = UTType(filenameExtension: (record.name as NSString).pathExtension),
              EmbeddedThumbnail.mayHaveThumbnail(type)
        else { return nil }
        let header = try await backend.read(try path(of: id), range: 0..<EmbeddedThumbnail.headerLength)
        return EmbeddedThumbnail.jpeg(fromHeader: header, maxPixelSize: maxPixelSize)
    }

    // MARK: Delta transfers

    /// Files this big or bigger move as deltas: below it, hashing costs more than sending the file.
    static let deltaThreshold: Int64 = 4 << 20

    /// Uploads only the blocks of `url` that differ from the server's current contents: the server clones
    /// the file to a temp name next to it, answers each block's hash, and only the blocks whose hash differs
    /// are written into the clone. Returns the temp path, or nil when a delta doesn't apply or fails (any
    /// clone is removed; the caller then uploads the whole file).
    private func deltaUpload(_ server: FangAPI, id: UUID, url: URL, key: String, folder: String, progress: Progress) async -> String? {
        let size = Self.localSize(of: url)
        guard size >= Self.deltaThreshold else { return nil }
        // Its own name: the resumable upload must never mistake a clone of the old contents for its own prefix.
        let name = RemotePath.uploadPrefix + key + "-delta"
        let temp = RemotePath.join(folder, name)
        do {
            let blocks = try await server.stage(id, temp: name)
            let ranges = try Self.changedRanges(of: url, size: size, against: blocks)
            let changed = ranges.reduce(Int64(0)) { $0 + Int64($1.count) }
            // Nearly everything changed (a re-export): the plain upload is as fast and resumable.
            guard changed < size * 3 / 4 else {
                try? await backend.remove(temp, isDirectory: false)
                return nil
            }
            try await backend.writeRanges(url, ranges: ranges, to: temp, size: size, progress: progress)
            DiagnosticLog.note("Delta upload: \(changed.formatted(.byteCount(style: .file))) of \(size.formatted(.byteCount(style: .file))) sent")
            return temp
        } catch {
            DiagnosticLog.note("Delta upload not used: \(String(describing: error))")
            try? await backend.remove(temp, isDirectory: false)
            return nil
        }
    }

    /// The byte ranges of the local file whose blocks differ from `blocks` (or lie past their end), merged.
    static func changedRanges(of url: URL, size: Int64, against blocks: FangAPI.Blocks) throws -> [Range<Int64>] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let blockSize = Int64(blocks.blockSize)
        let known = blocks.hashes.count / 32
        var ranges: [Range<Int64>] = []
        var offset: Int64 = 0, index = 0
        while offset < size {
            try Task.checkCancellation()
            let length = min(blockSize, size - offset)
            // Each block is released before the next is read. Without the pool every block read stayed in
            // memory until the whole file had been compared, and iOS ended the extension partway through a
            // 268 MB file, on every attempt.
            let same: Bool = try autoreleasepool {
                let data = try handle.read(upToCount: Int(length)) ?? Data()
                guard data.count == length else { throw POSIXError(.EIO) }
                guard index < known, offset + length <= blocks.size, length == min(blockSize, blocks.size - offset) else { return false }
                let digest = Data(SHA256.hash(data: data))
                return blocks.hashes[blocks.hashes.startIndex + index * 32 ..< blocks.hashes.startIndex + (index + 1) * 32] == digest
            }
            if !same {
                if let last = ranges.last, last.upperBound == offset {
                    ranges[ranges.count - 1] = last.lowerBound..<offset + length
                } else {
                    ranges.append(offset..<offset + length)
                }
            }
            offset += length
            index += 1
        }
        return ranges
    }

    /// Updates a downloaded file to the server's current contents, fetching only the blocks that changed:
    /// `existing` (the copy this device has) is cloned to `url`, and the blocks whose hash differs are read
    /// from the server into it. Throws if a delta doesn't apply (the caller downloads the whole file).
    public func downloadIncremental(_ id: String, existing: URL, to url: URL, progress: Progress) async throws -> ItemRecord {
        guard let server, let uuid = UUID(uuidString: id) else { throw POSIXError(.ENOTSUP) }
        let path = try path(of: id)
        let localSize = Self.localSize(of: existing)
        guard localSize >= Self.deltaThreshold else { throw POSIXError(.ENOTSUP) }
        let blocks = try await server.blocks(of: uuid)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: existing, to: url)  // A clone on APFS: no bytes copied.
        var ranges: [Range<Int64>] = []
        let blockSize = Int64(blocks.blockSize), count = blocks.hashes.count / 32
        do {
            let reader = try FileHandle(forReadingFrom: existing)
            defer { try? reader.close() }
            for index in 0..<count {
                try Task.checkCancellation()
                let offset = Int64(index) * blockSize, length = min(blockSize, blocks.size - offset)
                // One block in memory at a time (see `changedRanges`).
                let same: Bool = try autoreleasepool {
                    guard offset + length <= localSize else { return false }
                    try reader.seek(toOffset: UInt64(offset))
                    let data = try reader.read(upToCount: Int(length)) ?? Data()
                    return data.count == length && Data(SHA256.hash(data: data))
                        == blocks.hashes[blocks.hashes.startIndex + index * 32 ..< blocks.hashes.startIndex + (index + 1) * 32]
                }
                if !same { ranges.append(offset..<offset + length) }
            }
        }
        let changed = ranges.reduce(Int64(0)) { $0 + Int64($1.count) }
        guard changed < blocks.size * 3 / 4 else { throw POSIXError(.ENOTSUP) }
        progress.totalUnitCount = max(changed, 1)
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        var done: Int64 = 0
        for range in ranges {
            try Task.checkCancellation()
            let data = try await backend.read(path, range: UInt64(range.lowerBound)..<UInt64(range.upperBound))
            guard data.count == range.count else { throw POSIXError(.EIO) }
            try writer.seek(toOffset: UInt64(range.lowerBound))
            try writer.write(contentsOf: data)
            done += Int64(data.count)
            progress.completedUnitCount = done
        }
        try writer.truncate(atOffset: UInt64(blocks.size))
        try writer.synchronize()
        // Changed again meanwhile: the blocks may come from two versions.
        guard let now = try await server.item(uuid), now.contentVersion == blocks.item.contentVersion else { throw POSIXError(.EAGAIN) }
        let record = self.record(from: blocks.item)
        store.save(record)
        DiagnosticLog.note("Delta download: \(changed.formatted(.byteCount(style: .file))) of \(blocks.size.formatted(.byteCount(style: .file))) fetched")
        return record
    }

    /// Part of a file, read straight from the server (partial fetches on macOS). Also returns the item now.
    public func readRange(_ id: String, range: Range<UInt64>) async throws -> (Data, ItemRecord) {
        let record = try await refresh(id)
        let data = try await backend.read(try path(of: id), range: range)
        return (data, record)
    }

    /// Gives the uploaded temp file the local file's dates, so the file on the server keeps the dates the user
    /// sees (not the time of the upload). A failure only costs the dates.
    private func keepDates(of url: URL, on temp: String, modified: Date? = nil) async {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        try? await backend.setDates(temp, modified: modified ?? values?.contentModificationDate, created: values?.creationDate)
    }

    /// Sets a file's dates on the server (a date changed without new contents) and returns the item.
    public func setDates(_ id: String, modified: Date?, created: Date?) async throws -> ItemRecord {
        try await backend.setDates(try path(of: id), modified: modified, created: created)
        return try await refresh(id)
    }

    // MARK: Extended attributes

    /// Sets an item's extended attributes on the server (FaNG-server mode): the ones the system syncs, such as
    /// a folder's symbol or emoji.
    public func setXattrs(_ id: String, _ xattrs: [String: Data]) async throws -> ItemRecord {
        guard let server, let uuid = UUID(uuidString: id) else { throw POSIXError(.ENOTSUP) }
        let record = record(from: try await server.setXattrs(uuid, xattrs))
        store.save(record)
        return record
    }

    // MARK: Tags

    /// Sets an item's Finder tags on the server (FaNG-server mode; plain SMB keeps them only locally).
    public func setTags(_ id: String, _ tags: [String]) async throws -> ItemRecord {
        guard let server, let uuid = UUID(uuidString: id) else { throw POSIXError(.ENOTSUP) }
        let record = record(from: try await server.setTags(uuid, tags))
        store.save(record)
        return record
    }

    // MARK: Trash

    /// Moves an item into the trash (FaNG-server mode).
    public func moveToTrash(_ id: String) async throws -> ItemRecord {
        guard let server, let uuid = UUID(uuidString: id) else { throw POSIXError(.ENOTSUP) }
        let record = record(from: try await server.moveToTrash(uuid))
        store.save(record)
        return record
    }

    /// Takes an item out of the trash, into `parentID` (where it was, if that's the domain's root).
    public func putBack(_ id: String, into parentID: String) async throws -> ItemRecord {
        guard let server, let uuid = UUID(uuidString: id) else { throw POSIXError(.ENOTSUP) }
        let record = record(from: try await server.putBack(uuid, into: UUID(uuidString: parentID)))
        store.save(record)
        return record
    }

    // MARK: Changes

    /// Where `changes(since:)` starts for a client that has everything now.
    public func currentAnchor() async throws -> Data {
        guard let server else { return Self.timeAnchor() }
        var anchor = ServerAnchor(epoch: nil, shares: [:], format: ItemRecord.itemFormat, filter: Self.feedFilter)
        for share in try await server.shares() {
            let page = try await server.changes(share: share.name, since: .max)
            anchor.epoch = page.epoch
            anchor.shares[share.name] = page.latest
        }
        return try JSONEncoder().encode(anchor)
    }

    /// What changed since `anchor`. Against a FaNG server, from its change feed (every share, every page);
    /// against plain SMB, by re-listing the most recently listed folders.
    public func changes(since anchor: Data, workingSetFolderLimit: Int) async throws -> ChangeSet {
        guard let server else {
            // An anchor from before the current item format: every known item is sent again first, so the
            // system takes their new capabilities and flags (it keeps an item's until the item changes).
            let plain = try? JSONDecoder().decode(PlainAnchor.self, from: anchor)
            // Plain SMB has no extended attributes: from those formats there's nothing to resend.
            if let format = plain?.format, ItemRecord.xattrOnlyRefreshFrom.contains(format) {
                return ChangeSet(updated: [], deleted: [], anchor: Self.timeAnchor())
            }
            if plain?.format != ItemRecord.itemFormat {
                let page = store.records(after: plain?.refresh ?? "", limit: Self.changesPerBatch)
                let done = page.count < Self.changesPerBatch
                let next = PlainAnchor(format: done ? ItemRecord.itemFormat : nil, refresh: done ? nil : page.last?.id)
                return ChangeSet(updated: page, deleted: [], anchor: try JSONEncoder().encode(next), moreComing: !done)
            }
            var set = ChangeSet(updated: [], deleted: [], anchor: Self.timeAnchor())
            for folder in store.recentFolders(limit: workingSetFolderLimit) {
                try Task.checkCancellation()
                let result: ItemStore.Reconciliation
                do {
                    result = try await relist(folder)
                } catch let error as POSIXError where error.code == .ENOENT {
                    continue  // The folder is gone; listing its parent reports the deletion.
                }
                set.updated += result.changed
                set.deleted += result.deleted
                set.contentChanged.formUnion(result.contentChanged)
            }
            return set
        }
        guard var current = try? JSONDecoder().decode(ServerAnchor.self, from: anchor), let epoch = current.epoch else {
            throw AnchorExpired()
        }
        // As for plain SMB above: every known item again, a page per call. The feed is read in the same call,
        // so live changes never wait behind a long refresh (a Mac that knows 500,000 items needs many calls).
        var refreshing: [ItemRecord] = []
        var refreshDone = true
        if current.format != ItemRecord.itemFormat {
            let limit = Self.changesPerBatch / 2
            // A refresh under way (no format) is partial only if it's known to have started from such a format; one
            // whose start isn't known resends everything. (Taking every such refresh for one from format 3 left
            // devices that hadn't finished the earlier full resend without the Copy To / Move To and Versions flags.)
            let partial = current.format.map { ItemRecord.xattrOnlyRefreshFrom.contains($0) }
                ?? (current.from.map { ItemRecord.xattrOnlyRefreshFrom.contains($0) } ?? false)
            if let format = current.format, partial { current.from = format }
            refreshing = store.records(after: current.refresh ?? "", limit: limit,
                                       withXattrsOnly: partial || current.from.map { ItemRecord.xattrOnlyRefreshFrom.contains($0) } == true)
            refreshDone = refreshing.count < limit
            current.format = refreshDone ? ItemRecord.itemFormat : nil
            current.refresh = refreshDone ? nil : refreshing.last?.id
            if refreshDone { current.from = nil }
        }
        // Everything as before, except what's inside a folder that reached this device new through the feed
        // and that the system hasn't listed since: it asks for that folder's contents (from the server) when
        // it's opened. A finished copy of 170,000 files is then one new folder for every device, not 170,000
        // entries that kept phones busy for many minutes before any later change showed up. Folders known
        // from before carry no mark, so they get every change as they always did.
        if current.filter != Self.feedFilter {
            // Once, when the device first runs this: read the recent feed again. The first version of the
            // filter skipped new entries in folders it wrongly took for never listed; this brings them back
            // (everything already known is just sent again).
            for (share, since) in current.shares { current.shares[share] = max(0, since - Self.feedRewind) }
            current.filter = Self.feedFilter
        }
        var set = ChangeSet(updated: [], deleted: [], anchor: anchor)
        var read = 0
        let started = ContinuousClock.now
        let visibleShares = try await server.shares()
        // A share this user may no longer see (an admin took away everything they had in it): its folder goes.
        // One that appears starts from the beginning of its feed, which brings just its root folder.
        let gone = Set(current.shares.keys).subtracting(visibleShares.map(\.name))
        if !gone.isEmpty {
            let roots = store.children(of: store.rootID).filter { $0.isDirectory && gone.contains($0.name) }.map(\.id)
            store.remove(roots)
            set.deleted += roots
            for share in gone { current.shares[share] = nil }
        }
        // A share that's new here, or whose root is another folder now (a share removed and another added under
        // the same name, as "Home"): its root folder, and the feed from its latest change. What's inside is listed
        // from the server when it's opened. Reading such a share's whole feed from the start meant hundreds of
        // thousands of entries (a 670,000-item share) before anything newer showed up, on a phone the system
        // rarely lets run.
        let shownRoots = store.children(of: store.rootID).filter(\.isDirectory)
        var startedFresh: Set<String> = []
        for share in visibleShares {
            guard let root = share.root else { continue }
            let rootID = root.id.uuidString
            let replaced = shownRoots.filter { $0.name == share.name && $0.id != rootID }
            guard current.shares[share.name] == nil || !replaced.isEmpty else { continue }
            store.remove(replaced.map(\.id))
            set.deleted += replaced.map(\.id)
            let record = record(from: root)
            store.save(record)
            set.updated.append(record)
            let page = try await server.changes(share: share.name, since: .max)
            current.shares[share.name] = page.latest
            startedFresh.insert(share.name)
        }
        for share in visibleShares where !startedFresh.contains(share.name) {
            var since = current.shares[share.name] ?? 0
            while true {
                try Task.checkCancellation()
                if set.updated.count + set.deleted.count >= Self.changesPerBatch || read >= Self.feedPerBatch
                    || ContinuousClock.now - started > Self.feedTimePerBatch {
                    set.moreComing = true
                    break
                }
                let page: FangAPI.ChangesPage
                do {
                    page = try await server.changes(share: share.name, since: since, limit: 5000)
                } catch FangAPI.Failure.status(410) {
                    // The server no longer keeps the deletions since this anchor: list everything again.
                    throw AnchorExpired()
                }
                guard page.epoch == epoch else { throw AnchorExpired() }
                // Far behind (a phone that hardly ran while a big share was renumbered): listing again what this device
                // knows costs much less than reading the rest of the feed, so start over that way.
                if page.more, page.latest - since > 100_000, page.latest - since > Int64(store.count()) * 4 {
                    throw AnchorExpired()
                }
                read += page.items.count
                let known = store.known(page.items.map(\.id.uuidString))
                let parents = Set(page.items.compactMap { item in item.trashed == true ? nil : item.parent?.uuidString })
                var knownParents = store.known(parents)
                var skipped = store.unlisted(parents)
                var deleted: [String] = []
                var updated: [ItemRecord] = []
                var newFolders: [String] = []
                for item in page.items {
                    let id = item.id.uuidString
                    if item.deleted {
                        if known.contains(id) { deleted.append(id) }
                        continue
                    }
                    let record = record(from: item)
                    let parent = record.parentID
                    let shown = known.contains(id) || parent == store.rootID || parent == trashID
                        || (knownParents.contains(parent) && !skipped.contains(parent))
                    guard shown else {
                        if item.isDirectory { skipped.insert(id) }
                        continue
                    }
                    updated.append(record)
                    if !known.contains(id) {
                        knownParents.insert(id)
                        if item.isDirectory {
                            newFolders.append(id)
                            skipped.insert(id)
                        }
                    }
                }
                store.markUnlisted(newFolders)
                for record in updated where !record.isDirectory {
                    if let known = store.record(record.id), known.contentVersion != record.contentVersion {
                        set.contentChanged.insert(record.id)
                    }
                }
                store.remove(deleted)
                store.save(updated)
                set.deleted += deleted
                set.updated += updated
                since = page.anchor
                if !page.more { break }
            }
            current.shares[share.name] = since
        }
        // The refresh page goes first; anything the feed sent for the same item replaces it (it's newer).
        if !refreshing.isEmpty {
            let fromFeed = Set(set.updated.map(\.id)).union(set.deleted)
            set.updated = refreshing.filter { !fromFeed.contains($0.id) } + set.updated
        }
        if !refreshDone { set.moreComing = true }
        set.anchor = try JSONEncoder().encode(current)
        return set
    }

    /// FaNG-server anchor: the server database's epoch and the last change number seen in each share.
    private struct ServerAnchor: Codable {
        var epoch: UUID?
        var shares: [String: Int64]
        /// The item format (`ItemRecord.itemFormat`) the system has every known item in; nil while they're
        /// being sent again, `refresh` being the last ID sent.
        var format: Int?
        var refresh: String?
        /// The change-feed filter the anchor was made with (`feedFilter`).
        var filter: Int?
        /// The item format a refresh under way started from.
        var from: Int?
    }

    /// Plain-SMB anchor: changes are found by listing, so it only needs to move forward. It also carries the
    /// item format, as `ServerAnchor` does (an anchor that isn't this JSON is from before).
    private struct PlainAnchor: Codable {
        var time = Date().timeIntervalSince1970
        var format: Int?
        var refresh: String?
    }

    private static func timeAnchor() -> Data {
        (try? JSONEncoder().encode(PlainAnchor(format: ItemRecord.itemFormat))) ?? Data()
    }

    // MARK: FaNG server mode

    /// A server item as a record. Share roots hang off the domain's root.
    private func record(from item: FangItem) -> ItemRecord {
        let remote = RemoteItem(
            path: item.smbPath, name: item.name, isDirectory: item.isDirectory, size: item.size,
            modified: Date(timeIntervalSince1970: Double(item.mtimeNS) / 1_000_000_000),
            created: Date(timeIntervalSince1970: Double(item.mtimeNS) / 1_000_000_000),
            fileID: UInt64(bitPattern: item.inode)
        )
        let parentID = item.trashed == true ? trashID : item.parent?.uuidString ?? store.rootID
        var record = ItemRecord(id: item.id.uuidString, parentID: parentID, remote: remote)
        record.serverVersion = item.isDirectory ? nil : item.contentVersion
        record.tags = item.tags ?? []
        record.job = item.jobState
        record.progress = item.progress
        record.xattrs = item.xattrs ?? [:]
        record.readOnly = item.access == "read"
        return record
    }

    /// FaNG-server mode: uploads over SMB to the temp file as usual, then has the server put it in place,
    /// which checks the base version on disk, swaps atomically and keeps the old contents as a version.
    private func commitThroughServer(
        _ server: FangAPI, record: ItemRecord, key: String, folder: String, url: URL, baseVersion: Data?,
        modified: Date?, progress: Progress
    ) async throws -> ContentUpdate {
        guard let id = UUID(uuidString: record.id) else { throw POSIXError(.ENOENT) }
        let base = baseVersion.flatMap { String(decoding: $0, as: UTF8.self).dropFirst().description }.flatMap { Int64($0) }
            ?? record.serverVersion ?? 0
        var result: FangAPI.Commit?
        try await journaled(key: key, itemID: record.id, name: record.name, folder: folder, source: url) {
            // Only the blocks that changed, when the server has the old contents; otherwise the whole file.
            let temp: String
            if let delta = await deltaUpload(server, id: id, url: url, key: key, folder: folder, progress: progress) {
                temp = delta
            } else {
                temp = try await uploadToTemp(url, key: key, in: folder, progress: progress)
            }
            await keepDates(of: url, on: temp, modified: modified)
            let path = RemotePath.join(folder, record.name)
            let inner = path.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init)
            result = try await server.commit(id, temp: RemotePath.name(of: temp), baseVersion: base, modified: modified, path: inner)
        }
        guard let result else { throw POSIXError(.EIO) }
        let updated = self.record(from: result.item)
        store.save(updated)
        // A server from before `editWon` existed: after a conflict, fetching again is the safe choice.
        return ContentUpdate(record: updated, conflictCopyName: nil, conflict: result.conflict,
                             editLost: result.conflict && result.editWon != true)
    }

    /// Records an item this device just wrote. Against a FaNG server, it asks the server for the item (and
    /// so its ID) right away; against plain SMB, the store assigns one.
    private func adoptWritten(_ remote: RemoteItem, at path: String, parentID: String, reuseExisting: Bool) async throws -> ItemRecord {
        guard let server else {
            return store.adopt(remote, parentID: parentID, reuseExisting: reuseExisting)
        }
        let share = path.split(separator: "/", maxSplits: 1).first.map(String.init) ?? path
        let inner = path.count > share.count ? String(path.dropFirst(share.count + 1)) : ""
        guard let item = try await server.resolve(share: share, path: inner) else { throw POSIXError(.ENOENT) }
        let record = record(from: item)
        store.adopt(record)
        return record
    }

    // MARK: Uploads

    /// Records an upload in the journal while `work` runs: removed when it succeeds or can't be resumed,
    /// kept with the reason when it fails and will be retried.
    private func journaled(
        key: String, itemID: String?, name: String, folder: String, source: URL, _ work: () async throws -> Void
    ) async throws {
        journal?.started(key: key, itemID: itemID, name: name, folder: folder, size: Self.localSize(of: source))
        do {
            try await work()
            journal?.superseded(by: key, itemID: itemID, name: name, folder: folder)
            if journal?.temp(for: key) != nil {
                // It finished in a fresh temp file; the one the server held goes too, if it's let go by now.
                try? await backend.remove(RemotePath.join(folder, RemotePath.uploadPrefix + key), isDirectory: false)
            }
            journal?.finished(key: key)
        } catch {
            if error.discardsUpload || error.itemIsGone {
                // Nothing left to wait for (the system makes the file again if the item is gone).
                journal?.finished(key: key)
            } else {
                if error.isServerBusy {
                    journal?.markBusy(key)
                } else {
                    journal?.clearBusy(key)
                }
                journal?.failed(key: key, error: error.transferProblem)
            }
            throw error
        }
    }

    /// Uploads to the hidden temp name for `key` in `folder`, resuming what an earlier attempt left
    /// there, and returns the temp path. Other clients never see a half-written file; it's renamed into
    /// place when complete. A network failure is retried once right away, from where it stopped. If the
    /// retry fails too, the temp file is kept for the next attempt (see `discardsUpload`). If the server
    /// has refused the upload as busy for longer than `busyLimit`, it starts over in a fresh temp file.
    private func uploadToTemp(_ source: URL, key: String, in folder: String, progress: Progress) async throws -> String {
        var name = journal?.temp(for: key) ?? RemotePath.uploadPrefix + key
        if let journal, let since = journal.busySince(key), Date().timeIntervalSince(since) > Self.busyLimit {
            name = RemotePath.uploadPrefix + key + "-" + UUID().uuidString.prefix(8).lowercased()
            journal.startedFresh(key, temp: name)
        }
        let temp = RemotePath.join(folder, name)
        let size = Self.localSize(of: source)
        var retried = false
        while true {
            do {
                let offset = try await resumeOffset(for: temp, localSize: size)
                try await backend.upload(source, to: temp, from: offset, progress: progress)
                return temp
            } catch where error.isTransientNetworkError && !retried && !Task.isCancelled {
                retried = true
            } catch {
                if error.discardsUpload {
                    try? await backend.remove(temp, isDirectory: false)
                }
                throw error
            }
        }
    }

    /// Where an upload to `temp` resumes: `resumeOverlap` before the end of what arrived. 0, with the
    /// leftover removed, when there's nothing worth resuming or it can't belong to this file.
    private func resumeOffset(for temp: String, localSize: Int64) async throws -> Int64 {
        let existing: RemoteItem
        do {
            existing = try await backend.stat(temp)
        } catch let error as POSIXError where error.code == .ENOENT {
            return 0
        }
        let offset = existing.size - Self.resumeOverlap
        if !existing.isDirectory, existing.size <= localSize, offset > 0 {
            return offset
        }
        try await backend.remove(temp, isDirectory: existing.isDirectory)
        return 0
    }

    /// Runs the renames that put an upload in place. On failure the temp file is kept, so a retry finds
    /// it complete and only commits, unless the failure means the upload is over (`discardsUpload`).
    private func commit(removingOnFailure temp: String, _ renames: () async throws -> Void) async throws {
        do {
            try await renames()
        } catch {
            if error.discardsUpload {
                try? await backend.remove(temp, isDirectory: false)
            }
            throw error
        }
    }

    /// Names an upload by what it uploads: the operation (`scope`), and the local file's size, modification
    /// date, and first and last 64 KiB. A retry of the same upload gets the same name; another file or a
    /// newer edit gets another.
    static func uploadKey(scope: String, file url: URL) throws -> String {
        let sample = 64 << 10
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values.fileSize ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        hasher.update(data: Data("\(scope)\n\(size)\n\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)".utf8))
        hasher.update(data: try handle.read(upToCount: sample) ?? Data())
        if size > 2 * sample {
            try handle.seek(toOffset: UInt64(size - sample))
            hasher.update(data: try handle.readToEnd() ?? Data())
        }
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// A free name for a conflict copy: "report [CONFLICT 2026-11-02 14.03.11].docx", then " 2", " 3", ….
    private func conflictName(for name: String, in folder: String) async throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let ext = (name as NSString).pathExtension
        let stem = ((name as NSString).deletingPathExtension) + " [CONFLICT \(formatter.string(from: Date()))]"
        for number in 1...100 {
            let candidate = (number == 1 ? stem : "\(stem) \(number)") + (ext.isEmpty ? "" : ".\(ext)")
            do {
                _ = try await backend.stat(RemotePath.join(folder, candidate))
            } catch let error as POSIXError where error.code == .ENOENT {
                return candidate
            }
        }
        throw POSIXError(.EEXIST)
    }

    private static func localSize(of url: URL?) -> Int64 {
        guard let url else { return 0 }
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? -1
    }

    private static func emptyFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "fang-empty-\(UUID().uuidString)")
        try Data().write(to: url)
        return url
    }
}
