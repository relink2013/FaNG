import FaNGKit
import Observation
import SwiftUI

/// Where each FaNG server's own storage goes (trash, versions, thumbnails, database), with the rules that keep
/// each one from growing without bound, so used space always has an explanation.
@Observable final class ServerStorage {
    struct Entry: Identifiable {
        let server: String
        let report: FangAPI.StorageReport
        var id: String { server }
    }

    private(set) var entries: [Entry] = []

    func refresh() async {
        var entries: [Entry] = []
        for account in AccountStore.all() {
            guard let fang = account.fang, let token = try? CredentialStore.deviceToken(for: account),
                  let api = try? FangAPI(host: account.host, server: fang, token: token),
                  let report = try? await api.storage()
            else { continue }
            entries.append(Entry(server: account.displayName, report: report))
        }
        self.entries = entries
    }
}

struct ServerStorageSection: View {
    let storage: ServerStorage

    var body: some View {
        ForEach(storage.entries) { entry in
            Section {
                row("Trash", "trash", entry.report.trash, rule: "Emptied after \(entry.report.trashDays) days")
                row("Versions", "clock.arrow.circlepath", entry.report.versions,
                    rule: entry.report.versionDays > 0
                        ? "Thinned over time, kept up to \(entry.report.versionDays) days"
                        : "Thinned over time, monthly ones kept")
                row("Thumbnails", "photo.on.rectangle", entry.report.thumbnails, rule: "One per distinct file; removed with their files")
                LabeledContent {
                    Text(entry.report.databaseBytes.formatted(.byteCount(style: .file)))
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Database")
                            Text("\(entry.report.deletedRecords.formatted()) records of deleted items, kept \(entry.report.deletedRecordDays) days")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "cylinder.split.1x2")
                    }
                }
            } header: {
                Text("\(entry.server) Storage")
            } footer: {
                Text("What the server keeps besides your files, and how long. Everything here is cleaned up on its own.")
            }
        }
    }

    private func row(_ title: String, _ symbol: String, _ part: FangAPI.StorageReport.Part, rule: String) -> some View {
        LabeledContent {
            Text(part.bytes.formatted(.byteCount(style: .file)))
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(title)
                    Text("\(part.items.formatted()) items · \(rule)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
            }
        }
    }
}
