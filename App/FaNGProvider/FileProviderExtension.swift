import FaNGKit
import FileProvider
import OSLog
import UniformTypeIdentifiers

class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing, NSFileProviderServicing, NSFileProviderIncrementalContentFetching {
    private static let rootID = NSFileProviderItemIdentifier.rootContainer.rawValue
    static let log = Logger(subsystem: "com.rlx.fang.provider", category: "extension")

    /// Peak memory after each operation, kept in the App Group's Library/Diagnostics folder (Library is
    /// where Xcode's device tools may read an app group container from).
    static let meter: MemoryMeter? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: FaNGKit.appGroupIdentifier)
        .map { folder in
            let diagnostics = folder.appending(path: "Library/Diagnostics")
            try? FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true)
            // Builds before this one kept it outside Library.
            let earlier = folder.appending(path: "Diagnostics/extension-memory.json")
            if FileManager.default.fileExists(atPath: earlier.path) {
                try? FileManager.default.moveItem(at: earlier, to: diagnostics.appending(path: "extension-memory.json"))
                try? FileManager.default.removeItem(at: earlier.deletingLastPathComponent())
            }
            return MemoryMeter(folder: diagnostics)
        }

    private let domain: NSFileProviderDomain
    private let lock = NSLock()
    private var cachedConnection: DomainConnection?
    /// Downloaded items, so remote changes to them are fetched at once.
    private let materialized = MaterializedItems()
    /// Downloads the files that follow when an app fetches a folder's files one after another.
    private let readAhead = ReadAhead()
    /// The versions view's channel (kept alive here: the system doesn't hold on to it).
    private lazy var versionsService = VersionsServiceSource(server: { [weak self] in try self?.connection().server })

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        DiagnosticLog.note("Extension started (pid \(ProcessInfo.processInfo.processIdentifier))")
    }

    func invalidate() {}

    /// The account's backend and item store. Built on first use and retried on later calls if the
    /// account or password isn't available yet (for example before the first unlock).
    private func connection() throws -> DomainConnection {
        try lock.withLock {
            if let cachedConnection { return cachedConnection }
            guard let account = AccountStore.account(domainIdentifier: domain.identifier.rawValue),
                  let password = try CredentialStore.password(for: account)
            else { throw NSFileProviderError(.notAuthenticated) }
            guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FaNGKit.appGroupIdentifier) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let folder = container.appending(path: "Domains/\(account.domainIdentifier)")
            var server: FangAPI?
            if let fang = account.fang {
                guard let token = try CredentialStore.deviceToken(for: account) else { throw NSFileProviderError(.notAuthenticated) }
                server = try FangAPI(host: account.host, server: fang, token: token)
            }
            let connection = DomainConnection(
                backend: try SMBBackend(account: account, password: password),
                store: try ItemStore(url: folder.appending(path: "items.sqlite"), rootID: Self.rootID),
                journal: try TransferJournal(domainFolder: folder),
                server: server,
                trashID: NSFileProviderItemIdentifier.trashContainer.rawValue
            )
            FileProviderItem.trashAvailable = connection.hasTrash
            if let server {
                startWatching(server)
            }
            if let manager = NSFileProviderManager(for: domain) {
                Task { [materialized] in await materialized.refresh(manager) }
            }
            cachedConnection = connection
            return connection
        }
    }

    /// Runs `work` in a task that the returned progress can cancel. Errors are logged and mapped for File Provider.
    private func perform(
        _ name: String,
        item: String? = nil,
        detail: String? = nil,
        progress: Progress = Progress(totalUnitCount: 1),
        _ work: @escaping (DomainConnection) async throws -> Void,
        onError: @escaping (Error) -> Void
    ) -> Progress {
        // In the log: the operation, the start of the item's ID and what it's about, so a failure can be traced to
        // one item (never a name or a path).
        let operation = name + (item.map { " " + $0.prefix(8) } ?? "") + (detail.map { " [" + $0 + "]" } ?? "")
        let task = Task {
            let start = ContinuousClock.now
            // Fetches are what a user waits on: note each start, so "Waiting" in Files can be told apart from
            // the system never asking.
            let fetch = name.hasPrefix("fetch") && name != "fetchThumbnails"
            if fetch {
                DiagnosticLog.note("\(operation) started (pid \(ProcessInfo.processInfo.processIdentifier))")
                Self.log.notice("\(operation, privacy: .public) started")
            }
            do {
                try await work(try connection())
                let elapsed = ContinuousClock.now - start
                // Changes (creates, edits, deletes) are few and each one matters: every one is noted, so one the
                // system keeps asking for shows up. Lookups and thumbnails are too many to note unless slow.
                let change = name == "modifyItem" || name == "createItem" || name == "deleteItem"
                if elapsed > .seconds(3) || fetch || change {
                    DiagnosticLog.note("\(operation) done in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])))")
                    Self.log.notice("\(operation, privacy: .public) done in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)")
                }
            } catch {
                Self.log.error("\(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                DiagnosticLog.note("\(operation) failed after \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds]))): \(String(describing: error))")
                onError(Self.fileProviderError(error))
            }
            Self.meter?.measure(after: operation)
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if identifier == .rootContainer {
            completionHandler(FileProviderItem.root(rootID: Self.rootID, name: domain.displayName), nil)
            return Progress()
        }
        if identifier == .workingSet || (identifier == .trashContainer && !FileProviderItem.trashAvailable) {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        return perform("item", { connection in
            completionHandler(FileProviderItem(try await connection.refresh(identifier.rawValue)), nil)
        }, onError: { completionHandler(nil, $0) })
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        return perform("fetchContents", progress: progress, { [domain] connection in
            guard let directory = try NSFileProviderManager(for: domain)?.temporaryDirectoryURL() else {
                throw CocoaError(.fileNoSuchFile)
            }
            let url = directory.appending(path: UUID().uuidString)
            // A file fetched ahead downloads in the background, after the files apps are waiting for. (If an
            // app asks for it meanwhile, the system joins that request to this download.)
            let background = self.readAhead.isAhead(itemIdentifier.rawValue)
            let known = connection.store.record(itemIdentifier.rawValue)
            // Queued by read-ahead in a folder where downloads were then cancelled in bulk: refused, so a cancel
            // really stops everything.
            if background, let known, self.readAhead.isStopped(known.parentID) { throw CancellationError() }
            // Only an app waiting for files starts read-ahead. The system's own downloads (refreshing changed
            // files, filling space back after it evicted under storage pressure) don't: after an outage on a
            // nearly full disk they made read-ahead fetch files nobody asked for, which the system evicted again.
            let asked = !background && !request.isSystemRequest
            if let known, background || asked {
                self.readAhead.fetched(known, asked: asked, store: connection.store, materialized: self.materialized,
                                       manager: NSFileProviderManager(for: domain))
            }
            let record: ItemRecord
            do {
                record = try await TransferPriority.$isBackground.withValue(background) {
                    try await connection.download(itemIdentifier.rawValue, to: url, progress: progress)
                }
            } catch {
                if asked, let known, error is CancellationError || progress.isCancelled {
                    self.readAhead.askedFetchCancelled(known, manager: NSFileProviderManager(for: domain))
                }
                throw error
            }
            if background { self.readAhead.didFetchAhead(record.id, in: record.parentID) }
            completionHandler(url, FileProviderItem(record), nil)
        }, onError: { completionHandler(nil, nil, $0) })
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let type = itemTemplate.contentType ?? .data
        // Symbolic links and packages (bundles) aren't supported yet.
        if type.conforms(to: .symbolicLink) || type.conforms(to: .package) {
            completionHandler(nil, [], false, CocoaError(.featureUnsupported))
            return Progress()
        }
        // A file made new inside the trash: the system does this for a file whose edit was refused because the
        // server no longer has the item, then trashed. There is nothing to upload for something that's deleted;
        // answering with an item in the trash settles it, and the server (which doesn't list it) has the
        // system drop it.
        if itemTemplate.parentItemIdentifier == .trashContainer {
            DiagnosticLog.note("createItem in the trash: nothing to upload")
            let remote = RemoteItem(path: itemTemplate.filename, name: itemTemplate.filename, isDirectory: type.conforms(to: .folder),
                                    size: 0, modified: Date(), created: Date(), fileID: 0)
            completionHandler(FileProviderItem(ItemRecord(id: UUID().uuidString, parentID: NSFileProviderItemIdentifier.trashContainer.rawValue, remote: remote)),
                              [], false, nil)
            return Progress()
        }
        let progress = Progress(totalUnitCount: 0)
        return perform("createItem", progress: progress, { connection in
            let parentID = itemTemplate.parentItemIdentifier.rawValue
            var record = type.conforms(to: .folder)
                ? try await connection.createFolder(named: itemTemplate.filename, in: parentID)
                : try await connection.createFile(
                    named: itemTemplate.filename, in: parentID, contents: url,
                    mayAlreadyExist: options.contains(.mayAlreadyExist), progress: progress
                )
            // Extended attributes it was made with (a folder created with a symbol, a download's "Where from").
            if connection.server != nil, fields.contains(.extendedAttributes),
               let xattrs = itemTemplate.extendedAttributes, !xattrs.isEmpty, xattrs != record.xattrs {
                record = try await connection.setXattrs(record.id, xattrs)
            }
            completionHandler(FileProviderItem(record), [], false, nil)
        }, onError: { completionHandler(nil, [], false, $0) })
    }

    // Name, location, contents, tags, extended attributes (folder customization) and dates go to the server.
    // Last-used dates and favorite ranks stay on the device.
    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        var fields: [String] = []
        if changedFields.contains(.contents) { fields.append("contents") }
        if changedFields.contains(.filename) { fields.append("name") }
        if changedFields.contains(.parentItemIdentifier) { fields.append(item.parentItemIdentifier == .trashContainer ? "trash" : "parent") }
        if changedFields.contains(.tagData) { fields.append("tags") }
        if changedFields.contains(.extendedAttributes) { fields.append("xattrs") }
        return perform("modifyItem", item: item.itemIdentifier.rawValue, detail: fields.joined(separator: ","), progress: progress, { connection in
            let id = item.itemIdentifier.rawValue
            var record = try await connection.refresh(id)
            var fetchContent = false
            let trash = NSFileProviderItemIdentifier.trashContainer.rawValue
            if changedFields.contains(.parentItemIdentifier), item.parentItemIdentifier == .trashContainer {
                // Move to Trash: the server keeps it (and its versions) until it's emptied or expires.
                record = try await connection.moveToTrash(id)
            } else if changedFields.contains(.parentItemIdentifier), record.parentID == trash {
                record = try await connection.putBack(id, into: item.parentItemIdentifier.rawValue)
            } else if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                record = try await connection.move(id, to: item.filename, in: item.parentItemIdentifier.rawValue)
            }
            if changedFields.contains(.tagData), connection.server != nil {
                record = try await connection.setTags(id, FileProviderItem.tags(from: item.tagData ?? nil))
            }
            if changedFields.contains(.extendedAttributes), connection.server != nil {
                record = try await connection.setXattrs(id, item.extendedAttributes ?? [:])
            }
            if !changedFields.contains(.contents), !record.isDirectory,
               changedFields.contains(.contentModificationDate) || changedFields.contains(.creationDate) {
                record = try await connection.setDates(
                    id, modified: changedFields.contains(.contentModificationDate) ? item.contentModificationDate ?? nil : nil,
                    created: changedFields.contains(.creationDate) ? item.creationDate ?? nil : nil)
            }
            if changedFields.contains(.contents), let newContents {
                let update = try await connection.replaceContents(
                    of: id, with: newContents, baseVersion: version.contentVersion,
                    modified: item.contentModificationDate ?? nil, progress: progress
                )
                record = update.record
                fetchContent = update.editLost
                if update.conflictCopyName != nil || update.conflict {
                    Self.log.notice("Conflict on \(id, privacy: .public); the other side was kept")
                    self.signalChanges()
                }
            }
            // If the edit lost a conflict, the device's copy is the losing side: have the system fetch the file
            // that stayed, or it keeps showing (and opening) its own edit under the server's version.
            completionHandler(FileProviderItem(record), [], fetchContent, nil)
        }, onError: { completionHandler(nil, [], false, $0) })
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping (Error?) -> Void) -> Progress {
        perform("deleteItem", { connection in
            try await connection.delete(
                identifier.rawValue, baseVersion: version.contentVersion, recursive: options.contains(.recursive)
            )
            completionHandler(nil)
        }, onError: { completionHandler($0) })
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        FileProviderEnumerator(container: containerItemIdentifier, manager: NSFileProviderManager(for: domain), connection: connection) { [weak self] changed in
            guard let self, let manager = NSFileProviderManager(for: self.domain) else { return }
            self.materialized.fetchNow(changed, manager: manager)
        }
    }

    // MARK: Thumbnails

    /// Concurrent thumbnail reads. Each holds one file header (plain SMB) or one small WebP (FaNG server)
    /// in memory, so this stays well inside the iOS extension's limit.
    private static let thumbnailConcurrency = 8

    func materializedItemsDidChange(completionHandler: @escaping () -> Void) {
        guard let manager = NSFileProviderManager(for: domain) else { return completionHandler() }
        Task {
            await materialized.refresh(manager)
            completionHandler()
        }
    }

    func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier, completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void) -> Progress {
        completionHandler([versionsService], nil)
        return Progress()
    }

    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier], requestedSize size: CGSize, perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void, completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        let maxPixelSize = Int(max(size.width, size.height))
        return perform("fetchThumbnails", progress: progress, { connection in
            await withTaskGroup(of: (NSFileProviderItemIdentifier, Result<Data?, Error>).self) { group in
                func finishOne() async {
                    guard let (identifier, result) = await group.next() else { return }
                    switch result {
                    case .success(let data): perThumbnailCompletionHandler(identifier, data, nil)
                    case .failure(let error): perThumbnailCompletionHandler(identifier, nil, Self.fileProviderError(error))
                    }
                    progress.completedUnitCount += 1
                }
                for (index, identifier) in itemIdentifiers.enumerated() {
                    if index >= Self.thumbnailConcurrency {
                        await finishOne()
                    }
                    group.addTask {
                        do {
                            return (identifier, .success(try await connection.thumbnail(of: identifier.rawValue, maxPixelSize: maxPixelSize)))
                        } catch {
                            return (identifier, .failure(error))
                        }
                    }
                }
                while !group.isEmpty {
                    await finishOne()
                }
            }
            completionHandler(Task.isCancelled ? CocoaError(.userCancelled) : nil)
        }, onError: { completionHandler($0) })
    }

    /// Without push notifications (they need a paid developer account), the extension learns of server
    /// changes over one WebSocket it keeps open while it runs: no polling, the server speaks only when
    /// something changed, and the extension asks the system to sync. It ends with the extension.
    private var watching = false

    private func startWatching(_ server: FangAPI) {
        guard !watching else { return }
        watching = true
        Task.detached { [weak self] in
            var known: Int64?
            var pause: Duration = .seconds(5)
            while self != nil {
                do {
                    var connected = false
                    for try await latest in server.events() {
                        Self.log.debug("Server change \(latest, privacy: .public) (known \(known ?? -1, privacy: .public))")
                        if !connected {
                            // The server answers (again): the system ends its back-off for "server unreachable"
                            // at once (it can wait minutes otherwise) and catches up.
                            connected = true
                            self?.serverReachable()
                        } else if let previous = known, latest > previous {
                            self?.signalChanges()
                        }
                        known = latest
                        pause = .seconds(5)
                    }
                } catch {
                    Self.log.notice("Event stream ended: \(String(describing: error), privacy: .public)")
                    DiagnosticLog.note("Event stream ended: \(String(describing: error))")
                }
                // Dropped (server restart, network change, not reachable): reconnect, backing off to 5 min.
                try? await Task.sleep(for: pause)
                pause = min(pause * 2, .seconds(300))
            }
        }
    }

    /// The event stream (re)connected: transfers and enumerations that failed as unreachable are retried now,
    /// and the working set catches up with whatever changed meanwhile.
    private func serverReachable() {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalErrorResolved(NSFileProviderError(.serverUnreachable)) { _ in }
        manager.signalErrorResolved(NSFileProviderError(.cannotSynchronize)) { _ in }
        signalChanges()
    }

    /// Asks the system to enumerate changes, for items that appeared on the server because of this
    /// device's own operations (a conflict copy).
    private func signalChanges() {
        guard let manager = NSFileProviderManager(for: domain) else {
            Self.log.error("No manager to signal the working set")
            return
        }
        manager.signalEnumerator(for: .workingSet) { error in
            if let error {
                Self.log.error("Signaling the working set failed: \(String(describing: error), privacy: .public)")
            } else {
                Self.log.debug("Signaled the working set")
            }
        }
    }

    // MARK: Delta and partial downloads

    /// A file this device has changed on the server: only the blocks that differ are fetched (the server hashes
    /// its copy; this device keeps the blocks it has). Falls back to the whole file when that doesn't apply.
    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, usingExistingContentsAt existingContents: URL, existingVersion: NSFileProviderItemVersion, request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 0)
        return perform("fetchContents", progress: progress, { [domain] connection in
            guard let directory = try NSFileProviderManager(for: domain)?.temporaryDirectoryURL() else {
                throw CocoaError(.fileNoSuchFile)
            }
            let url = directory.appending(path: UUID().uuidString)
            let record: ItemRecord
            do {
                record = try await connection.downloadIncremental(itemIdentifier.rawValue, existing: existingContents, to: url, progress: progress)
            } catch where !(error is CancellationError) {
                try? FileManager.default.removeItem(at: url)
                record = try await connection.download(itemIdentifier.rawValue, to: url, progress: progress)
            }
            completionHandler(url, FileProviderItem(record), nil)
        }, onError: { completionHandler(nil, nil, $0) })
    }

    // MARK: Errors

    /// Maps backend errors to the errors File Provider acts on (retry later, pick another name, …).
    static func fileProviderError(_ error: Error) -> Error {
        if error is CancellationError {
            return CocoaError(.userCancelled)
        }
        // Another device changed the file since the version deleted here: the system keeps it.
        if let changed = error as? DomainConnection.ChangedOnServer {
            return NSError.fileProviderErrorForRejectedDeletion(of: FileProviderItem(changed.record))
        }
        if error is DomainConnection.AnchorExpired {
            return NSFileProviderError(.syncAnchorExpired)
        }
        if case FangAPI.Failure.notSignedIn = error {
            return NSFileProviderError(.notAuthenticated)
        }
        // The server no longer has the item (deleted or out of reach for this user while a change to it was
        // waiting here). Said as such, the system stops retrying the change and, for an edit, makes the file
        // again from the local copy. As "cannot synchronize" it was retried forever and showed as stuck.
        if case FangAPI.Failure.status(404) = error {
            return NSFileProviderError(.noSuchItem)
        }
        if error.isTransientNetworkError {
            return described(.serverUnreachable, error)
        }
        if error.isServerBusy {
            return described(.cannotSynchronize, error)  // Retried later.
        }
        let nsError = error as NSError
        if nsError.domain == NSFileProviderErrorDomain || nsError.domain == NSCocoaErrorDomain {
            return error
        }
        guard let posix = error as? POSIXError else { return described(.cannotSynchronize, error) }
        switch posix.code {
        case .ENOENT:
            return NSFileProviderError(.noSuchItem)
        case .EEXIST:
            return NSFileProviderError(.filenameCollision)
        case .ENOTEMPTY:
            return NSFileProviderError(.directoryNotEmpty)
        case .ENOSPC, .EDQUOT:
            return described(.insufficientQuota, error)
        case .EACCES, .EPERM:
            return CocoaError(.fileWriteNoPermission)
        case .EXDEV:
            return CocoaError(.featureUnsupported)  // Plain SMB: an SMB rename can't cross shares.
        default:
            // File Provider only accepts its own and Cocoa errors; anything else is reported as a failure
            // to sync, which the system retries.
            return described(.cannotSynchronize, error)
        }
    }

    /// A File Provider error that carries a plain explanation, which Finder shows on the item instead of
    /// a bare "NSFileProviderErrorDomain error -2005".
    private static func described(_ code: NSFileProviderError.Code, _ error: Error) -> Error {
        NSError(domain: NSFileProviderErrorDomain, code: code.rawValue, userInfo: [
            NSLocalizedDescriptionKey: error.transferProblem,
            NSUnderlyingErrorKey: error as NSError,
        ])
    }
}
