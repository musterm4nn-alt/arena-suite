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

    private var result: (SyncOutcome, AccountAuthState?) = (.completed, nil)
    func setResult(_ outcome: SyncOutcome, _ state: AccountAuthState?) { result = (outcome, state) }

    nonisolated func sync(
        account: AccountContext, principal: PrincipalIdentity, journal: JournalWriter, journalRoot: URL,
        options: SyncOptions, progress: @escaping @Sendable (SyncProgress) -> Void
    ) async -> SyncManifest {
        await record(account.accountID, principal)
        var manifest = SyncManifest(jobID: UUID(), accountID: account.accountID, outcome: await result.0)
        manifest.sessionState = await result.1
        return manifest
    }

    private(set) var refreshed: [String] = []

    nonisolated func refresh(
        account: AccountContext, principal: PrincipalIdentity, journal: JournalWriter, journalRoot: URL,
        conversationID: String, options: SyncOptions
    ) async -> SyncManifest {
        await noteRefresh(conversationID)
        await record(account.accountID, principal)
        var manifest = SyncManifest(jobID: UUID(), accountID: account.accountID, outcome: await result.0)
        manifest.sessionState = await result.1
        return manifest
    }

    private func noteRefresh(_ id: String) { refreshed.append(id) }

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

@Test func maintenanceAndSyncExcludeEachOther() async throws {
    let (accounts, service, engine, _) = try await setup()
    let a = try await accounts.addAccount(email: "a", password: "p", displayName: nil)
    // Maintenance held: no sync may start.
    try await service.beginMaintenance()
    await #expect(throws: AccountError.busy) { try await service.beginMaintenance() }
    await #expect(throws: AccountError.busy) { _ = try await service.sync(a.id) }
    #expect(await engine.calls.isEmpty)
    await service.endMaintenance()
    // Sync running: maintenance is refused until it ends.
    let job = Task { try await service.sync(a.id) }
    await waitUntilWaiting(engine)
    await #expect(throws: AccountError.busy) { try await service.beginMaintenance() }
    await engine.release()
    _ = try await job.value
    try await service.beginMaintenance()
    await service.endMaintenance()
}

// Review 2026-10-18, finding 6.

@Test(arguments: [
    (SyncOutcome.needsSignIn, AccountAuthState.needsSignIn), (.needsSignIn, .quarantined), (.blocked, .blocked),
])
func aRejectedSyncUpdatesTheAccountsState(_ outcome: SyncOutcome, _ state: AccountAuthState) async throws {
    let (accounts, service, engine, _) = try await setup()
    let a = try await accounts.addAccount(email: "a", password: "p", displayName: nil)
    let b = try await accounts.addAccount(email: "b", password: "p", displayName: nil)
    await engine.setResult(outcome, state)
    let job = Task { try await service.sync(a.id) }
    await waitUntilWaiting(engine)
    await engine.release()
    #expect(try await job.value.outcome == outcome)
    let states = Dictionary(uniqueKeysWithValues: await accounts.accounts().map { ($0.id, $0.state) })
    #expect(states == [a.id: state, b.id: .signedIn], "only the synced account changed")
    await #expect(throws: AccountError.notSignedIn(state)) { _ = try await service.sync(a.id) }
}

@Test func anOlderJobsRejectionNeverDowngradesANewerSignIn() async throws {
    let (accounts, service, engine, _) = try await setup()
    let a = try await accounts.addAccount(email: "a", password: "p", displayName: nil)
    await engine.setResult(.needsSignIn, .needsSignIn)
    let job = Task { try await service.sync(a.id) }
    await waitUntilWaiting(engine)
    // Signed in again while the job (started with generation 1) still runs.
    #expect(try await accounts.signInAgain(a.id, email: "a", password: "p").credentialGeneration == 2)
    await engine.release()
    #expect(try await job.value.outcome == .needsSignIn)
    #expect(await accounts.accounts().first?.state == .signedIn)
}

// Refresh (Docs/sync-refresh-2026-10-20.md): the same job slot as a sync.

@Test func aRefreshAndASyncOfOneAccountExcludeEachOther() async throws {
    let (accounts, service, engine, _) = try await setup()
    let a = try await accounts.addAccount(email: "a", password: "p", displayName: nil)
    let b = try await accounts.addAccount(email: "b", password: "p", displayName: nil)
    let refresh = Task { try await service.refresh(a.id, conversationID: "c1") }
    await waitUntilWaiting(engine)
    #expect(await service.isRunning(a.id))
    await #expect(throws: AccountError.busy) { _ = try await service.sync(a.id) }
    await #expect(throws: AccountError.busy) { _ = try await service.refresh(a.id, conversationID: "c2") }
    await #expect(throws: AccountError.busy) { try await service.beginMaintenance() }
    #expect(await !service.isRunning(b.id))
    await engine.release()
    #expect(try await refresh.value.outcome == .completed)
    #expect(await engine.refreshed == ["c1"])
    #expect(await service.manifest(a.id) == nil, "a refresh is not the account's last sync")
    // A sync running: no refresh of that account.
    let sync = Task { try await service.sync(a.id) }
    await waitUntilWaiting(engine)
    await #expect(throws: AccountError.busy) { _ = try await service.refresh(a.id, conversationID: "c1") }
    await engine.release()
    _ = try await sync.value
    #expect(await engine.refreshed == ["c1"])
}

@Test func aRefreshIsRefusedDuringMaintenanceAndWithoutASignedInAccount() async throws {
    let (accounts, service, engine, _) = try await setup()
    let a = try await accounts.addAccount(email: "a", password: "p", displayName: nil)
    try await service.beginMaintenance()
    await #expect(throws: AccountError.busy) { _ = try await service.refresh(a.id, conversationID: "c1") }
    await service.endMaintenance()
    await #expect(throws: AccountError.unknownAccount) { _ = try await service.refresh(AccountID(), conversationID: "c1") }
    #expect(await engine.refreshed.isEmpty)
}

@Test func aRejectedRefreshUpdatesTheAccountsState() async throws {
    let (accounts, service, engine, _) = try await setup()
    let a = try await accounts.addAccount(email: "a", password: "p", displayName: nil)
    await engine.setResult(.blocked, .blocked)
    let job = Task { try await service.refresh(a.id, conversationID: "c1") }
    await waitUntilWaiting(engine)
    await engine.release()
    #expect(try await job.value.outcome == .blocked)
    await #expect(throws: AccountError.notSignedIn(.blocked)) { _ = try await service.refresh(a.id, conversationID: "c1") }
}
