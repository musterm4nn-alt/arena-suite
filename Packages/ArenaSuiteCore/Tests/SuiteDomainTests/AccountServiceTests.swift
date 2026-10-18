import ApplicationActions
import Foundation
import SuiteDomain
import Testing

private func principal(_ name: String) -> PrincipalIdentity {
    PrincipalIdentity(namespace: "arena", claims: ["id": "id-\(name)", "supabaseUserId": "sb-\(name)"])
}

/// Scripted provider: email → principal (or failure); account → restore result.
private actor FakeSessions: AccountSessionProviding {
    var principals: [String: PrincipalIdentity] = ["a@x": principal("A"), "b@x": principal("B"), "a2@x": principal("A")]
    var restoreResults: [AccountID: SessionCheck] = [:]
    var signInFailure: SignInFailure?
    var persistFails = false
    var signInDelay: Duration = .zero
    private(set) var persisted: [AccountID: PrincipalIdentity] = [:]
    private(set) var discarded: [AccountID] = []
    private(set) var forgotten: [AccountID] = []
    private(set) var restoreCalls: [AccountID] = []

    func setRestore(_ id: AccountID, _ check: SessionCheck) { restoreResults[id] = check }
    func setFailure(_ failure: SignInFailure?) { signInFailure = failure }
    func setPersistFails(_ value: Bool) { persistFails = value }
    func setPrincipal(_ email: String, _ value: PrincipalIdentity) { principals[email] = value }
    func setDelay(_ value: Duration) { signInDelay = value }

    var forgetFails = false
    func setForgetFails(_ value: Bool) { forgetFails = value }

    /// `persist` for this account suspends until `releasePersist()`: a controlled suspension point.
    private var holdPersistFor: AccountID?
    private var heldPersist: CheckedContinuation<Void, Never>?
    var persistIsHeld: Bool { heldPersist != nil }
    func holdPersist(_ id: AccountID) { holdPersistFor = id }
    func releasePersist() {
        holdPersistFor = nil
        heldPersist?.resume()
        heldPersist = nil
    }

    func signIn(account: AccountID, email: String, password: String) async throws -> PrincipalIdentity {
        if signInDelay > .zero { try? await Task.sleep(for: signInDelay) }
        if let signInFailure { throw signInFailure }
        guard let value = principals[email] else { throw SignInFailure.rejected(status: 401) }
        return value
    }
    func persist(account: AccountID, principal: PrincipalIdentity) async throws {
        if account == holdPersistFor { await withCheckedContinuation { heldPersist = $0 } }
        if persistFails { throw SignInFailure.sessionStorageFailed }
        persisted[account] = principal
    }
    func restore(account: AccountID, expected: PrincipalIdentity) async -> SessionCheck {
        restoreCalls.append(account)
        return restoreResults[account] ?? .noSavedSession
    }
    func verify(account: AccountID, expected: PrincipalIdentity) async -> SessionCheck {
        restoreResults[account] ?? .unreachable
    }
    func discard(account: AccountID) async { discarded.append(account) }
    func forget(account: AccountID) async throws {
        forgotten.append(account)
        if forgetFails { throw SignInFailure.sessionStorageFailed }
        persisted[account] = nil
    }
}

private func makeService(_ sessions: FakeSessions) throws -> (AccountService, AccountRegistryStore) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(UUID().uuidString)")
    let store = AccountRegistryStore(url: directory.appendingPathComponent("accounts/registry.json"))
    return (AccountService(registry: store, sessions: sessions), store)
}

@Test func addedAccountIsPersistedPrivatelyAndSignedIn() async throws {
    let fake = FakeSessions()
    let (service, store) = try makeService(fake)
    let added = try await service.addAccount(email: "a@x", password: "p", displayName: "  Work  ")
    #expect(added.state == .signedIn && added.displayName == "Work" && added.credentialGeneration == 1)
    #expect(await fake.persisted[added.id] == principal("A"))
    let records = try store.load()
    #expect(records.map(\.id) == [added.id] && records.first?.principal == principal("A"))
    let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    let text = try String(contentsOf: store.url, encoding: .utf8)
    #expect(!text.contains("password") && !text.contains("a@x"))
    let context = try await service.context(for: added.id)
    #expect(context.accountID == added.id && context.credentialGeneration == 1)
}

@Test func sameArenaAccountCannotBeAddedTwice() async throws {
    let fake = FakeSessions()
    let (service, store) = try makeService(fake)
    let first = try await service.addAccount(email: "a@x", password: "p", displayName: nil)
    await #expect(throws: AccountError.duplicateAccount(existing: first.id)) {
        _ = try await service.addAccount(email: "a2@x", password: "p", displayName: nil)
    }
    #expect(try store.load().count == 1)
    #expect(await fake.discarded.count == 1)
}

@Test func concurrentDuplicateAddsLeaveOneAccount() async throws {
    let fake = FakeSessions()
    await fake.setDelay(.milliseconds(20))
    let (service, store) = try makeService(fake)
    async let one = try? service.addAccount(email: "a@x", password: "p", displayName: nil)
    async let two = try? service.addAccount(email: "a2@x", password: "p", displayName: nil)
    let results = await [one, two].compactMap { $0 }
    #expect(results.count == 1)
    #expect(try store.load().count == 1)
    #expect(await fake.persisted.count == 1)
}

@Test(arguments: [SignInFailure.rejected(status: 401), .identityUnverified, .unreachable])
func failedSignInAddsNothing(_ failure: SignInFailure) async throws {
    let fake = FakeSessions()
    await fake.setFailure(failure)
    let (service, store) = try makeService(fake)
    await #expect(throws: AccountError.signIn(failure)) {
        _ = try await service.addAccount(email: "a@x", password: "p", displayName: nil)
    }
    #expect(try store.load().isEmpty)
    #expect(await service.accounts().isEmpty)
}

@Test func storageFailureAddsNothing() async throws {
    let fake = FakeSessions()
    await fake.setPersistFails(true)
    let (service, store) = try makeService(fake)
    await #expect(throws: AccountError.signIn(.sessionStorageFailed)) {
        _ = try await service.addAccount(email: "a@x", password: "p", displayName: nil)
    }
    #expect(try store.load().isEmpty)
}

@Test func restoreAllSetsEachAccountIndependently() async throws {
    let fake = FakeSessions()
    let (service, store) = try makeService(fake)
    var ids: [AccountID] = []
    for email in ["a@x", "b@x"] { ids.append(try await service.addAccount(email: email, password: "p", displayName: nil).id) }
    await fake.setPrincipal("c@x", principal("C"))
    await fake.setPrincipal("d@x", principal("D"))
    await fake.setPrincipal("e@x", principal("E"))
    for email in ["c@x", "d@x", "e@x"] { ids.append(try await service.addAccount(email: email, password: "p", displayName: nil).id) }
    let checks: [SessionCheck] = [.verified, .rejected(status: 401), .mismatch, .unreachable, .noSavedSession]
    for (id, check) in zip(ids, checks) { await fake.setRestore(id, check) }

    let relaunched = AccountService(registry: store, sessions: fake)
    try await relaunched.load()
    #expect(await relaunched.accounts().allSatisfy { $0.state == .unverified })
    await relaunched.restoreAll()
    let states = Dictionary(uniqueKeysWithValues: await relaunched.accounts().map { ($0.id, $0.state) })
    #expect(ids.map { states[$0] } == [.signedIn, .needsSignIn, .quarantined, .unreachable, .needsSignIn])
    _ = try await relaunched.context(for: ids[0])
    await #expect(throws: AccountError.notSignedIn(.quarantined)) { _ = try await relaunched.context(for: ids[2]) }
}

@Test func signingInAgainMustKeepThePrincipal() async throws {
    let fake = FakeSessions()
    let (service, _) = try makeService(fake)
    let account = try await service.addAccount(email: "a@x", password: "p", displayName: nil)
    await #expect(throws: AccountError.principalChanged) {
        _ = try await service.signInAgain(account.id, email: "b@x", password: "p")
    }
    #expect(await service.accounts().first?.credentialGeneration == 1)
    let again = try await service.signInAgain(account.id, email: "a2@x", password: "p")
    #expect(again.credentialGeneration == 2 && again.state == .signedIn)
}

@Test func removeForgetsSessionAndPersists() async throws {
    let fake = FakeSessions()
    let (service, store) = try makeService(fake)
    let a = try await service.addAccount(email: "a@x", password: "p", displayName: nil)
    let b = try await service.addAccount(email: "b@x", password: "p", displayName: nil)
    try await service.remove(a.id)
    #expect(await fake.forgotten == [a.id])
    #expect(try store.load().map(\.id) == [b.id])
    await #expect(throws: AccountError.unknownAccount) { try await service.remove(a.id) }
}

@Test func corruptRegistryIsReportedNotReplaced() async throws {
    let fake = FakeSessions()
    let (service, store) = try makeService(fake)
    try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: store.url)
    await #expect(throws: AccountError.registryUnavailable) { try await service.load() }
    #expect(try Data(contentsOf: store.url) == Data("{not json".utf8))
}

// MARK: - Review follow-ups (ses_f2d263478ffe3Zrc1wEU4yZ50M)

private func mode(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Test func registryTightensExistingPermissionsOnLoadAndSave() async throws {
    let fake = FakeSessions()
    let (service, store) = try makeService(fake)
    _ = try await service.addAccount(email: "a@x", password: "p", displayName: nil)
    let directory = store.url.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url.path)
    _ = try store.load()
    #expect(try mode(directory) == 0o700 && mode(store.url) == 0o600)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    try store.save(try store.load())
    #expect(try mode(directory) == 0o700 && mode(store.url) == 0o600)
}

@Test func registrySymlinksAreRefusedNotFollowed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("symlink-\(UUID().uuidString)")
    let directory = root.appendingPathComponent("accounts")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("elsewhere.json")
    try Data("outside".utf8).write(to: target)
    let link = directory.appendingPathComponent("registry.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let store = AccountRegistryStore(url: link)
    #expect(throws: AccountError.registryUnavailable) { _ = try store.load() }
    #expect(throws: AccountError.registryUnavailable) { try store.save([]) }
    #expect(try Data(contentsOf: target) == Data("outside".utf8))
}

@Test func privateFileWritesEmptyDataAndReplacesAtomically() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pf-\(UUID().uuidString)/status.json")
    try PrivateFile.write(Data(), to: url)
    #expect(try PrivateFile.read(url) == Data())
    try PrivateFile.write(Data("two".utf8), to: url)
    #expect(try PrivateFile.read(url) == Data("two".utf8))
    #expect(try mode(url) == 0o600 && mode(url.deletingLastPathComponent()) == 0o700)
    #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["status.json"])
}

@Test func failedReSignInKeepsTheAccountSignedIn() async throws {
    let fake = FakeSessions()
    let (service, _) = try makeService(fake)
    let account = try await service.addAccount(email: "a@x", password: "p", displayName: nil)
    await #expect(throws: AccountError.signIn(.rejected(status: 401))) {
        _ = try await service.signInAgain(account.id, email: "unknown@x", password: "p")
    }
    #expect(await service.accounts().first?.state == .signedIn)
    #expect(await fake.forgotten.isEmpty)
}

// Review 2026-10-18, findings 3 and 8.

/// Removing an earlier account while another re-authenticates shifts positions in the registry; the
/// re-authenticated account must still be the one updated (with two accounts the stale position
/// would be past the end).
@Test(arguments: [2, 3])
func reauthenticationFindsItsAccountAgainAfterSuspending(_ count: Int) async throws {
    let fake = FakeSessions()
    await fake.setPrincipal("c@x", principal("C"))
    let (service, store) = try makeService(fake)
    var added: [AccountSummary] = []
    for email in ["a@x", "b@x", "c@x"].prefix(count) {
        added.append(try await service.addAccount(email: email, password: "p", displayName: nil))
    }
    let (first, target) = (added[0], added[1])
    await fake.holdPersist(target.id)
    let again = Task { try await service.signInAgain(target.id, email: "b@x", password: "p") }
    var waited = 0
    while await !fake.persistIsHeld, waited < 100_000 {
        await Task.yield()
        waited += 1
    }
    try #require(await fake.persistIsHeld, "re-authentication reached persist")
    try await service.remove(first.id)
    await fake.releasePersist()
    let result = try await again.value
    #expect(result.id == target.id && result.credentialGeneration == 2)
    let generations = Dictionary(uniqueKeysWithValues: try store.load().map { ($0.id, $0.credentialGeneration) })
    var expected = [target.id: UInt64(2)]
    if count == 3 { expected[added[2].id] = 1 }
    #expect(generations == expected, "only the re-authenticated account changed")
}

@Test func removalKeepsTheAccountWhenItsSavedSessionCannotBeDeleted() async throws {
    let fake = FakeSessions()
    let (service, store) = try makeService(fake)
    let account = try await service.addAccount(email: "a@x", password: "p", displayName: nil)
    await fake.setForgetFails(true)
    await #expect(throws: AccountError.sessionDeletionFailed) { try await service.remove(account.id) }
    #expect(try store.load().map(\.id) == [account.id], "still listed, so the removal can be retried")
    #expect(await service.accounts().first?.state == .needsSignIn)
    #expect(await fake.persisted[account.id] != nil)

    await fake.setForgetFails(false)
    try await service.remove(account.id)
    #expect(try store.load().isEmpty)
    #expect(await fake.persisted[account.id] == nil)
    #expect(await fake.forgotten == [account.id, account.id])
}

@Test func removalWhoseRegistrySaveFailsLeavesTheAccountUnableToSync() async throws {
    let fake = FakeSessions()
    let (service, store) = try makeService(fake)
    let account = try await service.addAccount(email: "a@x", password: "p", displayName: nil)
    // The registry refuses to write through a symlink: the session is deleted, the save then fails.
    let real = store.url.deletingLastPathComponent().appendingPathComponent("registry.real")
    try FileManager.default.moveItem(at: store.url, to: real)
    try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: real)
    await #expect(throws: AccountError.registryUnavailable) { try await service.remove(account.id) }
    #expect(await fake.persisted[account.id] == nil)
    #expect(await service.accounts().map(\.id) == [account.id])
    #expect(await service.accounts().first?.state == .needsSignIn)
    await #expect(throws: AccountError.notSignedIn(.needsSignIn)) { _ = try await service.context(for: account.id) }
}
