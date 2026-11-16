import Testing
@testable import FaNGCore

struct VersionPlaceTests {
    @Test func versionsOfAFileOnTheSharesOwnFilesystemAreAtItsTop() {
        #expect(VersionPlace.folder(itemPath: "a/b/file.txt", filesystemRoot: "") == ".fang-versions/a/b/file.txt")
        #expect(VersionPlace.folder(itemPath: "file.txt", filesystemRoot: "") == ".fang-versions/file.txt")
    }

    @Test func versionsOfAFileOnAFilesystemInsideTheShareAreAtThatFilesystemsTop() {
        #expect(VersionPlace.folder(itemPath: "a/b/file.txt", filesystemRoot: "a") == "a/.fang-versions/b/file.txt")
        #expect(VersionPlace.folder(itemPath: "a/b/c/file.txt", filesystemRoot: "a/b") == "a/b/.fang-versions/c/file.txt")
        #expect(VersionPlace.folder(itemPath: "a/file.txt", filesystemRoot: "a") == "a/.fang-versions/file.txt")
        // A root that isn't above the item is ignored.
        #expect(VersionPlace.folder(itemPath: "a/file.txt", filesystemRoot: "b") == ".fang-versions/a/file.txt")
    }

    @Test func findsTheTopOfTheFilesystemTheItemIsOn() {
        // The share ("") and "a" are on device 1; "a/b" is a dataset (device 2) with "a/b/c" in it.
        let devices: [String: UInt64] = ["": 1, "a": 1, "a/b": 2, "a/b/c": 2, "x": 1]
        let device: (String) -> UInt64? = { devices[$0] }
        #expect(VersionPlace.filesystemRoot(itemPath: "file.txt", device: device) == "")
        #expect(VersionPlace.filesystemRoot(itemPath: "a/file.txt", device: device) == "")
        #expect(VersionPlace.filesystemRoot(itemPath: "a/b/file.txt", device: device) == "a/b")
        #expect(VersionPlace.filesystemRoot(itemPath: "a/b/c/file.txt", device: device) == "a/b")
        // A folder that can't be read: the share's own version folder, as before.
        #expect(VersionPlace.filesystemRoot(itemPath: "gone/file.txt", device: device) == "")
    }

    @Test func aDatasetInsideADatasetHasItsOwn() {
        let devices: [String: UInt64] = ["": 1, "a": 2, "a/b": 3, "a/b/c": 3]
        #expect(VersionPlace.filesystemRoot(itemPath: "a/b/c/file.txt") { devices[$0] } == "a/b")
        #expect(VersionPlace.filesystemRoot(itemPath: "a/file.txt") { devices[$0] } == "a")
    }
}
