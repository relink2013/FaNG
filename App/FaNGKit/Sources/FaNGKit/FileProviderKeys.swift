import Foundation

/// Keys FaNG puts in a File Provider item's `userInfo`, so the File Provider UI extension's actions can show
/// up only where they apply (their activation rules test these).
public enum FileProviderKeys {
    /// The item is on a FaNG server (it has versions; plain SMB has none).
    public static let fang = "fang"
    /// The item has an open conflict (it carries the red [CONFLICT] tag).
    public static let conflict = "conflict"
    /// The server can copy or move the item (FaNG-server files and folders, not shares or trashed items):
    /// "Copy To…" and "Move To…".
    public static let transfer = "transfer"
    /// A server copy is making the item; `progress` is how far it is, in percent (decorations show both).
    public static let copying = "copying"
    public static let progress = "progress"
    /// The server copy that was making the item failed: it can only be deleted.
    public static let copyFailed = "copyFailed"

    /// The Finder tag a FaNG server puts on a file with an open conflict ("name\ncolor"; 6 is red).
    public static let conflictTag = "[CONFLICT]\n6"
}

extension FangAPI {
    /// The API of the FaNG server behind a File Provider domain, signed in as this device; nil for a
    /// plain-SMB domain or one that isn't signed in.
    public static func forDomain(_ identifier: String) throws -> FangAPI? {
        guard let account = AccountStore.account(domainIdentifier: identifier), let fang = account.fang,
              let token = try CredentialStore.deviceToken(for: account)
        else { return nil }
        return try FangAPI(host: account.host, server: fang, token: token)
    }
}
