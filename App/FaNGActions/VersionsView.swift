import FaNGKit
import FileProvider
import Observation
import os
import QuickLook
import SwiftUI

/// One file's history on the FaNG server: the file as it is, its earlier versions, and conflicting edits
/// that didn't become the file. Everything here is the server's, so it's the same on every device. The File
/// Provider extension fetches it (`VersionsService`); this extension never uses the network itself.
@Observable final class VersionsModel {
    enum State {
        case loading
        case failed(String)
        case loaded
    }

    let domainIdentifier: String
    let itemID: String
    let done: () -> Void

    private(set) var state = State.loading
    private(set) var item: FangItem?
    private(set) var versions: [FangAPI.VersionInfo] = []
    private(set) var thisDevice: String?
    private(set) var busy = false
    var errorMessage: String?
    /// A downloaded version being previewed (Quick Look).
    var preview: URL?
    private var client: VersionsClient?

    init(domainIdentifier: String, itemID: String, done: @escaping () -> Void) {
        self.domainIdentifier = domainIdentifier
        self.itemID = itemID
        self.done = done
    }

    var openBranches: [FangAPI.VersionInfo] { versions.filter(\.isOpenBranch) }
    var history: [FangAPI.VersionInfo] { versions.filter { !$0.isOpenBranch } }

    private static let log = Logger(subsystem: "com.rlx.fang.actions", category: "versions")

    func load() async {
        Self.log.notice("Versions for item \(self.itemID, privacy: .public) in domain \(self.domainIdentifier, privacy: .public)")
        do {
            guard let manager = try await manager(),
                  let id = await Self.serverID(for: itemID, manager: manager)
            else {
                state = .failed("Versions are kept by a FaNG server, and this item isn't one of its files.")
                return
            }
            let client = try await VersionsClient(manager: manager, item: id)
            self.client = client
            let history = try await client.history(itemID: id.uuidString)
            item = history.item
            versions = history.versions
            thisDevice = history.device
            state = .loaded
        } catch {
            Self.log.error("Versions failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    private func manager() async throws -> NSFileProviderManager? {
        try await NSFileProviderManager.domains()
            .first { $0.identifier.rawValue == domainIdentifier }
            .flatMap { NSFileProviderManager(for: $0) }
    }

    /// FaNG's ID for the item. Finder passes the system's own identifier instead ("__fp/fs/docID(…)");
    /// the file's place on disk leads back to FaNG's.
    static func serverID(for identifier: String, manager: NSFileProviderManager) async -> UUID? {
        if let id = UUID(uuidString: identifier) { return id }
        do {
            let url = try await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(identifier))
            let (resolved, _) = try await NSFileProviderManager.identifierForUserVisibleFile(at: url)
            return UUID(uuidString: resolved.rawValue)
        } catch {
            log.error("Couldn't resolve \(identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The version's contents become the file again. The file as it is now is kept as a version.
    func restore(_ version: FangAPI.VersionInfo) async {
        await run { client in try await client.restore(version: version.id) }
    }

    /// Settles the conflict: keep the file as it is, use the other edit, or keep both (the other edit
    /// goes next to the file as a copy). The red tag goes away on every device.
    func resolve(_ resolution: FangAPI.Resolution, with version: FangAPI.VersionInfo?) async {
        guard let id = item?.id else { return }
        await run { client in try await client.resolve(itemID: id.uuidString, resolution, version: version?.id) }
    }

    /// The file's thumbnail (`version` nil) or a version's, from the server.
    func thumbnail(of version: FangAPI.VersionInfo?) async -> Data? {
        await client?.thumbnail(item: item?.id, version: version?.id)
    }

    func showPreview(of version: FangAPI.VersionInfo) async {
        guard let client, let item else { return }
        busy = true
        defer { busy = false }
        do {
            preview = try await client.download(version: version.id, name: item.name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func run(_ work: (VersionsClient) async throws -> Void) async {
        guard let client else { return }
        busy = true
        defer { busy = false }
        do {
            try await work(client)
            // The File Provider extension picks the change up from the server's events; this makes it now.
            try? await manager()?.signalEnumerator(for: .workingSet)
            done()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The File Provider extension's `VersionsService`, with async calls.
final class VersionsClient {
    private let connection: NSXPCConnection

    init(manager: NSFileProviderManager, item: UUID) async throws {
        let service: NSFileProviderService? = try await withCheckedThrowingContinuation { continuation in
            manager.getService(named: VersionsService.name, for: NSFileProviderItemIdentifier(item.uuidString)) { service, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: service) }
            }
        }
        guard let service else { throw POSIXError(.ENOTSUP) }
        let connection: NSXPCConnection = try await withCheckedThrowingContinuation { continuation in
            service.getFileProviderConnection { connection, error in
                if let connection { continuation.resume(returning: connection) } else { continuation.resume(throwing: error ?? POSIXError(.ENOTCONN)) }
            }
        }
        connection.remoteObjectInterface = VersionsService.interface
        connection.resume()
        self.connection = connection
    }

    deinit {
        connection.invalidate()
    }

    /// No answer within `timeout` seconds (nil: none, for downloads of whole versions) fails the call, so the
    /// sheet never waits forever on an extension the system suspended or a request that's stuck.
    private func call<T>(timeout: TimeInterval? = 45, _ body: (VersionsServiceProtocol, Once<T>) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ once.fail($0) }) as? VersionsServiceProtocol else {
                return once.fail(POSIXError(.ENOTCONN))
            }
            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.fail(NoAnswer()) }
            }
            body(proxy, once)
        }
    }

    struct NoAnswer: LocalizedError {
        var errorDescription: String? {
            "FaNG didn't answer in time. If the server got the request, the result shows up when it's done; otherwise try again."
        }
    }

    func history(itemID: String) async throws -> VersionsService.History {
        let data: Data = try await call { proxy, once in
            proxy.history(itemID: itemID) { data, error in
                if let data { once.succeed(data) } else { once.fail(error ?? POSIXError(.EIO)) }
            }
        }
        let decoder = JSONDecoder()
        return try decoder.decode(VersionsService.History.self, from: data)
    }

    func restore(version: Int64) async throws {
        try await call { (proxy, once: Once<Void>) in
            proxy.restore(version: version) { error in
                if let error { once.fail(error) } else { once.succeed(()) }
            }
        }
    }

    func resolve(itemID: String, _ resolution: FangAPI.Resolution, version: Int64?) async throws {
        try await call { (proxy, once: Once<Void>) in
            proxy.resolve(itemID: itemID, action: resolution.rawValue, version: version ?? -1) { error in
                if let error { once.fail(error) } else { once.succeed(()) }
            }
        }
    }

    func items(_ ids: [String]) async throws -> [FangItem] {
        let data: Data = try await call { proxy, once in
            proxy.items(itemIDs: ids) { data, error in
                if let data { once.succeed(data) } else { once.fail(error ?? POSIXError(.EIO)) }
            }
        }
        return try JSONDecoder().decode([FangItem].self, from: data)
    }

    /// What's in `parentID` ("" for the shares), folders first.
    func children(of parentID: String) async throws -> [FangItem] {
        let data: Data = try await call { proxy, once in
            proxy.children(parentID: parentID) { data, error in
                if let data { once.succeed(data) } else { once.fail(error ?? POSIXError(.EIO)) }
            }
        }
        return try JSONDecoder().decode([FangItem].self, from: data)
    }

    /// An item's thumbnail, or a version's; nil if there's none.
    func thumbnail(item: UUID?, version: Int64?) async -> Data? {
        try? await call { (proxy, once: Once<Data?>) in
            proxy.thumbnail(itemID: item?.uuidString ?? "", version: version ?? -1) { data, error in
                if let error { once.fail(error) } else { once.succeed(data) }
            }
        }
    }

    func transfer(_ operation: String, _ ids: [String], into parentID: String) async throws -> [FangItem] {
        // Each item may take one 2-minute request, and a move one more after a dropped connection.
        let data: Data = try await call(timeout: 30 + 250 * Double(max(ids.count, 1))) { proxy, once in
            proxy.transfer(operation: operation, itemIDs: ids, parentID: parentID) { data, error in
                if let data { once.succeed(data) } else { once.fail(error ?? POSIXError(.EIO)) }
            }
        }
        return try JSONDecoder().decode([FangItem].self, from: data)
    }

    func download(version: Int64, name: String) async throws -> URL {
        let path: String = try await call(timeout: nil) { proxy, once in
            proxy.download(version: version, name: name) { path, error in
                if let path { once.succeed(path) } else { once.fail(error ?? POSIXError(.EIO)) }
            }
        }
        return URL(filePath: path)
    }
}

/// A continuation that can be finished by the reply or by a broken connection, whichever comes first.
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.withLock { defer { continuation = nil }; return continuation }
    }

    func succeed(_ value: T) { take()?.resume(returning: value) }

    func fail(_ error: Error) { take()?.resume(throwing: error) }
}

struct VersionsView: View {
    @State var model: VersionsModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.item?.name ?? "Versions")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { model.done() }
                    }
                }
                .overlay {
                    if model.busy { ProgressView().controlSize(.large) }
                }
                .disabled(model.busy)
                .alert("Couldn't Do That", isPresented: .constant(model.errorMessage != nil)) {
                    Button("OK") { model.errorMessage = nil }
                } message: {
                    Text(model.errorMessage ?? "")
                }
                .quickLookPreview($model.preview)
        }
        #if os(macOS)
        // The toolbar's Done isn't drawn in Finder's sheet; this one always is.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done") { model.done() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 520)
        #endif
        .task { await model.load() }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView("No Versions", systemImage: "clock.arrow.circlepath", description: Text(message))
        case .loaded:
            List {
                if !model.openBranches.isEmpty {
                    conflictSection
                }
                if let item = model.item {
                    Section("Current") {
                        VersionRow(title: "This file", saved: item.mtimeNS, size: item.size, detail: nil,
                                   thumbnailKey: "item-\(item.id)-\(item.contentVersion)") { await model.thumbnail(of: nil) }
                    }
                }
                Section {
                    if model.history.isEmpty {
                        Text("No earlier versions yet. FaNG keeps one each time the file is replaced.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.history, id: \.id) { version in
                        VStack(alignment: .leading, spacing: 8) {
                            VersionRow(title: version.created.formatted(date: .abbreviated, time: .shortened),
                                       saved: version.mtimeNS, size: version.size, detail: label(for: version),
                                       thumbnailKey: "version-\(version.id)") { await model.thumbnail(of: version) }
                            HStack {
                                Button("Preview") { Task { await model.showPreview(of: version) } }
                                Spacer()
                                Button("Restore") { Task { await model.restore(version) } }
                            }
                            .buttonStyle(.bordered)
                        }
                        .contextMenu { menu(for: version) }
                    }
                } header: {
                    Text("Earlier Versions")
                } footer: {
                    Text("Restoring keeps the file as it is now as a version, so nothing is lost.")
                }
            }
        }
    }

    private var conflictSection: some View {
        Section {
            ForEach(model.openBranches, id: \.id) { branch in
                VStack(alignment: .leading, spacing: 8) {
                    VersionRow(title: "Other edit", saved: branch.mtimeNS, size: branch.size, detail: label(for: branch),
                               thumbnailKey: "version-\(branch.id)") { await model.thumbnail(of: branch) }
                    HStack {
                        Button("Preview") { Task { await model.showPreview(of: branch) } }
                        Spacer()
                        Button("Use This") { Task { await model.resolve(.use, with: branch) } }
                        Button("Keep Both") { Task { await model.resolve(.copy, with: branch) } }
                    }
                    .buttonStyle(.bordered)
                }
            }
            Button("Keep Current File", systemImage: "checkmark.circle") {
                Task { await model.resolve(.keep, with: nil) }
            }
        } header: {
            Label("Conflict", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } footer: {
            Text("Two edits started from the same version. The newer one became the file; the other is kept here. Choose which to keep. Keep Both puts the other edit next to the file as a copy.")
        }
    }

    @ViewBuilder private func menu(for version: FangAPI.VersionInfo) -> some View {
        Button("Preview", systemImage: "eye") { Task { await model.showPreview(of: version) } }
        Button("Restore", systemImage: "clock.arrow.circlepath") { Task { await model.restore(version) } }
    }

    private func label(for version: FangAPI.VersionInfo) -> String? {
        switch version.device {
        case nil: nil
        case "server": version.kind == "branch" ? "The file before the other edit" : nil
        case model.thisDevice: "From this device"
        default: "From another device"
        }
    }
}

private struct VersionRow: View {
    let title: String
    let saved: Int64
    let size: Int64
    let detail: String?
    let thumbnailKey: String
    let thumbnail: () async -> Data?

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(key: thumbnailKey, isDirectory: false, side: 48, load: thumbnail)
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text("Saved \(Date(timeIntervalSince1970: Double(saved) / 1e9).formatted(date: .abbreviated, time: .shortened)) · \(size.formatted(.byteCount(style: .file)))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
