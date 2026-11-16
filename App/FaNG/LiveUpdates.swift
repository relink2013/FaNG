import FaNGKit
import FileProvider
import Foundation
#if os(macOS)
import ServiceManagement
#endif

/// Live changes while the app runs. The File Provider extension listens to the server only while the system
/// keeps it running, and the system ends it soon after it goes idle; without push notifications (they need a
/// paid developer account) nothing would wake it for a change made elsewhere. So the app keeps one WebSocket
/// per FaNG server open too, and on each change asks the system to sync that server's domain, which brings
/// the extension back to fetch exactly what changed (through the sync anchor).
///
/// On macOS the app keeps running with its window closed and can open at login, so a Mac stays current all
/// the time. iOS doesn't let an app keep a connection in the background; there the extension's own socket
/// covers the time Files is in use, and APNs File Provider pushes (paid account) would cover the rest.
final class LiveUpdates: @unchecked Sendable {
    static let shared = LiveUpdates()

    private let lock = NSLock()
    private var watchers: [UUID: Task<Void, Never>] = [:]

    /// Starts a watcher for every FaNG server that has none, and stops the ones whose server was removed.
    func refresh() {
        let accounts = AccountStore.all().filter { $0.fang != nil }
        lock.withLock {
            for (id, task) in watchers where !accounts.contains(where: { $0.id == id }) {
                task.cancel()
                watchers[id] = nil
            }
            for account in accounts where watchers[account.id] == nil {
                watchers[account.id] = Task.detached { await Self.watch(account) }
            }
        }
    }

    private static func watch(_ account: ServerAccount) async {
        var known: Int64?
        var pause: Duration = .seconds(5)
        while !Task.isCancelled {
            // The account as saved now (the server's addresses may have been learned since the last round).
            var account = AccountStore.account(domainIdentifier: account.domainIdentifier) ?? account
            if let fang = account.fang, let token = try? CredentialStore.deviceToken(for: account),
               let api = try? FangAPI(host: account.host, server: fang, token: token) {
                // The server's public name and SMB address, if its admin set or changed them: saved for the
                // app and the extensions, which use them the next time they connect.
                if let info = try? await api.serverInfo(), account.take(info) {
                    AccountStore.save(account)
                }
                do {
                    for try await latest in api.events() {
                        if let previous = known, latest > previous { await signal(account) }
                        if known == nil { await signal(account) }  // Connected (again): catch up once.
                        known = latest
                        pause = .seconds(5)
                    }
                } catch {}
            }
            try? await Task.sleep(for: pause)
            pause = min(pause * 2, .seconds(300))
        }
    }

    private static func signal(_ account: ServerAccount) async {
        guard let manager = NSFileProviderManager(for: DomainController.domain(for: account)) else { return }
        try? await manager.signalEnumerator(for: .workingSet)
    }

    #if os(macOS)
    /// Whether FaNG opens at login (and so keeps this Mac current from the start).
    static var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
    #endif
}
