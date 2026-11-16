import FaNGKit
import FileProvider
import Observation
import os
import SwiftUI

/// "Copy To…" and "Move To…": pick a folder on the FaNG server, and the server copies or moves the items
/// there itself (reflinks where it can), so no bytes travel through this device. As with the versions view,
/// the File Provider extension does the work (`VersionsService`); this extension never uses the network.
@Observable final class TransferModel {
    enum Operation: String {
        case copy, move

        var verb: String { self == .copy ? "Copy" : "Move" }
    }

    enum State {
        case loading
        case failed(String)
        case ready
    }

    let operation: Operation
    let domainIdentifier: String
    let itemIdentifiers: [String]
    let done: () -> Void
    /// Shows a folder, with these items in it selected (macOS), in Finder or Files; false if it couldn't.
    let reveal: (_ folder: URL, _ items: [URL]) async -> Bool

    private(set) var state = State.loading
    /// What's being copied or moved.
    private(set) var items: [FangItem] = []
    /// Where the picker is: the folders from a share's top folder down. Empty: the list of shares.
    private(set) var location: [FangItem] = []
    /// What's in the current folder: folders (to open) first, then files (shown, not chosen).
    private(set) var entries: [FangItem] = []
    private(set) var loadingFolders = false
    private(set) var busy = false
    var errorMessage: String?

    /// "Show Completed Transfer": open the destination when it's done. Remembered on this device.
    var showCompleted: Bool {
        didSet { Self.defaults?.set(showCompleted, forKey: Self.showCompletedKey) }
    }

    private var client: VersionsClient?
    private var manager: NSFileProviderManager?
    private var cache: [String: [FangItem]] = [:]

    private static let log = Logger(subsystem: "com.rlx.fang.actions", category: "transfer")
    private static let defaults = UserDefaults(suiteName: FaNGKit.appGroupIdentifier)
    private static let showCompletedKey = "showCompletedTransfer"

    init(operation: Operation, domainIdentifier: String, itemIdentifiers: [String], done: @escaping () -> Void, reveal: @escaping (_ folder: URL, _ items: [URL]) async -> Bool) {
        self.operation = operation
        self.domainIdentifier = domainIdentifier
        self.itemIdentifiers = itemIdentifiers
        self.done = done
        self.reveal = reveal
        showCompleted = Self.defaults?.object(forKey: Self.showCompletedKey) as? Bool ?? true
    }

    var title: String {
        let what = items.count == 1 ? "“\(items[0].name)”" : "\(items.count) Items"
        return "\(operation.verb) \(what) To"
    }

    /// The folder the items would go into: the picker's current folder (not the list of shares).
    var destination: FangItem? { location.last }

    /// Done copies or moves into the current folder; a move into the folder the items are already in does nothing.
    var canFinish: Bool {
        guard let destination, !busy else { return false }
        if operation == .move, items.allSatisfy({ $0.parent == destination.id }) { return false }
        return !isInsideItems(destination)
    }

    func load() async {
        do {
            guard let manager = try await NSFileProviderManager.domains()
                .first(where: { $0.identifier.rawValue == domainIdentifier })
                .flatMap({ NSFileProviderManager(for: $0) })
            else { throw POSIXError(.ENOENT) }
            self.manager = manager
            var ids: [UUID] = []
            for identifier in itemIdentifiers {
                if let id = await VersionsModel.serverID(for: identifier, manager: manager) { ids.append(id) }
            }
            guard let first = ids.first else {
                state = .failed("Only items on a FaNG server can be copied or moved by the server.")
                return
            }
            let client = try await VersionsClient(manager: manager, item: first)
            self.client = client
            items = try await client.items(ids.map(\.uuidString))
            guard let item = items.first else { throw POSIXError(.ENOENT) }
            // Start in the folder the first item is in, as Finder would.
            var chain: [FangItem] = []
            var parent = item.parent
            while let id = parent, chain.count < 64, let folder = try await client.items([id.uuidString]).first {
                chain.insert(folder, at: 0)
                parent = folder.parent
            }
            location = chain
            state = .ready
            await loadFolders()
        } catch {
            Self.log.error("Transfer sheet failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    func open(_ folder: FangItem) async {
        location.append(folder)
        await loadFolders()
    }

    /// Goes up to `index` in the path (-1: the list of shares).
    func goUp(to index: Int) async {
        location = Array(location.prefix(index + 1))
        await loadFolders()
    }

    private func loadFolders() async {
        let key = destination?.id.uuidString ?? ""
        if let cached = cache[key] {
            entries = cached
            return
        }
        guard let client else { return }
        entries = []
        loadingFolders = true
        defer { loadingFolders = false }
        do {
            let listed = try await client.children(of: key)
            cache[key] = listed
            if (destination?.id.uuidString ?? "") == key { entries = listed }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// True for one of the items being copied or moved, or a folder inside one: they can't be the destination.
    func isInsideItems(_ folder: FangItem) -> Bool {
        // A folder a server copy is still making (or failed to make) can't take anything yet.
        if folder.jobState != nil { return true }
        return items.contains { item in
            item.isDirectory && item.share == folder.share && (folder.path == item.path || folder.path.hasPrefix(item.path + "/"))
        }
    }

    func thumbnail(of item: FangItem) async -> Data? {
        await client?.thumbnail(item: item.id, version: nil)
    }

    func finish() async {
        guard let client, let destination, canFinish else { return }
        busy = true
        defer { busy = false }
        let start = ContinuousClock.now
        func elapsed() -> String { (ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds])) }
        // Both ends of the sheet's call go in the diagnostic log, so a wait can be placed: here or in the extension.
        DiagnosticLog.note("Sheet asked for \(operation.rawValue) of \(items.count) items")
        do {
            let results = try await client.transfer(operation.rawValue, items.map(\.id.uuidString), into: destination.id.uuidString)
            DiagnosticLog.note("Sheet got the \(operation.rawValue) answer after \(elapsed())")
            Self.log.notice("\(self.operation.rawValue, privacy: .public) of \(results.count) items done")
            // The File Provider extension picks the change up from the server's events; this makes it now.
            try? await manager?.signalEnumerator(for: .workingSet)
            if showCompleted, let manager {
                await revealDestination(destination, results: results, manager: manager)
            }
            done()
        } catch {
            DiagnosticLog.note("Sheet \(operation.rawValue) error after \(elapsed()): \(String(describing: error))")
            errorMessage = error.localizedDescription
        }
    }

    /// Shows the copied or moved items in their new folder. They reach this device a moment after the
    /// server made them; waits up to 3 s for that, then shows the folder alone.
    private func revealDestination(_ folder: FangItem, results: [FangItem], manager: NSFileProviderManager) async {
        do {
            let folderURL = try await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(folder.id.uuidString))
            var itemURLs: [URL] = []
            #if os(macOS)
            let deadline = ContinuousClock.now + .seconds(3)
            while itemURLs.count < results.count, ContinuousClock.now < deadline {
                itemURLs = []
                for item in results {
                    guard let url = try? await manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(item.id.uuidString)),
                          url.deletingLastPathComponent().standardizedFileURL == folderURL.standardizedFileURL
                    else { break }
                    itemURLs.append(url)
                }
                if itemURLs.count < results.count { try? await Task.sleep(for: .milliseconds(250)) }
            }
            if itemURLs.count < results.count { itemURLs = [] }
            #endif
            if !(await reveal(folderURL, itemURLs)) {
                Self.log.error("Couldn't show the destination folder")
            }
        } catch {
            Self.log.error("No location for the destination: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct TransferView: View {
    @State var model: TransferModel

    var body: some View {
        // The footer sits below the browser, not over it, so the last row can always be reached.
        VStack(spacing: 0) {
            browser
            Divider()
            footer
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 480)
        #endif
        .task { await model.load() }
    }

    private var browser: some View {
        NavigationStack {
            content
                // Only the browser: Cancel stays available while the server works, so the sheet can always close.
                .disabled(model.busy)
                .navigationTitle(model.items.isEmpty ? "\(model.operation.verb) To" : model.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.done() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(model.operation.verb) { Task { await model.finish() } }
                            .disabled(!model.canFinish)
                    }
                }
                #endif
                .overlay {
                    if model.busy {
                        ProgressView(model.operation == .copy ? "Copying…" : "Moving…").controlSize(.large)
                    }
                }
                .alert("Couldn't \(model.operation.verb)", isPresented: .constant(model.errorMessage != nil)) {
                    Button("OK") { model.errorMessage = nil }
                } message: {
                    Text(model.errorMessage ?? "")
                }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
        case .failed(let message):
            ContentUnavailableView("Can't \(model.operation.verb)", systemImage: "folder.badge.questionmark", description: Text(message))
        case .ready:
            VStack(spacing: 0) {
                pathBar
                Divider()
                List {
                    if model.loadingFolders {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else if model.entries.isEmpty {
                        Text(model.destination == nil ? "No shares." : "This folder is empty.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.entries, id: \.id) { entry in
                        if entry.isDirectory {
                            let blocked = model.isInsideItems(entry)
                            Button {
                                Task { await model.open(entry) }
                            } label: {
                                HStack(spacing: 10) {
                                    ThumbnailView(key: entry.id.uuidString, isDirectory: true, side: 32) { nil }
                                    Text(entry.name)
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(blocked)
                            .opacity(blocked ? 0.4 : 1)
                        } else {
                            // Files show what's in the folder; only folders can be chosen.
                            HStack(spacing: 10) {
                                ThumbnailView(key: "item-\(entry.id)-\(entry.contentVersion)", isDirectory: false, side: 32) {
                                    await model.thumbnail(of: entry)
                                }
                                Text(entry.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    /// Where the picker is, each step a button that goes back up to it.
    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button("Shares") { Task { await model.goUp(to: -1) } }
                    .disabled(model.location.isEmpty)
                ForEach(Array(model.location.enumerated()), id: \.element.id) { index, folder in
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    Button(folder.name) { Task { await model.goUp(to: index) } }
                        .disabled(index == model.location.count - 1)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show Completed Transfer", isOn: $model.showCompleted)
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
            if let destination = model.destination {
                Text("Into “\(destination.name)”").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Choose a folder.").font(.subheadline).foregroundStyle(.secondary)
            }
            #if os(macOS)
            // Finder's sheet draws no toolbar, so its buttons are here.
            HStack {
                Spacer()
                Button("Cancel") { model.done() }
                    .keyboardShortcut(.cancelAction)
                Button(model.operation.verb) { Task { await model.finish() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canFinish)
            }
            #endif
        }
        .padding()
        .background(.bar)
    }
}
