import FaNGKit
import FileProvider

/// Bulk downloads. When an app fetches files from one folder one after another (a photo editor walking a
/// folder of RAW files asks for the next only once the last one arrived), the files that follow are
/// requested ahead, so they download while the current one is in use and are there when the app gets to
/// them. It starts with the second file an app asks for from the same folder within a minute.
///
/// An app opening a file that's already here doesn't reach the extension, so each file fetched ahead
/// requests one more, up to three windows past the last file an app asked for; the next file an app asks for
/// that isn't here yet starts again from there. Files fetched ahead download in the background (see
/// `TransferBudget`) and are ordinary downloads the system manages (and may evict later).
final class ReadAhead: @unchecked Sendable {
    #if os(iOS) || os(visionOS)
    static let window = 6
    #else
    static let window = 12
    #endif

    private struct Folder {
        var asked: [Date] = []
        /// Files requested since an app last asked for one here.
        var requestedSinceAsk = 0
        /// Files an app asked for here whose download was cancelled, recently.
        var cancels: [Date] = []
        /// Set when downloads here were cancelled in bulk: read-ahead stays off until an app asks again.
        var stopped = false
        /// Files read-ahead downloaded here.
        var fetchedAhead: Set<String> = []
    }

    private let lock = NSLock()
    private var folders: [String: Folder] = [:]
    /// Files requested ahead (each only once while the extension runs).
    private var requested: Set<String> = []
    /// Files requested ahead that haven't been fetched yet.
    private var ahead: Set<String> = []

    /// True for a file requested ahead that nobody asked for yet (taken off the list).
    func isAhead(_ id: String) -> Bool {
        lock.withLock { ahead.remove(id) != nil }
    }

    /// True if read-ahead was stopped in this folder (its queued downloads are then refused).
    func isStopped(_ folder: String) -> Bool {
        lock.withLock { folders[folder]?.stopped == true }
    }

    func didFetchAhead(_ id: String, in folder: String) {
        lock.withLock { _ = folders[folder, default: Folder()].fetchedAhead.insert(id) }
    }

    /// A download an app asked for was cancelled. Two or more cancelled in a folder within a few seconds (a
    /// cancelled Duplicate, copy or bulk download) stop read-ahead there: what it queued is refused and what it
    /// already downloaded goes again (the system keeps files that are open or changed). One cancel alone (an
    /// app skipping a file) changes nothing.
    func askedFetchCancelled(_ record: ItemRecord, manager: NSFileProviderManager?) {
        let now = Date()
        let evict: Set<String>? = lock.withLock {
            var folder = folders[record.parentID] ?? Folder()
            folder.cancels = folder.cancels.filter { now.timeIntervalSince($0) < 5 } + [now]
            guard folder.cancels.count >= 2, !folder.stopped else {
                folders[record.parentID] = folder
                return nil
            }
            folder.stopped = true
            let fetched = folder.fetchedAhead
            folder.fetchedAhead = []
            folders[record.parentID] = folder
            return fetched
        }
        guard let evict, let manager else { return }
        DiagnosticLog.note("Read-ahead stopped after cancelled downloads; removing \(evict.count) files it fetched")
        for id in evict {
            manager.evictItem(identifier: NSFileProviderItemIdentifier(id)) { _ in }
        }
    }

    /// A file is being fetched: `asked` when an app asked for it, false when it was requested ahead.
    func fetched(_ record: ItemRecord, asked: Bool, store: ItemStore, materialized: MaterializedItems, manager: NSFileProviderManager?) {
        guard let manager, !record.isDirectory else { return }
        let now = Date()
        let count: Int = lock.withLock {
            requested.insert(record.id)
            var folder = folders[record.parentID] ?? Folder()
            if asked {
                folder.asked = folder.asked.filter { now.timeIntervalSince($0) < 60 } + [now]
                folder.requestedSinceAsk = 0
                // An app asking again after a bulk cancel: read-ahead starts over from here.
                if folder.stopped && folder.cancels.allSatisfy({ now.timeIntervalSince($0) > 5 }) { folder.stopped = false }
                if folder.stopped {
                    folders[record.parentID] = folder
                    return 0
                }
                folders[record.parentID] = folder
                return folder.asked.count >= 2 ? Self.window : 0
            }
            guard !folder.stopped, folder.requestedSinceAsk < 3 * Self.window else { return 0 }
            return 1
        }
        guard count > 0 else { return }
        let files = store.files(in: record.parentID)
        guard let index = files.firstIndex(where: { $0.id == record.id }) else { return }
        let next = files[(index + 1)...].filter { file in
            !materialized.contains(file.id) && file.job == nil && lock.withLock { !requested.contains(file.id) }
        }.prefix(count)
        guard !next.isEmpty else { return }
        lock.withLock {
            for file in next {
                requested.insert(file.id)
                ahead.insert(file.id)
            }
            folders[record.parentID, default: Folder()].requestedSinceAsk += next.count
        }
        if asked { DiagnosticLog.note("Read-ahead: \(next.count) files requested") }
        for file in next {
            manager.requestDownloadForItem(withIdentifier: NSFileProviderItemIdentifier(file.id), requestedRange: nil) { _ in }
        }
    }
}
