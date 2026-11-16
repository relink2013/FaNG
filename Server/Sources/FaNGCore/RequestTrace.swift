import Foundation

/// What a control request is doing right now, so one that hangs can be found: the code it runs marks its
/// steps (`RequestTrace.step("…")`), and a monitor logs requests that run long, with their last step.
/// Steps name code, never paths.
public final class RequestTrace: @unchecked Sendable {
    public let command: String
    public let started = Date()
    private let lock = NSLock()
    private var current = "start"
    private var changed = Date()
    /// Probes run once for this request (see the control monitor).
    public var probed = false

    @TaskLocal public static var active: RequestTrace?

    public init(command: String) {
        self.command = command
    }

    public var step: String {
        lock.withLock { current }
    }

    /// Seconds since the request last reached a new step.
    public var idle: TimeInterval {
        lock.withLock { Date().timeIntervalSince(changed) }
    }

    /// Marks the step the current request (if any) has reached.
    public static func step(_ name: String) {
        active?.mark(name)
    }

    public func mark(_ name: String) {
        lock.withLock {
            current = name
            changed = Date()
        }
    }

    // MARK: Requests in flight

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var running: [ObjectIdentifier: RequestTrace] = [:]

    public static func begin(_ trace: RequestTrace) {
        registryLock.withLock { running[ObjectIdentifier(trace)] = trace }
    }

    public static func end(_ trace: RequestTrace) {
        registryLock.withLock { running[ObjectIdentifier(trace)] = nil }
    }

    /// Requests running longer than `seconds`, oldest first.
    public static func running(longerThan seconds: TimeInterval) -> [RequestTrace] {
        let cutoff = Date().addingTimeInterval(-seconds)
        return registryLock.withLock { running.values.filter { $0.started < cutoff } }.sorted { $0.started < $1.started }
    }
}
