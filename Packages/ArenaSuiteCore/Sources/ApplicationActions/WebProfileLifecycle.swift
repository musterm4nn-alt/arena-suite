import Foundation
import SuiteDomain

/// When the embedded site window's per-account web profiles are deleted (ADR 0006).
///
/// A profile is deleted only for an account the user removed: never inferred from an account list,
/// which may be missing, unreadable or belong to another archive root. A profile still used by an
/// open window is deleted when its last window closes. A deletion that fails (WebKit releases a
/// closed web view asynchronously) stays pending in `persist` and is retried at the next launch.
@MainActor
public final class WebProfileLifecycle {
    /// Deletes one profile; false when it could not be deleted now.
    public typealias Remover = @MainActor (AccountID) async -> Bool

    private let remover: Remover
    private let persist: ([AccountID]) -> Void
    private var inUse: [AccountID: Int] = [:]
    public private(set) var pending: Set<AccountID>

    /// `pending`: removals saved by an earlier run. `persist` saves the current pending list.
    public init(pending: [AccountID], persist: @escaping ([AccountID]) -> Void, remover: @escaping Remover) {
        self.pending = Set(pending)
        self.persist = persist
        self.remover = remover
    }

    public func isInUse(_ account: AccountID) -> Bool { inUse[account] != nil }

    public func opened(_ account: AccountID) { inUse[account, default: 0] += 1 }

    public func closed(_ account: AccountID) async {
        guard let count = inUse[account] else { return }
        inUse[account] = count > 1 ? count - 1 : nil
        if inUse[account] == nil, pending.contains(account) { await attempt(account) }
    }

    /// The user removed the account from Arena Suite.
    public func accountRemoved(_ account: AccountID) async {
        mark(account)
        if inUse[account] == nil { await attempt(account) }
    }

    /// Retries removals that could not finish earlier (call at launch). Touches nothing else.
    public func retryPending() async {
        for account in pending.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) where inUse[account] == nil {
            await attempt(account)
        }
    }

    private func mark(_ account: AccountID) {
        guard pending.insert(account).inserted else { return }
        save()
    }

    private func attempt(_ account: AccountID) async {
        if await remover(account) {
            pending.remove(account)
            save()
        }
    }

    private func save() { persist(pending.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }) }
}
