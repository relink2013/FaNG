import Foundation

/// A folder FaNG serves over SMB under `name`. New files and folders get the host owner and exactly
/// these modes (on Unraid, the share's own `create mask` / `directory mask`).
public struct Share: Hashable, Sendable, Codable {
    public var name: String
    /// The folder inside the container.
    public var path: String
    public var createMask: Int
    public var directoryMask: Int
    /// Keep the old contents as a version whenever a file changes through FaNG (off by default).
    /// Conflict branches are kept either way.
    public var versions: Bool

    public init(name: String, path: String, createMask: Int, directoryMask: Int, versions: Bool = false) {
        self.name = name
        self.path = path
        self.createMask = createMask
        self.directoryMask = directoryMask
        self.versions = versions
    }

    /// Reads the shares file: one share a line, `name|path|create mask|directory mask[|options]` with
    /// octal masks and comma-separated options (`versions`). Blank lines and lines starting with `#` are
    /// skipped.
    public static func parse(_ text: String) throws -> [Share] {
        try text.split(separator: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count == 4 || fields.count == 5, !fields[0].isEmpty, fields[1].hasPrefix("/"),
                  let create = Int(fields[2], radix: 8), let directory = Int(fields[3], radix: 8)
            else { throw ParseError(line: line) }
            let options = fields.count == 5 ? Set(fields[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) : []
            return Share(name: fields[0], path: fields[1], createMask: create, directoryMask: directory,
                         versions: options.contains("versions"))
        }
    }

    /// Why a share can't be served right now, or nil if it can: its folder is missing (a pool not mounted, or
    /// the stack's mount changed), it isn't writable (start.sh makes only shares writable, so a share whose
    /// mount couldn't be set up stays read-only and isn't served), or it's /mnt itself or a pool's or disk's
    /// root: on Unraid every top-level folder of a pool becomes a user share, so FaNG never writes there.
    public var problem: String? { problem(needsWritableMount: true) }

    /// `needsWritableMount` false for fang-thumbs, which has the shares read-only by design.
    public func problem(needsWritableMount: Bool) -> String? {
        if Share.isUnraidRoot(path) {
            return "\(path) is /mnt or the top of a pool or disk; share a folder inside it"
        }
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return "\(path) doesn't exist in the container" }
        if needsWritableMount {
            var fs = statvfs()
            guard statvfs(path, &fs) == 0, fs.f_flag & UInt(ST_RDONLY) == 0 else {
                return "\(path) is on a read-only mount (start.sh couldn't make it writable)"
            }
        }
        return nil
    }

    /// /mnt, or a folder directly in it (/mnt/cache, /mnt/disk1, /mnt/user …).
    public static func isUnraidRoot(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.first == "mnt" && parts.count <= 2
    }

    // MARK: Home folders

    /// What every user calls their home share (Samba's `[Home]`, `path = <homes folder>/%U`).
    public static let homeName = "Home"
    /// The home shares fang-storaged keeps (one per user with a home folder), in the shares file's format.
    public static let homeSharesFile = ProcessInfo.processInfo.environment["FANG_HOME_SHARES_FILE"] ?? "/config/home-shares.conf"

    /// A user's home share inside FaNG: "~name". Users can't have "~" in their names, so it never clashes.
    public static func homeShare(of user: String) -> String { "~" + user }
    public var homeOwner: String? { name.hasPrefix("~") ? String(name.dropFirst()) : nil }

    /// The shares file's shares and the home shares.
    public static func loadAll(sharesFile: String) throws -> [Share] {
        let shares = try parse(String(contentsOfFile: sharesFile, encoding: .utf8))
        let homes = (try? parse(String(contentsOfFile: homeSharesFile, encoding: .utf8))) ?? []
        return shares + homes.filter { $0.homeOwner != nil }
    }

    /// The name a user sees for a share: their own home share is "Home".
    public static func presented(_ name: String, to user: String?) -> String {
        guard let user, name == homeShare(of: user) else { return name }
        return homeName
    }

    /// The share a user means: "Home" is their own home share.
    public static func meant(_ name: String, by user: String?) -> String {
        guard let user, name == homeName else { return name }
        return homeShare(of: user)
    }

    public struct ParseError: Error, CustomStringConvertible {
        public var line: String
        public var description: String { "Bad share line: \(line)" }
    }
}

/// Who the current API request is for, so items going out name that user's home share "Home" (and every other
/// share as it is). Unset everywhere else: fang-storaged and the database always use the real names.
public enum SharePresentation {
    @TaskLocal public static var user: String?
}
