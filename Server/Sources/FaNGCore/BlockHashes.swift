import Crypto
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// SHA-256 of each block of a file, read with several threads, for delta uploads and downloads: a client
/// compares them with its own copy and moves only the blocks that differ. 1 MiB blocks, 4 MiB above 4 GiB (so
/// a 20 GB file has about 5,000). Computed by fang-storaged, which can read every file; the API, which runs
/// unprivileged, asks it (most files on a real server aren't readable by everyone).
public enum BlockHashes {
    static let threads = Resources.workers(cpuShare: 0.25, memoryPerWorker: 16 << 20, limit: 8, setting: "FANG_HASH_THREADS")

    public static func blockSize(for size: Int64) -> Int { size > 4 << 30 ? 4 << 20 : 1 << 20 }

    /// The file's size, the block size, and the hashes (32 bytes each, in order).
    public static func of(_ path: String) async throws -> (Int64, Int, Data) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try compute(path) })
            }
        }
    }

    private final class Output: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        private let lock = NSLock()
        private(set) var failed: Int32 = 0
        init(count: Int) { pointer = .allocate(byteCount: max(count, 1), alignment: 8) }
        deinit { pointer.deallocate() }
        func fail(_ code: Int32) { lock.withLock { if failed == 0 { failed = code } } }
        var hasFailed: Bool { lock.withLock { failed != 0 } }
    }

    static func compute(_ path: String) throws -> (Int64, Int, Data) {
        #if canImport(Glibc)
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let size = Int64(st.st_size), block = blockSize(for: size)
        let count = Int((size + Int64(block) - 1) / Int64(block))
        let output = Output(count: count * 32)
        let workers = min(threads, max(count, 1))
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var buffer = [UInt8](repeating: 0, count: block)
            var index = worker
            while index < count, !output.hasFailed {
                let offset = Int64(index) * Int64(block)
                let length = Int(min(Int64(block), size - offset))
                var done = 0
                while done < length {
                    let read = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, length - done, off_t(offset) + off_t(done)) }
                    if read <= 0 {
                        output.fail(read == 0 ? EIO : errno)
                        return
                    }
                    done += read
                }
                let digest = SHA256.hash(data: buffer[0..<length])
                digest.withUnsafeBytes { bytes in
                    (output.pointer + index * 32).copyMemory(from: bytes.baseAddress!, byteCount: 32)
                }
                index += workers
            }
        }
        if output.failed != 0 { throw POSIXError(POSIXErrorCode(rawValue: output.failed) ?? .EIO) }
        return (size, block, Data(bytes: output.pointer, count: count * 32))
        #else
        throw POSIXError(.ENOSYS)
        #endif
    }
}
