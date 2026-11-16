import Foundation

/// Which FaNG ID an entry on disk is, from what's known about it. Pure, so the rules are testable without a
/// filesystem or a database; fang-storaged gathers the facts and acts on the decision.
///
/// - An entry carrying an ID that isn't in use anywhere else is that item (moved or renamed here, or
///   simply unchanged).
/// - An ID still carried by the entry at its recorded path too: this one is a copy, so it's a new item.
/// - A file saved over a known file at the same path (an app writing a temp file and renaming it over the
///   original, whether or not the temp file got an ID first) is new contents for that known file.
/// - Anything else is a new item. Folders are never merged with what was at their path.
public enum Identity {
    public struct Facts: Sendable {
        /// The ID in the entry's `user.fang.id` xattr, if any.
        public var carried: UUID?
        public var isDirectory: Bool
        /// The carried ID belongs to a live item recorded at another path.
        public var recordedElsewhere: Bool
        /// That other path still exists and carries the same ID.
        public var elsewhereStillCarries: Bool
        /// The live item recorded at this entry's path, if any.
        public var atThisPath: (id: UUID, isDirectory: Bool)?

        public init(carried: UUID?, isDirectory: Bool, recordedElsewhere: Bool = false, elsewhereStillCarries: Bool = false,
                    atThisPath: (id: UUID, isDirectory: Bool)? = nil) {
            self.carried = carried
            self.isDirectory = isDirectory
            self.recordedElsewhere = recordedElsewhere
            self.elsewhereStillCarries = elsewhereStillCarries
            self.atThisPath = atThisPath
        }
    }

    public enum Decision: Equatable, Sendable {
        /// The carried ID stands.
        case keep(UUID)
        /// The entry is this (known) item: write its ID onto the entry.
        case adopt(UUID)
        /// A new item: give the entry a new ID.
        case new
    }

    public static func decide(_ facts: Facts) -> Decision {
        // A file replacing a known file at the same path is that file's new contents.
        let replacedFile: UUID? = {
            guard !facts.isDirectory, let here = facts.atThisPath, !here.isDirectory else { return nil }
            return here.id
        }()
        guard let carried = facts.carried else {
            return replacedFile.map(Decision.adopt) ?? .new
        }
        guard facts.recordedElsewhere else { return .keep(carried) }
        if facts.elsewhereStillCarries {
            // A copy: the original is still where it was.
            return replacedFile.map(Decision.adopt) ?? .new
        }
        // Moved here, possibly over a known file.
        if let replacedFile, replacedFile != carried {
            return .adopt(replacedFile)
        }
        return .keep(carried)
    }
}

/// What a commit does with an edit, from versions alone (see `Tracker.commit`).
public enum CommitRule {
    public struct Outcome: Equatable, Sendable {
        /// Two edits started from the same version.
        public var conflict: Bool
        /// The edit becomes the file; otherwise the server's file stays and the edit becomes a branch.
        public var editWins: Bool
    }

    /// `base` is the content version the edit started from, `current` the file's now. On a conflict the
    /// newer save stays at the path, as iCloud does; a tie keeps the server's file.
    public static func decide(base: Int64, current: Int64, editSavedNS: Int64, currentSavedNS: Int64) -> Outcome {
        let conflict = base != current
        return Outcome(conflict: conflict, editWins: !conflict || editSavedNS > currentSavedNS)
    }
}
