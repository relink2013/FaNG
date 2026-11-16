#if os(Linux)
import CLinuxFS
import Foundation
import Glibc

/// The filesystem side of fang-storaged: entries, their FaNG IDs (`user.fang.id`), and listings.
enum Disk {
    static let idAttribute = "user.fang.id"

    struct Entry {
        var isDirectory: Bool
        var size: Int64
        var mtimeNS: Int64
        var inode: Int64
    }

    /// The entry at `path`, or nil if there's none or it isn't a regular file or folder (symbolic links
    /// and special files aren't served).
    static func entry(_ path: String) -> Entry? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        guard type == S_IFREG || type == S_IFDIR else { return nil }
        return Entry(
            isDirectory: type == S_IFDIR,
            size: Int64(st.st_size),
            mtimeNS: Int64(st.st_mtim.tv_sec) * 1_000_000_000 + Int64(st.st_mtim.tv_nsec),
            inode: Int64(bitPattern: UInt64(st.st_ino))
        )
    }

    /// True if anything at all is at `path`, a symbolic link included.
    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    static func readID(_ path: String) -> UUID? {
        var buffer = [CChar](repeating: 0, count: 64)
        let length = fang_lgetxattr(path, idAttribute, &buffer, buffer.count - 1)
        guard length > 0 else { return nil }
        return UUID(uuidString: String(cString: buffer))
    }

    /// Writes the ID xattr. It changes neither the contents nor the modification time.
    static func writeID(_ id: UUID, to path: String) -> Bool {
        let value = id.uuidString.lowercased()
        return fang_lsetxattr(path, idAttribute, value, value.utf8.count) == 0
    }

    /// Finder tags as Samba stores them: the "com.apple.metadata:_kMDItemUserTags" stream (a binary
    /// property list of "name\ncolor" strings) in an xattr, with the trailing NUL `streams_xattr` adds.
    static let tagsAttribute = "user.DosStream.com.apple.metadata:_kMDItemUserTags:$DATA"
    static let conflictTag = "[CONFLICT]\n6"

    static func readTags(_ path: String) -> [String] {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let length = fang_lgetxattr(path, tagsAttribute, &buffer, buffer.count)
        guard length > 0 else { return [] }
        var data = Data(buffer[0..<length])
        if data.last == 0 { data.removeLast() }
        return (try? PropertyListDecoder().decode([String].self, from: data)) ?? []
    }

    static func writeTags(_ tags: [String], to path: String) throws {
        if tags.isEmpty {
            _ = fang_lremovexattr(path, tagsAttribute)
            return
        }
        // PropertyListEncoder, not PropertyListSerialization: on Linux the latter can't take Swift arrays.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        var data = try encoder.encode(tags)
        data.append(0)
        let result = data.withUnsafeBytes { fang_lsetxattr(path, tagsAttribute, $0.baseAddress, data.count) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Client metadata Samba keeps as named streams (one xattr each, "user.DosStream.<name>:$DATA", with a
    /// trailing NUL): what a Mac writes with xattrs over SMB, and what File Provider syncs as an item's
    /// extended attributes (folder symbols and emoji, "Where from", …). Tags, Finder info, resource forks and
    /// what File Provider covers elsewhere are left out.
    static let streamPrefix = "user.DosStream.", streamSuffix = ":$DATA"
    static let unsyncedStreams: Set<String> = [
        "com.apple.metadata:_kMDItemUserTags", "AFP_AfpInfo", "AFP_Resource", "com.apple.FinderInfo",
        "com.apple.ResourceFork", "com.apple.quarantine", "com.apple.lastuseddate#PS",
    ]
    /// File Provider caps an item's synced attributes at about 32 KiB.
    static let metadataLimit = 32 * 1024

    static func readMetadata(_ path: String) -> [String: Data] {
        var names = [CChar](repeating: 0, count: 64 * 1024)
        let length = fang_llistxattr(path, &names, names.count)
        guard length > 0 else { return [:] }
        var result: [String: Data] = [:], total = 0
        var start = 0
        var value = [UInt8](repeating: 0, count: 64 * 1024)
        for index in 0..<length where names[index] == 0 {
            let full = names[start..<index].withUnsafeBufferPointer { String(decoding: UnsafeRawBufferPointer($0), as: UTF8.self) }
            start = index + 1
            guard full.hasPrefix(streamPrefix), full.hasSuffix(streamSuffix) else { continue }
            let name = String(full.dropFirst(streamPrefix.count).dropLast(streamSuffix.count))
            guard !name.isEmpty, !unsyncedStreams.contains(name) else { continue }
            let size = fang_lgetxattr(path, full, &value, value.count)
            guard size >= 0 else { continue }
            var data = Data(value[0..<size])
            if data.last == 0 { data.removeLast() }
            total += data.count + name.utf8.count
            guard total <= metadataLimit else { break }
            result[name] = data
        }
        return result
    }

    /// Makes the entry's client metadata `metadata` (names not in it are removed; tags and the rest are kept).
    static func writeMetadata(_ metadata: [String: Data], to path: String) throws {
        for name in readMetadata(path).keys where metadata[name] == nil {
            _ = fang_lremovexattr(path, streamPrefix + name + streamSuffix)
        }
        for (name, value) in metadata where !unsyncedStreams.contains(name) && !name.contains("/") && !name.isEmpty {
            var data = value
            data.append(0)
            let result = data.withUnsafeBytes { fang_lsetxattr(path, streamPrefix + name + streamSuffix, $0.baseAddress, data.count) }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }

    /// Writes the ID xattr only if the entry has none yet (false if it has one, or the write failed).
    static func writeNewID(_ id: UUID, to path: String) -> Bool {
        let value = id.uuidString.lowercased()
        return fang_lsetxattr_create(path, idAttribute, value, value.utf8.count) == 0
    }

    static func removeID(from path: String) {
        _ = fang_lremovexattr(path, idAttribute)
    }

    /// Gives `to` the owner and mode of `from`, so new contents never change a file's permissions.
    static func copyOwnership(from: String, to: String) throws {
        var st = stat()
        guard lstat(from, &st) == 0, lchown(to, st.st_uid, st.st_gid) == 0, chmod(to, st.st_mode & 0o7777) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Creates `path` and any missing parents, as the host's owner (99:100) with `mode`.
    static func makeFolders(_ path: String, mode: mode_t) throws {
        var built = ""
        for component in path.split(separator: "/") {
            built += "/" + component
            if mkdir(built, mode) == 0 {
                chown(built, 99, 100)
                chmod(built, mode)
            } else if errno != EEXIST {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// Entry names in a folder, without "." and "..".
    static func names(in path: String) -> [String] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        return names
    }
}
#endif
