import CryptoKit
import Foundation
import Testing
@testable import FaNGKit

/// Comparing a local file with the server's block hashes must not hold the file in memory: iOS ends a File
/// Provider extension at about 20 MB, and a 268 MB file once took the extension down on every attempt.
@Suite(.serialized) struct DeltaMemoryTests {
    private func file(megabytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "fang-delta-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let block = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        for _ in 0..<megabytes { try handle.write(contentsOf: block) }
        try handle.close()
        return url
    }

    private func blocks(of url: URL, megabytes: Int) throws -> FangAPI.Blocks {
        let block = try Data(contentsOf: url).prefix(1 << 20)
        let digest = Data(SHA256.hash(data: block))
        var hashes = Data()
        for _ in 0..<megabytes { hashes.append(digest) }
        let item = try JSONDecoder().decode(FangItem.self, from: Data(Self.item.utf8))
        return FangAPI.Blocks(item: item, size: Int64(megabytes) << 20, blockSize: 1 << 20, hashes: hashes)
    }

    private static let item = #"{"id":"6F0C1D4E-1111-4222-8333-444455556666","share":"S","name":"f","path":"f","isDirectory":false,"size":0,"mtimeNS":0,"inode":1,"seq":1,"contentVersion":1,"metadataVersion":1,"deleted":false}"#

    @Test func comparingABigFileStaysSmall() throws {
        let megabytes = 192
        let url = try file(megabytes: megabytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let blocks = try blocks(of: url, megabytes: megabytes)
        let before = MemoryMeter.footprint()
        let ranges = try DomainConnection.changedRanges(of: url, size: Int64(megabytes) << 20, against: blocks)
        let grown = Int64(MemoryMeter.footprint()) - Int64(before)
        #expect(ranges.isEmpty)
        #expect(grown < 12 << 20, "grew by \(grown >> 20) MB")
    }
}
