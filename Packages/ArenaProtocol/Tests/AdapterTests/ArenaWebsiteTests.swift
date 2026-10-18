import ApplicationActions
import Foundation
import Testing

@testable import ArenaAdapter

/// ADR 0006: the window's site is exactly the origin the native client already uses.
@Test func arenaWebsitePolicyIsTheObservedOrigin() {
    let policy = ArenaWebsite.policy
    #expect(policy.home == ArenaRoutes.origin)
    #expect(policy.home.scheme == "https")
    #expect(policy.isSitePage(policy.home))
    #expect(policy.mainFrame(ArenaRoutes.identity().url!) == .load)
    #expect(policy.mainFrame(URL(string: "https://www.google.com/recaptcha/api2/anchor")!) == .askToOpen,
            "challenge frames load as subframes; the policy only governs the main frame")
}
