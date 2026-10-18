import Foundation
import SuiteDomain
import Testing

@testable import ApplicationActions

// ADR 0006: a web profile is deleted only for an account the user removed, never inferred from an
// account list; one in use waits for its window to close; a failed deletion is retried next launch.

@MainActor
private final class Recorder {
    var removed: [AccountID] = []
    var saved: [[AccountID]] = []
    var succeed = true
    func lifecycle(pending: [AccountID] = []) -> WebProfileLifecycle {
        WebProfileLifecycle(pending: pending, persist: { self.saved.append($0) }, remover: { account in
            self.removed.append(account)
            return self.succeed
        })
    }
}

private let a = AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
private let b = AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)

@MainActor @Test func removingAnAccountDeletesOnlyItsProfile() async {
    let r = Recorder()
    let lifecycle = r.lifecycle()
    await lifecycle.accountRemoved(a)
    #expect(r.removed == [a])
    #expect(lifecycle.pending.isEmpty && r.saved.last == [])
}

@MainActor @Test func aProfileInUseIsDeletedWhenItsLastWindowCloses() async {
    let r = Recorder()
    let lifecycle = r.lifecycle()
    lifecycle.opened(a)
    lifecycle.opened(a)
    lifecycle.opened(b)
    await lifecycle.accountRemoved(a)
    #expect(r.removed.isEmpty && lifecycle.pending == [a] && r.saved.last == [a], "saved before anything is attempted")
    await lifecycle.closed(a)
    #expect(r.removed.isEmpty, "one window still open")
    await lifecycle.closed(a)
    #expect(r.removed == [a] && lifecycle.pending.isEmpty)
    await lifecycle.closed(b)
    #expect(r.removed == [a], "closing a window never deletes a profile that was not removed")
    await lifecycle.closed(b)  // extra close is harmless
    #expect(!lifecycle.isInUse(b))
}

@MainActor @Test func aFailedDeletionIsRetriedAtTheNextLaunchOnly() async {
    let r = Recorder()
    r.succeed = false
    let first = r.lifecycle()
    await first.accountRemoved(a)
    #expect(r.removed == [a] && first.pending == [a] && r.saved.last == [a])

    // Next launch: only the saved pending removal is retried; nothing else is touched.
    r.succeed = true
    r.removed = []
    let next = r.lifecycle(pending: r.saved.last!)
    await next.retryPending()
    #expect(r.removed == [a] && next.pending.isEmpty && r.saved.last == [])
    await next.retryPending()
    #expect(r.removed == [a], "nothing left to retry")
}

@MainActor @Test func nothingIsDeletedWithoutAnExplicitRemoval() async {
    let r = Recorder()
    let lifecycle = r.lifecycle()
    lifecycle.opened(a)
    await lifecycle.closed(a)
    await lifecycle.retryPending()
    #expect(r.removed.isEmpty && r.saved.isEmpty)
}
