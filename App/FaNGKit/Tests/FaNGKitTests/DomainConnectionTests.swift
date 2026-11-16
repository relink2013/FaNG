import Foundation
import Testing
@testable import FaNGKit

/// An in-memory server. Every new file gets a new file ID, like a new inode.
actor FakeBackend: FileBackend {
    private struct Entry {
        var isDirectory: Bool
        var data: Data
        var fileID: UInt64
        var modified: Date
    }

    private var entries: [String: Entry] = [:]
    private var nextFileID: UInt64 = 1

    /// Offsets uploads started from, in order.
    private(set) var uploadOffsets: [Int64] = []
    /// Paths removed, in order.
    private(set) var removed: [String] = []
    /// The next `failingUploads` uploads write this many bytes, then fail like a dropped connection.
    private var failingUploads = 0
    private var failAfterBytes = 0

    /// Paths another session holds open: writing, renaming or removing them fails as busy.
    private var held: Set<String> = []

    func hold(_ path: String) { held.insert(path) }

    private func checkNotHeld(_ paths: String...) throws {
        if paths.contains(where: held.contains) { throw POSIXError(.ETXTBSY) }
    }

    func failUploads(_ count: Int, afterBytes bytes: Int) {
        failingUploads = count
        failAfterBytes = bytes
    }

    func contents(_ path: String) -> Data? { entries[path]?.data }
    func exists(_ path: String) -> Bool { entries[path] != nil }
    var paths: [String] { entries.keys.sorted() }

    func put(_ path: String, _ text: String, modified: Date = Date()) {
        put(path, Data(text.utf8), modified: modified)
    }

    func put(_ path: String, _ data: Data, modified: Date = Date()) {
        entries[path] = Entry(isDirectory: false, data: data, fileID: newID(), modified: modified)
    }

    private func newID() -> UInt64 {
        defer { nextFileID += 1 }
        return nextFileID
    }

    private func item(_ path: String, _ entry: Entry) -> RemoteItem {
        RemoteItem(path: path, name: RemotePath.name(of: path), isDirectory: entry.isDirectory, size: Int64(entry.data.count),
                   modified: entry.modified, created: entry.modified, fileID: entry.fileID)
    }

    func list(_ path: String) throws -> [RemoteItem] {
        guard path.isEmpty || entries[path]?.isDirectory == true else { throw POSIXError(.ENOENT) }
        return entries.filter { RemotePath.parent(of: $0.key) == path && !RemotePath.isInternal(RemotePath.name(of: $0.key)) }
            .map { item($0.key, $0.value) }
    }

    func stat(_ path: String) throws -> RemoteItem {
        guard let entry = entries[path] else { throw POSIXError(.ENOENT) }
        return item(path, entry)
    }

    func download(_ path: String, to url: URL, progress: Progress) throws {
        guard let entry = entries[path] else { throw POSIXError(.ENOENT) }
        try entry.data.write(to: url)
    }

    func upload(_ url: URL, to path: String, from offset: Int64, progress: Progress) throws {
        try checkNotHeld(path)
        uploadOffsets.append(offset)
        var data: Data
        if offset == 0 {
            guard entries[path] == nil else { throw POSIXError(.EEXIST) }
            data = Data()
        } else {
            guard let existing = entries[path] else { throw POSIXError(.ENOENT) }
            data = existing.data.prefix(Int(offset))
        }
        let local = try Data(contentsOf: url).dropFirst(Int(offset))
        if failingUploads > 0 {
            failingUploads -= 1
            data.append(local.prefix(failAfterBytes))
            entries[path] = Entry(isDirectory: false, data: data, fileID: entries[path]?.fileID ?? newID(), modified: Date())
            throw POSIXError(.ECONNRESET)
        }
        data.append(local)
        entries[path] = Entry(isDirectory: false, data: data, fileID: entries[path]?.fileID ?? newID(), modified: Date())
    }

    func read(_ path: String, range: Range<UInt64>) throws -> Data {
        guard let entry = entries[path] else { throw POSIXError(.ENOENT) }
        return entry.data.prefix(Int(range.upperBound))
    }

    func createDirectory(_ path: String) throws {
        guard entries[path] == nil else { throw POSIXError(.EEXIST) }
        entries[path] = Entry(isDirectory: true, data: Data(), fileID: newID(), modified: Date())
    }

    func move(_ path: String, to destination: String, replacing: Bool) throws {
        try checkNotHeld(path, destination)
        guard entries[path] != nil else { throw POSIXError(.ENOENT) }
        if replacing, entries[destination]?.isDirectory == false {
            entries[destination] = nil
        }
        guard entries[destination] == nil else { throw POSIXError(.EEXIST) }
        for key in entries.keys where key == path || key.hasPrefix(path + "/") {
            entries[destination + key.dropFirst(path.count)] = entries.removeValue(forKey: key)
        }
    }

    func remove(_ path: String, isDirectory: Bool) throws {
        try checkNotHeld(path)
        guard entries[path] != nil else { throw POSIXError(.ENOENT) }
        removed.append(path)
        for key in entries.keys where key == path || key.hasPrefix(path + "/") {
            entries.removeValue(forKey: key)
        }
    }
}

struct DomainConnectionTests {
    private let backend = FakeBackend()
    private let connection: DomainConnection

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "DomainConnectionTests-\(UUID().uuidString).sqlite")
        connection = DomainConnection(backend: backend, store: try ItemStore(url: url, rootID: "root"))
    }

    private func localFile(_ text: String) throws -> URL {
        try localFile(Data(text.utf8))
    }

    private func localFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "local-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    /// Large enough that an interrupted upload has something to resume past the overlap.
    private static let bigFile = Data((0..<(DomainConnection.resumeOverlap + 4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    @Test func anchorFromOlderItemFormatSendsEveryKnownItemOnce() async throws {
        let saved = Date(timeIntervalSince1970: 1_790_000_000)
        await backend.put("a.txt", "a", modified: saved)
        await backend.put("b.txt", "b", modified: saved)
        _ = try await connection.relist("root")

        // An anchor from before item formats existed (plain SMB's used to be a bare time).
        let refresh = try await connection.changes(since: Data("1700000000".utf8), workingSetFolderLimit: 20)
        #expect(Set(refresh.updated.map(\.name)) == ["a.txt", "b.txt"])
        #expect(!refresh.moreComing)

        // From the anchor it hands back, only real changes (none here).
        let next = try await connection.changes(since: refresh.anchor, workingSetFolderLimit: 20)
        #expect(next.updated.isEmpty)
        let current = try await connection.currentAnchor()
        #expect(try await connection.changes(since: current, workingSetFolderLimit: 20).updated.isEmpty)
    }

    @Test func unchangedFileWithFractionalTimeIsNotReportedAgain() async throws {
        // SMB times arrive as seconds since 1970 in whole microseconds (AMSMB2), and must survive storage
        // exactly, or an unchanged file would look like new contents and download again.
        for i in 0..<50 {
            await backend.put("f\(i).txt", "x", modified: Date(timeIntervalSince1970: 1_790_000_000.123_456_7 + Double(i) * 0.000_013_7))
        }
        _ = try await connection.relist("root")
        #expect(try await connection.relist("root").changed.isEmpty)
    }

    @Test func newContentsAreReportedButOtherChangesAreNot() async throws {
        let saved = Date(timeIntervalSince1970: 1_790_000_000)
        await backend.put("a.txt", "a", modified: saved)
        await backend.put("b.txt", "b", modified: saved)
        let listing = try await connection.relist("root")
        let a = try #require(listing.items.first { $0.name == "a.txt" })

        await backend.put("a.txt", "a, edited elsewhere", modified: saved.addingTimeInterval(60))
        try await backend.move("b.txt", to: "c.txt", replacing: false)
        let result = try await connection.relist("root")
        #expect(result.contentChanged == [a.id])
        #expect(result.changed.count == 2)
    }

    @Test func createFileUploadsAndLeavesNoTempFile() async throws {
        let record = try await connection.createFile(
            named: "a.txt", in: "root", contents: try localFile("hello"), mayAlreadyExist: false, progress: Progress())
        #expect(record.name == "a.txt")
        #expect(record.size == 5)
        #expect(await backend.paths == ["a.txt"])
    }

    @Test func createFileFailsOnNameCollision() async throws {
        await backend.put("a.txt", "old")
        await #expect(throws: POSIXError(.EEXIST)) {
            try await connection.createFile(named: "a.txt", in: "root", contents: try localFile("new"), mayAlreadyExist: false, progress: Progress())
        }
        #expect(await backend.contents("a.txt") == Data("old".utf8))
        #expect(await backend.paths == ["a.txt"])
    }

    @Test func reimportAdoptsExistingFileOfSameSize() async throws {
        await backend.put("a.txt", "same")
        let record = try await connection.createFile(
            named: "a.txt", in: "root", contents: try localFile("same"), mayAlreadyExist: true, progress: Progress())
        #expect(record.name == "a.txt")
        #expect(await backend.paths == ["a.txt"])
    }

    @Test func createFolderMergesWithExistingFolder() async throws {
        let first = try await connection.createFolder(named: "dir", in: "root")
        let second = try await connection.createFolder(named: "dir", in: "root")
        #expect(first.id == second.id)
    }

    @Test func replacingContentsKeepsIdentity() async throws {
        let created = try await connection.createFile(
            named: "doc.txt", in: "root", contents: try localFile("v1"), mayAlreadyExist: false, progress: Progress())
        let update = try await connection.replaceContents(
            of: created.id, with: try localFile("version 2"), baseVersion: created.contentVersion, modified: Date(), progress: Progress())
        let replaced = update.record
        #expect(update.conflictCopyName == nil)
        #expect(replaced.id == created.id)
        #expect(replaced.fileID != created.fileID)
        #expect(await backend.contents("doc.txt") == Data("version 2".utf8))
        #expect(await backend.removed.isEmpty)  // Replaced by one rename, never deleted first.

        // A later listing still matches the same item.
        let listing = try await connection.relist("root")
        #expect(listing.items.map(\.id) == [created.id])
        #expect(listing.deleted.isEmpty)
    }

    @Test func moveIntoFolderAndRename() async throws {
        let folder = try await connection.createFolder(named: "dir", in: "root")
        let file = try await connection.createFile(
            named: "a.txt", in: "root", contents: try localFile("x"), mayAlreadyExist: false, progress: Progress())
        let moved = try await connection.move(file.id, to: "b.txt", in: folder.id)
        #expect(moved.id == file.id)
        #expect(try connection.path(of: file.id) == "dir/b.txt")
        #expect(await backend.exists("dir/b.txt"))
    }

    @Test func deleteNonEmptyFolderNeedsRecursive() async throws {
        let folder = try await connection.createFolder(named: "dir", in: "root")
        _ = try await connection.createFile(
            named: "a.txt", in: folder.id, contents: try localFile("x"), mayAlreadyExist: false, progress: Progress())
        await #expect(throws: POSIXError(.ENOTEMPTY)) {
            try await connection.delete(folder.id, baseVersion: nil, recursive: false)
        }
        try await connection.delete(folder.id, baseVersion: nil, recursive: true)
        #expect(await backend.paths.isEmpty)
        #expect(connection.store.record(folder.id) == nil)
    }

    @Test func refreshForgetsItemsDeletedOnServer() async throws {
        await backend.put("gone.txt", "x")
        let id = try #require(try await connection.relist("root").items.first?.id)
        try await backend.remove("gone.txt", isDirectory: false)
        await #expect(throws: POSIXError(.ENOENT)) {
            try await connection.refresh(id)
        }
        #expect(connection.store.record(id) == nil)
    }

    // MARK: Interrupted uploads

    @Test func uploadRetriesOnceFromWhereItStopped() async throws {
        await backend.failUploads(1, afterBytes: Int(DomainConnection.resumeOverlap) + (2 << 20))
        let record = try await connection.createFile(
            named: "big.bin", in: "root", contents: try localFile(Self.bigFile), mayAlreadyExist: false, progress: Progress())
        #expect(record.size == Int64(Self.bigFile.count))
        #expect(await backend.contents("big.bin") == Self.bigFile)
        #expect(await backend.uploadOffsets == [0, 2 << 20])
        #expect(await backend.paths == ["big.bin"])
    }

    @Test func failedUploadKeepsTempFileAndNextAttemptResumes() async throws {
        let local = try localFile(Self.bigFile)
        await backend.failUploads(2, afterBytes: Int(DomainConnection.resumeOverlap) + (1 << 20))
        await #expect(throws: POSIXError(.ECONNRESET)) {
            try await connection.createFile(named: "big.bin", in: "root", contents: local, mayAlreadyExist: false, progress: Progress())
        }
        let leftover = await backend.paths
        #expect(leftover.count == 1 && RemotePath.isInternal(leftover[0]))

        // The system retries later: the upload carries on from the temp file.
        _ = try await connection.createFile(named: "big.bin", in: "root", contents: local, mayAlreadyExist: false, progress: Progress())
        #expect(await backend.contents("big.bin") == Self.bigFile)
        #expect(await backend.paths == ["big.bin"])
        #expect(await backend.uploadOffsets.last! > 0)
    }

    @Test func nameCollisionRemovesTempFile() async throws {
        await backend.put("a.txt", "old")
        await #expect(throws: POSIXError(.EEXIST)) {
            try await connection.createFile(named: "a.txt", in: "root", contents: try localFile("new"), mayAlreadyExist: false, progress: Progress())
        }
        #expect(await backend.paths == ["a.txt"])
    }

    // MARK: Journal

    @Test func journalKeepsFailedUploadsAndDropsFinishedOnes() async throws {
        let temp = FileManager.default.temporaryDirectory
        let journal = try TransferJournal(url: temp.appending(path: "journal-\(UUID().uuidString).sqlite"))
        let connection = DomainConnection(
            backend: backend, store: try ItemStore(url: temp.appending(path: "store-\(UUID().uuidString).sqlite"), rootID: "root"),
            journal: journal)
        let local = try localFile(Self.bigFile)

        await backend.failUploads(2, afterBytes: 1 << 20)
        await #expect(throws: POSIXError(.ECONNRESET)) {
            try await connection.createFile(named: "big.bin", in: "root", contents: local, mayAlreadyExist: false, progress: Progress())
        }
        let entry = try #require(journal.entries().first)
        #expect(entry.name == "big.bin" && entry.itemID == nil && entry.size == Int64(Self.bigFile.count))
        #expect(entry.error == "The connection to the server was lost. Retrying.")

        _ = try await connection.createFile(named: "big.bin", in: "root", contents: local, mayAlreadyExist: false, progress: Progress())
        #expect(journal.entries().isEmpty)
    }

    @Test func journalDropsUploadsThatCantResume() async throws {
        let temp = FileManager.default.temporaryDirectory
        let journal = try TransferJournal(url: temp.appending(path: "journal-\(UUID().uuidString).sqlite"))
        let connection = DomainConnection(
            backend: backend, store: try ItemStore(url: temp.appending(path: "store-\(UUID().uuidString).sqlite"), rootID: "root"),
            journal: journal)
        await backend.put("a.txt", "old")
        await #expect(throws: POSIXError(.EEXIST)) {
            try await connection.createFile(named: "a.txt", in: "root", contents: try localFile("new"), mayAlreadyExist: false, progress: Progress())
        }
        #expect(journal.entries().isEmpty)  // The system retries under another name, as another upload.
    }

    @Test func longBusyUploadStartsOverInFreshTempFile() async throws {
        let temp = FileManager.default.temporaryDirectory
        let journal = try TransferJournal(url: temp.appending(path: "journal-\(UUID().uuidString).sqlite"))
        let connection = DomainConnection(
            backend: backend, store: try ItemStore(url: temp.appending(path: "store-\(UUID().uuidString).sqlite"), rootID: "root"),
            journal: journal)
        let local = try localFile(Self.bigFile)
        let key = try DomainConnection.uploadKey(scope: "create:root/big.bin", file: local)
        let heldTemp = RemotePath.uploadPrefix + key
        // A cut-off session left part of the upload and still holds it.
        await backend.put(heldTemp, Self.bigFile.prefix(Int(DomainConnection.resumeOverlap) * 2))
        await backend.hold(heldTemp)

        for _ in 0..<2 {
            await #expect(throws: POSIXError(.ETXTBSY)) {
                try await connection.createFile(named: "big.bin", in: "root", contents: local, mayAlreadyExist: false, progress: Progress())
            }
        }
        #expect(journal.entries().first?.error == "The server is still busy with this file. Retrying.")
        #expect(journal.temp(for: key) == nil)  // Not busy for long yet: still waiting for the held file.

        // Busy for longer than the limit: the next attempt starts over in a fresh temp file.
        journal.clearBusy(key)
        journal.markBusy(key, at: Date(timeIntervalSinceNow: -DomainConnection.busyLimit - 60))
        _ = try await connection.createFile(named: "big.bin", in: "root", contents: local, mayAlreadyExist: false, progress: Progress())
        #expect(await backend.contents("big.bin") == Self.bigFile)
        #expect(journal.entries().isEmpty)
        #expect(Set(await backend.paths) == ["big.bin", heldTemp])  // Still held, so it stays until it's let go.
    }

    // MARK: Conflicts

    private func knownFile(_ name: String, _ text: String, modified: Date) async throws -> ItemRecord {
        await backend.put(name, text, modified: modified)
        return try #require(try await connection.relist("root").items.first { $0.name == name })
    }

    @Test func newerLocalEditWinsAndServerVersionBecomesConflictCopy() async throws {
        let base = try await knownFile("doc.txt", "base", modified: Date(timeIntervalSinceNow: -60))
        await backend.put("doc.txt", "other device", modified: Date(timeIntervalSinceNow: -30))
        let update = try await connection.replaceContents(
            of: base.id, with: try localFile("mine"), baseVersion: base.contentVersion, modified: Date(), progress: Progress())
        let copy = try #require(update.conflictCopyName)
        #expect(copy.hasPrefix("doc [CONFLICT ") && copy.hasSuffix("].txt"))
        #expect(await backend.contents("doc.txt") == Data("mine".utf8))
        #expect(await backend.contents(copy) == Data("other device".utf8))
        #expect(update.record.id == base.id)
        #expect(!update.editLost)  // The device's copy is the file: nothing to fetch.

        // The copy is a new item in the next listing; the edited file keeps its ID.
        let listing = try await connection.relist("root")
        #expect(listing.items.first { $0.name == "doc.txt" }?.id == base.id)
        #expect(listing.changed.contains { $0.name == copy && $0.id != base.id })
    }

    @Test func newerServerEditStaysAndLocalEditBecomesConflictCopy() async throws {
        let base = try await knownFile("doc.txt", "base", modified: Date(timeIntervalSinceNow: -60))
        await backend.put("doc.txt", "other device", modified: Date())
        let update = try await connection.replaceContents(
            of: base.id, with: try localFile("mine"), baseVersion: base.contentVersion,
            modified: Date(timeIntervalSinceNow: -30), progress: Progress())
        let copy = try #require(update.conflictCopyName)
        #expect(await backend.contents("doc.txt") == Data("other device".utf8))
        #expect(await backend.contents(copy) == Data("mine".utf8))
        // The device's copy is now the conflict copy, not the file: the system has to fetch the file again
        // (a new content version alone doesn't make it; it takes the returned version as its own copy's).
        #expect(update.editLost)
        #expect(update.record.contentVersion != base.contentVersion)
    }

    @Test func editOfFileDeletedOnServerRecreatesIt() async throws {
        let base = try await knownFile("doc.txt", "base", modified: Date())
        try await backend.remove("doc.txt", isDirectory: false)
        let update = try await connection.replaceContents(
            of: base.id, with: try localFile("mine"), baseVersion: base.contentVersion, modified: Date(), progress: Progress())
        #expect(update.conflictCopyName == nil)
        #expect(await backend.contents("doc.txt") == Data("mine".utf8))
    }

    @Test func deleteOfFileChangedOnServerIsRefused() async throws {
        let base = try await knownFile("doc.txt", "base", modified: Date(timeIntervalSinceNow: -60))
        await backend.put("doc.txt", "other device")
        await #expect(throws: DomainConnection.ChangedOnServer.self) {
            try await connection.delete(base.id, baseVersion: base.contentVersion, recursive: false)
        }
        #expect(await backend.contents("doc.txt") == Data("other device".utf8))
    }

    @Test func deleteOfUnchangedFileDeletes() async throws {
        let base = try await knownFile("doc.txt", "base", modified: Date())
        try await connection.delete(base.id, baseVersion: base.contentVersion, recursive: false)
        #expect(await backend.paths.isEmpty)
    }

    @Test func downloadWritesLocalFile() async throws {
        await backend.put("a.txt", "content")
        let id = try #require(try await connection.relist("root").items.first?.id)
        let url = FileManager.default.temporaryDirectory.appending(path: "download-\(UUID().uuidString)")
        _ = try await connection.download(id, to: url, progress: Progress())
        #expect(try Data(contentsOf: url) == Data("content".utf8))
    }
}
