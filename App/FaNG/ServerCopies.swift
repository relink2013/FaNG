import FaNGKit
import Observation
import SwiftUI

/// Copies the FaNG servers are making (from any device), with what each is doing, and copies that failed.
/// A copy leaves the list on its own only when it succeeds; a failed one stays until it's deleted, so an
/// empty list always means every copy worked.
@Observable final class ServerCopies {
    struct Entry: Identifiable {
        let job: FangAPI.CopyJob
        let api: FangAPI
        let server: String
        /// Items and bytes a second, from what this device saw over the last few seconds.
        var entriesPerSecond: Double?
        var bytesPerSecond: Double?
        var id: UUID { job.id }
    }

    private(set) var entries: [Entry] = []
    var errorMessage: String?

    /// What each running copy had done when, for its speed.
    private var samples: [UUID: [(time: ContinuousClock.Instant, entries: Int, bytes: Int64)]] = [:]

    var isRunning: Bool { entries.contains { $0.job.state == "copying" } }

    /// Keeps the list current while it's on screen: every second while a copy runs, otherwise every 15 s.
    func watch() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: isRunning ? .seconds(1) : .seconds(15))
        }
    }

    func refresh() async {
        var entries: [Entry] = []
        let now = ContinuousClock.now
        for account in AccountStore.all() {
            guard let fang = account.fang, let token = try? CredentialStore.deviceToken(for: account),
                  let api = try? FangAPI(host: account.host, server: fang, token: token),
                  let jobs = try? await api.copyJobs()
            else { continue }
            for job in jobs {
                var entry = Entry(job: job, api: api, server: account.displayName)
                if job.state == "copying", job.phase == "copying" {
                    var history = samples[job.id] ?? []
                    history.append((now, job.entriesDone ?? 0, job.bytesDone ?? 0))
                    history.removeAll { now - $0.time > .seconds(5) }
                    samples[job.id] = history
                    if let first = history.first, let last = history.last, last.time > first.time {
                        let seconds = Double((last.time - first.time).components.seconds)
                            + Double((last.time - first.time).components.attoseconds) / 1e18
                        entry.entriesPerSecond = Double(last.entries - first.entries) / seconds
                        entry.bytesPerSecond = Double(last.bytes - first.bytes) / seconds
                    }
                }
                entries.append(entry)
            }
        }
        samples = samples.filter { id, _ in entries.contains { $0.id == id } }
        self.entries = entries.sorted { a, b in
            a.job.state != b.job.state ? a.job.state == "failed" : (a.job.started ?? .distantPast) < (b.job.started ?? .distantPast)
        }
    }

    /// Deletes a failed copy's item (nothing of it is on the server's disk), which takes it off the list.
    func delete(_ entry: Entry) async {
        do {
            try await entry.api.delete(entry.job.item.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }
}

struct ServerCopiesSection: View {
    let copies: ServerCopies

    var body: some View {
        if !copies.entries.isEmpty {
            Section {
                ForEach(copies.entries) { entry in
                    CopyRow(entry: entry) {
                        Task { await copies.delete(entry) }
                    }
                    .contextMenu {
                        if entry.job.state == "failed" {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await copies.delete(entry) }
                            }
                        }
                    }
                    .swipeActions {
                        if entry.job.state == "failed" {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await copies.delete(entry) }
                            }
                        }
                    }
                }
            } header: {
                Text("Copies on the Server")
            } footer: {
                if copies.entries.contains(where: { $0.job.state == "failed" }) {
                    Text("A copy that failed stays here until you delete it. Nothing of it is left on the server; the original is untouched.")
                } else {
                    Text("The server makes the copy; this device doesn't need to stay open. It leaves this list once it's done.")
                }
            }
            .alert("Couldn't Delete", isPresented: .constant(copies.errorMessage != nil)) {
                Button("OK") { copies.errorMessage = nil }
            } message: {
                Text(copies.errorMessage ?? "")
            }
        }
    }
}

private struct CopyRow: View {
    let entry: ServerCopies.Entry
    let delete: () -> Void

    private var job: FangAPI.CopyJob { entry.job }
    private var failed: Bool { job.state == "failed" }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(job.item.name)
                        .lineLimit(1)
                    Spacer()
                    if failed {
                        Button("Delete", role: .destructive, action: delete)
                            .buttonStyle(.borderless)
                            .font(.subheadline)
                    }
                }
                Text(verbatim: "\(entry.server) › \(place)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if failed {
                    Text(job.error ?? "The copy failed.")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                } else {
                    running
                }
            }
        } icon: {
            Image(systemName: failed ? "exclamationmark.triangle.fill" : "plus.square.on.square")
                .foregroundStyle(failed ? Color.red : Color.accentColor)
        }
    }

    /// The folder the copy goes into.
    private var place: String {
        let folder = job.item.path.split(separator: "/").dropLast().joined(separator: "/")
        return folder.isEmpty ? job.item.share : job.item.share + "/" + folder
    }

    @ViewBuilder private var running: some View {
        switch job.phase {
        case "counting":
            ProgressView()
                .progressViewStyle(.linear)
            Text("Finding what to copy…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case "recording":
            ProgressView(value: 0.99)
            Text("Finishing up: recording \((job.entriesTotal ?? 0).formatted()) items…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        default:
            let total = max(job.entriesTotal ?? 1, 1), done = job.entriesDone ?? 0
            ProgressView(value: Double(done), total: Double(total))
            Text(verbatim: amounts(done: done, total: total))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let speed = speed {
                Text(verbatim: speed)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let current = job.current {
                Text(current)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func amounts(done: Int, total: Int) -> String {
        var text = "\(min(99, done * 100 / total))% · \(done.formatted()) of \(total.formatted()) items"
        if let bytesTotal = job.bytesTotal, bytesTotal > 0 {
            let bytesDone = job.bytesDone ?? 0
            text += " · \(bytesDone.formatted(.byteCount(style: .file))) of \(bytesTotal.formatted(.byteCount(style: .file)))"
        }
        return text
    }

    private var speed: String? {
        guard let perSecond = entry.entriesPerSecond, perSecond > 0 else { return nil }
        var parts = ["\(Int(perSecond.rounded()).formatted()) items/s"]
        if let bytes = entry.bytesPerSecond, bytes > 0 {
            parts.append("\(Int64(bytes).formatted(.byteCount(style: .file)))/s")
        }
        let left = Double(max((job.entriesTotal ?? 0) - (job.entriesDone ?? 0), 0)) / perSecond
        if left >= 1 {
            parts.append("about \(Duration.seconds(left.rounded(.up)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) left")
        }
        return parts.joined(separator: " · ")
    }
}
