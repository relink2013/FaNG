#if os(Linux)
import FaNGCore
import Foundation
import Glibc

/// One entry a scan found on disk, with what the database keeps about it.
struct Found: Sendable {
    /// Inside the share ("" is its root).
    var path: String
    var entry: Disk.Entry
    var id: UUID?
    var tags: [String]
    var xattrs: [String: Data]
    /// 0 for the folder the walk started at, 1 for what's in it, and so on.
    var depth: Int
}

/// Reads a share (or a folder in it) from disk with many threads: folders level by level, every entry's
/// facts (type, size, time, inode, FaNG ID, tags, client metadata) in parallel. FaNG's own files are left
/// out; the leftovers a scan should clean up are reported.
enum Walker {
    struct Result: Sendable {
        /// Parents before what's in them.
        var found: [Found]
        /// Unfinished copies and moves (only collected when asked: none can be running then).
        var leftovers: [String] = []
        /// Upload temp files nobody has written to for longer than the upload age.
        var staleUploads: [String] = []
        /// Every upload temp file seen (uploads under way or interrupted), and their bytes.
        var uploadCount = 0
        var uploadBytes: Int64 = 0
    }

    static func walk(_ share: Share, from start: String, threads: Int, collectLeftovers: Bool, uploadAge: TimeInterval) -> Result {
        @Sendable func absolute(_ path: String) -> String { path.isEmpty ? share.path : share.path + "/" + path }
        guard let top = Disk.entry(absolute(start)) else { return Result(found: []) }
        var result = Result(found: [facts(start, top, absolute(start), depth: 0)])
        guard top.isDirectory else { return result }
        let leftovers = Collected(), stale = Collected(), uploads = Sizes()
        let cutoff = Int64((Date().timeIntervalSince1970 - uploadAge) * 1_000_000_000)
        var level = [start], depth = 0
        while !level.isEmpty {
            depth += 1
            // Each folder's names, several folders at a time.
            let lists = parallelMap(level, threads: threads) { folder -> [String] in
                var visible: [String] = []
                for name in Disk.names(in: absolute(folder)) {
                    let path = folder.isEmpty ? name : folder + "/" + name
                    if Tracker.isInternal(name) {
                        if collectLeftovers, name.hasPrefix(Tracker.copyPrefix) || name.hasPrefix(Tracker.movePrefix) {
                            leftovers.add(absolute(path))
                        } else if name.hasPrefix(".fang-upload-"), let entry = Disk.entry(absolute(path)), !entry.isDirectory {
                            uploads.add(entry.size)
                            if entry.mtimeNS < cutoff { stale.add(absolute(path)) }
                        }
                    } else {
                        visible.append(path)
                    }
                }
                return visible
            }
            // Every entry's facts, spread evenly over the threads (one folder can hold 100,000 entries).
            let children = lists.flatMap { $0 }
            let level_ = depth
            let found = parallelMap(children, threads: threads) { path -> Found? in
                guard let entry = Disk.entry(absolute(path)) else { return nil }  // Gone meanwhile, or a link.
                return facts(path, entry, absolute(path), depth: level_)
            }.compactMap { $0 }
            result.found += found
            level = found.filter(\.entry.isDirectory).map(\.path)
        }
        result.leftovers = leftovers.items
        result.staleUploads = stale.items
        (result.uploadCount, result.uploadBytes) = uploads.total
        return result
    }

    private static func facts(_ path: String, _ entry: Disk.Entry, _ absolute: String, depth: Int) -> Found {
        Found(path: path, entry: entry, id: Disk.readID(absolute), tags: Disk.readTags(absolute),
              xattrs: Disk.readMetadata(absolute), depth: depth)
    }

    /// `transform` over `items` on `threads` threads, results in the items' order.
    static func parallelMap<T: Sendable, R: Sendable>(_ items: [T], threads: Int, _ transform: @Sendable (T) -> R) -> [R] {
        guard !items.isEmpty else { return [] }
        let results = Slots<R>(count: items.count)
        let next = Counter()
        let workers = min(threads, max(1, items.count / 16 + 1))
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while true {
                let range = next.take(64, below: items.count)
                if range.isEmpty { break }
                for index in range { results.set(index, transform(items[index])) }
            }
        }
        return results.values
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ item: String) { lock.withLock { list.append(item) } }
        var items: [String] { lock.withLock { list } }
    }

    private final class Sizes: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0, bytes: Int64 = 0
        func add(_ size: Int64) { lock.withLock { count += 1; bytes += size } }
        var total: (Int, Int64) { lock.withLock { (count, bytes) } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var position = 0
        func take(_ count: Int, below limit: Int) -> Range<Int> {
            lock.withLock {
                let start = position
                position = min(limit, position + count)
                return start..<position
            }
        }
    }

    /// One slot per result; each is written by one thread only.
    /// (A raw buffer: a Swift array written from several threads at once trips the exclusivity checks.)
    private final class Slots<R>: @unchecked Sendable {
        private let storage: UnsafeMutablePointer<R?>
        private let count: Int
        init(count: Int) {
            self.count = count
            storage = .allocate(capacity: count)
            storage.initialize(repeating: nil, count: count)
        }
        deinit {
            storage.deinitialize(count: count)
            storage.deallocate()
        }
        func set(_ index: Int, _ value: R) { storage[index] = value }
        var values: [R] { (0..<count).map { storage[$0]! } }
    }
}
#endif
