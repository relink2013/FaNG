import AMSMB2
import Foundation

/// `FileBackend` over SMB2/3, using AMSMB2 (libsmb2), for a whole server.
///
/// The top level ("") lists the shares the user can open, as folders. Every other path starts with
/// a share name: "Share/folder/file". Each share has one connection for listings and metadata, and every
/// transfer gets a connection of its own, so a slow transfer never holds up browsing.
///
/// Every call runs under the `Watchdog`: a request with no answer within the timeout, or a transfer with
/// no progress within `transferStallLimit`, fails with `ETIMEDOUT`. A network failure drops the share's
/// connection, so the next call starts a fresh one.
public final class SMBBackend: FileBackend, @unchecked Sendable {
    public enum Failure: Error, LocalizedError {
        case invalidServerAddress

        public var errorDescription: String? {
            switch self {
            case .invalidServerAddress: "The server address isn't valid."
            }
        }
    }

    /// How long a single read or write may wait for the server. Much longer than for metadata: a ZFS pool
    /// slows writes down while it flushes a large backlog (up to `zfs_dirty_data_max`, 32 GiB on a big
    /// server) to disk, and one request can wait well over 30 seconds.
    static let transferRequestTimeout: TimeInterval = 120

    /// A transfer with no progress for this long is stalled.
    public static let transferStallLimit: Duration = .seconds(180)

    /// How long opening a connection (TCP, negotiate, sign-in, share) may take. Much shorter than a
    /// transfer's request limit: a server that can't be reached should fail fast, so the system shows it as
    /// unreachable and retries, instead of "Waiting" for minutes.
    static let connectLimit: Duration = .seconds(15)

    /// Connects `manager` to `share` within `connectLimit`, noting how it went in the diagnostic log.
    private func connect(_ manager: SMB2Manager, to share: String, purpose: String) async throws {
        let start = ContinuousClock.now
        do {
            try await Watchdog.run(idleLimit: Self.connectLimit) {
                try await manager.connectShare(name: share, encrypted: self.account.encrypted)
            }
            let elapsed = ContinuousClock.now - start
            if elapsed > .seconds(1) {
                DiagnosticLog.note("SMB \(purpose) connected in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])))")
            }
        } catch {
            DiagnosticLog.note("SMB \(purpose) connect failed after \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds]))): \(String(describing: error))")
            throw error
        }
    }

    /// Upload temp files untouched for this long belong to uploads that were given up (the file was
    /// deleted locally, or the device was reset), and are removed when their folder is listed.
    static let abandonedUploadAge: TimeInterval = 7 * 24 * 3600

    private let account: ServerAccount
    private let password: String
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var managers: [String: SMB2Manager] = [:]
    /// Where the server is reached: the address the account was added with, then the one a FaNG server names
    /// for SMB, if it differs. Connections use `addresses[current]`.
    private let addresses: [URL]
    private var current = 0
    private var otherAddressFailed: ContinuousClock.Instant?

    public init(account: ServerAccount, password: String, timeout: TimeInterval = 30) throws {
        guard let url = account.serverURL else { throw Failure.invalidServerAddress }
        self.account = account
        self.password = password
        self.timeout = timeout
        var addresses = [url]
        if let other = account.advertisedSMBURL, other != url { addresses.append(other) }
        self.addresses = addresses
    }

    // MARK: Connections

    private func makeManager(timeout: TimeInterval? = nil) throws -> SMB2Manager {
        try makeManager(at: lock.withLock { addresses[current] }, timeout: timeout)
    }

    /// Takes no lock: `cachedManager` calls it while holding one.
    private func makeManager(at url: URL, timeout: TimeInterval? = nil) throws -> SMB2Manager {
        let credential = URLCredential(user: account.username, password: password, persistence: .none)
        guard let manager = SMB2Manager(url: url, credential: credential) else {
            throw Failure.invalidServerAddress
        }
        manager.timeout = timeout ?? self.timeout
        return manager
    }

    /// After a connection to the current address failed: switches to the server's other address, if it has
    /// one and that one didn't fail within the last minute too (an unreachable server should fail fast, not
    /// after trying everything twice). True when the caller should connect again.
    private func switchAddress(after error: Error) -> Bool {
        guard addresses.count > 1, error.isTransientNetworkError else { return false }
        return lock.withLock {
            if let failed = otherAddressFailed, ContinuousClock.now - failed < .seconds(60) { return false }
            current = (current + 1) % addresses.count
            managers.removeAll()
            return true
        }
    }

    /// The address just switched to didn't answer either: back to the one before.
    private func switchBack() {
        lock.withLock {
            current = (current + addresses.count - 1) % addresses.count
            otherAddressFailed = .now
            managers.removeAll()
        }
    }

    private func cachedManager(for share: String) throws -> SMB2Manager {
        try lock.withLock {
            if let manager = managers[share] { return manager }
            let manager = try makeManager(at: addresses[current])
            managers[share] = manager
            return manager
        }
    }

    /// A connected manager for one share. Connecting is cheap when the session is already up,
    /// and reconnects after the server dropped it.
    private func manager(for share: String) async throws -> SMB2Manager {
        let manager = try cachedManager(for: share)
        do {
            try await connect(manager, to: share, purpose: "metadata")
            return manager
        } catch where switchAddress(after: error) {
            let first = error
            do {
                let manager = try cachedManager(for: share)
                try await connect(manager, to: share, purpose: "metadata")
                DiagnosticLog.note("SMB: using the server's other address")
                return manager
            } catch {
                switchBack()
                throw first
            }
        }
    }

    private func dropConnection(for share: String) {
        _ = lock.withLock { managers.removeValue(forKey: share) }
    }

    /// Runs `operation` on the share's connection under the watchdog. Network failures drop the connection.
    private func guarded<T: Sendable>(
        _ share: String,
        idleLimit: Duration? = nil,
        activity: Activity = Activity(),
        _ operation: @escaping @Sendable (SMB2Manager) async throws -> T
    ) async throws -> T {
        do {
            return try await Watchdog.run(idleLimit: idleLimit ?? .seconds(timeout), activity: activity) {
                try await operation(try await self.manager(for: share))
            }
        } catch where error.isTransientNetworkError {
            dropConnection(for: share)
            throw error
        }
    }

    /// A connection of its own for one transfer, at the server's other address if the current one can't be reached.
    private func transferManager(for share: String) async throws -> SMB2Manager {
        let manager = try makeManager(timeout: Self.transferRequestTimeout)
        do {
            try await connect(manager, to: share, purpose: "transfer")
            return manager
        } catch where switchAddress(after: error) {
            let first = error
            do {
                let manager = try makeManager(timeout: Self.transferRequestTimeout)
                try await connect(manager, to: share, purpose: "transfer")
                return manager
            } catch {
                switchBack()
                throw first
            }
        } catch {
            Task.detached { try? await manager.disconnectShare(gracefully: false) }
            throw error
        }
    }

    /// Runs a transfer on a connection of its own, under the watchdog. The connection is closed afterwards;
    /// after a failure, that also makes the server release whatever the transfer had open, so a retry
    /// isn't refused with a sharing violation.
    private func transferring(
        _ share: String,
        activity: Activity,
        _ operation: @escaping @Sendable (SMB2Manager) async throws -> Void
    ) async throws {
        let manager = try await transferManager(for: share)
        do {
            try await Watchdog.run(idleLimit: Self.transferStallLimit, activity: activity) {
                try await operation(manager)
            }
        } catch {
            Task.detached { try? await manager.disconnectShare(gracefully: false) }
            throw error
        }
        Task.detached { try? await manager.disconnectShare(gracefully: true) }
    }

    /// Splits "Share/rest/of/path" into the share and the path inside it, the latter as sent over SMB
    /// (`SMBName.wire`).
    private func split(_ path: String) throws -> (share: String, path: String) {
        guard !path.isEmpty else { throw POSIXError(.EPERM) }
        guard let slash = path.firstIndex(of: "/") else { return (path, "") }
        return (String(path[..<slash]), SMBName.wire(String(path[path.index(after: slash)...])))
    }

    private static func shareItem(_ name: String) -> RemoteItem {
        let epoch = Date(timeIntervalSince1970: 0)
        return RemoteItem(path: name, name: name, isDirectory: true, size: 0, modified: epoch, created: epoch, fileID: 0)
    }

    // MARK: FileBackend

    /// At the top level, the shares this user can open; elsewhere, the folder's contents.
    public func list(_ path: String) async throws -> [RemoteItem] {
        guard !path.isEmpty else { return try await accessibleShares().map(Self.shareItem) }
        let (share, inner) = try split(path)
        let (items, abandoned) = try await guarded(share) { manager in
            var items: [RemoteItem] = []
            var abandoned: [String] = []
            for attributes in try await manager.contentsOfDirectory(atPath: inner) {
                guard let wireName = attributes[.nameKey] as? String, wireName != ".", wireName != ".." else { continue }
                let name = SMBName.local(wireName)
                if RemotePath.isInternal(name) {
                    let modified = attributes[.contentModificationDateKey] as? Date ?? .distantFuture
                    if modified < Date(timeIntervalSinceNow: -Self.abandonedUploadAge) {
                        abandoned.append(RemotePath.join(inner, wireName))
                    }
                } else if let item = RemoteItem(path: RemotePath.join(path, name), name: name, attributes: attributes) {
                    items.append(item.scoped(to: share))
                }
            }
            return (items, abandoned)
        }
        for upload in abandoned {
            try? await guarded(share) { try await $0.removeFile(atPath: upload) }
        }
        return items
    }

    /// The visible (non-`$`) shares this user can open. Shares that refuse the login are left out.
    /// If none can be opened, the first error is thrown so the cause (wrong password, unreachable) shows.
    public func accessibleShares() async throws -> [String] {
        let manager = try makeManager()
        let names = try await Watchdog.run(idleLimit: .seconds(timeout)) { try await manager.listShares().map(\.name) }
        let results = await withTaskGroup(of: (String, Error?).self) { group in
            for name in names {
                group.addTask {
                    do {
                        try await self.guarded(name) { _ = try await $0.contentsOfDirectory(atPath: "") }
                        return (name, nil)
                    } catch {
                        return (name, error)
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let open = results.filter { $0.1 == nil }.map(\.0)
        if open.isEmpty, let error = results.compactMap(\.1).first {
            throw error
        }
        return open.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func stat(_ path: String) async throws -> RemoteItem {
        let (share, inner) = try split(path)
        if inner.isEmpty {
            _ = try await guarded(share) { _ in }  // Connecting checks that the share can be opened.
            return Self.shareItem(share)
        }
        let attributes = try await guarded(share) { try await $0.attributesOfItem(atPath: inner) }
        guard let item = RemoteItem(path: path, name: RemotePath.name(of: path), attributes: attributes) else {
            throw POSIXError(.ENOENT)
        }
        return item.scoped(to: share)
    }

    /// Files this big or bigger download in parallel pieces, each over a connection of its own: one stream
    /// waits a round trip per request, several keep the network busy.
    static let parallelDownloadThreshold: Int64 = 16 << 20

    #if os(iOS) || os(visionOS)
    /// Pieces read at the same time across every download, and bytes per request: the extension has ~20 MB
    /// in all, and each request's buffer exists twice. One file alone gets every stream; two share them.
    static let streamBudget = TransferBudget(streams: 4)
    static let pieceRequest = 1 << 20
    static let streamsPerFile = 4
    #else
    static let streamBudget = TransferBudget(streams: 16)
    static let pieceRequest = 4 << 20
    static let streamsPerFile = 6
    #endif

    public func download(_ path: String, to url: URL, progress: Progress) async throws {
        let (share, inner) = try split(path)
        // Every download draws on the shared stream budget (a read-ahead can start many at once, and on iOS
        // their buffers together must fit the extension's memory); a big file uses several streams at once.
        if let size = try? await stat(path).size {
            try await downloadInPieces(share: share, inner: inner, size: size, to: url, progress: progress)
            return
        }
        let activity = Activity()
        try await transferring(share, activity: activity) {
            try await $0.downloadItem(atPath: inner, to: url) { bytes, total in
                activity.touch()
                progress.totalUnitCount = total
                progress.completedUnitCount = bytes
                return !progress.isCancelled
            }
        }
        if progress.isCancelled { throw CancellationError() }
    }

    /// Downloads a big file as several byte ranges at once, each on its own connection, as many as the
    /// stream budget allows right now (at least one; a file that waits for streams starts with what's free).
    private func downloadInPieces(share: String, inner: String, size: Int64, to url: URL, progress: Progress) async throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw POSIXError(.EIO) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        let streams = await Self.streamBudget.take(upTo: size >= Self.parallelDownloadThreshold ? Self.streamsPerFile : 1,
                                                   background: TransferPriority.isBackground)
        defer { Task { await Self.streamBudget.give(streams) } }
        progress.totalUnitCount = size
        progress.completedUnitCount = 0
        let counter = ByteCounter()
        // Pieces of at least 8 MiB, split evenly between the streams.
        let pieceSize = max(8 << 20, (size + Int64(streams) - 1) / Int64(streams))
        let pieces = size == 0 ? [] : stride(from: Int64(0), to: size, by: Int(pieceSize)).map { $0..<min($0 + pieceSize, size) }
        let request = Self.pieceRequest
        try await withThrowingTaskGroup(of: Void.self) { group in
            for piece in pieces {
                group.addTask {
                    let activity = Activity()
                    try await self.transferring(share, activity: activity) { manager in
                        try await manager.downloadRange(atPath: inner, range: piece, to: url, chunkSize: request) { bytes in
                            activity.touch()
                            progress.completedUnitCount = counter.add(bytes)
                            DownloadMemory.sample()
                            return !progress.isCancelled
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        if progress.isCancelled { throw CancellationError() }
        DownloadMemory.reportIfNewPeak()
    }

    public func upload(_ url: URL, to path: String, from offset: Int64, progress: Progress) async throws {
        let (share, inner) = try split(path)
        guard !inner.isEmpty else { throw POSIXError(.EPERM) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        progress.totalUnitCount = size
        progress.completedUnitCount = offset
        let activity = Activity()
        try await transferring(share, activity: activity) {
            try await $0.uploadItem(at: url, toPath: inner, offset: offset) { bytes in
                activity.touch()
                progress.completedUnitCount = offset + bytes
                return !progress.isCancelled
            }
        }
        if progress.isCancelled { throw CancellationError() }
    }

    public func writeRanges(_ url: URL, ranges: [Range<Int64>], to path: String, size: Int64, progress: Progress) async throws {
        let (share, inner) = try split(path)
        guard !inner.isEmpty else { throw POSIXError(.EPERM) }
        let total = ranges.reduce(Int64(0)) { $0 + Int64($1.count) }
        progress.totalUnitCount = max(total, 1)
        progress.completedUnitCount = 0
        let activity = Activity()
        try await transferring(share, activity: activity) {
            try await $0.writeRanges(from: url, ranges: ranges, toPath: inner, size: size) { bytes in
                activity.touch()
                progress.completedUnitCount = bytes
                return !progress.isCancelled
            }
        }
        if progress.isCancelled { throw CancellationError() }
    }

    public func setDates(_ path: String, modified: Date?, created: Date?) async throws {
        let (share, inner) = try split(path)
        guard !inner.isEmpty else { return }
        guard modified != nil || created != nil else { return }
        try await guarded(share) { manager in
            var attributes: [URLResourceKey: Any] = [:]
            if let modified { attributes[.contentModificationDateKey] = modified }
            if let created { attributes[.creationDateKey] = created }
            try await manager.setAttributes(attributes: attributes, ofItemAtPath: inner)
        }
    }

    public func read(_ path: String, range: Range<UInt64>) async throws -> Data {
        let (share, inner) = try split(path)
        return try await guarded(share) { try await $0.contents(atPath: inner, range: range) }
    }

    public func createDirectory(_ path: String) async throws {
        let (share, inner) = try split(path)
        guard !inner.isEmpty else { throw POSIXError(.EPERM) }  // Shares can't be created over SMB.
        try await guarded(share) { try await $0.createDirectory(atPath: inner) }
    }

    public func move(_ path: String, to destination: String, replacing: Bool) async throws {
        let (share, inner) = try split(path)
        let (destinationShare, destinationInner) = try split(destination)
        guard !inner.isEmpty, !destinationInner.isEmpty else { throw POSIXError(.EPERM) }
        // An SMB rename can't cross shares; that needs copy and delete (not supported yet).
        guard share == destinationShare else { throw POSIXError(.EXDEV) }
        try await guarded(share) { manager in
            if replacing {
                try await manager.moveItem(atPath: inner, replacingItemAtPath: destinationInner)
            } else {
                try await manager.moveItem(atPath: inner, toPath: destinationInner)
            }
        }
    }

    public func remove(_ path: String, isDirectory: Bool) async throws {
        let (share, inner) = try split(path)
        guard !inner.isEmpty else { throw POSIXError(.EPERM) }
        try await guarded(share) { manager in
            if isDirectory {
                try await manager.removeDirectory(atPath: inner, recursive: true)
            } else {
                try await manager.removeFile(atPath: inner)
            }
        }
    }
}

/// Characters a name may hold on the Mac and on the server's disk but not in an SMB path: `:` there names a
/// file's stream (so "a:b" is stream "b" of file "a"), and `\ * ? " < > |` and control characters are
/// reserved. Like macOS's own SMB client, they travel as the Services for Macintosh private-use characters
/// (U+F001…U+F027), which Samba (`fruit:encoding = native`, catia) turns back into the real characters on
/// disk. Without this, a file named with a colon uploaded but could never be renamed into place, and one
/// already on the server couldn't be downloaded.
enum SMBName {
    private static let reserved: [UInt32: UInt32] = {
        var map: [UInt32: UInt32] = [:]
        for code in UInt32(0x01)...0x1F { map[code] = 0xF000 + code }
        for (character, code) in zip("\"*:<>?\\|".unicodeScalars, UInt32(0xF020)...0xF027) { map[character.value] = code }
        return map
    }()

    private static let back: [UInt32: UInt32] = Dictionary(uniqueKeysWithValues: reserved.map { ($1, $0) })

    /// A path (or name) as it goes over SMB. Slashes stay separators.
    static func wire(_ path: String) -> String { mapped(path, reserved) }

    /// A name as listed over SMB, as the Mac and the server's disk spell it.
    static func local(_ name: String) -> String { mapped(name, back) }

    private static func mapped(_ text: String, _ map: [UInt32: UInt32]) -> String {
        guard text.unicodeScalars.contains(where: { map[$0.value] != nil }) else { return text }
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            result.append(map[scalar.value].flatMap(Unicode.Scalar.init) ?? scalar)
        }
        return String(result)
    }
}

extension RemoteItem {
    /// Index numbers are only unique within one share (one file system), so the top 16 bits are
    /// replaced by a hash of the share name. Inode numbers fit comfortably in the lower 48 bits.
    func scoped(to share: String) -> RemoteItem {
        guard fileID != 0 else { return self }
        var hash: UInt32 = 2_166_136_261  // FNV-1a
        for byte in share.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        var item = self
        item.fileID = (fileID & 0x0000_FFFF_FFFF_FFFF) | (UInt64(hash & 0xFFFF) << 48)
        return item
    }

    /// Builds an item from AMSMB2's attribute dictionary. Symbolic links are skipped.
    init?(path: String, name: String, attributes: [URLResourceKey: Any]) {
        if (attributes[.isSymbolicLinkKey] as? NSNumber)?.boolValue == true { return nil }
        self.init(
            path: path,
            name: name,
            isDirectory: (attributes[.isDirectoryKey] as? NSNumber)?.boolValue ?? false,
            size: (attributes[.fileSizeKey] as? NSNumber)?.int64Value ?? 0,
            modified: attributes[.contentModificationDateKey] as? Date ?? .distantPast,
            created: attributes[.creationDateKey] as? Date ?? .distantPast,
            fileID: (attributes[.documentIdentifierKey] as? NSNumber)?.uint64Value ?? 0
        )
    }
}

/// Streams shared by all parallel downloads, so their buffers together stay inside the memory the process has.
public actor TransferBudget {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(streams: Int) {
        free = streams
    }

    /// Takes at least one stream (waiting for one if none is free) and up to `limit` if they're free. A
    /// background download (fetched ahead, nobody waiting for it yet) takes one stream at most, and only
    /// while another stays free, so a file an app is waiting for never queues behind files fetched ahead.
    public func take(upTo limit: Int, background: Bool = false) async -> Int {
        while background ? free < 2 : free == 0 {
            await withCheckedContinuation { waiting.append($0) }
        }
        let taken = background ? 1 : min(free, max(limit, 1))
        free -= taken
        return taken
    }

    public func give(_ count: Int) {
        free += count
        let woken = waiting
        waiting = []
        woken.forEach { $0.resume() }
    }
}

/// Bytes done across a download's pieces.
final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    func add(_ bytes: Int64) -> Int64 { lock.withLock { total += bytes; return total } }
}

/// Whether the download running in this task is a background one (see `TransferBudget`).
public enum TransferPriority {
    @TaskLocal public static var isBackground = false
}

/// The highest memory footprint seen while downloads ran in this process, noted in the diagnostic log when it
/// rises, so the stream budget can be sized from real numbers (iOS ends the extension at ~20 MB).
enum DownloadMemory {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var peak: UInt64 = 0
    nonisolated(unsafe) private static var reported: UInt64 = 0

    static func sample() {
        let now = MemoryMeter.footprint()
        lock.withLock { peak = max(peak, now) }
    }

    static func reportIfNewPeak() {
        let rise: UInt64? = lock.withLock {
            guard peak > reported + (512 << 10) else { return nil }
            reported = peak
            return peak
        }
        if let rise {
            DiagnosticLog.note("Download memory peak: \(String(format: "%.1f", Double(rise) / 1_048_576)) MB")
        }
    }
}
