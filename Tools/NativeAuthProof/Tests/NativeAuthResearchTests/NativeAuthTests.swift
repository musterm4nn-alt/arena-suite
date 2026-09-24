import Foundation
import Testing

@testable import NativeAuthResearch

@Test func projectedBrowserHistoryFixtureHasObservedSummary() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let manifest = try Data(
        contentsOf: root.appendingPathComponent("Fixtures/SanitizedArena/history-list.fixture.json"))
    let fields = try #require(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
    #expect(fields["fidelity"] as? String == "transformed")
    let units = try #require(fields["units"] as? [[String: Any]])
    let encoded = try #require(units.first?["base64"] as? String)
    let body = try #require(Data(base64Encoded: encoded))
    let observation = HistoryObservation(response: HTTPReply(status: 200, body: body))
    #expect(observation.summary.contains("Entries: 11; hasMore: false; partial: false; failed sources: 0"))
    #expect(!observation.summary.contains("scope-"))
    #expect(observation.response.body == body)
}

@Test func historyReadsOnlyObservedPageAndRetainsUnknownEvidence() async throws {
    let raw = Data(
        #"{"entries":[{"id":"private-test-id","type":"evaluation","unknown":"private-test-content"}],"pagination":{"hasMore":true,"cursor":"private-cursor"},"partial":true,"failedSources":[]}"#
            .utf8)
    let executor = ScriptedExecutor([
        HTTPReply(status: 200, body: Data()), identity(), identity(), HTTPReply(status: 200, body: raw),
    ])
    let client = NativeAuthClient(executor: executor)
    _ = try await client.signIn(email: "synthetic", password: "synthetic")
    let observed = try await client.inspectHistoryList()
    #expect(observed.response.body == raw)
    #expect(observed.summary.contains("hasMore: true; partial: true"))
    #expect(!observed.summary.contains("private-"))
    let requests = await executor.requests
    #expect(requests.count == 4)
    #expect(requests[2].url?.path == "/api/me")
    #expect(requests[3].httpMethod == "GET")
    #expect(requests[3].httpBody == nil)
    #expect(requests[3].url?.absoluteString == "https://arena.ai/api/history/unified?limit=20&includeArchived=false")
}

@Test(arguments: [false, true])
func historyIdentityMismatchNeverFetchesList(alternateClaim: Bool) async throws {
    let mismatch = alternateClaim ? identity(alternate: "different") : identity("different")
    let executor = ScriptedExecutor([HTTPReply(status: 200, body: Data()), identity(), mismatch])
    let client = NativeAuthClient(executor: executor)
    _ = try await client.signIn(email: "synthetic", password: "synthetic")
    await #expect(throws: ResearchFailure.identityMismatch) { try await client.inspectHistoryList() }
    await #expect(throws: ResearchFailure.identityMismatch) { try await client.recheckIdentity() }
    #expect(await executor.requests.count == 3)
}

@Test func historyUnknownAndInterruptedResponsesAreNotPresentedAsCompleteLists() {
    for reply in [
        HTTPReply(status: 200, body: Data("unknown".utf8)),
        HTTPReply(status: 403, body: Data("private-error".utf8)),
        HTTPReply(status: 200, body: Data("prefix".utf8), transferEnd: .interrupted),
        HTTPReply(status: 200, body: Data("prefix".utf8), observedByteCount: 100, transferEnd: .captureLimit),
    ] {
        let observed = HistoryObservation(response: reply)
        #expect(observed.summary.contains("List structure unverified"))
        #expect(observed.response.body == reply.body)
        #expect(!observed.summary.contains("private-error"))
        #expect(observed.summary.contains("may be incomplete"))
        #expect(!observed.summary.contains("original response retained"))
    }
}

@Test func nativeDetailSelectsOnlyObservedEvaluationAndKeepsPrivateBytes() async throws {
    let list = Data(
        #"{"entries":[{"id":"skip","type":"other"},{"id":"private-evaluation","type":"evaluation"}],"pagination":{"hasMore":true},"partial":true,"failedSources":[]}"#
            .utf8)
    let detail = Data(
        #"{"id":"private-evaluation","lastMessageIds":["private-m2"],"messages":[{"id":"private-m1","evaluationSessionId":"private-evaluation","parentMessageIds":[],"content":"private-content"},{"id":"private-m2","evaluationSessionId":"private-evaluation","parentMessageIds":["private-m1"]}],"future":"private-unknown"}"#
            .utf8)
    let executor = ScriptedExecutor([
        HTTPReply(status: 200, body: Data()), identity(), identity(), HTTPReply(status: 200, body: list),
        HTTPReply(status: 200, body: detail),
    ])
    let client = NativeAuthClient(executor: executor)
    _ = try await client.signIn(email: "synthetic", password: "synthetic")
    let observed = try await client.inspectFirstHistoryDetail()
    #expect(observed.detail?.body == detail && observed.list.body == list)
    #expect(observed.summary.contains("ID matches selected list entry: true"))
    #expect(observed.summary.contains("parent references outside response: 0"))
    #expect(observed.summary.contains("hasMore: true; partial: true"))
    #expect(!observed.summary.contains("private-"))
    let requests = await executor.requests
    #expect(requests.count == 5)
    #expect(requests[2].url?.path == "/api/me")
    #expect(requests[4].httpMethod == "GET")
    #expect(requests[4].url?.absoluteString == "https://arena.ai/api/evaluation/private-evaluation")
}

@Test(arguments: ["", "../other", "a/b", "a?x=1", "a#fragment", "%2f", "é"])
func unsafeDetailIDNeverBecomesAnotherRoute(id: String) {
    #expect(HistoryDetailRecipe.request(for: id) == nil)
}

@Test func detailIdentityMismatchDoesNotFetchList() async throws {
    let executor = ScriptedExecutor([
        HTTPReply(status: 200, body: Data()), identity(), identity(alternate: "different"),
    ])
    let client = NativeAuthClient(executor: executor)
    _ = try await client.signIn(email: "synthetic", password: "synthetic")
    await #expect(throws: ResearchFailure.identityMismatch) { try await client.inspectFirstHistoryDetail() }
    #expect(await executor.requests.count == 3)
}

@Test func detailMismatchAndUnknownShapesRemainExplicit() {
    let list = HTTPReply(status: 200, body: Data())
    let wrong = HTTPReply(
        status: 200,
        body: Data(
            #"{"id":"wrong","lastMessageIds":["absent"],"messages":[{"id":"dup","evaluationSessionId":"other","parentMessageIds":["absent"]},{"id":"dup","evaluationSessionId":"wrong","parentMessageIds":[]}]}"#
                .utf8))
    let observed = HistoryDetailObservation(list: list, detail: wrong, requestedID: "requested")
    #expect(observed.summary.contains("ID matches selected list entry: false"))
    #expect(observed.summary.contains("message session IDs match: false"))
    #expect(observed.summary.contains("duplicate message IDs: 1"))
    #expect(observed.summary.contains("parent references outside response: 1"))
    #expect(observed.summary.contains("last-message references outside response: 1"))
    let unknown = HistoryDetailObservation(
        list: list, detail: HTTPReply(status: 200, body: Data("unknown".utf8)), requestedID: "requested")
    #expect(unknown.summary.contains("Detail structure unverified"))
}

private actor ScriptedExecutor: HTTPExecuting {
    var cancelOnResponse = false
    func enableCancellation() { cancelOnResponse = true }
    var responses: [HTTPReply]
    var requests: [URLRequest] = []
    init(_ responses: [HTTPReply]) { self.responses = responses }
    func perform(_ request: URLRequest) throws -> HTTPReply {
        requests.append(request)
        if cancelOnResponse { withUnsafeCurrentTask { $0?.cancel() } }
        guard !responses.isEmpty else { throw ResearchFailure.transportFailed }
        return responses.removeFirst()
    }
}

@Test func repeatedLoginIsNotIdentityQuarantineAndDescriptionsAreRedacted() async throws {
    let executor = ScriptedExecutor([HTTPReply(status: 200, body: Data()), identity(), identity()])
    let client = NativeAuthClient(executor: executor)
    let observed = try await client.signIn(email: "synthetic", password: "synthetic")
    await #expect(throws: ResearchFailure.alreadyAuthenticated) {
        try await client.signIn(email: "other", password: "other")
    }
    #expect(await executor.requests.count == 2)
    #expect(try await client.recheckIdentity() == observed)
    #expect(String(describing: observed) == "ObservedIdentity(redacted)")
    #expect(String(reflecting: observed) == "ObservedIdentity(redacted)")
    #expect(String(describing: identity()) == "HTTPReply(redacted)")
    #expect(String(reflecting: identity()) == "HTTPReply(redacted)")
}

@Test(arguments: [false, true])
func cancellationAfterIdentityPreventsDispatch(history: Bool) async throws {
    let executor = ScriptedExecutor([HTTPReply(status: 200, body: Data()), identity(), identity()])
    let client = NativeAuthClient(executor: executor)
    _ = try await client.signIn(email: "synthetic", password: "synthetic")
    await executor.enableCancellation()
    let task = Task {
        if history { _ = try await client.inspectHistoryList() } else { _ = try await client.testOneGeneration() }
    }
    do {
        try await task.value
        Issue.record("Canceled preflight dispatched")
    } catch { #expect(error is CancellationError) }
    #expect(await executor.requests.count == 3)
}

private func identity(_ id: String = "synthetic-A", alternate: String = "synthetic-principal-A") -> HTTPReply {
    HTTPReply(
        status: 200,
        body: Data(
            "{\"user\":{\"id\":\"\(id)\",\"supabaseUserId\":\"\(alternate)\",\"email\":\"synthetic@example.invalid\",\"futureField\":true}}"
                .utf8))
}

@Test func signInRequiresIdentityAndUsesObservedContract() async throws {
    let executor = ScriptedExecutor([HTTPReply(status: 200, body: Data()), identity(), identity()])
    let client = NativeAuthClient(executor: executor)
    let result = try await client.signIn(email: "synthetic@example.invalid", password: "synthetic-test-only")
    #expect(result.id == "synthetic-A")
    #expect(try await client.recheckIdentity() == result)
    let requests = await executor.requests
    #expect(requests.count == 3)
    #expect(requests[0].url?.absoluteString == "https://arena.ai/nextjs-api/sign-in/email")
    #expect(requests[0].httpMethod == "POST")
    #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(requests[0].value(forHTTPHeaderField: "Cookie") == nil)
    let body = try #require(requests[0].httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(json.keys) == ["email", "password", "shouldLinkHistory"])
    #expect(json["shouldLinkHistory"] as? Bool == false)
    #expect(json["email"] as? String == "synthetic@example.invalid")
    #expect(json["password"] as? String == "synthetic-test-only")
    #expect(requests[1].url?.path == "/api/me")
    #expect(requests[1].httpMethod == "GET")
    #expect(requests[1].httpBody == nil)
}

@Test(arguments: [302, 401, 403, 429, 500])
func authFailureNeverRetriesOrChecksIdentity(status: Int) async {
    let executor = ScriptedExecutor([HTTPReply(status: status, body: Data("private-error-must-not-surface".utf8))])
    let client = NativeAuthClient(executor: executor)
    await #expect(throws: ResearchFailure.httpFailure(.signIn, status)) {
        try await client.signIn(email: "synthetic", password: "synthetic")
    }
    #expect(await executor.requests.count == 1)
}

@Test(arguments: [
    "{}", "{\"user\":null}", "{\"user\":{\"id\":42}}",
    "{\"user\":{\"id\":\"\",\"supabaseUserId\":\"x\",\"email\":\"x\"}}",
])
func successfulLoginStatusAloneIsNotIdentity(body: String) async {
    let executor = ScriptedExecutor([
        HTTPReply(status: 200, body: Data()), HTTPReply(status: 200, body: Data(body.utf8)),
    ])
    let client = NativeAuthClient(executor: executor)
    await #expect(throws: ResearchFailure.identityShapeUnverified) {
        try await client.signIn(email: "synthetic", password: "synthetic")
    }
}

@Test func identityMismatchQuarantinesFurtherRequests() async throws {
    let executor = ScriptedExecutor([
        HTTPReply(status: 200, body: Data()), identity(), identity(alternate: "synthetic-B"),
    ])
    let client = NativeAuthClient(executor: executor)
    _ = try await client.signIn(email: "synthetic", password: "synthetic")
    await #expect(throws: ResearchFailure.identityMismatch) { try await client.recheckIdentity() }
    await #expect(throws: ResearchFailure.identityMismatch) { try await client.recheckIdentity() }
    #expect(await executor.requests.count == 3)
}

@Test func identityFailureIsNotSuccessfulAuthentication() async {
    let executor = ScriptedExecutor([HTTPReply(status: 200, body: Data()), HTTPReply(status: 401, body: Data())])
    let client = NativeAuthClient(executor: executor)
    await #expect(throws: ResearchFailure.httpFailure(.identity, 401)) {
        try await client.signIn(email: "synthetic", password: "synthetic")
    }
    await #expect(throws: ResearchFailure.notAuthenticated) { try await client.recheckIdentity() }
}

private actor PausingExecutor: HTTPExecuting {
    private var pending: CheckedContinuation<HTTPReply, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private(set) var count = 0

    func perform(_ request: URLRequest) async -> HTTPReply {
        count += 1
        if count == 1 {
            return await withCheckedContinuation {
                pending = $0
                observer?.resume()
                observer = nil
            }
        }
        return identity()
    }

    func waitForRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        pending?.resume(returning: HTTPReply(status: 200, body: Data()))
        pending = nil
    }
}

@Test func concurrentSignInCannotRebindAnInflightSession() async throws {
    let executor = PausingExecutor()
    let client = NativeAuthClient(executor: executor)
    let first = Task { try await client.signIn(email: "synthetic-A", password: "synthetic") }
    await executor.waitForRequest()
    await #expect(throws: ResearchFailure.busy) {
        try await client.signIn(email: "synthetic-B", password: "synthetic")
    }
    #expect(await executor.count == 1)
    await executor.release()
    #expect(try await first.value.id == "synthetic-A")
    #expect(await executor.count == 2)
}

@Test func passwordIsPreservedExactlyWhenOriginalFieldIsCleared() async throws {
    let executor = ScriptedExecutor([HTTPReply(status: 401, body: Data())])
    let client = NativeAuthClient(executor: executor)
    var field = "  synthetic-\"päss\\word\n  "
    let submission = field
    field = ""
    await #expect(throws: ResearchFailure.httpFailure(.signIn, 401)) {
        try await client.signIn(email: "synthetic@example.invalid", password: submission)
    }
    let requests = await executor.requests
    let body = try #require(requests.first?.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(field.isEmpty)
    #expect(object["password"] as? String == submission)
}

@Test func localErrorNeverEscapesThroughOrdinaryFailureOrDescription() async throws {
    let marker = "synthetic-private-marker"
    let body = Data("{\"error\":\"\(marker)\",\"requiresVerification\":true,\"token\":\"synthetic-token\"}".utf8)
    let executor = ScriptedExecutor([HTTPReply(status: 401, body: body)])
    let client = NativeAuthClient(executor: executor)
    await #expect(throws: ResearchFailure.httpFailure(.signIn, 401)) {
        try await client.signIn(email: "synthetic", password: "synthetic")
    }
    let presentation = try #require(await client.errorForLocalPresentation())
    #expect(presentation.serverMessage == marker)
    #expect(presentation.requiresVerification == true)
    #expect(!String(describing: presentation).contains(marker))
    #expect(!String(reflecting: presentation).contains(marker))
    #expect(!String(describing: ResearchFailure.httpFailure(.signIn, 401)).contains(marker))
    #expect(await executor.requests.count == 1)
}

@Test(arguments: [
    "<html>synthetic-private-marker</html>", "{\"error\":42}",
    "{\"error\":\"synthetic-private-marker\",\"requiresVerification\":1}",
    "{\"error\":\"unfinished",
])
func unexpectedErrorShapeDoesNotExposeBody(body: String) {
    let presentation = LocalAuthError.inspect(Data(body.utf8))
    #expect(presentation.serverMessage == nil)
    #expect(presentation.requiresVerification == nil)
    #expect(!presentation.interpretation.contains("synthetic-private-marker"))
}

@Test func localErrorInspectionIsBounded() throws {
    let oversized = Data(repeating: 120, count: 65_537)
    #expect(LocalAuthError.inspect(oversized).serverMessage == nil)
    let message = String(repeating: "x", count: 600)
    let body = try JSONSerialization.data(withJSONObject: ["error": message])
    #expect(LocalAuthError.inspect(body).serverMessage?.count == 512)
    let absent = LocalAuthError.inspect(Data("{\"unrecognized\":\"synthetic-private-marker\"}".utf8))
    #expect(absent.serverMessage == nil)
    #expect(absent.requiresVerification == nil)
}

@Test func generationIsSingleShotUsesNullFallbackAndPreservesOpaqueBytes() async throws {
    let raw = Data([0, 255, 10, 195, 169])
    let executor = ScriptedExecutor([
        HTTPReply(status: 200, body: Data()), identity(), identity(),
        HTTPReply(status: 200, body: raw, contentType: "text/event-stream"),
    ])
    let client = NativeAuthClient(executor: executor)
    _ = try await client.signIn(email: "synthetic", password: "synthetic")
    let capture = try await client.testOneGeneration()
    #expect(capture.response.body == raw)
    let requests = await executor.requests
    #expect(requests.count == 4)
    #expect(requests[2].url?.path == "/api/me")
    #expect(requests[3].url?.absoluteString == "https://arena.ai/nextjs-api/stream/create-evaluation")
    #expect(requests[3].httpBody == capture.preparedBody)
    let body = try #require(JSONSerialization.jsonObject(with: capture.preparedBody) as? [String: Any])
    #expect(body["recaptchaV3Token"] is NSNull)
    #expect(body["recaptchaV2Token"] == nil)
    #expect(
        Set(body.keys) == [
            "id", "mode", "modelAId", "userMessageId", "modelAMessageId", "userMessage", "modality", "recaptchaV3Token",
        ])
    #expect(requests[3].value(forHTTPHeaderField: "Content-Type") == "text/plain;charset=UTF-8")
    await #expect(throws: ResearchFailure.generationAlreadyAttempted) { try await client.testOneGeneration() }
    #expect(await executor.requests.count == 4)
}

@Test func generationStopsOnIdentityMismatchBeforeMutation() async throws {
    let executor = ScriptedExecutor([HTTPReply(status: 200, body: Data()), identity(), identity("synthetic-B")])
    let client = NativeAuthClient(executor: executor)
    _ = try await client.signIn(email: "synthetic", password: "synthetic")
    await #expect(throws: ResearchFailure.identityMismatch) { try await client.testOneGeneration() }
    #expect(await executor.requests.count == 3)
    await #expect(throws: ResearchFailure.identityMismatch) { try await client.recheckIdentity() }
    #expect(await executor.requests.count == 3)
}

@Test(arguments: [403, 429])
func generationRejectionDoesNotEscalateOrRetry(status: Int) async throws {
    let executor = ScriptedExecutor([
        HTTPReply(status: 200, body: Data()), identity(), identity(),
        HTTPReply(status: status, body: Data("synthetic rejection".utf8)),
    ])
    let client = NativeAuthClient(executor: executor)
    _ = try await client.signIn(email: "synthetic", password: "synthetic")
    let capture = try await client.testOneGeneration()
    #expect(capture.response.status == status)
    await #expect(throws: ResearchFailure.generationAlreadyAttempted) { try await client.testOneGeneration() }
    #expect(await executor.requests.count == 4)
}

@Test func interruptedGenerationRetainsPrefixWithoutResend() async throws {
    let prefix = Data("synthetic-prefix".utf8)
    let executor = ScriptedExecutor([
        HTTPReply(status: 200, body: Data()), identity(), identity(),
        HTTPReply(status: 200, body: prefix, transferEnd: .interrupted),
    ])
    let client = NativeAuthClient(executor: executor)
    _ = try await client.signIn(email: "synthetic", password: "synthetic")
    let capture = try await client.testOneGeneration()
    #expect(capture.response.body == prefix)
    #expect(capture.response.transferEnd == .interrupted)
    await #expect(throws: ResearchFailure.generationAlreadyAttempted) { try await client.testOneGeneration() }
}

@Test func localRequestUUIDv7LayoutAndClockValidation() throws {
    let id = try GenerationRecipe.uuidV7(at: Date(timeIntervalSince1970: 1))
    #expect(id.hasPrefix("00000000-03e8-7"))
    #expect(UUID(uuidString: id) != nil)
    #expect(["8", "9", "a", "b"].contains(String(Array(id)[19])))
    #expect(throws: ResearchFailure.invalidLocalClock) {
        try GenerationRecipe.uuidV7(at: Date(timeIntervalSince1970: -1))
    }
}
