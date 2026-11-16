import Foundation
import Testing
@testable import FaNGKit

/// Against an address nothing listens on: every kind of call has to fail, promptly, instead of waiting on
/// anything of its own (a lock taken twice once froze every metadata call).
struct SMBBackendTests {
    private func backend(smb: String? = nil) throws -> SMBBackend {
        var account = ServerAccount(displayName: "Test", host: "127.0.0.1", port: 9, username: "tester", encrypted: false)
        if let smb { account.fang = FangServer(port: 443, fingerprint: "ab", smb: smb) }
        return try SMBBackend(account: account, password: "x", timeout: 5)
    }

    @Test(.timeLimit(.minutes(1))) func metadataCallsFailInsteadOfHanging() async throws {
        let backend = try backend()
        await #expect(throws: (any Error).self) { _ = try await backend.stat("Share/file") }
        // And again: the first failure must leave nothing locked.
        await #expect(throws: (any Error).self) { try await backend.remove("Share/file", isDirectory: false) }
    }

    @Test(.timeLimit(.minutes(1))) func metadataCallsFailWithASecondAddressToo() async throws {
        let backend = try backend(smb: "127.0.0.1:10")
        await #expect(throws: (any Error).self) { _ = try await backend.stat("Share/file") }
        await #expect(throws: (any Error).self) { _ = try await backend.stat("Share/file") }
    }

    @Test(.timeLimit(.minutes(1))) func transfersFailInsteadOfHanging() async throws {
        let backend = try backend(smb: "127.0.0.1:10")
        let file = FileManager.default.temporaryDirectory.appending(path: "fang-test-\(UUID().uuidString)")
        try Data(repeating: 1, count: 16).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: (any Error).self) { try await backend.upload(file, to: "Share/file", from: 0, progress: Progress()) }
    }
}

/// Names with characters SMB reserves travel as the private-use characters Samba maps back on disk.
struct SMBNameTests {
    @Test func reservedCharactersTravelAsPrivateUseCharacters() {
        #expect(SMBName.wire("Downloads/a.json:Zone.Identifier") == "Downloads/a.json\u{F022}Zone.Identifier")
        #expect(SMBName.wire("x\"*<>?\\|y") == "x\u{F020}\u{F021}\u{F023}\u{F024}\u{F025}\u{F026}\u{F027}y")
        #expect(SMBName.wire("tab\there") == "tab\u{F009}here")
    }

    @Test func plainNamesAndSeparatorsAreUntouched() {
        #expect(SMBName.wire("Folder/Café é.txt") == "Folder/Café é.txt")
        #expect(SMBName.local("Café.txt") == "Café.txt")
    }

    @Test func listedNamesComeBackAsWritten() {
        let name = "a:b*c?\"d<e>f|g\\h\u{01}"
        #expect(SMBName.local(SMBName.wire(name)) == name)
        // A colon followed by a combining mark is still mapped (scalars, not characters).
        #expect(SMBName.wire(":\u{301}") == "\u{F022}\u{301}")
    }
}
