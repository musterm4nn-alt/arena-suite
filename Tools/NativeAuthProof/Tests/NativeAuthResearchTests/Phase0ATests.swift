import CryptoKit
import Foundation
import Testing

@testable import NativeAuthResearch

private actor Server: HTTPExecuting {
    var responses: [HTTPReply]
    var requests: [URLRequest] = []
    init(_ responses: [HTTPReply]) { self.responses = responses }
    func perform(_ request: URLRequest) throws -> HTTPReply {
        requests.append(request)
        guard !responses.isEmpty else { throw ResearchFailure.transportFailed }
        return responses.removeFirst()
    }
}

private func me(_ id: String = "private-user-A", _ principal: String = "private-principal-A") -> HTTPReply {
    HTTPReply(
        status: 200,
        body: Data(#"{"user":{"id":"\#(id)","supabaseUserId":"\#(principal)","email":"private@example.invalid"}}"#.utf8))
}

private func page(_ ids: [String], hasMore: Bool, cursor: String?, titles: [String: String] = [:]) -> HTTPReply {
    let entries = ids.map { id -> String in
        let title = titles[id] ?? "private-title-\(id)"
        return #"{"id":"\#(id)","type":"evaluation","mode":"direct-battle","modality":"chat","title":"\#(title)"}"#
    }.joined(separator: ",")
    let cursorJSON = cursor.map { "\"\($0)\"" } ?? "null"
    return HTTPReply(
        status: 200,
        body: Data(
            #"{"entries":[\#(entries)],"pagination":{"hasMore":\#(hasMore),"cursor":\#(cursorJSON),"limit":5},"partial":false,"failedSources":[]}"#
                .utf8))
}

private let noSleep: Phase0ARunner.Sleeper = { _ in }
private let keychain = Phase0AReport.Keychain(preflight: .found, preflightStatus: 0, restored: true)
private let signing = SigningInfo(adhoc: true, teamIdentifier: nil, cdhashPrefix: nil, bundleVersion: "test")

@Test func pageURLEncodesOpaqueCursorsAndBoundsLimit() throws {
    let url = try #require(HistoryPageRecipe.url(limit: 5, includeArchived: false, cursor: "a+b/c=d e"))
    #expect(
        url.absoluteString
            == "https://arena.ai/api/history/unified?limit=5&includeArchived=false&cursor=a%2Bb%2Fc%3Dd%20e")
    #expect(HistoryPageRecipe.url(limit: 0, includeArchived: false, cursor: nil) == nil)
    #expect(HistoryPageRecipe.url(limit: 5, includeArchived: true, cursor: "") == nil)
}

@Test func pageSummaryCountsShapesWithoutValues() {
    let parsed = PageSummary.parse(page(["1", "2"], hasMore: true, cursor: "private-cursor"))
    #expect(parsed.summary.entries == 2)
    #expect(parsed.summary.typeCounts == ["evaluation": 2])
    #expect(parsed.summary.paginationKeys == ["cursor", "hasMore", "limit"])
    #expect(parsed.summary.cursorLength == 14)
    #expect(parsed.cursor == "private-cursor")
    let failed = PageSummary.parse(HTTPReply(status: 403, body: Data("private-error".utf8)))
    #expect(!failed.summary.decoded && failed.summary.entries == 0)
}

@Test func runFollowsCursorsAndReportsNoPrivateValues() async throws {
    let synthetic = "Reply with exactly this text and nothing else: Arena Suite feasibility check."
    let all = (1...7).map { "00000000-0000-4000-8000-00000000000\($0)" }
    let titles = [all[2]: synthetic]
    let detail = HTTPReply(
        status: 200,
        body: Data(
            #"{"id":"\#(all[2])","userId":"private-user-A","title":"\#(synthetic)","createdAt":"2026-09-22T07:43:17.277Z","messages":[{"id":"11111111-1111-4111-8111-111111111111","role":"user","content":"\#(synthetic)"},{"id":"22222222-2222-4222-8222-222222222222","role":"assistant","content":"private answer","parentMessageIds":["11111111-1111-4111-8111-111111111111"]}]}"#
                .utf8))
    let server = Server([
        me(),  // A4 identity
        page(all, hasMore: false, cursor: nil, titles: titles),  // A3 includeArchived=false
        page(all, hasMore: false, cursor: nil, titles: titles),  // A3 includeArchived=true
        page(Array(all[0..<5]), hasMore: true, cursor: "private+cursor/1"),  // A2 page 1
        page(Array(all[5..<7]), hasMore: false, cursor: nil),  // A2 page 2
        detail,  // A8
        me(),  // final identity
    ])
    let client = NativeAuthClient(executor: server)
    _ = try await client.restoreForTesting(me())
    let anonymous = Server([HTTPReply(status: 401, body: Data(#"{"error":"private-reason"}"#.utf8))])
    let candidate = FileManager.default.temporaryDirectory.appendingPathComponent("candidate-\(UUID()).json")

    let report = await Phase0ARunner.run(
        client: client, keychain: keychain, signing: signing, fixtureCandidate: candidate,
        anonymousExecutor: anonymous, sleep: noSleep)

    #expect(report.stoppedEarly == nil)
    #expect(report.identityVerifiedAtStart && report.identityVerifiedAtEnd)
    #expect(report.requestsSent == 8)
    let pagination = try #require(report.pagination)
    #expect(pagination.pages.count == 2 && pagination.stoppedBecause == "hasMore=false")
    #expect(pagination.overlapBetweenPages == 0 && pagination.unionEqualsSinglePageList == true)
    #expect(report.anonymousIdentity?.status == 401 && report.anonymousIdentity?.topLevelKeys == ["error"])
    #expect(report.fixture?.selected == true && report.fixture?.keptSyntheticTexts == 2)

    let requests = await server.requests
    #expect(requests[4].url?.query == "limit=5&includeArchived=false&cursor=private%2Bcursor%2F1")
    #expect(requests[5].url?.path == "/api/evaluation/\(all[2])")

    let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    for secret in ["private", all[0], "0000-4000"] { #expect(!encoded.contains(secret), "report leaked \(secret)") }

    let projection = String(decoding: try Data(contentsOf: candidate), as: UTF8.self)
    #expect(projection.contains(synthetic))
    #expect(!projection.contains("private"))
    #expect(!projection.contains("11111111-1111"))
    #expect(projection.contains("[timestamp]"))
}

@Test func runStopsOnRepeatedCursorAndNeverFetchesDetailWithoutSyntheticTitle() async throws {
    let server = Server([
        me(), page(["a"], hasMore: false, cursor: nil), page(["a"], hasMore: false, cursor: nil),
        page(["a"], hasMore: true, cursor: "same"), page(["b"], hasMore: true, cursor: "same"), me(),
    ])
    let client = NativeAuthClient(executor: server)
    _ = try await client.restoreForTesting(me())
    let report = await Phase0ARunner.run(
        client: client, keychain: keychain, signing: signing, fixtureCandidate: nil,
        anonymousExecutor: Server([HTTPReply(status: 401, body: Data())]), sleep: noSleep)
    #expect(report.pagination?.repeatedCursor == true)
    #expect(report.pagination?.stoppedBecause == "repeated cursor")
    #expect(report.fixture?.selected == false)
    #expect(await server.requests.allSatisfy { $0.url?.path != "/api/evaluation/a" })
}

@Test func runStopsWhenIdentityFailsBeforeAnyHistoryRequest() async throws {
    let server = Server([me("someone-else")])
    let client = NativeAuthClient(executor: server)
    _ = try await client.restoreForTesting(me())
    let report = await Phase0ARunner.run(
        client: client, keychain: keychain, signing: signing, fixtureCandidate: nil,
        anonymousExecutor: Server([]), sleep: noSleep)
    #expect(report.stoppedEarly == "identity verification failed at start")
    #expect(await server.requests.count == 1)
}

@Test func sanitizerKeepsOnlySyntheticTextAndEnumerations() throws {
    let body = Data(
        #"{"a":"12345678-1234-4234-8234-123456789abc","b":["12345678-1234-4234-8234-123456789abc"],"role":"assistant","status":"a very long free-text status that is not an enumeration value","note":"private words","content":"Arena Suite continuation check.","n":3,"ok":true,"none":null,"12345678-1234-4234-8234-123456789abc":{"mode":"direct-battle"}}"#
            .utf8)
    let result = try #require(DetailSanitizer.sanitize(body))
    let object = try #require(JSONSerialization.jsonObject(with: result.projection) as? [String: Any])
    #expect(object["a"] as? String == "id-1")
    #expect((object["b"] as? [String]) == ["id-1"])
    #expect(object["role"] as? String == "assistant")
    #expect(object["status"] as? String == "[string]")
    #expect(object["note"] as? String == "[string]")
    #expect(object["content"] as? String == "Arena Suite continuation check.")
    #expect(object["n"] as? Int == 3 && object["ok"] as? Bool == true && object["none"] is NSNull)
    #expect((object["id-1"] as? [String: Any])?["mode"] as? String == "direct-battle")
    #expect(result.aliased == 1 && result.kept == 1)
}

@Test func isolationReportsDistinctPrincipalsAndOverlap() async throws {
    let serverA = Server([page(["shared", "a1"], hasMore: false, cursor: nil), me()])
    let serverB = Server([
        page(["shared", "b1", "b2"], hasMore: false, cursor: nil), me("private-user-B", "private-principal-B"),
    ])
    let a = NativeAuthClient(executor: serverA)
    let b = NativeAuthClient(executor: serverB)
    let identityA = try await a.restoreForTesting(me())
    let identityB = try await b.restoreForTesting(me("private-user-B", "private-principal-B"))
    let report = await IsolationRunner.run(
        a: a, identityA: identityA, b: b, identityB: identityB, signing: signing, sleep: noSleep)
    #expect(report.principalsDiffer == true)
    #expect(report.identityStableA && report.identityStableB)
    #expect(report.entriesA == 2 && report.entriesB == 3 && report.overlappingEntryIDs == 1)
    let encoded = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    #expect(!encoded.contains("private") && !encoded.contains("\"shared\"") && !encoded.contains("a1"))
}

@Test func cookieChangesAreDetectedByDigestNotReported() {
    func cookie(_ name: String, _ digest: String) -> CookieMetadata {
        CookieMetadata(
            name: name, domain: "arena.ai", path: "/", expires: nil, secure: true, httpOnly: true, sameSite: nil,
            valueDigest: digest)
    }
    let changed = Phase0ARunner.changedCookies(
        [cookie("kept", "1"), cookie("rotated", "1"), cookie("gone", "1")],
        [cookie("kept", "1"), cookie("rotated", "2"), cookie("new", "1")])
    #expect(changed == ["gone", "new", "rotated"])
}

@Test func sanitizerMasksTelemetryInsideMetadata() throws {
    let body = Data(
        #"{"inputTokens":15,"metadata":{"botScore":1,"wouldEscalate":false,"attributes":{"account_age_seconds":573437.9,"votes":[3]},"none":null},"ok":true}"#
            .utf8)
    let result = try #require(DetailSanitizer.sanitize(body))
    let text = String(decoding: result.projection, as: UTF8.self)
    #expect(
        text
            == #"{"inputTokens":15,"metadata":{"attributes":{"account_age_seconds":"[number]","votes":["[number]"]},"botScore":"[number]","none":null,"wouldEscalate":"[bool]"},"ok":true}"#
    )
}

@Test func nativeDetailFixtureKeepsTheSyntheticMessageChain() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let manifest = try Data(contentsOf: root.appendingPathComponent("Fixtures/SanitizedArena/native-detail.fixture.json"))
    let fields = try #require(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
    let unit = try #require((fields["units"] as? [[String: Any]])?.first)
    let encoded = try #require(unit["base64"] as? String)
    let body = try #require(Data(base64Encoded: encoded))
    let detail = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try #require(detail["messages"] as? [[String: Any]])
    #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user", "assistant"])
    var parent: String?
    for message in messages {
        #expect((message["parentMessageIds"] as? [String]) == (parent.map { [$0] } ?? []))
        #expect(message["evaluationSessionId"] as? String == detail["id"] as? String)
        parent = message["id"] as? String
    }
    #expect((detail["lastMessageIds"] as? [String]) == [parent].compactMap { $0 })
    let text = String(decoding: body, as: UTF8.self)
    #expect(!text.contains("0.") && !text.contains("ja4\":0"), "telemetry numbers must be masked")
    #expect(!text.contains("[string:"), "string lengths must be withheld")
    #expect(SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined() == unit["sha256"] as? String)
    #expect((fields["stream_sha256"] as? [String: String])?["response"] == unit["sha256"] as? String)
}
