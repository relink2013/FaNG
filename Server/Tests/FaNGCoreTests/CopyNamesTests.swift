import Testing
@testable import FaNGCore

struct CopyNamesTests {
    @Test func copyInTheSameFolder() {
        #expect(CopyNames.candidate("Photo.jpg", isDirectory: false, sameFolder: true, attempt: 0) == "Photo copy.jpg")
        #expect(CopyNames.candidate("Photo.jpg", isDirectory: false, sameFolder: true, attempt: 1) == "Photo copy 2.jpg")
        #expect(CopyNames.candidate("Project", isDirectory: true, sameFolder: true, attempt: 0) == "Project copy")
    }

    @Test func elsewhereKeepsTheNameUntilTaken() {
        #expect(CopyNames.candidate("Photo.jpg", isDirectory: false, sameFolder: false, attempt: 0) == "Photo.jpg")
        #expect(CopyNames.candidate("Photo.jpg", isDirectory: false, sameFolder: false, attempt: 1) == "Photo 2.jpg")
        #expect(CopyNames.candidate("Photo.jpg", isDirectory: false, sameFolder: false, attempt: 2) == "Photo 3.jpg")
    }

    @Test func extensionsOnlyForFiles() {
        #expect(CopyNames.candidate("v1.2", isDirectory: true, sameFolder: false, attempt: 1) == "v1.2 2")
        #expect(CopyNames.candidate(".profile", isDirectory: false, sameFolder: false, attempt: 1) == ".profile 2")
        #expect(CopyNames.candidate("README", isDirectory: false, sameFolder: true, attempt: 0) == "README copy")
        #expect(CopyNames.candidate("archive.", isDirectory: false, sameFolder: false, attempt: 1) == "archive. 2")
    }

    @Test func acceptableNames() {
        #expect(CopyNames.isAcceptable("Notes.txt"))
        #expect(!CopyNames.isAcceptable(""))
        #expect(!CopyNames.isAcceptable(".."))
        #expect(!CopyNames.isAcceptable("a/b"))
        #expect(!CopyNames.isAcceptable(".fang-trash"))
    }
}
