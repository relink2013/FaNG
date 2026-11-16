import Testing
@testable import FaNGCore

struct ShareTests {
    @Test func parsesSharesFile() throws {
        let shares = try Share.parse("""
            # name | path | create mask | directory mask
            Test | /shares/Test | 0664 | 0775

            Other|/shares/Other|0640|0750
            """)
        #expect(shares == [
            Share(name: "Test", path: "/shares/Test", createMask: 0o664, directoryMask: 0o775),
            Share(name: "Other", path: "/shares/Other", createMask: 0o640, directoryMask: 0o750),
        ])
    }

    @Test func rejectsBadLines() {
        #expect(throws: Share.ParseError.self) { try Share.parse("Test|relative/path|0664|0775") }
        #expect(throws: Share.ParseError.self) { try Share.parse("Test|/shares/Test|0664") }
        #expect(throws: Share.ParseError.self) { try Share.parse("Test|/shares/Test|0999|0775") }
    }
}
