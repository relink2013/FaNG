#if os(Linux)
import FaNGCore
import Foundation
import Glibc

/// Home folders, as Samba's `path = <homes folder>/%U`: a folder (say /mnt/pool/homes) holds one folder per
/// user, named exactly like the user. Each user sees theirs as a share called "Home", with their files directly in
/// it; nobody sees anyone else's. A folder with no matching user is left alone; a user with no folder gets one,
/// made as the host's 99:100 with the home folders' folder mask.
///
/// Inside FaNG each home is a share of its own, "~name" (scanned, watched, with its own trash and versions),
/// listed in /config/home-shares.conf for every process; its owner may read and write it (a permission rule kept
/// here). The homes folder itself isn't a share and can't overlap one (the same files would be tracked twice).
/// Off until an admin turns it on, which needs the folder chosen first. Settings in /config/homes.json; start.sh
/// reads /config/homes.conf (the folder, while on) to set up Samba's [Home] and make the folder writable.
/// A home added while FaNG runs (a new user) is served after the next restart.
enum Homes {
    static let file = ProcessInfo.processInfo.environment["FANG_HOMES_FILE"] ?? "/config/homes.json"
    static let rootFile = ProcessInfo.processInfo.environment["FANG_HOMES_ROOT_FILE"] ?? "/config/homes.conf"

    struct Settings: Codable {
        var enabled = false
        var path = ""
        var createMask: String? = "0664"
        var directoryMask: String? = "0775"
    }

    static func settings() -> Settings {
        guard let data = FileManager.default.contents(atPath: file),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return settings
    }

    /// Why the home folders can't be served from `path`, or nil.
    static func problem(_ path: String, shares: [Share]) -> String? {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return "Choose the folder that holds the home folders." }
        if Share.isUnraidRoot(path) {
            return "\(path) is /mnt or the top of a pool or disk: choose a folder inside it (like /mnt/pool/homes)."
        }
        if let share = shares.first(where: { $0.homeOwner == nil && ($0.path == path || $0.path.hasPrefix(path + "/") || path.hasPrefix($0.path + "/")) }) {
            return "The share \"\(share.name)\" (\(share.path)) overlaps the home folders. Remove it in Shares and apply: each user gets their own folder as \"Home\" instead."
        }
        guard Disk.entry(path)?.isDirectory == true else { return "\(path) isn't a folder." }
        return nil
    }

    /// Saves new settings: turning them on needs a usable folder.
    static func save(_ new: Settings, shares: [Share]) throws {
        var new = new
        new.path = new.path.trimmingCharacters(in: .whitespaces)
        while new.path.count > 1, new.path.hasSuffix("/") { new.path.removeLast() }
        for mask in [new.createMask, new.directoryMask] {
            guard let mask, mask.range(of: "^0[0-7]{3}$", options: .regularExpression) != nil else { throw Admin.Failure(reason: "Masks are like 0664.") }
        }
        if new.enabled, let problem = problem(new.path, shares: shares) { throw Admin.Failure(reason: problem) }
        let data = try JSONEncoder().encode(new)
        try data.write(to: URL(fileURLWithPath: file), options: .atomic)
        chmod(file, 0o644)
    }

    private static func writeIfChanged(_ text: String, to path: String) throws {
        guard (try? String(contentsOfFile: path, encoding: .utf8)) != text else { return }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o644)
    }

    /// Finds or makes each user's home folder, writes the home shares and the root for start.sh, and keeps the
    /// owners' permission rules. Returns user → folder, and why nothing is served if something's wrong.
    @discardableResult
    static func sync(shares: [Share], store: ItemStore) async throws -> (homes: [String: String], problem: String?) {
        let settings = settings()
        let configured = shares.filter { $0.homeOwner == nil }
        var lines = ["# ~user|home folder|create mask|directory mask (written by fang-storaged from the home folder settings)"]
        var rules: [(share: String, path: String, user: String)] = []
        var found: [String: String] = [:]
        var problem: String?
        if settings.enabled {
            problem = Self.problem(settings.path, shares: configured)
            if problem == nil {
                let create = settings.createMask ?? "0664", directory = settings.directoryMask ?? "0775"
                let names = Set(Disk.names(in: settings.path))
                for user in Admin.userList() {
                    let folder = settings.path + "/" + user.name
                    if !names.contains(user.name) {
                        try? Disk.makeFolders(folder, mode: mode_t(Int(directory, radix: 8) ?? 0o775))
                    }
                    guard Disk.entry(folder)?.isDirectory == true else { continue }
                    lines.append([Share.homeShare(of: user.name), folder, create, directory, "versions"].joined(separator: "|"))
                    rules.append((Share.homeShare(of: user.name), "", user.name))
                    found[user.name] = folder
                }
            }
        }
        try writeIfChanged(lines.joined(separator: "\n") + "\n", to: Share.homeSharesFile)
        try writeIfChanged((settings.enabled && problem == nil ? settings.path : "") + "\n", to: rootFile)
        try await store.setHomeRules(rules)
        return (found, problem)
    }
}
#endif
