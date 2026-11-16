import FaNGCore
import Foundation

/// The latest change number, watched once for every client: one cheap query (the newest entry of an index)
/// every quarter second while anyone listens, none while nobody does. WebSocket clients and long polls
/// subscribe here instead of each asking the database on their own.
final class ChangeFeed: @unchecked Sendable {
    private let store: ItemStore
    private let lock = NSLock()
    private var latest: Int64 = -1
    private var listeners: [UUID: AsyncStream<Int64>.Continuation] = [:]

    init(store: ItemStore) {
        self.store = store
    }

    /// Changes from now on: the current number first, then every new one.
    func subscribe() -> AsyncStream<Int64> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Int64.self, bufferingPolicy: .bufferingNewest(1))
        let current: Int64 = lock.withLock {
            listeners[id] = continuation
            return latest
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.lock.withLock { self?.listeners.removeValue(forKey: id) }
        }
        if current >= 0 { continuation.yield(current) }
        return stream
    }

    /// Runs for the life of the server.
    func run() async {
        while !Task.isCancelled {
            let listening = lock.withLock { !listeners.isEmpty }
            if listening, let now = try? await store.latestChange() {
                let changed: [AsyncStream<Int64>.Continuation] = lock.withLock {
                    guard now != latest else { return [] }
                    latest = now
                    return Array(listeners.values)
                }
                for listener in changed { listener.yield(now) }
            } else if !listening {
                lock.withLock { latest = -1 }  // Read fresh when the next listener arrives.
            }
            try? await Task.sleep(for: .milliseconds(listening ? 250 : 500))
        }
    }
}
