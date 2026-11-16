import FaNGKit
import Observation
import SwiftUI

/// The app's side of iCloud sync (see `CloudSync`): when it's on, this device's servers go into iCloud
/// Keychain, and servers added on the user's other devices are added here, each signing in on its own.
@Observable final class ServerSync {
    var isEnabled = CloudSync.isEnabled
    /// Servers this device has that another device removed (offered for removal here; never removed silently,
    /// since removing a domain drops changes that haven't synced).
    private(set) var removedElsewhere: [ServerAccount] = []
    /// Servers in iCloud this device couldn't add, with why.
    private(set) var problems: [String] = []
    private(set) var isSyncing = false

    /// Publishes this device's servers and adds the ones from other devices. Returns true if servers were added.
    @discardableResult
    func sync() async -> Bool {
        guard CloudSync.isEnabled, !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        let local = AccountStore.all()
        try? CloudSync.publish(local, password: { try? CredentialStore.password(for: $0) })
        var added = false
        var problems: [String] = []
        let known = Set(local.map(\.id))
        for server in CloudSync.servers() where server.removed == nil && !known.contains(server.account.id) {
            guard let password = CloudSync.password(for: server.account) else { continue }  // Not synced yet.
            do {
                try await DomainController.add(server.account, password: password)
                added = true
            } catch {
                problems.append("\(server.account.displayName): \(error.localizedDescription)")
            }
        }
        self.problems = problems
        let removed = Set(CloudSync.servers().filter { $0.removed != nil }.map(\.account.id))
        removedElsewhere = AccountStore.all().filter { removed.contains($0.id) }
        return added
    }

    func setEnabled(_ enabled: Bool) async {
        CloudSync.isEnabled = enabled
        isEnabled = enabled
        if enabled { await sync() } else { removedElsewhere = []; problems = [] }
    }
}

struct ServerSyncSection: View {
    let sync: ServerSync
    let remove: (ServerAccount) -> Void
    @State private var confirmingClear = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { sync.isEnabled }, set: { value in Task { await sync.setEnabled(value) } })) {
                Label("Sync Servers with iCloud", systemImage: "icloud")
            }
            ForEach(sync.removedElsewhere) { account in
                HStack {
                    VStack(alignment: .leading) {
                        Text(account.displayName)
                        Text("Removed on another device")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove Here Too", role: .destructive) { remove(account) }
                        .buttonStyle(.borderless)
                }
            }
            ForEach(sync.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.subheadline)
            }
            if !sync.isEnabled {
                Button("Remove Servers from iCloud…", role: .destructive) { confirmingClear = true }
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Server addresses, user names and passwords are kept in iCloud Keychain, end-to-end encrypted, so your other devices set themselves up when you open FaNG there. Each device signs in to the server with its own key. Storage settings stay on each device.")
        }
        .confirmationDialog("Remove FaNG's servers and passwords from iCloud Keychain?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Remove from iCloud", role: .destructive) { CloudSync.clear() }
        } message: {
            Text("Devices that already have the servers keep them.")
        }
    }
}
