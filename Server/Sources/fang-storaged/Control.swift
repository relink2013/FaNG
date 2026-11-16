#if os(Linux)
import FaNGCore
import Foundation
import Glibc

/// fang-storaged's local socket, for fang-api. One request a line, one answer a line:
///   RESOLVE <share> <path>   looks at the entry now, records it, and answers "OK <id>" or "NONE"
///   COMMIT <share> <id> <temp> <base> <modified ns> [<device> [<path the client sees>]]
///                            puts an upload in place (see `Tracker.commit`): "OK <id> <0|1 conflict> <0|1 edit won>"
///   RESTORE <version>        makes a version current again: "OK <id>"
///   TRASH <id>               moves an item into the trash: "OK <id>"
///   UNTRASH <id> [<parent>]  puts it back (into <parent> if given): "OK <id>"
///   PURGE <id>               deletes a trashed item for good: "OK <id>"
///   TAGS <id> <json array>   sets the Finder tags: "OK <id>"
///   SETTLE <id> <keep|use|copy> [<version>]
///                            resolves a conflict: "OK <id>"
///   COPY <id> <parent> [<name>]
///                            copies an item into a folder (see `Tracker.copy`): "OK <id of the copy>"
///   MOVE <id> <parent> [<name>]
///                            moves an item into a folder (see `Tracker.move`): "OK <id>"
///   JOBS                     the copies running now: "OK <json array of CopyProgress.Snapshot>"
/// Failures answer "ERROR <reason>".
/// Fields are tab-separated. The socket is only reachable inside the container.
final class Control: @unchecked Sendable {
    let path: String
    let tracker: Tracker
    let store: ItemStore

    init(path: String, tracker: Tracker, store: ItemStore) {
        self.path = path
        self.tracker = tracker
        self.store = store
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
        guard bound == 0, listen(fd, 16) == 0 else { throw POSIXError(.EIO) }
        chmod(path, 0o666)  // fang-api runs as nobody.
        // Requests that hang: logged with the step they're stuck at, and after 90 s the daemon exits so the
        // container restarts, instead of every later request waiting behind them.
        Thread.detachNewThread { [tracker] in
            while true {
                Thread.sleep(forTimeInterval: 15)
                for trace in RequestTrace.running(longerThan: 30) {
                    let age = Int(Date().timeIntervalSince(trace.started)), idle = Int(trace.idle)
                    tracker.logger.warning("\(trace.command) running for \(age) s, at: \(trace.step) (no new step for \(idle) s)")
                    if !trace.probed {
                        trace.probed = true
                        Self.probe(tracker)
                    }
                    // A long copy keeps reaching new steps (one per entry); only one that makes no progress is stuck.
                    // Not while it's in a database statement: a big one (trashing 170,000 entries) can take minutes,
                    // and exiting rolled it back halfway through the request. A database that stopped answering
                    // is caught by the database heartbeat instead.
                    if idle > 180 && !trace.step.hasPrefix("db ") || idle > 900 {
                        tracker.logger.critical("\(trace.command) made no progress for \(idle) s at: \(trace.step); exiting so the container restarts")
                        exit(1)
                    }
                }
            }
        }
        let thread = Thread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                Thread { self.serve(client) }.start()
            }
        }
        thread.name = "control"
        thread.start()
    }

    /// What a slow request may be waiting for: whether a new background task gets to run at all (the
    /// concurrency pool), whether the tracker answers, and where the process's threads wait in the kernel.
    private static func probe(_ tracker: Tracker) {
        final class Flag: @unchecked Sendable {
            let done = DispatchSemaphore(value: 0)
        }
        let pool = Flag(), actor = Flag()
        Task.detached { pool.done.signal() }
        Task.detached { _ = await tracker.ping(); actor.done.signal() }
        let poolRuns = pool.done.wait(timeout: .now() + 3) == .success
        let actorAnswers = actor.done.wait(timeout: .now() + 3) == .success
        var waits: [String: Int] = [:]
        for task in Disk.names(in: "/proc/self/task") {
            let wchan = (readSystemFile("/proc/self/task/\(task)/wchan")) ?? "?"
            let state = (readSystemFile("/proc/self/task/\(task)/stat"))?
                .split(separator: ")").last?.split(separator: " ").first.map(String.init) ?? "?"
            waits["\(state):\(wchan.isEmpty ? "-" : wchan)", default: 0] += 1
        }
        let summary = waits.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
        tracker.logger.warning("Probe: new background task runs \(poolRuns ? "yes" : "NO"), tracker answers \(actorAnswers ? "yes" : "NO"), threads \(summary)")
    }

    static let adminCommands: Set<String> = ["AUTH", "USERS", "HOMES", "HOMESET", "USERADD", "PASSWD", "USERDEL", "ADMIN", "DEVREVOKE", "SHARES",
                                             "SHARESET", "APPLY", "BROWSE", "SYSINFO"]

    private func serve(_ client: Int32) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = [UInt8]()
        var byte: UInt8 = 0
        while data.count < 256 * 1024, read(client, &byte, 1) == 1, byte != 10 {
            data.append(byte)
        }
        let fields = String(decoding: data, as: UTF8.self).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        // Answered here, not through the tracker: it's asked every second while the app shows copies.
        if fields == ["JOBS"] {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let json = (try? encoder.encode(CopyProgress.running)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            _ = "OK\t\(json)\n".utf8CString.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count - 1) }
            return
        }
        let reply = Reply()
        let started = Date()
        let trace = RequestTrace(command: fields.first ?? "?")
        RequestTrace.begin(trace)
        Task { [self] in
            reply.text = await RequestTrace.$active.withValue(trace) { await handle(fields) }
            RequestTrace.end(trace)
            reply.done.signal()
        }
        reply.done.wait()
        // Slow requests in the log (the command only: arguments can be paths), so a stall shows.
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 5 {
            tracker.logger.warning("\(fields.first ?? "?") took \(Int(elapsed)) s: \(reply.text.prefix(while: { $0 != "\t" && $0 != "\n" }))")
        }
        _ = reply.text.utf8CString.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count - 1) }
    }

    /// Hands an answer from the async side back to the blocking thread.
    private final class Reply: @unchecked Sendable {
        var text = "ERROR\n"
        let done = DispatchSemaphore(value: 0)
    }

    /// How many filesystems the watcher covers (for the admin page).
    var watcherCount = 0

    private func handle(_ fields: [String]) async -> String {
        if let command = fields.first, Self.adminCommands.contains(command) {
            return await Admin.handle(fields, tracker: tracker, watcherCount: watcherCount)
        }
        do {
            switch fields.first {
            case "COMMIT" where (6...8).contains(fields.count):
                guard let share = tracker.shares.first(where: { $0.name == fields[1] }), let id = UUID(uuidString: fields[2]),
                      let base = Int64(fields[4]), let modified = Int64(fields[5])
                else { return "ERROR\tbadrequest\n" }
                let (item, conflict, editWon) = try await tracker.commit(share, id: id, temp: fields[3], base: base, modifiedNS: modified,
                                                                device: fields.count >= 7 ? fields[6] : nil,
                                                                path: fields.count == 8 ? fields[7] : nil)
                return "OK\t\(item.id.uuidString.lowercased())\t\(conflict ? 1 : 0)\t\(editWon ? 1 : 0)\n"
            case "TRASH" where fields.count == 2:
                guard let id = UUID(uuidString: fields[1]) else { return "ERROR\tbadrequest\n" }
                let item = try await tracker.trash(id)
                return "OK\t\(item.id.uuidString.lowercased())\n"
            case "UNTRASH" where fields.count == 2 || fields.count == 3:
                guard let id = UUID(uuidString: fields[1]) else { return "ERROR\tbadrequest\n" }
                let item = try await tracker.untrash(id, into: fields.count == 3 ? UUID(uuidString: fields[2]) : nil)
                return "OK\t\(item.id.uuidString.lowercased())\n"
            case "TAGS" where fields.count == 3:
                guard let id = UUID(uuidString: fields[1]),
                      let tags = try? JSONDecoder().decode([String].self, from: Data(fields[2].utf8))
                else { return "ERROR\tbadrequest\n" }
                let item = try await tracker.setTags(id, tags)
                return "OK\t\(item.id.uuidString.lowercased())\n"
            case "XATTRS" where fields.count == 3:
                guard let id = UUID(uuidString: fields[1]),
                      let strings = try? JSONDecoder().decode([String: String].self, from: Data(fields[2].utf8))
                else { return "ERROR\tbadrequest\n" }
                let item = try await tracker.setMetadata(id, strings.compactMapValues { Data(base64Encoded: $0) })
                return "OK\t\(item.id.uuidString.lowercased())\n"
            case "STAGE" where fields.count == 3:
                guard let id = UUID(uuidString: fields[1]) else { return "ERROR\tbadrequest\n" }
                let item = try await tracker.stage(id, temp: fields[2])
                return "OK\t\(item.id.uuidString.lowercased())\n"
            case "BLOCKS" where fields.count == 3:
                // The block hashes of a file in a share, for delta transfers (the API can't read most files itself).
                guard let share = tracker.shares.first(where: { $0.name == fields[1] }) else { return "ERROR\tnotfound\n" }
                let path = fields[2]
                guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }) else {
                    return "ERROR\tbadrequest\n"
                }
                let (size, blockSize, hashes) = try await BlockHashes.of(share.path + "/" + path)
                return "OK\t\(size)\t\(blockSize)\t\(hashes.base64EncodedString())\n"
            case "SETTLE" where fields.count == 3 || fields.count == 4:
                guard let id = UUID(uuidString: fields[1]) else { return "ERROR\tbadrequest\n" }
                let item = try await tracker.resolve(id, action: fields[2], version: fields.count == 4 ? Int64(fields[3]) : nil)
                return "OK\t\(item.id.uuidString.lowercased())\n"
            case "COPY" where fields.count == 3 || fields.count == 4, "MOVE" where fields.count == 3 || fields.count == 4:
                guard let id = UUID(uuidString: fields[1]), let parent = UUID(uuidString: fields[2]) else { return "ERROR\tbadrequest\n" }
                let name = fields.count == 4 ? fields[3] : nil
                let item = fields[0] == "COPY"
                    ? try await tracker.copy(id, into: parent, name: name)
                    : try await tracker.move(id, into: parent, name: name)
                return "OK\t\(item.id.uuidString.lowercased())\n"
            case "PURGE" where fields.count == 2:
                guard let id = UUID(uuidString: fields[1]) else { return "ERROR\tbadrequest\n" }
                try await tracker.purge(id)
                return "OK\t\(id.uuidString.lowercased())\n"
            case "RESTORE" where fields.count == 2:
                guard let version = Int64(fields[1]) else { return "ERROR\tbadrequest\n" }
                let item = try await tracker.restore(version: version)
                return "OK\t\(item.id.uuidString.lowercased())\n"
            default:
                break
            }
        } catch let error as Tracker.CommitError {
            return "ERROR\t\(error.description)\n"
        } catch {
            return "ERROR\t\(String(describing: error).replacingOccurrences(of: "\n", with: " "))\n"
        }
        guard fields.count == 3, fields[0] == "RESOLVE",
              let share = tracker.shares.first(where: { $0.name == fields[1] })
        else { return "ERROR\n" }
        let path = fields[2]
        guard !path.contains("/../"), !path.hasPrefix("../"), path != "..", !path.hasPrefix("/") else { return "ERROR\n" }
        await tracker.reconcile(share, path)
        guard let item = try? await store.liveItem(share: share.name, path: path) else { return "NONE\n" }
        return "OK\t\(item.id.uuidString.lowercased())\n"
    }
}
#endif
