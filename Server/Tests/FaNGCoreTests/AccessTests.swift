import Testing
@testable import FaNGCore

struct AccessTests {
    @Test func noRulesMeansNoAccess() {
        #expect(AccessRules().access(user: "a", share: "S", path: "x/y") == .none)
        #expect(AccessRules().access(user: "a", share: "S", path: "") == .none)
    }

    @Test func foldersOnTheWayArePassedThrough() {
        let rules = AccessRules([AccessRule(share: "S", path: "homes/a", principal: "user:a", access: .write)])
        #expect(rules.access(user: "a", share: "S", path: "") == .read)
        #expect(rules.access(user: "a", share: "S", path: "homes") == .read)
        #expect(rules.isPassedThrough(user: "a", share: "S", path: "homes"))
        #expect(rules.access(user: "a", share: "S", path: "homes/a/doc.txt") == .write)
        #expect(rules.access(user: "a", share: "S", path: "homes/b") == .none)
        #expect(rules.access(user: "a", share: "S", path: "other") == .none)
        // Someone with nothing in the share doesn't see it.
        #expect(rules.access(user: "b", share: "S", path: "") == .none)
        #expect(rules.access(user: "a", share: "T", path: "") == .none)
    }

    @Test func closestRuleWinsAndUserBeatsEveryone() {
        let rules = AccessRules([
            AccessRule(share: "S", path: "", principal: "everyone", access: .read),
            AccessRule(share: "S", path: "private", principal: "everyone", access: .none),
            AccessRule(share: "S", path: "private", principal: "user:a", access: .write),
            AccessRule(share: "S", path: "private/shared", principal: "everyone", access: .read),
        ])
        #expect(rules.access(user: "b", share: "S", path: "photos/1.jpg") == .read)
        #expect(rules.access(user: "b", share: "S", path: "private/x") == .none)
        #expect(rules.access(user: "a", share: "S", path: "private/x") == .write)
        // A rule for everyone further down beats the user's rule further up.
        #expect(rules.access(user: "a", share: "S", path: "private/shared/y") == .read)
        #expect(rules.access(user: "b", share: "S", path: "private/shared/y") == .read)
        // Other shares have no rules: no access.
        #expect(rules.access(user: "b", share: "T", path: "private/x") == .none)
        // The share's root itself.
        #expect(rules.access(user: "b", share: "S", path: "") == .read)
    }

    @Test func trashedItemsUseWhereTheyWere() {
        #expect(permissionPath(path: ".fang-trash/2026-11-05 10.00.00/private/a.jpg") == "private/a.jpg")
    }

    private func permissionPath(path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.first == ".fang-trash", parts.count > 2 { return parts.dropFirst(2).joined(separator: "/") }
        return path
    }

    @Test func groupsGiveTheirMembersAccess() {
        let rules = AccessRules([
            AccessRule(share: "S", path: "family", principal: "group:Family", access: .write),
            AccessRule(share: "S", path: "family/taxes", principal: "group:Kids", access: .none),
        ], memberships: ["a": ["Family"], "b": ["Family", "Kids"]])
        #expect(rules.access(user: "a", share: "S", path: "family/photo.jpg") == .write)
        #expect(rules.access(user: "a", share: "S", path: "family/taxes/2025.pdf") == .write)
        #expect(rules.access(user: "b", share: "S", path: "family/photo.jpg") == .write)
        // The closer rule, for another of their groups, decides.
        #expect(rules.access(user: "b", share: "S", path: "family/taxes/2025.pdf") == .none)
        // Not a member: nothing, and the share stays hidden.
        #expect(rules.access(user: "c", share: "S", path: "family") == .none)
        #expect(rules.access(user: "c", share: "S", path: "") == .none)
        // Members pass through the folders above.
        #expect(rules.access(user: "a", share: "S", path: "") == .read)
        #expect(rules.isPassedThrough(user: "a", share: "S", path: ""))
    }

    @Test func userBeatsGroupBeatsEveryoneAtTheSamePlace() {
        let rules = AccessRules([
            AccessRule(share: "S", path: "", principal: "everyone", access: .read),
            AccessRule(share: "S", path: "", principal: "group:Editors", access: .write),
            AccessRule(share: "S", path: "", principal: "user:b", access: .none),
        ], memberships: ["a": ["Editors"], "b": ["Editors"]])
        #expect(rules.access(user: "a", share: "S", path: "x") == .write)
        #expect(rules.access(user: "b", share: "S", path: "x") == .none)
        #expect(rules.access(user: "c", share: "S", path: "x") == .read)
    }

    @Test func amongAUsersGroupsNoAccessWinsOtherwiseTheMost() {
        let rules = AccessRules([
            AccessRule(share: "S", path: "a", principal: "group:Readers", access: .read),
            AccessRule(share: "S", path: "a", principal: "group:Editors", access: .write),
            AccessRule(share: "S", path: "b", principal: "group:Editors", access: .write),
            AccessRule(share: "S", path: "b", principal: "group:Blocked", access: .none),
        ], memberships: ["u": ["Readers", "Editors", "Blocked"]])
        #expect(rules.access(user: "u", share: "S", path: "a/file") == .write)
        #expect(rules.access(user: "u", share: "S", path: "b/file") == .none)
    }

    @Test func rulesWithoutGroupsAreUnchanged() {
        let list = [
            AccessRule(share: "S", path: "", principal: "everyone", access: .read),
            AccessRule(share: "S", path: "p", principal: "user:a", access: .write),
        ]
        let before = AccessRules(list), after = AccessRules(list, memberships: ["a": ["G"], "b": ["G"]])
        for user in ["a", "b", "c"] {
            for path in ["", "p", "p/x", "q"] {
                #expect(before.access(user: user, share: "S", path: path) == after.access(user: user, share: "S", path: path))
            }
        }
    }

    @Test func groupNames() {
        #expect(UserGroup.validName("Family"))
        #expect(UserGroup.validName("Photo Editors 2"))
        for bad in ["", " Family", "Family ", "a\tb", "a/b", "a:b", String(repeating: "x", count: 65)] {
            #expect(!UserGroup.validName(bad))
        }
    }
}
