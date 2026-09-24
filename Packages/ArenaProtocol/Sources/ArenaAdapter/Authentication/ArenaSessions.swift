import ApplicationActions
import FoundationTransport
import Foundation
import SuiteDomain

/// Observed request recipes (ledger B-001, S-001, N-002..N-010). Nothing here is guessed.
enum ArenaRoutes {
    static let origin = URL(string: "https://arena.ai")!
    static let cookieDomains: Set<String> = ["arena.ai"]

    /// B-001/S-001: JSON `{email, password, shouldLinkHistory}`. `false` is our declared choice (N-002).
    static func signIn(email: String, password: String) throws -> URLRequest {
        var request = URLRequest(url: origin.appendingPathComponent("nextjs-api/sign-in/email"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SignInBody(email: email, password: password, shouldLinkHistory: false))
        return request
    }

    /// B-001: `GET /api/me` → `user.id`, `user.supabaseUserId`. No session → 401 JSON (N-008).
    static func identity() -> URLRequest {
        var request = URLRequest(url: origin.appendingPathComponent("api/me"))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private struct SignInBody: Encodable {
        let email: String
        let password: String
        let shouldLinkHistory: Bool
    }

    struct IdentityResponse: Decodable {
        struct User: Decodable {
            let id: String
            let supabaseUserId: String
        }
        let user: User
    }

    static func principal(from exchange: HTTPExchange) -> PrincipalIdentity? {
        guard exchange.status == 200, exchange.transferEnd == .complete,
            let decoded = try? JSONDecoder().decode(IdentityResponse.self, from: exchange.body),
            !decoded.user.id.isEmpty, !decoded.user.supabaseUserId.isEmpty
        else { return nil }
        return PrincipalIdentity(
            namespace: "arena", claims: ["id": decoded.user.id, "supabaseUserId": decoded.user.supabaseUserId])
    }
}

public enum SessionGateError: Error, Equatable, Sendable {
    /// The session has no verified principal yet (or was quarantined); nothing was sent.
    case notVerified
}

/// One account's live session. Only sign-in and identity requests may be sent before the principal
/// is verified; every other request goes through `performVerified`.
actor ArenaAccountSession {
    nonisolated let transport: any HTTPTransporting
    private(set) var verified: PrincipalIdentity?
    private var savedFingerprint: String?

    init(transport: any HTTPTransporting) { self.transport = transport }

    func signIn(email: String, password: String) async throws -> PrincipalIdentity {
        verified = nil
        let request: URLRequest
        do { request = try ArenaRoutes.signIn(email: email, password: password) } catch {
            throw SignInFailure.identityUnverified
        }
        // Authentication request and response bodies are never retained or logged.
        let reply: HTTPExchange
        do { reply = try await transport.perform(request) } catch { throw SignInFailure.unreachable }
        guard reply.transferEnd == .complete, let status = reply.status else { throw SignInFailure.unreachable }
        guard status == 200 else { throw SignInFailure.rejected(status: status) }
        let identity: HTTPExchange
        do { identity = try await transport.perform(ArenaRoutes.identity()) } catch { throw SignInFailure.unreachable }
        guard let principal = ArenaRoutes.principal(from: identity) else { throw SignInFailure.identityUnverified }
        verified = principal
        return principal
    }

    func check(expected: PrincipalIdentity) async -> SessionCheck {
        let reply: HTTPExchange
        do { reply = try await transport.perform(ArenaRoutes.identity()) } catch { return .unreachable }
        guard reply.transferEnd == .complete, let status = reply.status else { return .unreachable }
        switch status {
        case 200:
            guard let principal = ArenaRoutes.principal(from: reply) else { return .unreachable }
            guard principal == expected else {
                verified = nil
                return .mismatch
            }
            verified = principal
            return .verified
        case 401, 403:
            verified = nil
            return .rejected(status: status)
        default:
            return .unreachable
        }
    }

    /// Phase 3 entry point for every non-authentication request.
    func performVerified(_ request: URLRequest) async throws -> HTTPExchange {
        guard verified != nil else { throw SessionGateError.notVerified }
        return try await transport.perform(request)
    }

    func exportForStorage() throws -> (cookies: Data, fingerprint: String) {
        (try transport.exportCookies(domains: ArenaRoutes.cookieDomains),
            transport.cookieFingerprint(domains: ArenaRoutes.cookieDomains))
    }

    var needsSave: Bool { transport.cookieFingerprint(domains: ArenaRoutes.cookieDomains) != savedFingerprint }
    func markSaved(_ fingerprint: String) { savedFingerprint = fingerprint }
}

/// Per-account sessions for the application layer. Accounts never share a transport or cookie jar.
public actor ArenaAccountSessions: AccountSessionProviding {
    private let vault: any SessionVault
    private let makeTransport: @Sendable () -> any HTTPTransporting
    private var sessions: [AccountID: ArenaAccountSession] = [:]

    public init(
        vault: any SessionVault = KeychainSessionVault(),
        makeTransport: @escaping @Sendable () -> any HTTPTransporting = { AccountHTTPSession() }
    ) {
        self.vault = vault
        self.makeTransport = makeTransport
    }

    public func signIn(account: AccountID, email: String, password: String) async throws -> PrincipalIdentity {
        let session = ArenaAccountSession(transport: makeTransport())
        sessions[account] = session  // replaces any previous session for this account
        return try await session.signIn(email: email, password: password)
    }

    public func persist(account: AccountID, principal: PrincipalIdentity) async throws {
        guard let session = sessions[account], await session.verified == principal else {
            throw SignInFailure.identityUnverified
        }
        try await save(session, account: account, principal: principal)
    }

    public func restore(account: AccountID, expected: PrincipalIdentity) async -> SessionCheck {
        sessions[account] = nil
        let stored: StoredSession?
        do { stored = try vault.load(account: account) } catch {
            try? vault.delete(account: account)
            return .rejected(status: nil)
        }
        guard let stored else { return .noSavedSession }
        // Material saved for another principal is never sent anywhere.
        guard stored.principal == expected else {
            try? vault.delete(account: account)
            return .mismatch
        }
        let session = ArenaAccountSession(transport: makeTransport())
        do { try session.transport.importCookies(stored.cookies, domains: ArenaRoutes.cookieDomains) } catch {
            try? vault.delete(account: account)
            return .rejected(status: nil)
        }
        await session.markSaved(session.transport.cookieFingerprint(domains: ArenaRoutes.cookieDomains))
        sessions[account] = session
        return await settle(session, account: account, expected: expected, check: session.check(expected: expected))
    }

    public func verify(account: AccountID, expected: PrincipalIdentity) async -> SessionCheck {
        guard let session = sessions[account] else { return await restore(account: account, expected: expected) }
        return await settle(session, account: account, expected: expected, check: session.check(expected: expected))
    }

    public func discard(account: AccountID) async { sessions[account] = nil }

    public func forget(account: AccountID) async throws {
        sessions[account] = nil
        try vault.delete(account: account)
    }

    /// The verified session for Phase 3 requests, or nil.
    func session(for account: AccountID) async -> ArenaAccountSession? {
        guard let session = sessions[account], await session.verified != nil else { return nil }
        return session
    }

    private func settle(
        _ session: ArenaAccountSession, account: AccountID, expected: PrincipalIdentity, check: SessionCheck
    ) async -> SessionCheck {
        switch check {
        case .verified:
            // Arena re-issues auth cookies from time to time (N-008); keep the saved copy current.
            if await session.needsSave { try? await save(session, account: account, principal: expected) }
        case .mismatch, .rejected:
            sessions[account] = nil
            try? vault.delete(account: account)
        case .noSavedSession, .unreachable:
            break
        }
        return check
    }

    private func save(_ session: ArenaAccountSession, account: AccountID, principal: PrincipalIdentity) async throws {
        let exported: (cookies: Data, fingerprint: String)
        do { exported = try await session.exportForStorage() } catch { throw SignInFailure.sessionStorageFailed }
        do {
            try vault.save(StoredSession(principal: principal, cookies: exported.cookies), account: account)
        } catch { throw SignInFailure.sessionStorageFailed }
        await session.markSaved(exported.fingerprint)
    }
}
