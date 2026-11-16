#if os(Linux)
import FaNGCore
import Foundation
import Glibc

/// Answers Samba's FaNG module (`fang:acl socket`): the ACL of an item, from FaNG's permission rules, one
/// line per request ("GET\t<share>\t<path>" → "OK\t<SDDL>"). Every SMB open asks, so it answers from memory:
/// the rules (`AccessCache`) and FaNG's users (/config/users, read again when it changes). An ACL set from a
/// client is accepted and ignored (permissions are set in FaNG's admin page).
final class AclService: @unchecked Sendable {
    private let path: String
    private let cache: AccessCache
    private let usersFile: String
    private let lock = NSLock()
    private var users: [(name: String, uid: Int)] = []
    private var usersStamp: Date?

    /// Owner and group as before (the host's 99:100), and SYSTEM.
    private static let head = "O:S-1-22-1-99G:S-1-22-2-100D:P(A;OICI;FA;;;SY)"

    init(path: String, cache: AccessCache, usersFile: String) {
        self.path = path
        self.cache = cache
        self.usersFile = usersFile
    }

    /// The ACL for an item: an entry per FaNG user with what the rules give them there.
    func sddl(share: String, path: String) -> String {
        let rules = cache.rules
        var sddl = Self.head
        for user in currentUsers() {
            switch rules.access(user: user.name, share: share, path: path) {
            case .write: sddl += "(A;;FA;;;S-1-22-1-\(user.uid))"
            case .read: sddl += "(A;;0x1200a9;;;S-1-22-1-\(user.uid))"
            case .none: break
            }
        }
        return sddl
    }

    private var usersChecked = Date.distantPast

    /// FaNG's users, the file looked at again at most every two seconds (every SMB open asks).
    func currentUsers() -> [(name: String, uid: Int)] {
        let now = Date()
        if lock.withLock({ now.timeIntervalSince(usersChecked) < 2 }) { return lock.withLock { users } }
        var st = stat()
        let stamp: Date? = stat(usersFile, &st) == 0 ? Date(timeIntervalSince1970: Double(st.st_mtim.tv_sec) + Double(st.st_mtim.tv_nsec) / 1e9) : nil
        return lock.withLock {
            usersChecked = now
            if stamp != usersStamp {
                usersStamp = stamp
                users = ((try? String(contentsOfFile: usersFile, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line in
                    let fields = line.split(separator: ":")
                    guard fields.count == 2, let uid = Int(fields[1]) else { return nil }
                    return (String(fields[0]), uid)
                }
            }
            return users
        }
    }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            _ = path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buffer.count - 1))) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 256) == 0 else { throw POSIXError(.EIO) }
        // smbd runs a session as its user when it asks, so everyone in the container may connect. It only answers
        // what the rules allow (an ACL set through it is ignored), so that reveals nothing a session can't see.
        chmod(path, 0o666)
        let thread = Thread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                // A thread of its own: each smbd process keeps its connection open, idle most of the time.
                Thread { self.serve(client) }.start()
            }
        }
        thread.name = "acl"
        thread.start()
    }

    /// Answers requests on one connection until the other side closes it (each smbd process keeps one open).
    private func serve(_ client: Int32) {
        defer { close(client) }
        var buffer = [UInt8](repeating: 0, count: 16384)
        var pending = [UInt8]()
        while true {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { return }
            pending += buffer[0..<count]
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                let reply = answer(line) + "\n"
                let sent = reply.utf8CString.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count - 1) }
                if sent <= 0 { return }
            }
            if pending.count > 256 * 1024 { return }
        }
    }

    private func answer(_ line: String) -> String {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        switch fields.first {
        case "GET" where fields.count == 3:
            let path = fields[2] == "." ? "" : (fields[2].hasPrefix("./") ? String(fields[2].dropFirst(2)) : fields[2])
            return "OK\t" + sddl(share: fields[1], path: path)
        case "SET":
            return "OK"
        default:
            return "ERROR"
        }
    }
}
#endif
