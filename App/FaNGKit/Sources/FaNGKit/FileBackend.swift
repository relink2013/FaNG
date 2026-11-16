import Foundation

/// A file or folder on the server, as the backend reports it.
public struct RemoteItem: Hashable, Sendable {
    /// Path relative to the share root, without a leading slash. The root is "".
    public var path: String
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
    public var created: Date
    /// The server's file index number (the inode on Samba), or 0 if the server doesn't give one.
    public var fileID: UInt64

    public init(path: String, name: String, isDirectory: Bool, size: Int64, modified: Date, created: Date, fileID: UInt64) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.created = created
        self.fileID = fileID
    }
}

/// What the File Provider extension needs from a server. SMB is the first backend; a FaNG server
/// backend and a photo-library backend (such as Immich) come later.
///
/// Errors are `POSIXError`s where the cause is known (`ENOENT`, `EEXIST`, `ETIMEDOUT`, …), so callers
/// can map them to File Provider errors without knowing the backend.
public protocol FileBackend: Sendable {
    func list(_ path: String) async throws -> [RemoteItem]
    func stat(_ path: String) async throws -> RemoteItem
    /// Streams the file to `url`, reporting into and honoring cancellation of `progress`.
    func download(_ path: String, to url: URL, progress: Progress) async throws
    /// Streams the local file at `url` to `path`, starting at `offset` in both files, and flushes it to the
    /// server's disk. With an offset of 0 the file must not exist (`EEXIST`); otherwise it must, and it's
    /// truncated to `offset` first, which resumes an interrupted upload.
    func upload(_ url: URL, to path: String, from offset: Int64, progress: Progress) async throws
    func read(_ path: String, range: Range<UInt64>) async throws -> Data
    func createDirectory(_ path: String) async throws
    /// Fails with `EEXIST` if the destination exists, unless `replacing`: then the destination is replaced
    /// in one step, so the path never goes missing.
    func move(_ path: String, to destination: String, replacing: Bool) async throws
    func remove(_ path: String, isDirectory: Bool) async throws
    /// Writes these byte ranges of the local file at `url` into the existing file at `path`, at the same
    /// offsets, sets its length to `size` and flushes it (a delta upload into a clone of the old contents).
    func writeRanges(_ url: URL, ranges: [Range<Int64>], to path: String, size: Int64, progress: Progress) async throws
    /// Sets the file's modification and creation dates (nil leaves one as it is).
    func setDates(_ path: String, modified: Date?, created: Date?) async throws
}

extension FileBackend {
    public func writeRanges(_ url: URL, ranges: [Range<Int64>], to path: String, size: Int64, progress: Progress) async throws {
        throw POSIXError(.ENOTSUP)
    }

    public func setDates(_ path: String, modified: Date?, created: Date?) async throws {}
}

public enum RemotePath {
    public static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    public static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Prefix of in-progress uploads. They are hidden from listings and renamed into place when complete.
    /// The rest of the name identifies the upload, so a retry finds and resumes it.
    public static let uploadPrefix = ".fang-upload-"

    public static func isInternal(_ name: String) -> Bool {
        name.hasPrefix(uploadPrefix)
    }
}
