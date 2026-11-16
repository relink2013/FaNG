#if os(Linux)
import FaNGCore
import Foundation
import Glibc

/// The admin page's commands that need root: sign-in against Samba's password database, FaNG's users and
/// their devices, the shares file, browsing the folders FaNG can see, and system figures. Answers are JSON.
/// Passwords arrive base64-encoded and are never logged.
enum Admin {
    static let usersFile = ProcessInfo.processInfo.environment["FANG_USERS_FILE"] ?? "/config/users"
    static let adminsFile = ProcessInfo.processInfo.environment["FANG_ADMINS_FILE"] ?? "/config/admins"
    static let devicesFolder = ProcessInfo.processInfo.environment["FANG_DEVICES_FOLDER"] ?? "/config/fang-share/devices"
    static let sharesFile = ProcessInfo.processInfo.environment["FANG_SHARES_FILE"] ?? "/config/shares.conf"
    /// What the file browser shows: /mnt when the host's pools are mounted there, otherwise the shares' folder.
    static let browseRoot: String = {
        if let root = ProcessInfo.processInfo.environment["FANG_BROWSE_ROOT"], !root.isEmpty { return root }
        return FileManager.default.fileExists(atPath: "/mnt") && !Disk.names(in: "/mnt").isEmpty ? "/mnt" : "/shares"
    }()
    static let started = Date()

    struct Failure: Error { var reason: String }

    static func handle(_ fields: [String], tracker: Tracker, watcherCount: Int) async -> String {
        do {
            let answer: Any
            switch fields.first {
            case "AUTH" where fields.count == 3:
                answer = ["user": fields[1], "admin": try authenticate(fields[1], decode(fields[2]))]
            case "USERS":
                answer = users()
            case "USERADD" where fields.count == 4:
                try addUser(fields[1], password: decode(fields[2]), admin: fields[3] == "1")
                // Their home folder (when home folders are on): found or made, and theirs to read and write.
                try await Homes.sync(shares: tracker.shares, store: tracker.store)
                answer = ["ok": true]
            case "PASSWD" where fields.count == 3:
                try setPassword(fields[1], decode(fields[2]))
                answer = ["ok": true]
            case "USERDEL" where fields.count == 2:
                try removeUser(fields[1])
                // Their home folder stays, with nobody given it.
                try await Homes.sync(shares: tracker.shares, store: tracker.store)
                answer = ["ok": true]
            case "HOMES":
                answer = try await homesAnswer(tracker: tracker)
            case "HOMESET" where fields.count == 2:
                guard let new = try? JSONDecoder().decode(Homes.Settings.self, from: Data(decode(fields[1]).utf8)) else {
                    throw Failure(reason: "bad settings")
                }
                try Homes.save(new, shares: tracker.shares)
                answer = try await homesAnswer(tracker: tracker)
            case "ADMIN" where fields.count == 3:
                try setAdmin(fields[1], fields[2] == "1")
                answer = ["ok": true]
            case "DEVREVOKE" where fields.count == 2:
                guard fields[1].count == 64, fields[1].allSatisfy(\.isHexDigit) else { throw Failure(reason: "bad device") }
                guard unlink(devicesFolder + "/" + fields[1]) == 0 else { throw Failure(reason: "no such device") }
                answer = ["ok": true]
            case "SHARES":
                answer = ["shares": sharesFileEntries(served: Set(tracker.shares.map(\.name))), "browseRoot": browseRoot]
            case "SHARESET" where fields.count == 2:
                try writeShares(decode(fields[1]))
                answer = ["ok": true]
            case "APPLY":
                // The container restarts with the new shares (start.sh ends when fang-storaged does).
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { exit(0) }
                answer = ["ok": true]
            case "ADDRESS" where fields.count == 2:
                guard let address = try? JSONDecoder().decode(ServerAddress.self, from: Data(decode(fields[1]).utf8)) else {
                    throw Failure(reason: "bad address")
                }
                try publish(address)
                answer = ["ok": true]
            case "BROWSE" where fields.count == 2:
                answer = try browse(decode(fields[1]))
            case "SYSINFO":
                answer = await sysinfo(tracker: tracker, watcherCount: watcherCount)
            default:
                throw Failure(reason: "badrequest")
            }
            let data = try JSONSerialization.data(withJSONObject: answer, options: [.sortedKeys])
            return "OK\t" + String(decoding: data, as: UTF8.self) + "\n"
        } catch let failure as Failure {
            return "ERROR\t\(failure.reason)\n"
        } catch {
            return "ERROR\t\(String(describing: error).replacingOccurrences(of: "\n", with: " "))\n"
        }
    }

    /// The home folder settings for the admin page: each user's home, why none are served (if so), and whether
    /// FaNG has to restart to serve them as they're set now.
    private static func homesAnswer(tracker: Tracker) async throws -> [String: Any] {
        let settings = Homes.settings()
        let (homes, problem) = try await Homes.sync(shares: tracker.shares, store: tracker.store)
        let served = Set(tracker.shares.compactMap(\.homeOwner))
        return ["enabled": settings.enabled, "path": settings.path, "homes": homes, "problem": problem as Any,
                "createMask": settings.createMask ?? "0664", "directoryMask": settings.directoryMask ?? "0775",
                "served": served.sorted(), "needsRestart": Set(homes.keys) != served]
    }

    static let serverFile = ProcessInfo.processInfo.environment["FANG_SERVER_FILE"] ?? "/config/fang-share/server.json"

    /// Writes the server's public and SMB addresses into `fang$/server.json`, next to the certificate fingerprint
    /// and port start.sh put there (which stay: installed apps read only those).
    static func publish(_ address: ServerAddress) throws {
        guard let data = FileManager.default.contents(atPath: serverFile),
              var json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure(reason: "server.json is missing") }
        json["url"] = address.url
        json["smb"] = address.smb
        let text = String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        try (text + "\n").write(toFile: serverFile, atomically: true, encoding: .utf8)
        chmod(serverFile, 0o644)
    }

    private static func decode(_ base64: String) throws -> String {
        guard let data = Data(base64Encoded: base64) else { throw Failure(reason: "bad encoding") }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Users

    static func userList() -> [(name: String, uid: Int)] {
        ((try? String(contentsOfFile: usersFile, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
            let fields = line.split(separator: ":")
            guard fields.count == 2, let uid = Int(fields[1]) else { return nil }
            return (String(fields[0]), uid)
        }
    }

    static func admins() -> Set<String> {
        Set(((try? String(contentsOfFile: adminsFile, encoding: .utf8)) ?? "").split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty })
    }

    private static func writeAdmins(_ names: Set<String>) throws {
        try (names.sorted().joined(separator: "\n") + "\n").write(toFile: adminsFile, atomically: true, encoding: .utf8)
        chmod(adminsFile, 0o644)
    }

    private static func users() -> [[String: Any]] {
        let admins = admins()
        let homes = Homes.settings()
        var devices: [Int: [[String: Any]]] = [:]
        for name in Disk.names(in: devicesFolder) where name.count == 64 {
            var st = stat()
            guard lstat(devicesFolder + "/" + name, &st) == 0 else { continue }
            devices[Int(st.st_uid), default: []].append(["id": name, "added": Double(st.st_mtim.tv_sec)])
        }
        return userList().map { user in
            ["name": user.name, "uid": user.uid, "admin": admins.contains(user.name), "devices": devices[user.uid] ?? [],
             "homesOn": homes.enabled]
        }
    }

    static func validName(_ name: String) -> Bool {
        name.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil
    }

    private static func addUser(_ name: String, password: String, admin: Bool) throws {
        guard validName(name) else { throw Failure(reason: "Names are lowercase letters, digits, - and _ (up to 32).") }
        guard password.count >= 8 else { throw Failure(reason: "Passwords need at least 8 characters.") }
        let existing = userList()
        guard !existing.contains(where: { $0.name == name }) else { throw Failure(reason: "That user exists already.") }
        let uid = max(1999, existing.map(\.uid).max() ?? 1999) + 1
        try run("/usr/sbin/useradd", ["--uid", "\(uid)", "--gid", "100", "--no-create-home", "--shell", "/usr/sbin/nologin", name])
        try run("smbpasswd", ["-s", "-a", name], input: password + "\n" + password + "\n")
        let line = "\(name):\(uid)\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: usersFile))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
        if admin { try writeAdmins(admins().union([name])) }
    }

    private static func setPassword(_ name: String, _ password: String) throws {
        guard userList().contains(where: { $0.name == name }) else { throw Failure(reason: "No such user.") }
        guard password.count >= 8 else { throw Failure(reason: "Passwords need at least 8 characters.") }
        try run("smbpasswd", ["-s", name], input: password + "\n" + password + "\n")
    }

    private static func removeUser(_ name: String) throws {
        let list = userList()
        guard let user = list.first(where: { $0.name == name }) else { throw Failure(reason: "No such user.") }
        let remaining = admins().subtracting([name])
        guard !remaining.isEmpty || !admins().contains(name) else { throw Failure(reason: "The last admin can't be removed.") }
        try? run("smbpasswd", ["-x", name])
        try? run("/usr/sbin/userdel", [name])
        try (list.filter { $0.name != name }.map { "\($0.name):\($0.uid)" }.joined(separator: "\n") + "\n")
            .write(toFile: usersFile, atomically: true, encoding: .utf8)
        chmod(usersFile, 0o644)
        try writeAdmins(remaining)
        // Their devices can't sign in any more.
        for device in Disk.names(in: devicesFolder) {
            var st = stat()
            if lstat(devicesFolder + "/" + device, &st) == 0, Int(st.st_uid) == user.uid { unlink(devicesFolder + "/" + device) }
        }
    }

    private static func setAdmin(_ name: String, _ admin: Bool) throws {
        guard userList().contains(where: { $0.name == name }) else { throw Failure(reason: "No such user.") }
        var set = admins()
        if admin { set.insert(name) } else {
            set.remove(name)
            guard !set.isEmpty else { throw Failure(reason: "There has to be at least one admin.") }
        }
        try writeAdmins(set)
    }

    /// Checks a password against Samba's database (the NT hash, MD4 of the UTF-16LE password). Returns whether
    /// the user is an admin; throws if the password is wrong.
    private static func authenticate(_ name: String, _ password: String) throws -> Bool {
        guard validName(name), userList().contains(where: { $0.name == name }) else { throw Failure(reason: "denied") }
        let output = (try? run("pdbedit", ["-w", "-u", name])) ?? ""
        let fields = output.split(separator: ":")
        guard fields.count > 3 else { throw Failure(reason: "denied") }
        let stored = fields[3].lowercased()
        let computed = MD4.hash(Array(password.utf16).flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
            .map { String(format: "%02x", $0) }.joined()
        // Constant-time comparison.
        guard stored.count == computed.count, zip(stored.utf8, computed.utf8).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
            throw Failure(reason: "denied")
        }
        return admins().contains(name)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], input: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool.hasPrefix("/") ? tool : "/usr/bin/env")
        process.arguments = tool.hasPrefix("/") ? arguments : [tool] + arguments
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(reason: String(decoding: err, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? "\(tool) failed")
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: Shares

    private static func sharesFileEntries(served: Set<String>) -> [[String: Any]] {
        ((try? String(contentsOfFile: sharesFile, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let f = trimmed.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4 else { return nil }
            let share = Share(name: f[0], path: f[1], createMask: 0, directoryMask: 0)
            // A share saved since FaNG started is set up (made writable, watched) when it restarts.
            let problem = served.contains(share.name) ? nil
                : share.problem(needsWritableMount: false) ?? "saved, not in use yet: Apply restarts FaNG with it"
            return ["name": f[0], "path": f[1], "createMask": f[2], "directoryMask": f[3],
                    "versions": f.count > 4 && f[4].contains("versions"), "problem": problem as Any]
        }
    }

    /// Writes the shares file (applied on the next start). Paths must exist under the browse root, can't be
    /// Unraid's user-share FUSE mounts (no change events, no reflinks), and shares can't overlap.
    private static func writeShares(_ json: String) throws {
        guard let list = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { throw Failure(reason: "bad shares") }
        var lines = ["# name|path in the container|create mask|directory mask|options (written by FaNG's admin page)"]
        var paths: [String] = []
        for entry in list {
            guard let name = entry["name"] as? String, name.range(of: "^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$", options: .regularExpression) != nil,
                  let path = entry["path"] as? String, path.hasPrefix("/"), !path.contains("|"), !path.contains("/../")
            else { throw Failure(reason: "Share names are letters, digits, space . _ - (up to 64), paths absolute.") }
            guard name != Share.homeName else {
                throw Failure(reason: "\"\(Share.homeName)\" is every user's own home folder (set in Users); choose another share name.")
            }
            let homes = Homes.settings()
            if homes.enabled, !homes.path.isEmpty, path == homes.path || path.hasPrefix(homes.path + "/") || homes.path.hasPrefix(path + "/") {
                throw Failure(reason: "\(path) overlaps the home folders (\(homes.path)), which every user sees as their own \"Home\". Turn home folders off in Users first to share it.")
            }
            for blocked in ["/mnt/user", "/mnt/user0", "/mnt/disks", "/mnt/remotes", "/mnt/addons", "/mnt/rootshare"] where path == blocked || path.hasPrefix(blocked + "/") {
                throw Failure(reason: "\(blocked) can't be shared by FaNG (Unraid's user shares and mounts don't report changes or allow reflinks): use the pool or disk path instead.")
            }
            // On Unraid every top-level folder of a pool or disk is a user share: FaNG writes only inside one.
            guard !Share.isUnraidRoot(path) else {
                throw Failure(reason: "\(path) is /mnt or the top of a pool or disk. Share a folder inside it (an existing share's folder, like /mnt/pool/Photos): FaNG never writes at the top level, where new folders become Unraid user shares.")
            }
            // A folder that isn't there now (a pool not mounted, or the stack's mount changed) can stay listed: it
            // isn't served until it's there, and the Shares page says so. Something else at that path can't.
            if let entry = Disk.entry(path), !entry.isDirectory { throw Failure(reason: "\(path) isn't a folder.") }
            if paths.contains(where: { $0 == path || $0.hasPrefix(path + "/") || path.hasPrefix($0 + "/") }) {
                throw Failure(reason: "Shares can't be inside one another.")
            }
            paths.append(path)
            let create = entry["createMask"] as? String ?? "0664", directory = entry["directoryMask"] as? String ?? "0775"
            guard create.range(of: "^0[0-7]{3}$", options: .regularExpression) != nil,
                  directory.range(of: "^0[0-7]{3}$", options: .regularExpression) != nil else { throw Failure(reason: "Masks are like 0664.") }
            lines.append([name, path, create, directory, (entry["versions"] as? Bool ?? false) ? "versions" : ""].joined(separator: "|"))
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: sharesFile, atomically: true, encoding: .utf8)
        chmod(sharesFile, 0o644)
    }

    // MARK: Browsing

    private static func browse(_ requested: String) throws -> [String: Any] {
        let path = (requested.isEmpty ? browseRoot : requested).replacingOccurrences(of: "//", with: "/")
        guard path == browseRoot || path.hasPrefix(browseRoot + "/"), !path.split(separator: "/").contains("..") else {
            throw Failure(reason: "outside")
        }
        guard Disk.entry(path)?.isDirectory == true else { throw Failure(reason: "not a folder") }
        var entries: [[String: Any]] = []
        let names = Disk.names(in: path).filter { !Tracker.isInternal($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in names.prefix(5000) {
            guard let entry = Disk.entry(path + "/" + name) else { continue }
            entries.append(["name": name, "dir": entry.isDirectory, "size": entry.size, "mtime": Double(entry.mtimeNS) / 1e9])
        }
        return ["path": path, "root": browseRoot, "entries": entries, "total": names.count]
    }

    // MARK: System

    private static func sysinfo(tracker: Tracker, watcherCount: Int) async -> [String: Any] {
        func read(_ file: String) -> String { (readSystemFile(file) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var sessions: [[String: Any]] = []
        if let json = try? run("smbstatus", ["-b", "--json"]),
           let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           let list = object["sessions"] as? [String: [String: Any]] {
            for session in list.values {
                sessions.append(["user": session["username"] as? String ?? "", "machine": session["remote_machine"] as? String ?? "",
                                 "encryption": (session["encryption"] as? [String: Any])?["cipher"] as? String ?? ""])
            }
        }
        let scan = await tracker.lastScan
        return [
            "uptime": Date().timeIntervalSince(started),
            "load": read("/proc/loadavg").split(separator: " ").prefix(3).map(String.init),
            "cpus": Resources.cpus,
            "memoryLimit": Resources.memory,
            "memoryUsed": Int64(read("/sys/fs/cgroup/memory.current")) ?? 0,
            "filesystems": watcherCount,
            "sessions": sessions,
            "lastScan": scan.map { ["at": $0.at.timeIntervalSince1970, "seconds": $0.seconds, "entries": $0.entries,
                                    "uploadTemps": $0.uploadTemps, "uploadBytes": $0.uploadBytes] } ?? [:],
            "workers": ["scan": Tracker.scanThreads, "copy": Copier.workers],
        ]
    }
}

/// MD4 (RFC 1320), for checking passwords against Samba's NT hashes. Not for anything else.
enum MD4 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in 0..<8 { data.append(UInt8((bitLength >> (8 * UInt64(i))) & 0xff)) }
        var a: UInt32 = 0x67452301, b: UInt32 = 0xefcdab89, c: UInt32 = 0x98badcfe, d: UInt32 = 0x10325476
        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
        for chunk in stride(from: 0, to: data.count, by: 64) {
            var x = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                x[i] = UInt32(data[chunk + 4 * i]) | UInt32(data[chunk + 4 * i + 1]) << 8
                    | UInt32(data[chunk + 4 * i + 2]) << 16 | UInt32(data[chunk + 4 * i + 3]) << 24
            }
            let (aa, bb, cc, dd) = (a, b, c, d)
            func f(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (~x & z) }
            func g(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (x & z) | (y & z) }
            func h(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }
            for i in [0, 4, 8, 12] {
                a = rotl(a &+ f(b, c, d) &+ x[i], 3); d = rotl(d &+ f(a, b, c) &+ x[i + 1], 7)
                c = rotl(c &+ f(d, a, b) &+ x[i + 2], 11); b = rotl(b &+ f(c, d, a) &+ x[i + 3], 19)
            }
            for i in [0, 1, 2, 3] {
                a = rotl(a &+ g(b, c, d) &+ x[i] &+ 0x5a827999, 3); d = rotl(d &+ g(a, b, c) &+ x[i + 4] &+ 0x5a827999, 5)
                c = rotl(c &+ g(d, a, b) &+ x[i + 8] &+ 0x5a827999, 9); b = rotl(b &+ g(c, d, a) &+ x[i + 12] &+ 0x5a827999, 13)
            }
            for i in [0, 2, 1, 3] {
                a = rotl(a &+ h(b, c, d) &+ x[i] &+ 0x6ed9eba1, 3); d = rotl(d &+ h(a, b, c) &+ x[i + 8] &+ 0x6ed9eba1, 9)
                c = rotl(c &+ h(d, a, b) &+ x[i + 4] &+ 0x6ed9eba1, 11); b = rotl(b &+ h(c, d, a) &+ x[i + 12] &+ 0x6ed9eba1, 15)
            }
            a = a &+ aa; b = b &+ bb; c = c &+ cc; d = d &+ dd
        }
        return [a, b, c, d].flatMap { v in (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
    }
}
#endif
