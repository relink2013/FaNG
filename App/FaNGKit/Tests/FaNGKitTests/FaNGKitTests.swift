import Testing
@testable import FaNGKit

struct FaNGKitTests {
    @Test func appGroupIdentifierMatchesEntitlements() {
        #expect(FaNGKit.appGroupIdentifier == "group.com.rlx.fang")
    }
}
