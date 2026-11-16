import Foundation
import Testing
@testable import FaNGCore

struct ServerAddressTests {
    @Test func nothingSetIsValid() throws {
        #expect(try ServerAddress().validated() == ServerAddress())
        #expect(try ServerAddress(url: "  ", smb: "", proxies: [" "]).validated() == ServerAddress())
    }

    @Test func tidiesThePublicAddress() throws {
        #expect(try ServerAddress(url: "https://Files.Example.com/").validated().url == "https://files.example.com")
        #expect(try ServerAddress(url: "https://files.example.com:443").validated().url == "https://files.example.com")
        #expect(try ServerAddress(url: "https://files.example.com:8443").validated().url == "https://files.example.com:8443")
        #expect(ServerAddress(url: "https://Files.Example.com:8443").host == "files.example.com")
    }

    @Test func refusesAddressesThatArentPlainHTTPSNames() {
        for bad in ["http://files.example.com", "files.example.com", "https://files.example.com/path",
                    "https://user:pw@files.example.com", "https://files.example.com?x=1", "https://"] {
            #expect(throws: ServerAddress.Invalid.self) { try ServerAddress(url: bad).validated() }
        }
    }

    @Test func checksSMBAndProxies() throws {
        let address = try ServerAddress(smb: "Files.Example.com:4450", proxies: ["192.0.2.5", " 2001:DB8::1 "]).validated()
        #expect(address.smb == "files.example.com:4450")
        #expect(address.proxies == ["192.0.2.5", "2001:db8::1"])
        #expect(throws: ServerAddress.Invalid.self) { try ServerAddress(smb: "smb://files").validated() }
        #expect(throws: ServerAddress.Invalid.self) { try ServerAddress(proxies: ["proxy.example.com"]).validated() }
    }

    @Test func believesForwardedAddressesOnlyFromProxies() {
        let address = ServerAddress(proxies: ["192.0.2.5"])
        #expect(address.clientAddress(remote: "192.0.2.5", forwardedFor: "203.0.113.9") == "203.0.113.9")
        // A client can put anything in front; the last address the proxy added counts.
        #expect(address.clientAddress(remote: "192.0.2.5", forwardedFor: "10.0.0.1, 203.0.113.9") == "203.0.113.9")
        #expect(address.clientAddress(remote: "192.0.2.5", forwardedFor: "203.0.113.9, 192.0.2.5") == "203.0.113.9")
        #expect(address.clientAddress(remote: "192.0.2.5", forwardedFor: nil) == "192.0.2.5")
        // Not from a proxy: the header is ignored.
        #expect(address.clientAddress(remote: "198.51.100.7", forwardedFor: "203.0.113.9") == "198.51.100.7")
        #expect(ServerAddress().clientAddress(remote: "198.51.100.7", forwardedFor: "203.0.113.9") == "198.51.100.7")
    }

    @Test func readsSettingsSavedWithoutProxies() throws {
        let address = try JSONDecoder().decode(ServerAddress.self, from: Data(#"{"url":"https://files.example.com"}"#.utf8))
        #expect(address == ServerAddress(url: "https://files.example.com"))
    }
}
