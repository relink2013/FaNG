#if os(Linux)
import FaNGCore
import Foundation
import Glibc

/// Hides a share from users who have nothing in it: Samba's `valid users` for each share, written to the file
/// start.sh includes in that share's section (/run/fang/shares/<name in hex>.conf), and Samba told to reload.
/// With `access based share enum` a share a user isn't valid for doesn't appear in their share list, and they
/// can't connect to it either. Kept in step with the rules and the users every two seconds.
final class ShareVisibility: @unchecked Sendable {
    static let folder = ProcessInfo.processInfo.environment["FANG_SHARE_ACCESS_FOLDER"] ?? "/run/fang/shares"
    /// A Unix group that doesn't exist ('+' names a group in `valid users`), so a share nobody may use admits no one.
    static let nobody = "+fang-nobody"

    private let shares: [Share]
    private let cache: AccessCache
    private let acl: AclService
    private var written: [String: String] = [:]

    init(shares: [Share], cache: AccessCache, acl: AclService) {
        self.shares = shares
        self.cache = cache
        self.acl = acl
    }

    static func fileName(_ share: String) -> String {
        Array(share.utf8).map { String(format: "%02x", $0) }.joined() + ".conf"
    }

    /// Writes what changed; true if Samba was told to reload.
    @discardableResult
    func update() -> Bool {
        let rules = cache.rules
        let users = acl.currentUsers()
        var changed = false
        // Samba's [Home] (path = <homes folder>/%U): everyone with a home share they may open.
        let homeOwners = Set(shares.compactMap(\.homeOwner))
        var entries = shares.filter { $0.homeOwner == nil }.map { share in
            (share.name, users.filter { rules.access(user: $0.name, share: share.name, path: "") != .none }.map(\.name))
        }
        entries.append((Share.homeName, users.filter {
            homeOwners.contains($0.name) && rules.access(user: $0.name, share: Share.homeShare(of: $0.name), path: "") != .none
        }.map(\.name)))
        for (name, valid) in entries {
            let line = "valid users = \(valid.isEmpty ? Self.nobody : valid.joined(separator: " "))\n"
            guard written[name] != line else { continue }
            let path = Self.folder + "/" + Self.fileName(name)
            if (try? line.write(toFile: path, atomically: true, encoding: .utf8)) != nil {
                chmod(path, 0o644)
                written[name] = line
                changed = true
            }
        }
        if changed { _ = try? Admin.run("smbcontrol", ["smbd", "reload-config"]) }
        return changed
    }

    func run() async {
        while !Task.isCancelled {
            update()
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
#endif
