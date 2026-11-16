import FaNGKit
import FileProvider
import OSLog

class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    /// Most folders the working set re-lists when asked for changes against plain SMB, which has no change
    /// feed: changes are found by listing the folders that were browsed most recently.
    private static let workingSetFolderLimit = 20
    private static let pageSize = 200

    private let container: NSFileProviderItemIdentifier
    private let connection: () throws -> DomainConnection
    /// Called with the IDs of known files whose contents changed.
    private let contentChanged: (Set<String>) -> Void
    /// The domain's manager, to look at the system's pending set.
    private let manager: NSFileProviderManager?
    private var task: Task<Void, Never>?

    init(container: NSFileProviderItemIdentifier, manager: NSFileProviderManager? = nil,
         connection: @escaping () throws -> DomainConnection,
         contentChanged: @escaping (Set<String>) -> Void) {
        self.container = container
        self.manager = manager
        self.connection = connection
        self.contentChanged = contentChanged
        super.init()
    }

    func invalidate() {
        task?.cancel()
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // Nothing to add to the working set up front: the system learns items by enumerating folders. Only
        // a FaNG server has a trash.
        guard container != .workingSet, container != .trashContainer || FileProviderItem.trashAvailable else {
            observer.finishEnumerating(upTo: nil)
            return
        }
        task = Task {
            do {
                let result = try await connection().relist(container.rawValue)
                for start in stride(from: 0, to: result.items.count, by: Self.pageSize) {
                    let page = result.items[start..<min(start + Self.pageSize, result.items.count)]
                    observer.didEnumerate(page.map(FileProviderItem.init))
                }
                observer.finishEnumerating(upTo: nil)
                FileProviderExtension.meter?.measure(after: "enumerateItems")
            } catch {
                FileProviderExtension.log.error("Enumerating \(self.container.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                DiagnosticLog.note("enumerateItems \(Self.kind(self.container)) failed: \(error)")
                observer.finishEnumeratingWithError(FileProviderExtension.fileProviderError(error))
            }
        }
    }

    // MARK: Diagnostics (no names)

    static func kind(_ container: NSFileProviderItemIdentifier) -> String {
        switch container {
        case .workingSet: "working set"
        case .rootContainer: "root"
        case .trashContainer: "trash"
        default: "folder"
        }
    }

    /// What the system gets for a few items: folder or file, capabilities and userInfo (no names).
    static func sample(_ records: [ItemRecord]) -> String {
        records.prefix(3).map { record in
            let item = FileProviderItem(record)
            let info = item.userInfo.map { $0.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",") } ?? "nil"
            return "\(record.isDirectory ? "dir" : "file") caps=\(item.capabilities.rawValue) info=[\(info)] trash=\(FileProviderItem.trashAvailable)"
        }.joined(separator: " | ")
    }

    /// The anchor's item format and whether a refresh is under way.
    static func anchorSummary(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "(\(data.count) bytes)" }
        return "format \(object["format"].map { "\($0)" } ?? "nil") refresh \(object["refresh"] == nil ? "no" : "yes") from \(object["from"].map { "\($0)" } ?? "-")"
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        guard container != .trashContainer || FileProviderItem.trashAvailable else {
            observer.finishEnumeratingChanges(upTo: Self.timeAnchor, moreComing: false)
            return
        }
        task = Task {
            do {
                let connection = try connection()
                var updated: [ItemRecord] = []
                var deleted: [String] = []
                var next = Self.timeAnchor
                var moreComing = false
                var changedContent: Set<String> = []
                if container == .workingSet {
                    let changes = try await connection.changes(since: anchor.rawValue, workingSetFolderLimit: Self.workingSetFolderLimit)
                    (updated, deleted, next) = (changes.updated, changes.deleted, NSFileProviderSyncAnchor(changes.anchor))
                    moreComing = changes.moreComing
                    changedContent = changes.contentChanged
                    // Things in the trash with a change waiting that the server no longer has: the system keeps
                    // listing them as not synced until it is told they're gone.
                    let gone = await trashedItemsGoneFromServer(connection)
                    deleted += gone.filter { !deleted.contains($0) }
                } else {
                    do {
                        let result = try await connection.relist(container.rawValue)
                        (updated, deleted) = (result.changed, result.deleted)
                        changedContent = result.contentChanged
                    } catch let error as POSIXError where error.code == .ENOENT {
                        // The folder is gone; its parent reports the deletion.
                    }
                }
                FileProviderExtension.log.debug("Changes for \(self.container.rawValue, privacy: .public): \(updated.count) updated, \(deleted.count) deleted")
                if !updated.isEmpty || !deleted.isEmpty {
                    DiagnosticLog.note("enumerateChanges \(Self.kind(container)): \(updated.count) updated, \(deleted.count) deleted, more \(moreComing), anchor \(Self.anchorSummary(anchor.rawValue)) → \(Self.anchorSummary(next.rawValue)); sample \(Self.sample(updated))")
                }
                for start in stride(from: 0, to: updated.count, by: Self.pageSize) {
                    observer.didUpdate(updated[start..<min(start + Self.pageSize, updated.count)].map(FileProviderItem.init))
                }
                if !deleted.isEmpty {
                    observer.didDeleteItems(withIdentifiers: deleted.map { NSFileProviderItemIdentifier($0) })
                }
                observer.finishEnumeratingChanges(upTo: next, moreComing: moreComing)
                if !changedContent.isEmpty {
                    contentChanged(changedContent)
                }
                FileProviderExtension.meter?.measure(after: "enumerateChanges")
            } catch {
                FileProviderExtension.log.error("Enumerating \(self.container.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                DiagnosticLog.note("enumerateChanges \(Self.kind(self.container)) failed: \(error)")
                observer.finishEnumeratingWithError(FileProviderExtension.fileProviderError(error))
            }
        }
    }

    /// Items in the system's pending set that sit in the trash and that the server doesn't have (deleted or
    /// restored under another ID directly on the server) or has in its trash too. The delete was what the user wanted, and it has
    /// happened, so nothing is left to wait for. Only a definite "no such item" counts: any other error leaves
    /// the item alone.
    private func trashedItemsGoneFromServer(_ connection: DomainConnection) async -> [String] {
        guard let enumerator = manager?.enumeratorForPendingItems() else { return [] }
        let pending = await Self.pendingItems(of: enumerator)
        var gone: [String] = []
        var outcomes: [String] = []
        for item in pending where item.parentItemIdentifier == .trashContainer {
            let id = item.itemIdentifier.rawValue
            do {
                let record = try await connection.refresh(id)
                // Already in the server's trash too: the delete is done on both sides, and what's left is an edit
                // upload the system won't retry for a trashed item. The server's trash keeps the last uploaded
                // version, so the pending state can go.
                if record.parentID == NSFileProviderItemIdentifier.trashContainer.rawValue { gone.append(id) }
                outcomes.append("\(id.prefix(8)) on server, parent \(record.parentID.prefix(8)) dir \(record.isDirectory) size \(record.size) version \(record.serverVersion.map(String.init) ?? "-") job \(record.job ?? "-")")
            } catch where error.itemIsGone {
                gone.append(id)
                outcomes.append("\(id.prefix(8)) gone")
            } catch {
                outcomes.append("\(id.prefix(8)) error \(error)")
            }
        }
        if !pending.isEmpty {
            DiagnosticLog.note("Pending set seen by the extension: \(pending.count) items, \(outcomes.count) in the trash {\(outcomes.joined(separator: "; "))}")
        }
        if !gone.isEmpty {
            DiagnosticLog.note("Pending items in the trash that the server no longer has: \(gone.map { String($0.prefix(8)) }.joined(separator: ", "))")
        }
        return gone
    }

    private static func pendingItems(of enumerator: NSFileProviderEnumerator) async -> [NSFileProviderItem] {
        final class Collector: NSObject, NSFileProviderEnumerationObserver {
            var items: [NSFileProviderItem] = []
            var next: NSFileProviderPage?
            var continuation: CheckedContinuation<Void, Never>?
            func didEnumerate(_ updatedItems: [NSFileProviderItem]) { items += updatedItems }
            func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
                next = nextPage
                continuation?.resume()
                continuation = nil
            }
            func finishEnumeratingWithError(_ error: Error) {
                next = nil
                continuation?.resume()
                continuation = nil
            }
        }
        let collector = Collector()
        var page = NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
        while true {
            collector.next = nil
            await withCheckedContinuation { continuation in
                collector.continuation = continuation
                enumerator.enumerateItems(for: collector, startingAt: page)
            }
            guard let next = collector.next else { return collector.items }
            page = next
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard container == .workingSet else { return completionHandler(Self.timeAnchor) }
        let connection = connection
        Task {
            let anchor = try? await connection().currentAnchor()
            completionHandler(anchor.map { NSFileProviderSyncAnchor($0) })
        }
    }

    /// Folders find changes by listing again, not by anchor, so their anchor only needs to move forward.
    private static var timeAnchor: NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data("\(Date().timeIntervalSince1970)".utf8))
    }
}
