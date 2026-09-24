import Foundation
import SuiteDomain

/// Result of checking a saved or live session against an account's principal.
public enum SessionCheck: Equatable, Sendable {
    case verified
    /// Nothing saved for this account.
    case noSavedSession
    /// The server no longer accepts the session (e.g. 401). Sign in again.
    case rejected(status: Int?)
    /// The server identified a different principal. Session material has been discarded.
    case mismatch
    /// Transport failure, rate limit or server error; nothing was concluded.
    case unreachable
}

public enum SignInFailure: Error, Equatable, Sendable {
    case rejected(status: Int)
    case identityUnverified
    case unreachable
    case sessionStorageFailed
}

/// Implemented by the Arena adapter. Each account has its own isolated session; no request other
/// than sign-in and identity verification is sent before the principal is verified.
public protocol AccountSessionProviding: Sendable {
    /// Signs in on a fresh isolated session for `account` and returns the verified principal.
    /// The new session is *pending*: it does not replace the account's active session until `persist`.
    func signIn(account: AccountID, email: String, password: String) async throws -> PrincipalIdentity
    /// Saves the pending session to secure storage and makes it the account's active session.
    func persist(account: AccountID, principal: PrincipalIdentity) async throws
    /// Loads saved session material into a fresh isolated session and verifies it.
    func restore(account: AccountID, expected: PrincipalIdentity) async -> SessionCheck
    /// Verifies the live session again (and saves rotated session material).
    func verify(account: AccountID, expected: PrincipalIdentity) async -> SessionCheck
    /// Drops a pending (unsaved) sign-in. The active session and saved material are kept.
    func discard(account: AccountID) async
    /// Drops the in-memory session and deletes saved session material.
    func forget(account: AccountID) async throws
}

public enum AccountError: Error, Equatable, Sendable {
    case duplicateAccount(existing: AccountID)
    /// Signing in to an existing account produced a different principal.
    case principalChanged
    case unknownAccount
    case notSignedIn(AccountAuthState)
    case busy
    case signIn(SignInFailure)
    case registryUnavailable
}

/// What views and future MCP/CLI surfaces see. No credentials, no identity claim values.
public struct AccountSummary: Equatable, Sendable, Identifiable {
    public let id: AccountID
    public let displayName: String
    public let state: AccountAuthState
    public let credentialGeneration: UInt64
    public let createdAt: Date
}

/// Owns the account registry and per-account authentication state (plan v3 §13, Phase 2).
/// Operations on different accounts run independently; one operation per account at a time.
public actor AccountService {
    private let registry: AccountRegistryStore
    private let sessions: any AccountSessionProviding
    private let now: @Sendable () -> Date
    private var records: [AccountRecord] = []
    private var states: [AccountID: AccountAuthState] = [:]
    private var busy: Set<AccountID> = []

    public init(
        registry: AccountRegistryStore, sessions: any AccountSessionProviding,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.registry = registry
        self.sessions = sessions
        self.now = now
    }

    /// Loads the registry. Every account starts `unverified`; call `restoreAll()` to check sessions.
    public func load() throws {
        records = try registry.load()
        states = Dictionary(uniqueKeysWithValues: records.map { ($0.id, .unverified) })
    }

    public func accounts() -> [AccountSummary] {
        records.map { summary($0) }
    }

    /// The immutable context for a new operation. Only signed-in accounts get one.
    public func context(for id: AccountID) throws -> AccountContext {
        guard let record = records.first(where: { $0.id == id }) else { throw AccountError.unknownAccount }
        let state = states[id] ?? .unverified
        guard state == .signedIn else { throw AccountError.notSignedIn(state) }
        return record.context
    }

    public func addAccount(email: String, password: String, displayName: String?) async throws -> AccountSummary {
        let id = AccountID()
        busy.insert(id)
        defer { busy.remove(id) }
        let principal: PrincipalIdentity
        do {
            principal = try await sessions.signIn(account: id, email: email, password: password)
        } catch {
            await sessions.discard(account: id)
            throw AccountError.signIn((error as? SignInFailure) ?? .unreachable)
        }
        if let existing = records.first(where: { $0.principal == principal }) {
            await sessions.discard(account: id)
            throw AccountError.duplicateAccount(existing: existing.id)
        }
        do {
            try await sessions.persist(account: id, principal: principal)
        } catch {
            await sessions.discard(account: id)
            throw AccountError.signIn(.sessionStorageFailed)
        }
        // Actor reentrancy: another addAccount for the same principal may have finished meanwhile.
        if let existing = records.first(where: { $0.principal == principal }) {
            try? await sessions.forget(account: id)
            throw AccountError.duplicateAccount(existing: existing.id)
        }
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = AccountRecord(
            id: id, displayName: name?.isEmpty == false ? name! : "Account \(records.count + 1)",
            principal: principal, createdAt: now(), credentialGeneration: 1)
        do {
            try registry.save(records + [record])
        } catch {
            try? await sessions.forget(account: id)
            throw AccountError.registryUnavailable
        }
        records.append(record)
        states[id] = .signedIn
        return summary(record)
    }

    /// Re-authenticates an existing account. The new session must belong to the same principal.
    public func signInAgain(_ id: AccountID, email: String, password: String) async throws -> AccountSummary {
        guard records.contains(where: { $0.id == id }) else { throw AccountError.unknownAccount }
        guard busy.insert(id).inserted else { throw AccountError.busy }
        defer { busy.remove(id) }
        let principal: PrincipalIdentity
        do {
            principal = try await sessions.signIn(account: id, email: email, password: password)
        } catch {
            await sessions.discard(account: id)
            throw AccountError.signIn((error as? SignInFailure) ?? .unreachable)
        }
        // The account may have been removed while signing in.
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            await sessions.discard(account: id)
            throw AccountError.unknownAccount
        }
        guard records[index].principal == principal else {
            await sessions.discard(account: id)
            throw AccountError.principalChanged
        }
        do {
            try await sessions.persist(account: id, principal: principal)
        } catch {
            await sessions.discard(account: id)
            throw AccountError.signIn(.sessionStorageFailed)
        }
        var updated = records
        updated[index].credentialGeneration += 1
        do { try registry.save(updated) } catch { throw AccountError.registryUnavailable }
        records = updated
        states[id] = .signedIn
        return summary(records[index])
    }

    /// Restores every account's saved session concurrently (one request in flight per account).
    public func restoreAll() async {
        let targets = records.filter { !busy.contains($0.id) }
        targets.forEach { busy.insert($0.id) }
        let sessions = self.sessions
        let results = await withTaskGroup(of: (AccountID, SessionCheck).self) { group in
            for record in targets {
                group.addTask { (record.id, await sessions.restore(account: record.id, expected: record.principal)) }
            }
            var collected: [(AccountID, SessionCheck)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        for (id, check) in results {
            busy.remove(id)
            if records.contains(where: { $0.id == id }) { states[id] = Self.state(for: check) }
        }
    }

    @discardableResult
    public func verify(_ id: AccountID) async throws -> AccountAuthState {
        guard let record = records.first(where: { $0.id == id }) else { throw AccountError.unknownAccount }
        guard busy.insert(id).inserted else { throw AccountError.busy }
        defer { busy.remove(id) }
        let check =
            states[id] == .signedIn
            ? await sessions.verify(account: id, expected: record.principal)
            : await sessions.restore(account: id, expected: record.principal)
        guard records.contains(where: { $0.id == id }) else { throw AccountError.unknownAccount }
        let state = Self.state(for: check)
        states[id] = state
        return state
    }

    public func rename(_ id: AccountID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = records.firstIndex(where: { $0.id == id }), !trimmed.isEmpty else {
            throw AccountError.unknownAccount
        }
        var updated = records
        updated[index].displayName = trimmed
        do { try registry.save(updated) } catch { throw AccountError.registryUnavailable }
        records = updated
    }

    /// Deletes saved session material, then the registry entry. Local archive data is not deleted.
    public func remove(_ id: AccountID) async throws {
        guard records.contains(where: { $0.id == id }) else { throw AccountError.unknownAccount }
        guard busy.insert(id).inserted else { throw AccountError.busy }
        defer { busy.remove(id) }
        try? await sessions.forget(account: id)
        let remaining = records.filter { $0.id != id }
        do { try registry.save(remaining) } catch { throw AccountError.registryUnavailable }
        records = remaining
        states[id] = nil
    }

    private func summary(_ record: AccountRecord) -> AccountSummary {
        AccountSummary(
            id: record.id, displayName: record.displayName, state: states[record.id] ?? .unverified,
            credentialGeneration: record.credentialGeneration, createdAt: record.createdAt)
    }

    static func state(for check: SessionCheck) -> AccountAuthState {
        switch check {
        case .verified: .signedIn
        case .noSavedSession, .rejected: .needsSignIn
        case .mismatch: .quarantined
        case .unreachable: .unreachable
        }
    }
}

/// `accounts/registry.json`: the list of local accounts. Written atomically with owner-only access.
public struct AccountRegistryStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    private struct File: Codable {
        let format: Int
        let accounts: [AccountRecord]
    }

    public func load() throws -> [AccountRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data: Data?
        do { data = try PrivateFile.read(url) } catch { throw AccountError.registryUnavailable }
        guard let data else { return [] }
        guard let file = try? decoder.decode(File.self, from: data), file.format == 1 else {
            throw AccountError.registryUnavailable
        }
        return file.accounts
    }

    public func save(_ accounts: [AccountRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try PrivateFile.write(try encoder.encode(File(format: 1, accounts: accounts)), to: url)
        } catch { throw AccountError.registryUnavailable }
    }
}
