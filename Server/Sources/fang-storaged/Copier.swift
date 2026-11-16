#if os(Linux)
import CLinuxFS
import FaNGCore
import Foundation
import Glibc

/// How far a copy is, for the item's percentage and the app's list of copies: what it's doing, entries and
/// bytes done out of the total, and the file being copied. Running copies are listed in `running`, which
/// the control socket reads without going through the tracker.
final class CopyProgress: @unchecked Sendable {
    enum Phase: String, Sendable {
        case counting, copying, recording
    }

    struct Snapshot: Codable, Sendable {
        var id: UUID
        var phase: String
        var entriesDone: Int
        var entriesTotal: Int
        var bytesDone: Int64
        var bytesTotal: Int64
        /// Inside the copy (its own name first): the file being copied now.
        var current: String?
        var started: Date
    }

    private let lock = NSLock()
    let id: UUID
    let name: String
    let started = Date()
    private var phase = Phase.counting
    private var total = 1
    private var done = 0
    private var bytesTotal: Int64 = 0
    private var bytesDone: Int64 = 0
    private var current: String?

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    func setTotal(_ count: Int, bytes: Int64) {
        lock.withLock {
            total = max(count, 1)
            bytesTotal = bytes
            phase = .copying
        }
    }

    func starting(_ relative: String) {
        lock.withLock { current = relative.isEmpty ? name : name + "/" + relative }
    }

    func advance(bytes: Int64 = 0) {
        lock.withLock {
            done += 1
            bytesDone += bytes
        }
    }

    func recording() {
        lock.withLock {
            phase = .recording
            current = nil
        }
    }

    /// Percent done, at most 99 until the copy is in place.
    var percent: Int {
        lock.withLock { min(99, done * 100 / total) }
    }

    var snapshot: Snapshot {
        lock.withLock {
            Snapshot(id: id, phase: phase.rawValue, entriesDone: done, entriesTotal: phase == .counting ? 0 : total,
                     bytesDone: bytesDone, bytesTotal: bytesTotal, current: current, started: started)
        }
    }

    // MARK: Running copies

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [UUID: CopyProgress] = [:]

    static func register(_ progress: CopyProgress) {
        registryLock.withLock { registry[progress.id] = progress }
    }

    static func unregister(_ id: UUID) {
        registryLock.withLock { registry[id] = nil }
    }

    static var running: [Snapshot] {
        registryLock.withLock { Array(registry.values) }.map(\.snapshot).sorted { $0.started < $1.started }
    }
}

/// The disk side of a server copy (see `Tracker.copy`). Files are reflinked where the filesystem can and
/// copied in the kernel otherwise, several at a time. Every entry gets the host owner (99:100) and the
/// share's mode as it's made, a new FaNG ID, the original's client metadata (but no [CONFLICT] tag) and
/// modification time. Symbolic links, special files and FaNG's own files are left out.
enum Copier {
    /// Files copied at the same time: ZFS handles parallel metadata work well, and a copy is mostly that.
    static let workers = Resources.workers(cpuShare: 0.5, memoryPerWorker: 32 << 20, limit: 16, setting: "FANG_COPY_WORKERS")

    private struct Entry: Sendable {
        let relative: String
        let isDirectory: Bool
        let mtimeNS: Int64
        let size: Int64
        let id: UUID
        let parent: UUID
    }

    /// Makes the copy of `job.source` at `temp` and returns what's below its top (the top keeps the job's
    /// item, which already exists), with the paths it will have once `temp` is renamed into place.
    /// Also returns, for every file, the original it came from (copy ID, original ID), for its thumbnail.
    static func copy(_ job: Tracker.CopyJob, to temp: String, progress: CopyProgress) throws -> (entries: [Observed], sources: [(copy: UUID, source: UUID)]) {
        guard let top = Disk.entry(job.source), top.isDirectory == job.isDirectory else { throw POSIXError(.ENOENT) }

        // What's there, each folder before what's in it.
        var folders: [Entry] = [], files: [Entry] = []
        var bytes: Int64 = job.isDirectory ? 0 : top.size
        if job.isDirectory {
            var queue: [(String, UUID)] = [("", job.id)]
            var index = 0
            while index < queue.count {
                let (relative, id) = queue[index]
                index += 1
                for name in Disk.names(in: at(job.source, relative)) where !Tracker.isInternal(name) {
                    let child = relative.isEmpty ? name : relative + "/" + name
                    guard let entry = Disk.entry(job.source + "/" + child) else { continue }
                    let item = Entry(relative: child, isDirectory: entry.isDirectory, mtimeNS: entry.mtimeNS, size: entry.size,
                                     id: UUID(), parent: id)
                    if entry.isDirectory {
                        folders.append(item)
                        queue.append((child, item.id))
                    } else {
                        files.append(item)
                        bytes += entry.size
                    }
                }
            }
        }
        progress.setTotal(folders.count + files.count + 1, bytes: bytes)
        let topEntry = Entry(relative: "", isDirectory: job.isDirectory, mtimeNS: top.mtimeNS, size: job.isDirectory ? 0 : top.size,
                             id: job.id, parent: job.parent)

        // The folders, in order.
        if job.isDirectory {
            try makeFolder(temp, id: job.id, mode: job.modes.folder)
            progress.advance()
            for folder in folders {
                try makeFolder(at(temp, folder.relative), id: folder.id, mode: job.modes.folder)
                progress.advance()
            }
        }

        // The files, several at a time.
        let work = job.isDirectory ? files : [topEntry]
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: min(workers, max(work.count, 1))) { _ in
            while let index = results.next(below: work.count) {
                let entry = work[index]
                progress.starting(entry.relative)
                do {
                    let observed = try copyFile(from: at(job.source, entry.relative), to: at(temp, entry.relative), entry: entry,
                                                finalPath: at(job.path, entry.relative), mode: job.modes.file)
                    if !entry.relative.isEmpty { results.add(observed) }
                    if let source = Disk.readID(at(job.source, entry.relative)) { results.addSource(entry.id, source) }
                    progress.advance(bytes: entry.size)
                } catch {
                    results.fail(error)
                }
            }
        }
        if let error = results.error { throw error }

        // The folders' metadata and times, deepest first: adding entries to a folder changes its time.
        var observed = results.items
        for folder in folders.reversed() {
            observed.append(try finishFolder(at(temp, folder.relative), source: at(job.source, folder.relative), entry: folder,
                                             finalPath: at(job.path, folder.relative)))
        }
        if job.isDirectory {
            _ = try finishFolder(temp, source: job.source, entry: topEntry, finalPath: job.path)
        }
        return (observed, results.sources)
    }

    /// `relative` inside `base` ("" is `base` itself).
    private static func at(_ base: String, _ relative: String) -> String {
        relative.isEmpty ? base : base + "/" + relative
    }

    private static func failure() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func makeFolder(_ path: String, id: UUID, mode: mode_t) throws {
        guard mkdir(path, 0o700) == 0, lchown(path, 99, 100) == 0, chmod(path, mode) == 0 else { throw failure() }
        _ = Disk.writeID(id, to: path)
    }

    private static func copyFile(from source: String, to path: String, entry: Entry, finalPath: String, mode: mode_t) throws -> Observed {
        guard fang_clone(source, path) == 0, lchown(path, 99, 100) == 0, chmod(path, mode) == 0 else { throw failure() }
        return try finish(path, source: source, entry: entry, finalPath: finalPath)
    }

    private static func finishFolder(_ path: String, source: String, entry: Entry, finalPath: String) throws -> Observed {
        try finish(path, source: source, entry: entry, finalPath: finalPath)
    }

    /// Client metadata (without FaNG's ID, and without the [CONFLICT] tag), the ID, the original's time,
    /// and what the entry looks like now, for the database.
    private static func finish(_ path: String, source: String, entry: Entry, finalPath: String) throws -> Observed {
        _ = fang_copy_xattrs(source, path, Disk.idAttribute)
        var tags = Disk.readTags(path)
        if tags.contains(Disk.conflictTag) {
            tags.removeAll { $0 == Disk.conflictTag }
            try? Disk.writeTags(tags, to: path)
        }
        _ = Disk.writeID(entry.id, to: path)
        _ = fang_set_mtime(path, entry.mtimeNS)
        guard let made = Disk.entry(path) else { throw POSIXError(.ENOENT) }
        var observed = Observed(
            id: entry.id, parent: entry.parent, name: String(finalPath.split(separator: "/").last ?? ""), path: finalPath,
            isDirectory: made.isDirectory, size: made.isDirectory ? 0 : made.size, mtimeNS: made.mtimeNS, inode: made.inode)
        observed.tags = tags
        observed.xattrs = Disk.readMetadata(path)
        return observed
    }

    /// Shared between the workers: the next file to copy, what's done, and the first error (which stops them).
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var position = 0
        private(set) var items: [Observed] = []
        private(set) var sources: [(copy: UUID, source: UUID)] = []
        private(set) var error: Error?

        func next(below count: Int) -> Int? {
            lock.withLock {
                guard error == nil, position < count else { return nil }
                defer { position += 1 }
                return position
            }
        }

        func add(_ item: Observed) {
            lock.withLock { items.append(item) }
        }

        func addSource(_ copy: UUID, _ source: UUID) {
            lock.withLock { sources.append((copy, source)) }
        }

        func fail(_ failure: Error) {
            lock.withLock { if error == nil { error = failure } }
        }
    }
}
#endif
