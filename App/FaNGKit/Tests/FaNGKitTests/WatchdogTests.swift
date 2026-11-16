import Foundation
import Testing
@testable import FaNGKit

struct WatchdogTests {
    @Test func returnsTheResult() async throws {
        let value = try await Watchdog.run(idleLimit: .seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func failsAStalledOperation() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: POSIXError(.ETIMEDOUT)) {
            try await Watchdog.run(idleLimit: .milliseconds(300)) {
                // Like a libsmb2 call that never answers and ignores cancellation.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        }
        #expect(clock.now - start < .seconds(3))
    }

    @Test func progressKeepsATransferAlive() async throws {
        let activity = Activity()
        let value = try await Watchdog.run(idleLimit: .milliseconds(400), activity: activity) {
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(150))
                activity.touch()
            }
            return "done"
        }
        #expect(value == "done")
    }

    @Test func cancellationEndsTheWaitRightAway() async throws {
        let task = Task {
            try await Watchdog.run(idleLimit: .seconds(60)) {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
