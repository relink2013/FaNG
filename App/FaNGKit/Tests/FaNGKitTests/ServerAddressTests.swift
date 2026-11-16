import Foundation
import Testing
@testable import FaNGKit

struct ServerAddressTests {
    private func account(smb: String? = nil, url: String? = nil) -> ServerAccount {
        var account = ServerAccount(displayName: "Test", host: "192.0.2.10", username: "tester", encrypted: true)
        account.fang = FangServer(port: 443, fingerprint: "ab", url: url, smb: smb)
        return account
    }

    @Test func readsWhatAnOlderServerPublishes() throws {
        let server = try JSONDecoder().decode(FangServer.self, from: Data(#"{"fingerprint":"ab","port":443}"#.utf8))
        #expect(server == FangServer(port: 443, fingerprint: "ab"))
    }

    @Test func readsTheAddressesANewerServerPublishes() throws {
        let json = #"{"fingerprint":"ab","port":443,"smb":"192.0.2.10","url":"https://files.example.com"}"#
        let server = try JSONDecoder().decode(FangServer.self, from: Data(json.utf8))
        #expect(server.url == "https://files.example.com")
        #expect(server.smb == "192.0.2.10")
    }

    @Test func anAccountSavedBeforeAddressesExistedStillLoads() throws {
        let saved = #"{"id":"6F0C1D4E-1111-4222-8333-444455556666","displayName":"Test","host":"192.0.2.10","port":445,"username":"tester","encrypted":true,"fang":{"port":443,"fingerprint":"ab"}}"#
        let account = try JSONDecoder().decode(ServerAccount.self, from: Data(saved.utf8))
        #expect(account.fang?.url == nil)
        #expect(account.advertisedSMBURL == nil)
    }

    @Test func theServersSMBAddressAsAURL() {
        #expect(account(smb: "files.example.com").advertisedSMBURL?.absoluteString == "smb://files.example.com")
        #expect(account(smb: "files.example.com:445").advertisedSMBURL?.absoluteString == "smb://files.example.com")
        #expect(account(smb: "192.0.2.99:4450").advertisedSMBURL?.absoluteString == "smb://192.0.2.99:4450")
        #expect(account(smb: "[2001:db8::1]").advertisedSMBURL?.host() == "2001:db8::1")
        #expect(account(smb: "").advertisedSMBURL == nil)
        #expect(account().advertisedSMBURL == nil)
    }

    @Test func takesInWhatTheServerSays() {
        var account = account()
        let changed1 = account.take(FangAPI.ServerInfo(version: "1", url: "https://files.example.com", smb: ""))
        #expect(changed1)
        #expect(account.fang?.url == "https://files.example.com")
        #expect(account.fang?.smb == nil)
        // Nothing new: nothing to save.
        let changed2 = account.take(FangAPI.ServerInfo(version: "1", url: "https://files.example.com", smb: nil))
        #expect(!changed2)
        // Taken away on the server: gone here too, and the pinned address is what's left.
        let changed3 = account.take(FangAPI.ServerInfo(version: "1", url: nil, smb: nil))
        #expect(changed3)
        #expect(account.fang == FangServer(port: 443, fingerprint: "ab"))
    }

    @Test func plainSMBAccountsTakeNothing() {
        var account = ServerAccount(displayName: "Test", host: "192.0.2.10", username: "tester", encrypted: true)
        let changed4 = account.take(FangAPI.ServerInfo(version: "1", url: "https://files.example.com", smb: nil))
        #expect(!changed4)
        #expect(account.fang == nil)
    }
}
