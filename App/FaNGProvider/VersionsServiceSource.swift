import FaNGKit
import FileProvider
import OSLog

/// Serves the versions view (`VersionsService`) over a private connection, using this extension's own
/// connection to the FaNG server.
final class VersionsServiceSource: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate {
    let serviceName = VersionsService.name
    private let listener = NSXPCListener.anonymous()
    private let server: () throws -> FangAPI?

    init(server: @escaping () throws -> FangAPI?) {
        self.server = server
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        listener.endpoint
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = VersionsService.interface
        connection.exportedObject = VersionsServer(server: server)
        connection.resume()
        return true
    }
}

private final class VersionsServer: NSObject, VersionsServiceProtocol, @unchecked Sendable {
    private let server: () throws -> FangAPI?

    init(server: @escaping () throws -> FangAPI?) {
        self.server = server
    }

    private func api() throws -> FangAPI {
        guard let api = try server() else { throw POSIXError(.ENOTSUP) }
        return api
    }

    private func run(_ operation: String, _ work: @escaping @Sendable () async throws -> Void, failed: @escaping @Sendable (Error) -> Void) {
        // Copies and moves go in the diagnostic log, start to end (other calls only when they fail), so a
        // sheet that waits can be traced on the device.
        let traced = operation == "copy" || operation == "move"
        if traced { DiagnosticLog.note("Sheet \(operation) started") }
        let start = ContinuousClock.now
        Task {
            do {
                try await work()
                if traced { DiagnosticLog.note("Sheet \(operation) done in \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds])))") }
            } catch {
                FileProviderExtension.log.error("Versions \(operation, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                DiagnosticLog.note("Sheet \(operation) failed after \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds, .milliseconds]))): \(String(describing: error))")
                failed(VersionsService.transportable(error))
            }
        }
    }

    func history(itemID: String, reply: @escaping (Data?, Error?) -> Void) {
        run("history", { [self] in
            let api = try api()
            guard let id = UUID(uuidString: itemID), let item = try await api.item(id) else { throw POSIXError(.ENOENT) }
            let versions = try await api.versions(of: id).sorted { $0.created > $1.created }
            reply(try JSONEncoder().encode(VersionsService.History(item: item, versions: versions, device: api.device)), nil)
        }, failed: { reply(nil, $0) })
    }

    func restore(version: Int64, reply: @escaping (Error?) -> Void) {
        run("restore", { [self] in
            _ = try await api().restore(version: version)
            reply(nil)
        }, failed: { reply($0) })
    }

    func resolve(itemID: String, action: String, version: Int64, reply: @escaping (Error?) -> Void) {
        run("resolve", { [self] in
            guard let id = UUID(uuidString: itemID), let resolution = FangAPI.Resolution(rawValue: action) else {
                throw POSIXError(.EINVAL)
            }
            _ = try await api().resolve(id, resolution, version: version < 0 ? nil : version)
            reply(nil)
        }, failed: { reply($0) })
    }

    func download(version: Int64, name: String, reply: @escaping (String?, Error?) -> Void) {
        run("download", { [self] in
            guard let folder = VersionsService.downloadFolder(for: version), !name.contains("/") else { throw POSIXError(.EINVAL) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appending(path: name)
            if !FileManager.default.fileExists(atPath: file.path) {
                try await api().download(version: version, to: file)
            }
            reply(file.path, nil)
        }, failed: { reply(nil, $0) })
    }

    func items(itemIDs: [String], reply: @escaping (Data?, Error?) -> Void) {
        run("items", { [self] in
            let api = try api()
            var items: [FangItem] = []
            for id in itemIDs.compactMap(UUID.init(uuidString:)) {
                if let item = try await api.item(id), !item.deleted { items.append(item) }
            }
            reply(try JSONEncoder().encode(items), nil)
        }, failed: { reply(nil, $0) })
    }

    func children(parentID: String, reply: @escaping (Data?, Error?) -> Void) {
        run("children", { [self] in
            let api = try api()
            let items: [FangItem]
            if parentID.isEmpty {
                items = try await api.shares().compactMap(\.root)
            } else {
                guard let id = UUID(uuidString: parentID) else { throw POSIXError(.EINVAL) }
                items = try await api.children(of: id).filter { !$0.deleted && !$0.name.hasPrefix(".") }
            }
            let sorted = items.sorted { a, b in
                a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            reply(try JSONEncoder().encode(sorted), nil)
        }, failed: { reply(nil, $0) })
    }

    func thumbnail(itemID: String, version: Int64, reply: @escaping (Data?, Error?) -> Void) {
        run("thumbnail", { [self] in
            let api = try api()
            if version >= 0 {
                reply(try await api.thumbnail(version: version), nil)
            } else {
                guard let id = UUID(uuidString: itemID) else { throw POSIXError(.EINVAL) }
                reply(try await api.thumbnail(id), nil)
            }
        }, failed: { reply(nil, $0) })
    }

    func transfer(operation: String, itemIDs: [String], parentID: String, reply: @escaping (Data?, Error?) -> Void) {
        run(operation, { [self] in
            let api = try api()
            guard operation == "copy" || operation == "move", let parent = UUID(uuidString: parentID) else { throw POSIXError(.EINVAL) }
            var results: [FangItem] = []
            for id in itemIDs.compactMap(UUID.init(uuidString:)) {
                do {
                    if operation == "copy" {
                        // Not retried: a copy that reached the server before the connection dropped would be made twice.
                        results.append(try await api.copy(id, into: parent))
                    } else {
                        do {
                            results.append(try await api.move(id, into: parent))
                        } catch where (error as? POSIXError).map({ $0.code != .ETIMEDOUT }) ?? (error is URLError) {
                            // A connection that dropped (iOS tears down idle sockets): once more on a fresh one.
                            // Safe for a move: one that already happened answers with the item where it is now.
                            FileProviderExtension.log.notice("Move retried after \(String(describing: error), privacy: .public)")
                            DiagnosticLog.note("Sheet move retried after \(String(describing: error))")
                            results.append(try await api.move(id, into: parent))
                        }
                    }
                } catch POSIXError.ETIMEDOUT {
                    throw TransferRefused(message: "The server didn't answer in time. If it's still working on it, the result shows up when it's done; otherwise try again.")
                } catch FangAPI.Failure.status(409) {
                    throw TransferRefused(message: operation == "copy"
                        ? "A folder can't be copied into itself, and an item that's still being copied can't be copied yet."
                        : "A folder can't be moved into itself, an item that's still being copied can't be moved yet, and a file that changed during the move stays where it was. Try again.")
                } catch FangAPI.Failure.status(404) {
                    throw TransferRefused(message: "The item or the folder isn't on the server any more.")
                }
            }
            reply(try JSONEncoder().encode(results), nil)
        }, failed: { reply(nil, $0) })
    }
}

/// A copy or move the server refused, with a message for the sheet.
private struct TransferRefused: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
