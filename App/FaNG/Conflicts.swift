import FaNGKit
import Observation
import SwiftUI

/// Open conflicts on every FaNG server: files where two edits started from the same version. The file
/// carries a red [CONFLICT] tag everywhere until it's resolved here (or later in the versions view).
@Observable final class Conflicts {
    struct Entry: Identifiable {
        let conflict: FangAPI.Conflict
        let api: FangAPI
        let server: String
        var id: UUID { conflict.id }
    }

    private(set) var entries: [Entry] = []
    private(set) var groups: [String] = []
    var errorMessage: String?

    func refresh() async {
        var entries: [Entry] = []
        for account in AccountStore.all() {
            guard let fang = account.fang, let token = try? CredentialStore.deviceToken(for: account),
                  let api = try? FangAPI(host: account.host, server: fang, token: token),
                  let conflicts = try? await api.conflicts()
            else { continue }
            entries += conflicts.map { Entry(conflict: $0, api: api, server: account.displayName) }
        }
        self.entries = entries
        var seen = Set<String>()
        groups = entries.map(\.conflict.group).filter { seen.insert($0).inserted }
    }

    func resolve(_ entry: Entry, _ resolution: FangAPI.Resolution) async {
        do {
            // "Use" and "copy" take the newest other edit.
            let version = resolution == .keep ? nil : entry.conflict.branches.first?.id
            _ = try await entry.api.resolve(entry.conflict.item.id, resolution, version: version)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    /// Keeps the current file for every conflict in a group.
    func keepAll(in group: String) async {
        for entry in entries where entry.conflict.group == group {
            _ = try? await entry.api.resolve(entry.conflict.item.id, .keep)
        }
        await refresh()
    }
}

struct ConflictsSection: View {
    let conflicts: Conflicts

    var body: some View {
        if !conflicts.entries.isEmpty {
            ForEach(conflicts.groups, id: \.self) { group in
                let entries = conflicts.entries.filter { $0.conflict.group == group }
                Section {
                    ForEach(entries) { entry in
                        ConflictRow(entry: entry)
                            .contextMenu {
                                Button("Keep Current Version", systemImage: "checkmark.circle") {
                                    Task { await conflicts.resolve(entry, .keep) }
                                }
                                Button("Use Other Version", systemImage: "arrow.uturn.backward.circle") {
                                    Task { await conflicts.resolve(entry, .use) }
                                }
                                Button("Keep Both", systemImage: "plus.square.on.square") {
                                    Task { await conflicts.resolve(entry, .copy) }
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text(entries.count == 1 ? "Conflict" : "\(entries.count) Related Conflicts")
                        Spacer()
                        if entries.count > 1 {
                            Button("Keep All Current") {
                                Task { await conflicts.keepAll(in: group) }
                            }
                            .font(.subheadline)
                        }
                    }
                } footer: {
                    Text("Two edits started from the same version. The newer one is the file; the other is kept as a version. Right-click (or touch and hold) to choose.")
                }
            }
        }
    }
}

private struct ConflictRow: View {
    let entry: Conflicts.Entry

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(entry.conflict.item.name)
                Text(verbatim: "\(entry.server) › \(entry.conflict.item.share)/\(entry.conflict.item.path)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let branch = entry.conflict.branches.first {
                    Text("Other edit: \(branch.created.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}
