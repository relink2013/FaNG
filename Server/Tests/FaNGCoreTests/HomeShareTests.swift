import Foundation
import Testing
@testable import FaNGCore

struct HomeShareTests {
    @Test func ownHomeIsPresentedAsHome() {
        #expect(Share.presented("~alice", to: "alice") == "Home")
        #expect(Share.presented("~alice", to: "bob") == "~alice")
        #expect(Share.presented("Photos", to: "alice") == "Photos")
        #expect(Share.meant("Home", by: "alice") == "~alice")
        #expect(Share.meant("Photos", by: "alice") == "Photos")
        #expect(Share(name: "~alice", path: "/x", createMask: 0o664, directoryMask: 0o775).homeOwner == "alice")
    }

    @Test func itemsGoOutWithTheirOwnersHomeName() throws {
        var item = try JSONDecoder().decode(Item.self, from: Data(Self.json.utf8))
        #expect(item.share == "~alice")
        let asAlice = try SharePresentation.$user.withValue("alice") { try JSONEncoder().encode(item) }
        #expect(String(decoding: asAlice, as: UTF8.self).contains("\"share\":\"Home\""))
        let asNobody = try JSONEncoder().encode(item)
        #expect(String(decoding: asNobody, as: UTF8.self).contains("\"share\":\"~alice\""))
        // Its root folder is named "Home" for its owner too; a file named like the share isn't.
        var root = item
        (root.path, root.name) = ("", "~alice")
        let rootAsAlice = try SharePresentation.$user.withValue("alice") { try JSONEncoder().encode(root) }
        #expect(String(decoding: rootAsAlice, as: UTF8.self).contains("\"name\":\"Home\""))
        item.name = "~alice"
        let fileAsAlice = try SharePresentation.$user.withValue("alice") { try JSONEncoder().encode(item) }
        #expect(String(decoding: fileAsAlice, as: UTF8.self).contains("\"name\":\"~alice\""))
        // Round trip: what the API decodes from fang-storaged is unchanged.
        let back = try JSONDecoder().decode(Item.self, from: try JSONEncoder().encode(item))
        #expect(back == item)
    }

    @Test func unraidRoots() {
        #expect(Share.isUnraidRoot("/mnt"))
        #expect(Share.isUnraidRoot("/mnt/tank"))
        #expect(!Share.isUnraidRoot("/mnt/tank/homes"))
    }

    static let json = """
    {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","share":"~alice","name":"a","path":"a","isDirectory":false,"size":1,
     "mtimeNS":1,"inode":1,"contentVersion":1,"metadataVersion":1,"deleted":false,"seq":1,"trashed":false,"tags":[]}
    """
}
