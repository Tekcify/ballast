import Foundation
import Testing
@testable import Ballast

struct DeletionGuardTests {
    private let home = "/Users/ballast-guard-test"

    private var guardrail: DeletionGuard {
        DeletionGuard(home: home, targets: CleanupTarget.all(home: home, includeDependencies: true))
    }

    @Test func theTrashCanBeEmptied() {
        #expect(guardrail.rejection(for: home + "/.Trash") == nil)
    }

    @Test func knownTargetsAreAllowed() {
        #expect(guardrail.rejection(for: home + "/Library/Caches/com.example.app") == nil)
        #expect(guardrail.rejection(for: home + "/Library/Developer/Xcode/DerivedData/App-abc") == nil)
        #expect(guardrail.rejection(for: home + "/code/web/.next/cache") == nil)
    }

    @Test func everythingElseIsRefused() {
        #expect(guardrail.rejection(for: home) == "the home folder itself")
        #expect(guardrail.rejection(for: home + "/Library") == "too close to the top of the home folder")
        #expect(guardrail.rejection(for: "/Library/Caches/x") == "outside the home folder")
        #expect(guardrail.rejection(for: home + "/code/.git/.turbo") == "inside .git, which Ballast never deletes from")
        #expect(guardrail.rejection(for: home + "/Desktop/web/.next/cache") == "inside Desktop, which Ballast never deletes from")
        #expect(guardrail.rejection(for: home + "/Downloads/big") == "not a path Ballast knows how to clean")
    }

    @Test func cachesTheGuardWouldRefuseAreShownButNeverOffered() {
        let refused = guardrail.offer(.safe, reason: "r", for: home + "/Documents/web/.next/cache")
        #expect(refused.risk == .reportOnly)
        #expect(refused.reason.contains("inside Documents, which Ballast never deletes from"))

        let allowed = guardrail.offer(.safe, reason: "r", for: home + "/code/web/.next/cache")
        #expect(allowed.risk == .safe)
        #expect(allowed.reason == "r")

        let kept = guardrail.offer(.reportOnly, reason: "yours", for: home + "/Downloads")
        #expect(kept.risk == .reportOnly)
        #expect(kept.reason == "yours")
    }
}
