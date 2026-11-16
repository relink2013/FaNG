import Foundation
import Testing
@testable import FaNGKit

struct ItemStoreTests {
    private let store: ItemStore

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "ItemStoreTests-\(UUID().uuidString).sqlite")
        store = try ItemStore(url: url, rootID: "root")
    }

    private func remote(_ path: String, fileID: UInt64, size: Int64 = 1, directory: Bool = false) -> RemoteItem {
        RemoteItem(
            path: path, name: RemotePath.name(of: path), isDirectory: directory, size: size,
            modified: Date(timeIntervalSince1970: 1000), created: Date(timeIntervalSince1970: 1000), fileID: fileID
        )
    }

    @Test func firstListingReportsEverythingAsChanged() {
        let result = store.reconcile(parentID: "root", listing: [remote("a.txt", fileID: 1), remote("b.txt", fileID: 2)])
        #expect(result.items.count == 2)
        #expect(result.changed.count == 2)
        #expect(result.deleted.isEmpty)
    }

    @Test func unchangedListingReportsNothing() {
        let listing = [remote("a.txt", fileID: 1)]
        let first = store.reconcile(parentID: "root", listing: listing)
        let second = store.reconcile(parentID: "root", listing: listing)
        #expect(second.changed.isEmpty)
        #expect(second.deleted.isEmpty)
        #expect(second.items.map(\.id) == first.items.map(\.id))
    }

    @Test func renameOnServerKeepsIdentity() throws {
        let id = try #require(store.reconcile(parentID: "root", listing: [remote("old.txt", fileID: 7)]).items.first?.id)
        let result = store.reconcile(parentID: "root", listing: [remote("new.txt", fileID: 7)])
        #expect(result.items.first?.id == id)
        #expect(result.changed.first?.name == "new.txt")
        #expect(result.deleted.isEmpty)
        #expect(store.path(of: id) == "new.txt")
    }

    @Test func replacedContentKeepsIdentityByName() throws {
        let id = try #require(store.reconcile(parentID: "root", listing: [remote("doc.txt", fileID: 1, size: 1)]).items.first?.id)
        let result = store.reconcile(parentID: "root", listing: [remote("doc.txt", fileID: 99, size: 5)])
        #expect(result.items.first?.id == id)
        #expect(result.changed.first?.size == 5)
    }

    @Test func missingItemsAreDeletedWithDescendants() throws {
        let folder = try #require(store.reconcile(parentID: "root", listing: [remote("dir", fileID: 1, directory: true)]).items.first)
        let child = try #require(store.reconcile(parentID: folder.id, listing: [remote("dir/file", fileID: 2)]).items.first)
        #expect(store.path(of: child.id) == "dir/file")

        let result = store.reconcile(parentID: "root", listing: [])
        #expect(result.deleted == [folder.id])
        #expect(store.record(child.id) == nil)
        #expect(store.path(of: child.id) == nil)
    }

    @Test func folderRenameMovesChildPaths() throws {
        let folder = try #require(store.reconcile(parentID: "root", listing: [remote("dir", fileID: 1, directory: true)]).items.first)
        let child = try #require(store.reconcile(parentID: folder.id, listing: [remote("dir/file", fileID: 2)]).items.first)
        var renamed = folder
        renamed.name = "renamed"
        store.save(renamed)
        #expect(store.path(of: child.id) == "renamed/file")
    }

    @Test func rootPathIsEmpty() {
        #expect(store.path(of: "root") == "")
        #expect(store.path(of: "unknown") == nil)
    }

    @Test func recentFoldersAreNewestFirst() throws {
        _ = store.reconcile(parentID: "root", listing: [])
        _ = store.reconcile(parentID: "other", listing: [])
        #expect(store.recentFolders(limit: 1) == ["other"])
    }
}

struct RemotePathTests {
    @Test func joinAndSplit() {
        #expect(RemotePath.join("", "a") == "a")
        #expect(RemotePath.join("a/b", "c") == "a/b/c")
        #expect(RemotePath.parent(of: "a/b/c") == "a/b")
        #expect(RemotePath.parent(of: "a") == "")
        #expect(RemotePath.name(of: "a/b/c") == "c")
        #expect(RemotePath.name(of: "a") == "a")
    }

    @Test func uploadTempFilesAreInternal() {
        #expect(RemotePath.isInternal(RemotePath.uploadPrefix + "123-photo.jpg"))
        #expect(!RemotePath.isInternal(".DS_Store"))
    }
}

struct ScopedFileIDTests {
    private func item(fileID: UInt64) -> RemoteItem {
        RemoteItem(path: "a", name: "a", isDirectory: false, size: 0, modified: .distantPast, created: .distantPast, fileID: fileID)
    }

    @Test func sameInodeInDifferentSharesDiffers() {
        #expect(item(fileID: 42).scoped(to: "Photos").fileID != item(fileID: 42).scoped(to: "Documents").fileID)
        #expect(item(fileID: 42).scoped(to: "Photos").fileID == item(fileID: 42).scoped(to: "Photos").fileID)
    }

    @Test func unknownFileIDStaysUnknown() {
        #expect(item(fileID: 0).scoped(to: "Photos").fileID == 0)
    }
}

struct ServerAccountTests {
    @Test func serverURL() {
        let account = ServerAccount(displayName: "FaNG", host: "192.0.2.10", username: "user", encrypted: false)
        #expect(account.serverURL?.absoluteString == "smb://192.0.2.10")
        var custom = account
        custom.port = 4450
        #expect(custom.serverURL?.absoluteString == "smb://192.0.2.10:4450")
        custom.host = "2001:db8::1"
        #expect(custom.serverURL?.absoluteString == "smb://[2001:db8::1]:4450")
    }
}
