import FaNGKit
import FileProvider
import Foundation

/// Adds and removes accounts, keeping the File Provider domain, keychain item and saved account in step.
enum DomainController {
    static func domain(for account: ServerAccount) -> NSFileProviderDomain {
        NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(account.domainIdentifier), displayName: account.displayName)
    }

    /// Adds the account as a domain. A FaNG server behind the login is found here, and this device signs
    /// in to its API (see `FangSignIn`); otherwise the domain works against plain SMB.
    static func add(_ account: ServerAccount, password: String) async throws {
        var account = account
        let backend = try SMBBackend(account: account, password: password)
        if let server = await FangSignIn.detect(on: backend) {
            let token = try await FangSignIn.signIn(on: backend)
            account.fang = server
            try CredentialStore.setDeviceToken(token, for: account)
        }
        try CredentialStore.setPassword(password, for: account)
        AccountStore.save(account)
        do {
            try await NSFileProviderManager.add(domain(for: account))
        } catch {
            AccountStore.remove(account)
            CredentialStore.removePassword(for: account)
            throw error
        }
        if CloudSync.isEnabled {
            try? CloudSync.publish([account], password: { _ in password })
        }
    }

    static func remove(_ account: ServerAccount) async throws {
        try await NSFileProviderManager.remove(domain(for: account))
        if CloudSync.isEnabled {
            try? CloudSync.markRemoved(account)
        }
        AccountStore.remove(account)
        CredentialStore.removePassword(for: account)
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FaNGKit.appGroupIdentifier) {
            try? FileManager.default.removeItem(at: container.appending(path: "Domains/\(account.domainIdentifier)"))
        }
    }

    /// Asks every domain to look for server changes. Plain SMB has no push, so the app does this when it opens.
    static func refreshAll() async {
        guard let domains = try? await NSFileProviderManager.domains() else { return }
        for domain in domains {
            try? await NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet)
        }
    }

    /// Ends the system's back-off for transfers that failed with a temporary error (server unreachable or
    /// busy), so they're retried right away instead of minutes or hours later.
    static func retryFailedTransfers() async {
        guard let domains = try? await NSFileProviderManager.domains() else { return }
        for domain in domains {
            guard let manager = NSFileProviderManager(for: domain) else { continue }
            try? await manager.signalErrorResolved(NSFileProviderError(.serverUnreachable))
            try? await manager.signalErrorResolved(NSFileProviderError(.cannotSynchronize))
        }
    }
}
