import ApplicationActions
import Foundation
import FoundationTransport
import SuiteDomain
import Testing

@testable import ArenaAdapter

/// Scripted server plus an in-memory "cookie jar" (opaque bytes) per transport.
final class FakeTransport: HTTPTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<HTTPExchange, any Error>]
    private(set) var requests: [URLRequest] = []
    private var jar = Data()
    /// Simulates the server re-issuing cookies on the next response.
    var rotateOnNextResponse = false

    init(_ replies: [HTTPExchange]) { self.replies = replies.map { .success($0) } }
    init(results: [Result<HTTPExchange, any Error>]) { self.replies = results }

    func perform(_ request: URLRequest) async throws -> HTTPExchange {
        try lock.withLock {
            requests.append(request)
            guard !replies.isEmpty else { throw URLError(.cannotConnectToHost) }
            if jar.isEmpty { jar = Data("session-cookie".utf8) }
            if rotateOnNextResponse {
                jar = Data("rotated-cookie".utf8)
                rotateOnNextResponse = false
            }
            return try replies.removeFirst().get()
        }
    }

    func exportCookies(domains: Set<String>) throws -> Data { lock.withLock { jar } }

    func importCookies(_ data: Data, domains: Set<String>) throws {
        try lock.withLock {
            guard jar.isEmpty else { throw TransportError.cookieJarNotEmpty }
            jar = data
        }
    }

    func cookieFingerprint(domains: Set<String>) -> String { lock.withLock { String(decoding: jar, as: UTF8.self) } }
    var requestCount: Int { lock.withLock { requests.count } }
    var paths: [String] { lock.withLock { requests.compactMap { $0.url?.path } } }
}

final class MemoryVault: SessionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AccountID: StoredSession] = [:]
    func load(account: AccountID) throws -> StoredSession? { lock.withLock { items[account] } }
    func save(_ session: StoredSession, account: AccountID) throws { lock.withLock { items[account] = session } }
    func delete(account: AccountID) throws { lock.withLock { items[account] = nil } }
    subscript(account: AccountID) -> StoredSession? { lock.withLock { items[account] } }
}

/// Hands out pre-built transports in order, so tests can script each session.
final class TransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [FakeTransport]
    private(set) var made: [FakeTransport] = []
    init(_ transports: [FakeTransport]) { queue = transports }
    func make() -> any HTTPTransporting {
        lock.withLock {
            let next = queue.isEmpty ? FakeTransport([]) : queue.removeFirst()
            made.append(next)
            return next
        }
    }
}

func me(_ id: String = "user-A", _ principal: String = "principal-A") -> HTTPExchange {
    HTTPExchange(
        status: 200, body: Data(#"{"user":{"id":"\#(id)","supabaseUserId":"\#(principal)","email":"x@example.invalid"}}"#.utf8))
}

let principalA = PrincipalIdentity(namespace: "arena", claims: ["id": "user-A", "supabaseUserId": "principal-A"])
let ok = HTTPExchange(status: 200, body: Data())

private func sessions(_ vault: MemoryVault, _ factory: TransportFactory) -> ArenaAccountSessions {
    ArenaAccountSessions(vault: vault, makeTransport: { factory.make() })
}

@Test func signInUsesObservedContractThenVerifiesIdentity() async throws {
    let transport = FakeTransport([ok, me()])
    let factory = TransportFactory([transport])
    let account = AccountID()
    let principal = try await sessions(MemoryVault(), factory).signIn(account: account, email: "e", password: "p")
    #expect(principal == principalA)
    #expect(transport.paths == ["/nextjs-api/sign-in/email", "/api/me"])
    let body = try #require(transport.requests.first?.httpBody)
    let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(fields["shouldLinkHistory"] as? Bool == false)
    #expect(Set(fields.keys) == ["email", "password", "shouldLinkHistory"])
    #expect(transport.requests.first?.httpMethod == "POST")
}

@Test(arguments: [400, 401, 403, 429, 500])
func rejectedSignInNeverChecksIdentity(_ status: Int) async throws {
    let transport = FakeTransport([HTTPExchange(status: status, body: Data("private".utf8))])
    await #expect(throws: SignInFailure.rejected(status: status)) {
        _ = try await sessions(MemoryVault(), TransportFactory([transport])).signIn(
            account: AccountID(), email: "e", password: "p")
    }
    #expect(transport.requestCount == 1)
}

@Test func persistRequiresTheVerifiedPrincipal() async throws {
    let vault = MemoryVault()
    let provider = sessions(vault, TransportFactory([FakeTransport([ok, me()])]))
    let account = AccountID()
    _ = try await provider.signIn(account: account, email: "e", password: "p")
    let other = PrincipalIdentity(namespace: "arena", claims: ["id": "someone", "supabaseUserId": "else"])
    await #expect(throws: SignInFailure.identityUnverified) { try await provider.persist(account: account, principal: other) }
    #expect(vault[account] == nil)
    try await provider.persist(account: account, principal: principalA)
    #expect(vault[account]?.principal == principalA)
    #expect(vault[account]?.cookies == Data("session-cookie".utf8))
}

@Test func restoreWithoutSavedSessionSendsNothing() async {
    let factory = TransportFactory([])
    #expect(await sessions(MemoryVault(), factory).restore(account: AccountID(), expected: principalA) == .noSavedSession)
    #expect(factory.made.isEmpty)
}

@Test func sessionSavedForAnotherPrincipalIsNeverSent() async {
    let vault = MemoryVault()
    let account = AccountID()
    let other = PrincipalIdentity(namespace: "arena", claims: ["id": "user-B", "supabaseUserId": "principal-B"])
    try? vault.save(StoredSession(principal: other, cookies: Data("b".utf8)), account: account)
    let factory = TransportFactory([])
    #expect(await sessions(vault, factory).restore(account: account, expected: principalA) == .mismatch)
    #expect(factory.made.isEmpty)
    #expect(vault[account] == nil)
}

@Test func restoreVerifiesAndSavesRotatedCookies() async throws {
    let vault = MemoryVault()
    let account = AccountID()
    try vault.save(StoredSession(principal: principalA, cookies: Data("session-cookie".utf8)), account: account)
    let transport = FakeTransport([me()])
    transport.rotateOnNextResponse = true
    let provider = sessions(vault, TransportFactory([transport]))
    #expect(await provider.restore(account: account, expected: principalA) == .verified)
    #expect(transport.paths == ["/api/me"])
    #expect(vault[account]?.cookies == Data("rotated-cookie".utf8))
    #expect(await provider.session(for: account) != nil)
}

@Test(arguments: [401, 403])
func rejectedRestoreDeletesSavedSession(_ status: Int) async throws {
    let vault = MemoryVault()
    let account = AccountID()
    try vault.save(StoredSession(principal: principalA, cookies: Data("c".utf8)), account: account)
    let provider = sessions(vault, TransportFactory([FakeTransport([HTTPExchange(status: status, body: Data())])]))
    #expect(await provider.restore(account: account, expected: principalA) == .rejected(status: status))
    #expect(vault[account] == nil)
    #expect(await provider.session(for: account) == nil)
}

@Test func identityMismatchQuarantinesAndGatesAllFurtherRequests() async throws {
    let vault = MemoryVault()
    let account = AccountID()
    try vault.save(StoredSession(principal: principalA, cookies: Data("c".utf8)), account: account)
    let transport = FakeTransport([me("user-B", "principal-B")])
    let provider = sessions(vault, TransportFactory([transport]))
    #expect(await provider.restore(account: account, expected: principalA) == .mismatch)
    #expect(vault[account] == nil)
    #expect(await provider.session(for: account) == nil)
    #expect(transport.requestCount == 1)
}

@Test func transientFailuresKeepTheSavedSession() async throws {
    let vault = MemoryVault()
    let account = AccountID()
    try vault.save(StoredSession(principal: principalA, cookies: Data("c".utf8)), account: account)
    let failures = [
        FakeTransport([HTTPExchange(status: 503, body: Data())]),
        FakeTransport([HTTPExchange(status: 429, body: Data())]),
        FakeTransport(results: [.failure(URLError(.notConnectedToInternet))]),
        FakeTransport([HTTPExchange(status: 200, body: Data("<html>".utf8))]),
        FakeTransport([HTTPExchange(status: 200, body: Data(), transferEnd: .interrupted)]),
    ]
    let provider = sessions(vault, TransportFactory(failures))
    for _ in failures {
        #expect(await provider.restore(account: account, expected: principalA) == .unreachable)
        #expect(vault[account] != nil)
    }
}

@Test func unverifiedSessionRefusesEveryOtherRequest() async throws {
    let transport = FakeTransport([ok])
    let session = ArenaAccountSession(transport: transport)
    await #expect(throws: SessionGateError.notVerified) {
        _ = try await session.performVerified(URLRequest(url: URL(string: "https://arena.ai/api/history/unified")!))
    }
    #expect(transport.requestCount == 0)
    #expect(await session.check(expected: principalA) == .unreachable)  // scripted non-identity reply
    await #expect(throws: SessionGateError.notVerified) {
        _ = try await session.performVerified(URLRequest(url: URL(string: "https://arena.ai/")!))
    }
}

@Test func accountsNeverShareATransport() async throws {
    let vault = MemoryVault()
    let a = AccountID()
    let b = AccountID()
    let principalB = PrincipalIdentity(namespace: "arena", claims: ["id": "user-B", "supabaseUserId": "principal-B"])
    try vault.save(StoredSession(principal: principalA, cookies: Data("a".utf8)), account: a)
    try vault.save(StoredSession(principal: principalB, cookies: Data("b".utf8)), account: b)
    let factory = TransportFactory([FakeTransport([me()]), FakeTransport([me("user-B", "principal-B")])])
    let provider = sessions(vault, factory)
    async let restoredA = provider.restore(account: a, expected: principalA)
    async let restoredB = provider.restore(account: b, expected: principalB)
    #expect(await [restoredA, restoredB] == [.verified, .verified])
    let sessionA = try #require(await provider.session(for: a))
    let sessionB = try #require(await provider.session(for: b))
    #expect(sessionA !== sessionB)
    #expect((sessionA.transport as? FakeTransport) !== (sessionB.transport as? FakeTransport))
    #expect(vault[a]?.cookies == Data("a".utf8) && vault[b]?.cookies == Data("b".utf8))
}

@Test func principalDescriptionIsRedacted() {
    #expect(!String(describing: principalA).contains("user-A"))
    let exchange = HTTPExchange(status: 200, headers: ["Set-Cookie": "secret-cookie"], body: Data("secret-body".utf8))
    for text in [String(describing: exchange), String(reflecting: exchange)] {
        #expect(!text.contains("secret"))
    }
}
