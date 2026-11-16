import FaNGKit
import FileProvider
import Observation
import notify

/// Files that haven't synced yet, gathered in one place so nothing is stuck unnoticed. Two sources:
/// - each domain's `TransferJournal`, written by the extension: every upload that hasn't reached the
///   server, including a new file's first upload, which File Provider's pending set leaves out;
/// - each domain's File Provider pending set: downloads and other changes the system hasn't been able
///   to apply for a while, with the error when the system reports one.
@Observable final class PendingItems {
    struct Entry: Identifiable, Hashable {
        let id: String
        /// The upload's journal and key, for "Remove from List"; nil for pending-set items.
        var journal: String?
        var key: String?
        let name: String
        /// Where it goes or comes from: "Server › Share/folder", or just the server.
        let place: String
        let isUpload: Bool
        let problem: String?
    }

    private(set) var entries: [Entry] = []
    private(set) var isLoaded = false

    /// Kept so the system posts `NSFileProviderPendingSetDidChange` for them.
    @ObservationIgnored private var enumerators: [String: NSFileProviderPendingSetEnumerator] = [:]
    @ObservationIgnored private var journals: [String: TransferJournal] = [:]

    func refresh() async {
        var entries: [Entry] = []
        for account in AccountStore.all() {
            let uploads = journal(for: account)?.entries() ?? []
            entries += uploads.map { upload in
                Entry(
                    id: "upload:\(upload.key)",
                    journal: account.domainIdentifier,
                    key: upload.key,
                    name: upload.name,
                    place: "\(account.displayName) › \(upload.folder)",
                    isUpload: true,
                    problem: upload.error
                )
            }
            // An edit that's in the journal is listed once, from the journal.
            let journaled = Set(uploads.compactMap(\.itemID))
            guard let manager = NSFileProviderManager(for: DomainController.domain(for: account)) else { continue }
            let enumerator = enumerators[account.domainIdentifier] ?? manager.enumeratorForPendingItems()
            enumerators[account.domainIdentifier] = enumerator
            let items = (try? await Self.items(of: enumerator)) ?? []
            Self.note(uploads: uploads, pending: items)
            entries += items
                .filter { !journaled.contains($0.itemIdentifier.rawValue) }
                .map { Entry(item: $0, server: account.displayName) }
                // Downloads in progress are normal activity (a photo app opening a folder queues hundreds):
                // only the ones the system reports a problem for belong in this list.
                .filter { $0.isUpload || $0.problem != nil }
        }
        self.entries = entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        isLoaded = true
    }

    /// Refreshes whenever the extension records a transfer change or the system reports a change to a
    /// pending set, until the calling task ends.
    func watch() async {
        _ = try? await NSFileProviderManager.domains()  // Pending-set notifications start only after this.
        await refresh()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await _ in Self.darwinNotifications(TransferJournal.changedNotification) {
                    await self.refresh()
                }
            }
            group.addTask { @MainActor in
                for await _ in NotificationCenter.default.notifications(named: .fileProviderPendingSetDidChange) {
                    await self.refresh()
                }
            }
        }
    }

    /// Forgets a stale upload entry (one the system no longer retries).
    func remove(_ entry: Entry) async {
        guard let key = entry.key, let domain = entry.journal, let journal = journals[domain] else { return }
        journal.finished(key: key)
        await refresh()
    }

    private func journal(for account: ServerAccount) -> TransferJournal? {
        if let journal = journals[account.domainIdentifier] { return journal }
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FaNGKit.appGroupIdentifier),
              let journal = try? TransferJournal(domainFolder: container.appending(path: "Domains/\(account.domainIdentifier)"))
        else { return nil }
        journals[account.domainIdentifier] = journal
        return journal
    }

    /// A Darwin notification posted by another process (the extension), as an async sequence.
    private static func darwinNotifications(_ name: String) -> AsyncStream<Void> {
        AsyncStream { continuation in
            var token: Int32 = 0
            let status = notify_register_dispatch(name, &token, .main) { _ in
                continuation.yield()
            }
            guard status == NOTIFY_STATUS_OK else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in
                notify_cancel(token)
            }
        }
    }

    /// What the journal and the system hold as not synced, in the diagnostic log when it changes: the starts of
    /// IDs, states and error codes (never a name), so a list that looks stuck can be explained off the device.
    @ObservationIgnored private static var lastNote = ""
    private static func note(uploads: [TransferJournal.Entry], pending: [NSFileProviderItem]) {
        func code(_ error: Error?) -> String {
            guard let error = error as NSError? else { return "-" }
            let under = (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { " <\($0.domain) \($0.code)>" } ?? ""
            return "\(error.domain) \(error.code)\(under)"
        }
        let journal = uploads.map { "\($0.itemID?.prefix(8) ?? "new") \($0.size >> 20)MB age \(Int(Date().timeIntervalSince($0.updated) / 60))min \($0.error == nil ? "no error" : "error")" }
        let system = pending.map { item in
            "\(item.itemIdentifier.rawValue.prefix(8)) up=\(item.isUploaded ?? true) uploading=\(item.isUploading ?? false) upErr=[\(code(item.uploadingError ?? nil))] "
                + "down=\(item.isDownloaded ?? true) downloading=\(item.isDownloading ?? false) downErr=[\(code(item.downloadingError ?? nil))] trash=\(item.parentItemIdentifier == .trashContainer)"
        }
        let text = "Not synced: journal \(journal.count) {\(journal.joined(separator: "; "))} system \(system.count) {\(system.joined(separator: "; "))}"
        guard text.replacingOccurrences(of: #"age \d+min"#, with: "", options: .regularExpression) != lastNote else { return }
        lastNote = text.replacingOccurrences(of: #"age \d+min"#, with: "", options: .regularExpression)
        DiagnosticLog.note(text)
    }

    private static func items(of enumerator: NSFileProviderEnumerator) async throws -> [NSFileProviderItem] {
        var items: [NSFileProviderItem] = []
        var page = NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
        while true {
            let observer = Observer()
            let next = try await withCheckedThrowingContinuation { continuation in
                observer.continuation = continuation
                enumerator.enumerateItems(for: observer, startingAt: page)
            }
            items += observer.items
            guard let next else { return items }
            page = next
        }
    }

    /// Collects one page of an enumeration.
    private final class Observer: NSObject, NSFileProviderEnumerationObserver {
        var items: [NSFileProviderItem] = []
        var continuation: CheckedContinuation<NSFileProviderPage?, Error>?

        func didEnumerate(_ updatedItems: [NSFileProviderItem]) {
            items += updatedItems
        }

        func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
            continuation?.resume(returning: nextPage)
            continuation = nil
        }

        func finishEnumeratingWithError(_ error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

private extension PendingItems.Entry {
    init(item: NSFileProviderItem, server: String) {
        let uploadError = item.uploadingError ?? nil
        let downloadError = item.downloadingError ?? nil
        // Local changes waiting to go up: an upload error, or not uploaded while this device has the contents.
        // A file waiting to download is reported "not uploaded" too, so that alone doesn't make it an upload.
        let downloading = (item.isDownloading ?? false) || downloadError != nil || (item.isDownloaded ?? true) == false
        let isUpload = uploadError != nil || (item.isUploading ?? false) || ((item.isUploaded ?? true) == false && !downloading)
        // Something in the trash with a change that never reached the server: said as that, since "uploading"
        // alone reads as a file that's stuck. It ends when the item is put back or deleted from the trash.
        let inTrash = item.parentItemIdentifier == .trashContainer
        self.init(
            id: item.itemIdentifier.rawValue,
            name: item.filename,
            place: inTrash ? "\(server) › Recently Deleted" : server,
            isUpload: isUpload,
            problem: (isUpload ? uploadError : downloadError)?.localizedDescription
                ?? (inTrash ? "In the trash, with an edit that wasn't uploaded. Put it back to keep the edit, or delete it from Recently Deleted." : nil)
        )
    }
}
