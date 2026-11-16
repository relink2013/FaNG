import Foundation

/// When an operation last made progress. Transfers touch it from their progress callbacks.
public final class Activity: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now

    public init() {}

    public func touch() {
        lock.withLock { last = .now }
    }

    var idle: Duration {
        lock.withLock { ContinuousClock.now - last }
    }
}

/// Runs operations that must never hang: one fails with `ETIMEDOUT` as soon as its `Activity` has been
/// idle longer than the limit, and with `CancellationError` as soon as the calling task is cancelled.
///
/// libsmb2 calls can't be interrupted once started, so a stalled operation is abandoned: it finishes (or
/// times out in libsmb2) in the background, and its result is dropped. The caller should then drop the
/// connection it ran on.
public enum Watchdog {
    public static func run<T: Sendable>(
        idleLimit: Duration,
        activity: Activity = Activity(),
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let outcome = Outcome<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                outcome.attach(continuation)
                let work = Task {
                    do {
                        outcome.finish(.success(try await operation()))
                    } catch {
                        outcome.finish(.failure(error))
                    }
                }
                Task {
                    while !outcome.isFinished {
                        try? await Task.sleep(for: .milliseconds(250))
                        if activity.idle > idleLimit {
                            outcome.finish(.failure(POSIXError(.ETIMEDOUT)))
                            work.cancel()
                        }
                    }
                }
            }
        } onCancel: {
            outcome.finish(.failure(CancellationError()))
        }
    }

    /// The first result wins; later ones are dropped. Cancellation can arrive before the continuation exists.
    private final class Outcome<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var result: Result<T, Error>?
        private var resumed = false

        var isFinished: Bool {
            lock.withLock { result != nil }
        }

        func attach(_ continuation: CheckedContinuation<T, Error>) {
            lock.withLock { self.continuation = continuation }
            resumeIfReady()
        }

        func finish(_ result: Result<T, Error>) {
            lock.withLock {
                if self.result == nil { self.result = result }
            }
            resumeIfReady()
        }

        private func resumeIfReady() {
            let ready: (CheckedContinuation<T, Error>, Result<T, Error>)? = lock.withLock {
                guard !resumed, let continuation, let result else { return nil }
                resumed = true
                return (continuation, result)
            }
            if let (continuation, result) = ready {
                continuation.resume(with: result)
            }
        }
    }
}

extension Error {
    /// The server or network failed, rather than the request: worth retrying later. libsmb2 reports a
    /// failed connect (including "no route to host") as `EIO`.
    public var isTransientNetworkError: Bool {
        guard let posix = self as? POSIXError else { return false }
        switch posix.code {
        case .ETIMEDOUT, .ECONNREFUSED, .ECONNRESET, .ECONNABORTED, .ENOTCONN, .EHOSTUNREACH, .EHOSTDOWN,
             .ENETUNREACH, .ENETDOWN, .ENETRESET, .EPIPE, .EIO:
            return true
        default:
            return false
        }
    }

    /// The server still has the file open for an earlier session (`STATUS_SHARING_VIOLATION`, which libsmb2
    /// reports as `ETXTBSY`), for example one cut off mid-transfer. It goes away when the server closes
    /// that session, so it's worth retrying later.
    public var isServerBusy: Bool {
        guard let posix = self as? POSIXError else { return false }
        return posix.code == .ETXTBSY || posix.code == .EBUSY
    }

    /// A failure that means this upload can't be resumed, so its temp file should go: it was cancelled, or
    /// its name was taken when it was put in place. Anything else keeps the temp file for the next
    /// attempt; one that's never retried is removed after a week.
    /// The server answered that the item doesn't exist (any more).
    public var itemIsGone: Bool {
        if let failure = self as? FangAPI.Failure, case .status(404) = failure { return true }
        return (self as? POSIXError)?.code == .ENOENT
    }

    var discardsUpload: Bool {
        if self is CancellationError { return true }
        return (self as? POSIXError)?.code == .EEXIST
    }
}
