import Foundation
import Testing
@testable import FaNGCore

struct IdentityTests {
    let a = UUID(), b = UUID()

    @Test func newFileGetsNewID() {
        #expect(Identity.decide(.init(carried: nil, isDirectory: false)) == .new)
    }

    @Test func unchangedOrRenamedKeepsItsID() {
        #expect(Identity.decide(.init(carried: a, isDirectory: false)) == .keep(a))
        // Renamed: recorded at the old path, which no longer carries it.
        #expect(Identity.decide(.init(carried: a, isDirectory: false, recordedElsewhere: true)) == .keep(a))
        #expect(Identity.decide(.init(carried: a, isDirectory: true, recordedElsewhere: true)) == .keep(a))
    }

    @Test func copyGetsNewID() {
        #expect(Identity.decide(.init(carried: a, isDirectory: false, recordedElsewhere: true, elsewhereStillCarries: true)) == .new)
        #expect(Identity.decide(.init(carried: a, isDirectory: true, recordedElsewhere: true, elsewhereStillCarries: true)) == .new)
    }

    @Test func saveOverKeepsTheOriginalsID() {
        // The temp file had no ID yet.
        #expect(Identity.decide(.init(carried: nil, isDirectory: false, atThisPath: (b, false))) == .adopt(b))
        // The temp file got an ID before it was renamed over the original.
        #expect(Identity.decide(.init(carried: a, isDirectory: false, recordedElsewhere: true, atThisPath: (b, false))) == .adopt(b))
    }

    @Test func copyOverAFileBecomesThatFile() {
        #expect(Identity.decide(.init(carried: a, isDirectory: false, recordedElsewhere: true, elsewhereStillCarries: true,
                                      atThisPath: (b, false))) == .adopt(b))
    }

    @Test func foldersNeverMergeWithWhatWasThere() {
        #expect(Identity.decide(.init(carried: nil, isDirectory: true, atThisPath: (b, true))) == .new)
        #expect(Identity.decide(.init(carried: nil, isDirectory: false, atThisPath: (b, true))) == .new)
        #expect(Identity.decide(.init(carried: a, isDirectory: true, recordedElsewhere: true, atThisPath: (b, true))) == .keep(a))
    }
}

struct CommitRuleTests {
    @Test func editFromTheCurrentVersionWins() {
        #expect(CommitRule.decide(base: 4, current: 4, editSavedNS: 1, currentSavedNS: 9) == .init(conflict: false, editWins: true))
    }

    @Test func conflictKeepsTheNewerSave() {
        #expect(CommitRule.decide(base: 3, current: 4, editSavedNS: 9, currentSavedNS: 5) == .init(conflict: true, editWins: true))
        #expect(CommitRule.decide(base: 3, current: 4, editSavedNS: 5, currentSavedNS: 9) == .init(conflict: true, editWins: false))
    }

    @Test func tieKeepsTheServersFile() {
        #expect(CommitRule.decide(base: 3, current: 4, editSavedNS: 7, currentSavedNS: 7) == .init(conflict: true, editWins: false))
    }
}
