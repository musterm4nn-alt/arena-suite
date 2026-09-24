import Foundation
import Testing

@testable import NativeAuthResearch

private final class MemorySessionStore: ResearchSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func load() -> Data? { lock.withLock { data } }
    func save(_ data: Data) { lock.withLock { self.data = data } }
    func remove() { lock.withLock { data = nil } }
}

private final class CookieExecutor: CookieSessionExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [HTTPReply]
    private var requestCount = 0
    private var cookies = Data()
    init(_ replies: [HTTPReply]) { self.replies = replies }
    var count: Int { lock.withLock { requestCount } }
    func perform(_ request: URLRequest) async throws -> HTTPReply {
        try lock.withLock {
            requestCount += 1
            guard !replies.isEmpty else { throw ResearchFailure.transportFailed }
            return replies.removeFirst()
        }
    }
    func exportCookieData() throws -> Data { lock.withLock { cookies } }
    func importCookieData(_ data: Data) throws { lock.withLock { cookies = data } }
}

private func principal(_ id: String = "synthetic-account", alternate: String = "synthetic-principal") -> HTTPReply {
    HTTPReply(
        status: 200,
        body: Data(
            "{\"user\":{\"id\":\"\(id)\",\"supabaseUserId\":\"\(alternate)\",\"email\":\"test@example.invalid\"}}".utf8)
    )
}

@Test func sessionRestoresOnlyAfterBothIdentityClaimsMatch() async throws {
    let store = MemorySessionStore()
    let original = NativeAuthClient(
        executor: CookieExecutor([HTTPReply(status: 200, body: Data()), principal()]), sessionStore: store)
    _ = try await original.signIn(email: "synthetic", password: "password-must-not-be-saved")
    try await original.saveSession()
    let saved = try #require(store.load())
    #expect(!String(decoding: saved, as: UTF8.self).contains("password-must-not-be-saved"))
    let executor = CookieExecutor([principal()])
    let restored = NativeAuthClient(executor: executor, sessionStore: store)
    #expect(try await restored.restoreSavedSession()?.id == "synthetic-account")
    #expect(executor.count == 1)
    try await restored.forgetSavedSession()
    #expect(store.load() == nil)
}

@Test(arguments: [false, true])
func restoredIdentityMismatchQuarantinesBeforeHistory(alternate: Bool) async throws {
    let store = MemorySessionStore()
    store.save(
        try JSONEncoder().encode(
            SavedResearchSession(
                version: 1, id: "synthetic-account", supabaseUserID: "synthetic-principal", cookies: Data())))
    let executor = CookieExecutor([alternate ? principal(alternate: "different") : principal("different")])
    let client = NativeAuthClient(executor: executor, sessionStore: store)
    await #expect(throws: ResearchFailure.identityMismatch) { try await client.restoreSavedSession() }
    await #expect(throws: ResearchFailure.identityMismatch) { try await client.inspectHistoryList() }
    #expect(executor.count == 1)
}

@Test func corruptOrAbsentSessionNeverDispatches() async throws {
    let store = MemorySessionStore()
    let executor = CookieExecutor([])
    let client = NativeAuthClient(executor: executor, sessionStore: store)
    #expect(try await client.restoreSavedSession() == nil)
    store.save(Data("invalid".utf8))
    await #expect(throws: ResearchFailure.sessionStorageFailed) { try await client.restoreSavedSession() }
    #expect(executor.count == 0)
}

@Test func cookiePropertiesRoundTripAndRejectForeignDomain() throws {
    let cookie = try #require(
        HTTPCookie(properties: [
            .domain: ".arena.ai", .path: "/", .name: "synthetic", .value: "synthetic-only", .secure: "TRUE",
            .expires: Date(timeIntervalSince1970: 2_000_000_000), HTTPCookiePropertyKey("HttpOnly"): "TRUE",
        ]))
    let restored = try ResearchCookieCodec.decode(ResearchCookieCodec.encode([cookie]))
    #expect(restored.count == 1)
    #expect(restored[0].name == cookie.name && restored[0].value == cookie.value)
    #expect(restored[0].domain == cookie.domain && restored[0].path == cookie.path)
    #expect(restored[0].isSecure == cookie.isSecure)
    #expect(restored[0].isHTTPOnly == cookie.isHTTPOnly)
    #expect(restored[0].expiresDate == cookie.expiresDate)
    let foreign = try #require(
        HTTPCookie(properties: [.domain: "example.invalid", .path: "/", .name: "synthetic", .value: "synthetic-only"]))
    #expect(throws: ResearchFailure.sessionStorageFailed) {
        try ResearchCookieCodec.decode(ResearchCookieCodec.encode([foreign]))
    }
}

@Test func expiredRestoredAuthenticationDoesNotReadHistory() async throws {
    let store = MemorySessionStore()
    store.save(
        try JSONEncoder().encode(
            SavedResearchSession(
                version: 1, id: "synthetic-account", supabaseUserID: "synthetic-principal", cookies: Data())))
    let executor = CookieExecutor([HTTPReply(status: 401, body: Data())])
    let client = NativeAuthClient(executor: executor, sessionStore: store)
    await #expect(throws: ResearchFailure.httpFailure(.identity, 401)) { try await client.restoreSavedSession() }
    await #expect(throws: ResearchFailure.identityMismatch) { try await client.inspectHistoryList() }
    #expect(executor.count == 1)
}

@Test func restoredCookieJarsRemainIsolated() throws {
    let cookie = try #require(
        HTTPCookie(properties: [.domain: "arena.ai", .path: "/", .name: "synthetic", .value: "synthetic-only"]))
    let data = try ResearchCookieCodec.encode([cookie])
    let first = NativeHTTPExecutor()
    let second = NativeHTTPExecutor()
    try first.importCookieData(data)
    #expect(try ResearchCookieCodec.decode(first.exportCookieData()).count == 1)
    #expect(try ResearchCookieCodec.decode(second.exportCookieData()).isEmpty)
    #expect(throws: ResearchFailure.sessionStorageFailed) { try first.importCookieData(data) }
}
