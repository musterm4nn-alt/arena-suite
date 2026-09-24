import Foundation

public enum AuthStep: String, Sendable { case signIn, identity }

/// Deliberately value-free errors; underlying HTTP bodies/URLs/errors are never interpolated.
public enum ResearchFailure: Error, Equatable, Sendable {
    case busy, inputMissing, notAuthenticated, identityMismatch, identityShapeUnverified, transportFailed
    case httpFailure(AuthStep, Int)
    case generationAlreadyAttempted, invalidLocalClock
    case alreadyAuthenticated
    case sessionStorageFailed
}

/// Sensitive identity values remain in memory/UI only. This is not an account registry entry.
public struct ObservedIdentity: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: String
    public let supabaseUserID: String
    public let email: String
    public var description: String { "ObservedIdentity(redacted)" }
    public var debugDescription: String { description }
}

/// Sensitive presentation-only data. Not an Error, archive DTO, or diagnostic/log payload.
/// User may reveal this text locally; ordinary status remains value-free.
public struct LocalAuthError: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let serverMessage: String?
    public let requiresVerification: Bool?
    public let interpretation: String
    public var description: String { "LocalAuthError(redacted)" }
    public var debugDescription: String { description }

    static func inspect(_ body: Data) -> LocalAuthError {
        guard body.count <= 65_536 else {
            return LocalAuthError(
                serverMessage: nil, requiresVerification: nil, interpretation: "Body exceeds local inspection limit.")
        }
        guard let fields = try? JSONDecoder().decode(ErrorFields.self, from: body) else {
            return LocalAuthError(
                serverMessage: nil, requiresVerification: nil,
                interpretation: "No matching JSON error shape; body remains omitted.")
        }
        return LocalAuthError(
            serverMessage: fields.error.map { String($0.prefix(512)) },
            requiresVerification: fields.requiresVerification,
            interpretation: "Selected error fields only; server text is untrusted and limited to 512 characters."
        )
    }
}

private struct ErrorFields: Decodable {
    // These keys are observed in S-001's public error-handling source, not invented response semantics.
    let error: String?
    let requiresVerification: Bool?
}

/// Disposable proof based on B-001/S-001, not the product Arena adapter.
/// No automatic retry, refresh, durable storage or production archive support.
public actor NativeAuthClient {
    private let executor: any HTTPExecuting
    private var inFlight = false
    private var identity: ObservedIdentity?
    private var quarantined = false
    private var localAuthError: LocalAuthError?
    private var generationAttempted = false
    private let sessionStore: any ResearchSessionStoring

    public init(
        executor: any HTTPExecuting = NativeHTTPExecutor(),
        sessionStore: any ResearchSessionStoring = KeychainResearchSessionStore()
    ) {
        self.executor = executor
        self.sessionStore = sessionStore
    }

    public func saveSession() throws {
        guard !inFlight else { throw ResearchFailure.busy }
        guard !quarantined else { throw ResearchFailure.identityMismatch }
        guard let identity else { throw ResearchFailure.notAuthenticated }
        guard let cookieExecutor = executor as? any CookieSessionExecuting else {
            throw ResearchFailure.sessionStorageFailed
        }
        do {
            let saved = SavedResearchSession(
                version: 1, id: identity.id, supabaseUserID: identity.supabaseUserID,
                cookies: try cookieExecutor.exportCookieData())
            try sessionStore.save(JSONEncoder().encode(saved))
        } catch { throw ResearchFailure.sessionStorageFailed }
    }

    public func forgetSavedSession() throws {
        guard !inFlight else { throw ResearchFailure.busy }
        do { try sessionStore.remove() } catch { throw ResearchFailure.sessionStorageFailed }
    }

    public func restoreSavedSession() async throws -> ObservedIdentity? {
        guard !inFlight else { throw ResearchFailure.busy }
        guard !quarantined else { throw ResearchFailure.identityMismatch }
        guard identity == nil else { throw ResearchFailure.alreadyAuthenticated }
        inFlight = true
        defer { inFlight = false }
        let saved: SavedResearchSession
        do {
            guard let data = try sessionStore.load() else { return nil }
            guard data.count <= 2_097_152 else { throw ResearchFailure.sessionStorageFailed }
            saved = try JSONDecoder().decode(SavedResearchSession.self, from: data)
            guard saved.version == 1, !saved.id.isEmpty, !saved.supabaseUserID.isEmpty,
                let cookieExecutor = executor as? any CookieSessionExecuting
            else { throw ResearchFailure.sessionStorageFailed }
            try cookieExecutor.importCookieData(saved.cookies)
        } catch {
            quarantined = true
            throw ResearchFailure.sessionStorageFailed
        }
        do {
            try Task.checkCancellation()
            let observed = try await fetchIdentity()
            guard observed.id == saved.id && observed.supabaseUserID == saved.supabaseUserID else {
                throw ResearchFailure.identityMismatch
            }
            identity = observed
            return observed
        } catch {
            quarantined = true
            throw error
        }
    }

    public func errorForLocalPresentation() -> LocalAuthError? { localAuthError }

    public func signIn(email: String, password: String) async throws -> ObservedIdentity {
        guard !inFlight else { throw ResearchFailure.busy }
        guard !quarantined else { throw ResearchFailure.identityMismatch }
        guard identity == nil else { throw ResearchFailure.alreadyAuthenticated }
        guard !email.isEmpty && !password.isEmpty else { throw ResearchFailure.inputMissing }
        inFlight = true
        localAuthError = nil
        defer { inFlight = false }

        var request = URLRequest(url: URL(string: "https://arena.ai/nextjs-api/sign-in/email")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Auth-only material is intentionally excluded from ordinary evidence. Never log this request/body.
        // S-001 exposes a Boolean; false is a declared proof choice, not yet a native-verified contract.
        request.httpBody = try JSONEncoder().encode(
            LoginBody(email: email, password: password, shouldLinkHistory: false))
        let response = try await perform(request)
        guard let status = response.status else { throw ResearchFailure.transportFailed }
        guard status == 200 else {
            localAuthError = LocalAuthError.inspect(response.body)
            throw ResearchFailure.httpFailure(.signIn, status)
        }
        // Successful authentication response bodies are neither interpreted nor exported.
        let observed = try await fetchIdentity()
        identity = observed
        return observed
    }

    public func recheckIdentity() async throws -> ObservedIdentity {
        guard !inFlight else { throw ResearchFailure.busy }
        guard !quarantined else { throw ResearchFailure.identityMismatch }
        guard let expected = identity else { throw ResearchFailure.notAuthenticated }
        inFlight = true
        defer { inFlight = false }
        let observed = try await fetchIdentity()
        guard observed.id == expected.id && observed.supabaseUserID == expected.supabaseUserID else {
            quarantined = true
            throw ResearchFailure.identityMismatch
        }
        return observed
    }

    /// H-001: one observed read-only page. No pagination, detail dispatch or generation.
    public func inspectHistoryList() async throws -> HistoryObservation {
        guard !inFlight else { throw ResearchFailure.busy }
        guard !quarantined else { throw ResearchFailure.identityMismatch }
        guard let expected = identity else { throw ResearchFailure.notAuthenticated }
        inFlight = true
        defer { inFlight = false }
        let current = try await fetchIdentity()
        guard current.id == expected.id && current.supabaseUserID == expected.supabaseUserID else {
            quarantined = true
            throw ResearchFailure.identityMismatch
        }
        try Task.checkCancellation()
        var request = URLRequest(
            url: URL(string: "https://arena.ai/api/history/unified?limit=20&includeArchived=false")!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            return HistoryObservation(response: try await executor.perform(request))
        } catch {
            throw ResearchFailure.transportFailed
        }
    }

    public func inspectFirstHistoryDetail() async throws -> HistoryDetailObservation {
        guard !inFlight else { throw ResearchFailure.busy }
        guard !quarantined else { throw ResearchFailure.identityMismatch }
        guard let expected = identity else { throw ResearchFailure.notAuthenticated }
        inFlight = true
        defer { inFlight = false }
        let current = try await fetchIdentity()
        guard current.id == expected.id && current.supabaseUserID == expected.supabaseUserID else {
            quarantined = true
            throw ResearchFailure.identityMismatch
        }
        try Task.checkCancellation()
        var listRequest = URLRequest(
            url: URL(string: "https://arena.ai/api/history/unified?limit=20&includeArchived=false")!)
        listRequest.httpMethod = "GET"
        listRequest.cachePolicy = .reloadIgnoringLocalCacheData
        let list: HTTPReply
        do { list = try await executor.perform(listRequest) } catch { throw ResearchFailure.transportFailed }
        guard let id = HistoryObservation(response: list).firstEvaluationID,
            let request = HistoryDetailRecipe.request(for: id)
        else {
            return HistoryDetailObservation(list: list, detail: nil, requestedID: nil)
        }
        try Task.checkCancellation()
        do {
            let detail = try await executor.perform(request)
            return HistoryDetailObservation(list: list, detail: detail, requestedID: id)
        } catch { throw ResearchFailure.transportFailed }
    }

    /// Explicit single-shot feasibility experiment, not a production Send action.
    /// No automatic retry, no challenge escalation, no continuation or remote stop claim.
    public func testOneGeneration() async throws -> GenerationObservation {
        guard !inFlight else { throw ResearchFailure.busy }
        guard !quarantined else { throw ResearchFailure.identityMismatch }
        guard let expected = identity else { throw ResearchFailure.notAuthenticated }
        guard !generationAttempted else { throw ResearchFailure.generationAlreadyAttempted }
        inFlight = true
        generationAttempted = true
        defer { inFlight = false }
        let current = try await fetchIdentity()
        guard current.id == expected.id && current.supabaseUserID == expected.supabaseUserID else {
            quarantined = true
            throw ResearchFailure.identityMismatch
        }
        let request = try GenerationRecipe.request()
        try Task.checkCancellation()
        // Freeze noncredential request bytes before dispatch; this is in-memory research evidence only.
        let prepared = request.httpBody ?? Data()
        do {
            let response = try await executor.perform(request)
            return GenerationObservation(preparedBody: prepared, response: response)
        } catch {
            // Request may have reached Arena. The attempted flag remains set; never resend automatically.
            throw ResearchFailure.transportFailed
        }
    }

    private func fetchIdentity() async throws -> ObservedIdentity {
        var request = URLRequest(url: URL(string: "https://arena.ai/api/me")!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let response = try await perform(request)
        guard let status = response.status else { throw ResearchFailure.transportFailed }
        guard status == 200 else { throw ResearchFailure.httpFailure(.identity, status) }
        // B-001 identity response shape. Unknown fields are not claimed captured by this auth-only proof.
        guard let decoded = try? JSONDecoder().decode(IdentityResponse.self, from: response.body),
            !decoded.user.id.isEmpty, !decoded.user.supabaseUserId.isEmpty, !decoded.user.email.isEmpty
        else {
            throw ResearchFailure.identityShapeUnverified
        }
        return ObservedIdentity(
            id: decoded.user.id, supabaseUserID: decoded.user.supabaseUserId, email: decoded.user.email)
    }

    private func perform(_ request: URLRequest) async throws -> HTTPReply {
        do {
            let reply = try await executor.perform(request)
            guard reply.transferEnd == .complete else { throw ResearchFailure.transportFailed }
            return reply
        } catch { throw ResearchFailure.transportFailed }
    }
}

private struct LoginBody: Encodable {
    let email: String
    let password: String
    let shouldLinkHistory: Bool
}

private struct IdentityResponse: Decodable {
    struct User: Decodable {
        let id: String
        let supabaseUserId: String
        let email: String
    }
    let user: User
}
