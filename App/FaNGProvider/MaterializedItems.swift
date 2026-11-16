import FileProvider
import OSLog

/// Which items the system has downloaded on this device, so a remote change to one of them can be fetched
/// right away. Left alone, the system refreshes a downloaded file only when its background-download
/// activity next runs (about 45 s later on a Mac), or when someone opens the file, so other devices showed
/// the old contents until then.
final class MaterializedItems: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []
    private var refreshing: Task<Void, Never>?

    func contains(_ id: String) -> Bool {
        lock.withLock { ids.contains(id) }
    }

    /// Reads the set again from the system (on start, and when the system says it changed).
    func refresh(_ manager: NSFileProviderManager) async {
        let collector = Collector(enumerator: manager.enumeratorForMaterializedItems())
        let found = await collector.all()
        lock.withLock { ids = found }
        collector.enumerator.invalidate()
        FileProviderExtension.log.notice("Downloaded items on this device: \(found.count, privacy: .public)")
    }

    /// Asks the system to download the new contents of every downloaded item among `changed`, now.
    func fetchNow(_ changed: Set<String>, manager: NSFileProviderManager) {
        let downloaded = changed.filter(contains)
        FileProviderExtension.log.notice("New contents for \(changed.count, privacy: .public) known files, \(downloaded.count, privacy: .public) downloaded here: fetching those now")
        for id in downloaded {
            refetch(NSFileProviderItemIdentifier(id), manager: manager, attempt: 1)
        }
    }

    /// A download request alone doesn't hurry an outdated local copy (only a missing one), so the stale copy
    /// goes first. The system refuses to evict a copy that's open, has unsynced edits or was only just
    /// uploaded (no local work is lost); then it's tried again a few seconds later, a few times, instead of
    /// waiting for the system's next background download pass (about 40 s after an upload of the same file).
    private func refetch(_ identifier: NSFileProviderItemIdentifier, manager: NSFileProviderManager, attempt: Int) {
        let id = identifier.rawValue
        manager.evictItem(identifier: identifier) { evictError in
            if evictError != nil, attempt < 4 {
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3 * attempt)) {
                    self.refetch(identifier, manager: manager, attempt: attempt + 1)
                }
                return
            }
            manager.requestDownloadForItem(withIdentifier: identifier, requestedRange: nil) { error in
                if let error {
                    FileProviderExtension.log.error("Download request for \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                } else {
                    FileProviderExtension.log.notice("Fetching \(id, privacy: .public) now (stale copy \(evictError == nil ? "removed" : "kept: \(String(describing: evictError!))", privacy: .public))")
                }
            }
        }
    }

    /// Pages through the system's enumerator of materialized items.
    private final class Collector: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
        let enumerator: NSFileProviderEnumerator
        private var found: Set<String> = []
        private var continuation: CheckedContinuation<Set<String>, Never>?

        init(enumerator: NSFileProviderEnumerator) {
            self.enumerator = enumerator
        }

        func all() async -> Set<String> {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                enumerator.enumerateItems(for: self, startingAt: NSFileProviderPage.initialPageSortedByName as NSFileProviderPage)
            }
        }

        func didEnumerate(_ updatedItems: [NSFileProviderItemProtocol]) {
            for item in updatedItems { found.insert(item.itemIdentifier.rawValue) }
        }

        func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
            if let nextPage {
                enumerator.enumerateItems(for: self, startingAt: nextPage)
            } else {
                continuation?.resume(returning: found)
                continuation = nil
            }
        }

        func finishEnumeratingWithError(_ error: Error) {
            FileProviderExtension.log.error("Listing downloaded items failed: \(String(describing: error), privacy: .public)")
            continuation?.resume(returning: found)
            continuation = nil
        }
    }
}
