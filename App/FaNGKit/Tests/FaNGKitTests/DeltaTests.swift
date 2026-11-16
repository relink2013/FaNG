import CryptoKit
import Foundation
import Testing
@testable import FaNGKit

/// Delta uploads send only the blocks whose hash differs from the server's copy.
struct DeltaTests {
    private func blocks(of data: Data, blockSize: Int) throws -> FangAPI.Blocks {
        var hashes = Data()
        var offset = 0
        while offset < data.count {
            hashes.append(contentsOf: SHA256.hash(data: data[offset..<min(offset + blockSize, data.count)]))
            offset += blockSize
        }
        let item = try JSONDecoder().decode(FangItem.self, from: Data("""
            {"id":"8C3A6E75-4476-401D-B333-8BD4C777AE10","share":"S","name":"f","path":"f","isDirectory":false,"size":\(data.count),
             "mtimeNS":0,"inode":1,"contentVersion":1,"metadataVersion":1,"deleted":false,"seq":1}
            """.utf8))
        return FangAPI.Blocks(item: item, size: Int64(data.count), blockSize: blockSize, hashes: hashes)
    }

    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "delta-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    @Test func onlyChangedBlocksAreSent() throws {
        let old = Data((0..<(10 << 10)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var new = old
        new[5000] ^= 0xFF  // In block 4 (1 KiB blocks).
        new[5001] ^= 0xFF
        let url = try file(new)
        defer { try? FileManager.default.removeItem(at: url) }
        let ranges = try DomainConnection.changedRanges(of: url, size: Int64(new.count), against: blocks(of: old, blockSize: 1024))
        #expect(ranges == [4096..<5120])
    }

    @Test func growthAndAdjacentChangesMerge() throws {
        let old = Data(repeating: 7, count: 4096)
        var new = old + Data(repeating: 9, count: 1500)  // Grew by a block and a half.
        new[3000] = 1  // Block 2 changed; 3 is unchanged; 4 and 5 are new.
        let url = try file(new)
        defer { try? FileManager.default.removeItem(at: url) }
        let ranges = try DomainConnection.changedRanges(of: url, size: Int64(new.count), against: blocks(of: old, blockSize: 1024))
        #expect(ranges == [2048..<3072, 4096..<5596])
    }

    @Test func shrunkFileSendsOnlyTheShortLastBlock() throws {
        let old = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
        let new = old.prefix(3000)  // The last block is now shorter: its hash can't match.
        let url = try file(Data(new))
        defer { try? FileManager.default.removeItem(at: url) }
        let ranges = try DomainConnection.changedRanges(of: url, size: 3000, against: blocks(of: old, blockSize: 1024))
        #expect(ranges == [2048..<3000])
    }
}
