import ApplicationActions
import CaptureJournal
import Foundation
import SuiteDomain
import Testing

private actor SlowEngine: HistorySyncing {
    private(set) var calls: [(AccountID, PrincipalIdentity)] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var waiting = false

    func release() { gate?.resume(); gate = nil }
    var isWaiting: Bool { waiting }

    nonisolated func sync(
        account: AccountContext, principal: PrincipalIdentity, journal: JournalWriter, journalRoot: URL,
        options: SyncOptions, progress: @escaping @Sendable (SyncProgress) -> Void
    ) async -> SyncManifest {
        await record(account.accountID, principal)
        return SyncManifest(jobID: UUID(), accountID: account.accountID, outcome: .completed)
    }

    private func record(_ id: AccountID, _ principal: PrincipalIdentity) async {
        calls.append((id, principal))
        waiting = true
        await withCheckedContinuation { gate = $0 }
        waiting = false
    }
}

private actor Signer: AccountSessionProviding {
    func signIn(account: AccountID, email: String, password: String) async throws -> PrincipalIdentity {
        PrincipalIdentity(namespace: "arena", claims: ["id": email])
    }
    func persist(account: AccountID, principal: PrincipalIdentity) async throws {}
    func restore(account: AccountID, expected: PrincipalIdentity) async -> SessionCheck { .noSavedSession }
    func verify(account: AccountID, expected: PrincipalIdentity) async -> SessionCheck { .verified }
    func discard(account: AccountID) async {}
    func forget(account: AccountID) async throws {}
}

private func setup() async throws -> (AccountService, HistorySyncService, SlowEngine, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("svc-\(UUID().uuidString)")
    let accounts = AccountService(
        registry: AccountRegistryStore(url: root.appendingPathComponent("accounts/registry.json")), sessions: Signer())
    let engine = SlowEngine()
    return (accounts, HistorySyncService(accounts: accounts, journals: JournalStore(archiveRoot: root), engine: engine), engine, root)
}

private func waitUntilWaiting(_ engine: SlowEngine) async {
    while await !engine.isWaiting { await Task.yield() }
}

@Test func syncRequiresASignedInAccount() async throws {
    let (_, service, _, _) = try await setup()
    await #expect(throws: AccountError.unknownAccount) { _ = try await service.sync(AccountID()) }
}

@Test func oneJobPerAccountAndAccountsAreIndependent() async throws {
    let (accounts, service, engine, root) = try await setup()
    let a = try await accounts.addAccount(email: "a", password: "p", displayName: nil)
    let b = try await accounts.addAccount(email: "b", password: "p", displayName: nil)
    let first = Task { try await service.sync(a.id) }
    await waitUntilWaiting(engine)
    #expect(await service.isRunning(a.id))
    await #expect(throws: AccountError.busy) { _ = try await service.sync(a.id) }
    #expect(await !service.isRunning(b.id))
    await engine.release()
    let manifest = try await first.value
    #expect(manifest.outcome == .completed && manifest.accountID == a.id)
    #expect(await engine.calls.map(\.1) == [PrincipalIdentity(namespace: "arena", claims: ["id": "a"])])
    #expect(await service.manifest(a.id) == manifest)
    let journal = root.appendingPathComponent("accounts/\(a.id.rawValue.uuidString)/journal")
    #expect(FileManager.default.fileExists(atPath: journal.appendingPathComponent("journal.lock").path))
}
