import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Talks to fang-storaged's local socket (see its `Control`).
struct Storaged: Sendable {
    var socketPath: String

    /// Has fang-storaged look at `path` in `share` now and returns the entry's ID, or nil if there's none.
    func resolve(share: String, path: String) async throws -> UUID? {
        let reply = try await request("RESOLVE\t\(share)\t\(path)\n")
        guard reply.hasPrefix("OK\t") else {
            if reply == "NONE" { return nil }
            throw StoragedError()
        }
        return UUID(uuidString: String(reply.dropFirst(3)))
    }

    /// Puts an upload in place of an item. Returns the item's ID, whether the edit conflicted, and whether it
    /// became the file.
    func commit(share: String, id: UUID, temp: String, base: Int64, modifiedNS: Int64, device: String, path: String?) async throws -> (id: UUID, conflict: Bool, editWon: Bool) {
        let fields = try await answer("COMMIT\t\(share)\t\(id.uuidString.lowercased())\t\(temp)\t\(base)\t\(modifiedNS)\t\(device)\(path.map { "\t" + $0 } ?? "")\n")
        guard fields.count == 4, let committed = UUID(uuidString: fields[1]) else { throw StoragedError(reason: "bad answer") }
        return (committed, fields[2] == "1", fields[3] == "1")
    }

    /// Runs an item command and returns the item's ID: TAGS <json>, SETTLE <action> [<version>].
    func itemCommand(_ command: String, _ id: UUID, _ arguments: [String]) async throws -> UUID {
        let line = ([command, id.uuidString.lowercased()] + arguments).joined(separator: "\t")
        let fields = try await answer(line + "\n")
        guard fields.count == 2, let result = UUID(uuidString: fields[1]) else { throw StoragedError(reason: "bad answer") }
        return result
    }

    func restore(version: Int64) async throws -> UUID {
        let fields = try await answer("RESTORE\t\(version)\n")
        guard fields.count == 2, let id = UUID(uuidString: fields[1]) else { throw StoragedError(reason: "bad answer") }
        return id
    }

    /// Runs a trash command (TRASH, UNTRASH, PURGE) and returns the item's ID.
    func trashCommand(_ command: String, _ id: UUID, parent: UUID? = nil) async throws -> UUID {
        var line = "\(command)\t\(id.uuidString.lowercased())"
        if let parent { line += "\t\(parent.uuidString.lowercased())" }
        // A folder with tens of thousands of entries takes a while to record or delete; answering "failed"
        // for one that then succeeds would be worse than waiting.
        let fields = try await answer(line + "\n", timeout: 120)
        guard fields.count == 2, let result = UUID(uuidString: fields[1]) else { throw StoragedError(reason: "bad answer") }
        return result
    }

    /// Copies (COPY) or moves (MOVE) an item into a folder, as `name` if given. Returns the ID of the copy,
    /// or of the moved item. A copy between filesystems moves every byte, so this may take a while.
    func transfer(_ command: String, _ id: UUID, into parent: UUID, name: String?) async throws -> UUID {
        var line = "\(command)\t\(id.uuidString.lowercased())\t\(parent.uuidString.lowercased())"
        if let name { line += "\t\(name)" }
        let fields = try await answer(line + "\n", timeout: 3600)
        guard fields.count == 2, let result = UUID(uuidString: fields[1]) else { throw StoragedError(reason: "bad answer") }
        return result
    }

    /// The SHA-256 of each block of a file in a share (see `BlockHashes`), read by fang-storaged.
    func blocks(share: String, path: String) async throws -> (size: Int64, blockSize: Int, hashes: Data) {
        // A 20 GB file is read whole: minutes on a busy pool.
        let reply = try await request("BLOCKS\t\(share)\t\(path)\n", timeout: 900, limit: 64 << 20)
        let fields = reply.trimmingCharacters(in: .newlines).split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 4, fields[0] == "OK", let size = Int64(fields[1]), let blockSize = Int(fields[2]),
              let hashes = Data(base64Encoded: String(fields[3]))
        else { throw StoragedError(reason: fields.count >= 2 && fields[0] == "ERROR" ? String(fields[1]) : "bad answer") }
        return (size, blockSize, hashes)
    }

    /// The copies running now, as fang-storaged reports them (JSON array).
    func jobs() async throws -> Data {
        let reply = try await request("JOBS\n", limit: 1 << 20)
        guard reply.hasPrefix("OK\t") else { throw StoragedError(reason: "bad answer") }
        return Data(reply.dropFirst(3).utf8)
    }

    /// An admin command (fields joined by tabs); returns its JSON answer.
    func admin(_ fields: [String], timeout: Int = 60) async throws -> Data {
        let reply = try await request(fields.joined(separator: "\t") + "\n", timeout: timeout, limit: 32 << 20)
        guard reply.hasPrefix("OK\t") else {
            throw StoragedError(reason: reply.hasPrefix("ERROR\t") ? String(reply.dropFirst(6)) : "unreachable")
        }
        return Data(reply.dropFirst(3).utf8)
    }

    struct StoragedError: Error {
        var reason = "unreachable"
    }

    /// The answer's fields, or the reason it failed.
    private func answer(_ line: String, timeout: Int = 15) async throws -> [String] {
        let fields = try await request(line, timeout: timeout).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.first == "OK" else { throw StoragedError(reason: fields.dropFirst().first ?? "failed") }
        return fields
    }

    private func request(_ line: String, timeout seconds: Int = 15, limit: Int = 4096) async throws -> String {
        let socketPath = socketPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                #if canImport(Glibc)
                let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
                guard fd >= 0 else { return continuation.resume(throwing: StoragedError()) }
                defer { close(fd) }
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                    _ = socketPath.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count - 1))) }
                }
                var timeout = timeval(tv_sec: seconds, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                guard connected == 0 else { return continuation.resume(throwing: StoragedError()) }
                _ = line.utf8CString.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count - 1) }
                // The answer is one line; read in chunks (an admin listing can be megabytes).
                var data = [UInt8]()
                var chunk = [UInt8](repeating: 0, count: 65536)
                while data.count < limit {
                    let count = read(fd, &chunk, chunk.count)
                    if count <= 0 { break }
                    if let newline = chunk[0..<count].firstIndex(of: 10) {
                        data += chunk[0..<newline]
                        break
                    }
                    data += chunk[0..<count]
                }
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
                #else
                continuation.resume(throwing: StoragedError())
                #endif
            }
        }
    }
}
