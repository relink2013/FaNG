import FaNGKit
import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var accounts = AccountStore.all()
    @State private var isAddingServer = false
    @State private var errorMessage: String?
    @State private var pending = PendingItems()
    @State private var conflicts = Conflicts()
    @State private var copies = ServerCopies()
    @State private var serverSync = ServerSync()
    @State private var storage = ServerStorage()

    var body: some View {
        NavigationStack {
            Group {
                if accounts.isEmpty {
                    ContentUnavailableView {
                        Label("No Servers", systemImage: "externaldrive.connected.to.line.below")
                    } description: {
                        Text("Connect to an SMB server to use its shares in \(Self.filesAppName).")
                    } actions: {
                        Button("Add Server") { isAddingServer = true }
                            .buttonStyle(.borderedProminent)
                        if !serverSync.isEnabled {
                            Button("Set Up from iCloud") { Task { await serverSync.setEnabled(true); reload() } }
                        }
                    }
                } else {
                    List {
                        Section {
                            ForEach(accounts) { account in
                                AccountRow(account: account)
                                    .contextMenu {
                                        Button("Remove", systemImage: "trash", role: .destructive) { remove(account) }
                                    }
                                    .swipeActions {
                                        Button("Remove", systemImage: "trash", role: .destructive) { remove(account) }
                                    }
                            }
                        } footer: {
                            Text("Each server appears in \(Self.filesAppName) under its name, with a folder for every share.")
                        }
                        ConflictsSection(conflicts: conflicts)
                        ServerCopiesSection(copies: copies)
                        SyncStatusSection(pending: pending)
                        ServerStorageSection(storage: storage)
                        ServerSyncSection(sync: serverSync, remove: remove)
                        #if os(macOS)
                        BackgroundSection()
                        #endif
                    }
                }
            }
            .navigationTitle("FaNG")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Server", systemImage: "plus") { isAddingServer = true }
                }
            }
            .task { await pending.watch() }
            .task { await conflicts.refresh() }
            .task { await copies.watch() }
            .sheet(isPresented: $isAddingServer, onDismiss: reload) {
                AddServerView()
            }
            .alert("Couldn't Remove Server", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                Task {
                    if await serverSync.sync() { reload() }
                    await storage.refresh()
                    await DomainController.refreshAll()
                    await DomainController.retryFailedTransfers()
                    await pending.refresh()
                    await conflicts.refresh()
                }
            }
        }
    }

    private func reload() {
        accounts = AccountStore.all()
        LiveUpdates.shared.refresh()
    }

    private func remove(_ account: ServerAccount) {
        Task {
            do {
                try await DomainController.remove(account)
            } catch {
                errorMessage = error.localizedDescription
            }
            reload()
        }
    }

    static var filesAppName: String {
        #if os(macOS)
        "Finder"
        #else
        "the Files app"
        #endif
    }
}

/// Everything that hasn't synced yet, so a stuck upload never goes unnoticed.
private struct SyncStatusSection: View {
    let pending: PendingItems

    var body: some View {
        if pending.isLoaded {
            Section {
                if pending.entries.isEmpty {
                    Label("Everything is synced", systemImage: "checkmark.icloud")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pending.entries) { entry in
                        PendingRow(entry: entry)
                            .contextMenu {
                                if entry.key != nil {
                                    Button("Remove from List", systemImage: "xmark.circle") {
                                        Task { await pending.remove(entry) }
                                    }
                                }
                            }
                            .swipeActions {
                                if entry.key != nil {
                                    Button("Remove", systemImage: "xmark.circle") {
                                        Task { await pending.remove(entry) }
                                    }
                                }
                            }
                    }
                }
            } header: {
                HStack {
                    Text("Not Synced")
                    Spacer()
                    if !pending.entries.isEmpty {
                        Button("Retry Now") {
                            Task { await DomainController.retryFailedTransfers() }
                        }
                        .font(.subheadline)
                    }
                }
            } footer: {
                if !pending.entries.isEmpty {
                    Text("These files haven't reached the server yet, or are still downloading. Failed transfers are retried automatically and carry on where they stopped.")
                }
            }
        }
    }
}

private struct PendingRow: View {
    let entry: PendingItems.Entry

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(entry.name)
                Text(entry.place)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(entry.problem ?? (entry.isUpload ? "Uploading" : "Waiting to download"))
                    .font(.subheadline)
                    .foregroundStyle(entry.problem == nil ? Color.secondary : Color.red)
            }
        } icon: {
            Image(systemName: entry.problem != nil ? "exclamationmark.icloud" : entry.isUpload ? "icloud.and.arrow.up" : "icloud.and.arrow.down")
                .foregroundStyle(entry.problem == nil ? Color.secondary : Color.red)
        }
    }
}

private struct AccountRow: View {
    let account: ServerAccount

    var body: some View {
        VStack(alignment: .leading) {
            Text(account.displayName)
                .font(.headline)
            Text(verbatim: "\(account.username)@\(account.host)\(account.port == 445 ? "" : ":\(account.port)")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label(account.fang != nil ? "FaNG server" : "Plain SMB", systemImage: account.fang != nil ? "server.rack" : "externaldrive.connected.to.line.below")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#if os(macOS)
/// Opening at login keeps the app's live connection running, so Finder shows other devices' changes at once.
private struct BackgroundSection: View {
    @State private var opensAtLogin = LiveUpdates.opensAtLogin

    var body: some View {
        Section {
            Toggle("Open FaNG at Login", isOn: $opensAtLogin)
                .onChange(of: opensAtLogin) { _, value in
                    LiveUpdates.opensAtLogin = value
                    opensAtLogin = LiveUpdates.opensAtLogin
                }
        } header: {
            Text("Live Updates")
        } footer: {
            Text("While FaNG runs, even with its window closed, changes made on other devices show up in Finder within a second. Without it, they show up when Finder next asks the server.")
        }
    }
}
#endif

#Preview {
    ContentView()
}
