import ApplicationActions
import CaptureJournal
import Foundation
import FoundationTransport
import SuiteDomain
import Testing

@testable import ArenaAdapter

// MARK: - Fixtures

/// An object store beside a test journal (Docs/attachments-2026-10-20.md).
func testObjects(_ journalRoot: URL) -> ObjectStore {
    ObjectStore(root: journalRoot.appendingPathExtension("objects"), durability: .fsync)
}

private func listReply(_ entries: [(String, String, String?)], hasMore: Bool, cursor: String?, headers: [String: String] = [:]) -> HTTPExchange {
    let items = entries.map { id, type, updated in
        #"{"id":"\#(id)","type":"\#(type)","title":"private title","unknownField":1"# + (updated.map { #","updatedAt":"\#($0)""# } ?? "") + "}"
    }.joined(separator: ",")
    let cursorJSON = cursor.map { "\"\($0)\"" } ?? "null"
    return HTTPExchange(
        status: 200, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a },
        body: Data(#"{"entries":[\#(items)],"pagination":{"hasMore":\#(hasMore),"cursor":\#(cursorJSON),"limit":20},"partial":false,"failedSources":[]}"#.utf8))
}

private func detailReply(_ id: String) -> HTTPExchange {
    HTTPExchange(
        status: 200, headers: ["Content-Type": "application/json"],
        body: Data(#"{"id":"\#(id)","messages":[{"id":"m1","content":"private text"}],"future":true}"#.utf8))
}

private let page1 = [("e1", "evaluation", "2026-09-24T10:00:00Z"), ("e2", "evaluation", "2026-09-23T10:00:00Z")]
private let page2 = [("e3", "evaluation", "2026-09-22T10:00:00Z"), ("a1", "other", "2026-09-21T10:00:00Z")]

/// Records sleeps; optional hook runs at the n-th sleep.
private actor Sleeps {
    var durations: [Duration] = []
    var hook: (@Sendable () async throws -> Void)?
    var hookAt = 0
    func setHook(at index: Int, _ hook: @escaping @Sendable () async throws -> Void) {
        hookAt = index
        self.hook = hook
    }
    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        if durations.count == hookAt, let hook { try await hook() }
    }
}

private struct Harness {
    let root: URL
    let journal: JournalWriter
    let vault = MemoryVault()
    let account = AccountID()
    let sleeps = Sleeps()
    let transport: FakeTransport
    let provider: ArenaAccountSessions
    let record: AccountRecord

    /// `replies` excludes the restore and job-start identity checks, which are prepended.
    init(_ replies: [HTTPExchange], extraTransports: [FakeTransport] = []) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
        journal = try JournalWriter.open(at: root, options: JournalOptions(durability: .fsync))
        try vault.save(StoredSession(principal: principalA, cookies: Data("c".utf8)), account: account)
        transport = FakeTransport([me(), me()] + replies)
        let factory = TransportFactory([transport] + extraTransports)
        provider = ArenaAccountSessions(vault: vault, makeTransport: { factory.make() })
        record = AccountRecord(id: account, displayName: "A", principal: principalA, createdAt: Date(), credentialGeneration: 1)
        #expect(await provider.restore(account: account, expected: principalA) == .verified)
    }

    func run(_ options: SyncOptions = .testing()) async -> SyncManifest {
        let sleeps = self.sleeps
        let engine = ArenaHistorySync(sessions: provider, sleep: { try await sleeps.sleep($0) })
        return await engine.sync(
            account: record.context, principal: principalA, journal: journal, journalRoot: root, objects: testObjects(root), options: options,
            progress: { _ in })
    }

    /// Adds more scripted replies to the same session for a second job.
    func script(_ replies: [HTTPExchange]) { transport.append([me()] + replies) }

    var records: [JournalRecord] { (try? JournalReader(root: root).readAll()) ?? [] }
    func exchanges(_ role: String) -> [JournalRecord] {
        records.filter { $0.envelope.kind == "exchange" && $0.envelope.metadata["role"] == .string(role) }
    }
}

extension FakeTransport {
    func append(_ more: [HTTPExchange]) { appendReplies(more) }
}

// MARK: - Tests

@Test func fullSyncPaginatesRecordsBeforeInterpretingAndCompletes() async throws {
    let h = try await Harness([
        listReply(page1, hasMore: true, cursor: "cur+sor/1", headers: ["Set-Cookie": "secret=1"]),
        listReply(page2, hasMore: false, cursor: nil),
        detailReply("e1"), detailReply("e2"), detailReply("e3"),
    ])
    let manifest = await h.run()
    #expect(manifest.outcome == .completed)
    #expect(manifest.pagesListed == 2 && manifest.entriesListed == 4)
    #expect(manifest.entryTypes == ["evaluation": 3, "other": 1])
    #expect(manifest.detailsFetched == 3 && manifest.listOnlyEntries == 1 && manifest.detailsFailed == 0)
    #expect(manifest.listingEnd == "hasMore=false")

    let paths = h.transport.paths
    #expect(paths.filter { $0 == "/api/evaluation/a1" }.isEmpty, "a kind without an observed detail route is list-only")
    let queries = h.transport.requests.compactMap { $0.url?.query }
    #expect(queries == ["limit=20&includeArchived=true", "limit=20&includeArchived=true&cursor=cur%2Bsor%2F1"])

    let kinds = h.records.map(\.envelope.kind)
    #expect(kinds == ["job.started", "exchange", "session.verified", "exchange", "exchange", "exchange", "exchange", "exchange", "job.finished"])
    #expect(h.exchanges("identity").count == 1, "identity response journaled before interpretation")
    let firstList = try #require(h.exchanges("list").first)
    #expect(firstList.payload == listReply(page1, hasMore: true, cursor: "cur+sor/1").body, "raw body stored exactly")
    #expect(firstList.envelope.transformations == ["credential_omitted"])
    let headers = firstList.envelope.metadata["response_headers"]
    #expect(headers == .object(["Set-Cookie": .string("[omitted]"), "Content-Type": .string("application/json")]))
    #expect(h.exchanges("detail").map { $0.envelope.metadata["source_updated_at"] } == page1.map { .string($0.2) } + [.string(page2[0].2)])
    #expect(h.records.allSatisfy { $0.envelope.accountID == h.account.rawValue })
}

@Test func secondSyncCatchesUpWithoutRefetching() async throws {
    let h = try await Harness([
        listReply(page1, hasMore: true, cursor: "c1"), listReply(page2, hasMore: false, cursor: nil),
        detailReply("e1"), detailReply("e2"), detailReply("e3"),
    ])
    #expect(await h.run().outcome == .completed)
    h.script([listReply(page1, hasMore: true, cursor: "c1")])
    let before = h.transport.requestCount
    let manifest = await h.run()
    #expect(manifest.outcome == .completed)
    #expect(manifest.detailsFetched == 0 && manifest.pagesListed == 1)
    #expect(manifest.listingEnd?.hasPrefix("caught up") == true)
    #expect(h.transport.requestCount - before == 2)  // identity + one list page
}

@Test func onlyChangedConversationsAreRefetched() async throws {
    let h = try await Harness([
        listReply(page1, hasMore: false, cursor: nil), detailReply("e1"), detailReply("e2"),
    ])
    #expect(await h.run().detailsFetched == 2)
    let changed = [("e2", "evaluation", "2026-09-25T09:00:00Z"), ("e1", "evaluation", "2026-09-24T10:00:00Z")]
    h.script([listReply(changed, hasMore: false, cursor: nil), detailReply("e2")])
    let manifest = await h.run()
    #expect(manifest.detailsFetched == 1 && manifest.detailsUnchanged == 1)
    #expect(h.exchanges("detail").map { $0.envelope.metadata["entry_id"] } == [.string("e1"), .string("e2"), .string("e2")])
}

@Test func fullPassListsEveryPage() async throws {
    let h = try await Harness([
        listReply(page1, hasMore: true, cursor: "c1"), listReply(page2, hasMore: false, cursor: nil),
        detailReply("e1"), detailReply("e2"), detailReply("e3"),
    ])
    _ = await h.run()
    h.script([listReply(page1, hasMore: true, cursor: "c1"), listReply(page2, hasMore: false, cursor: nil)])
    let manifest = await h.run(.testing(fullPass: true))
    #expect(manifest.pagesListed == 2 && manifest.detailsFetched == 0 && manifest.listingEnd == "hasMore=false")
}

@Test func interruptedJobResumesFromItsLastPageAndSkipsCommittedDetails() async throws {
    let h = try await Harness([
        // resumed job: continues at cursor "c1", then fetches only e2 and e3
        listReply(page2, hasMore: false, cursor: nil), detailReply("e2"), detailReply("e3"),
    ])
    // A job that was killed: started, listed page 1, archived e1, never finished.
    let crashed = UUID()
    _ = try h.journal.append(
        JournalDraft(kind: JournalKind.jobStarted, accountID: h.account.rawValue, jobID: crashed, metadata: ["job_kind": .string("history_sync")]))
    _ = try h.journal.append(
        JournalDraft(
            kind: "exchange", payload: listReply(page1, hasMore: true, cursor: "c1").body, accountID: h.account.rawValue,
            jobID: crashed, metadata: ["role": .string("list"), "status": .integer(200), "transfer_end": .string("complete")]))
    _ = try h.journal.append(
        JournalDraft(
            kind: "exchange", payload: detailReply("e1").body, accountID: h.account.rawValue, jobID: crashed,
            metadata: [
                "role": .string("detail"), "status": .integer(200), "transfer_end": .string("complete"),
                "entry_id": .string("e1"), "source_updated_at": .string(page1[0].2),
            ]))

    let manifest = await h.run()
    #expect(manifest.outcome == .completed)
    #expect(manifest.resumedJobID == crashed)
    #expect(manifest.entriesListed == 4 && manifest.detailsFetched == 2 && manifest.detailsUnchanged == 1)
    #expect(h.transport.requests.compactMap { $0.url?.query }.first == "limit=20&includeArchived=true&cursor=c1")
    #expect(!h.transport.paths.contains("/api/evaluation/e1"), "committed detail was refetched")
    let closed = h.records.first { $0.envelope.kind == JournalKind.jobFinished && $0.envelope.jobID == crashed }
    #expect(closed?.envelope.metadata["outcome"] == .string("interrupted"))
    #expect(closed?.envelope.metadata["resumed_by"] == .string(manifest.jobID.uuidString))
}

@Test(arguments: [(403, SyncOutcome.blocked), (401, SyncOutcome.needsSignIn)])
func rejectionsStopTheJobCleanly(_ status: Int, _ outcome: SyncOutcome) async throws {
    let h = try await Harness([
        listReply(page1, hasMore: true, cursor: "c1"), HTTPExchange(status: status, body: Data("private".utf8)),
    ])
    let manifest = await h.run()
    #expect(manifest.outcome == outcome && manifest.reason == "HTTP \(status)")
    #expect(h.transport.requestCount == 4)  // restore, verify, page 1, rejected page 2: nothing after
    #expect(h.records.last?.envelope.kind == JournalKind.jobFinished)
    #expect(h.exchanges("list").count == 2, "the rejection itself is recorded")
}

@Test func rateLimitHonorsRetryAfterOnceThenStops() async throws {
    let limited = HTTPExchange(status: 429, headers: ["Retry-After": "7"], body: Data())
    let h = try await Harness([limited, listReply(page1, hasMore: false, cursor: nil), detailReply("e1"), limited, limited])
    let manifest = await h.run()
    #expect(manifest.outcome == .partial && manifest.reason == "rate limited (HTTP 429)")
    #expect(await h.sleeps.durations.contains(.seconds(7)))
    #expect(manifest.pagesListed == 1 && manifest.detailsFetched == 1)
}

@Test func rateLimitWithoutUsableRetryAfterStopsImmediately() async throws {
    let h = try await Harness([HTTPExchange(status: 503, headers: ["Retry-After": "600"], body: Data())])
    let manifest = await h.run()
    #expect(manifest.outcome == .partial && manifest.reason == "rate limited (HTTP 503)")
    #expect(h.transport.requestCount == 3)
}

@Test func paginationAnomaliesStopWithPartial() async throws {
    let repeated = try await Harness([
        listReply(page1, hasMore: true, cursor: "same"), listReply(page2, hasMore: true, cursor: "same"),
    ])
    #expect(await repeated.run().reason == "repeated cursor")
    let missing = try await Harness([listReply(page1, hasMore: true, cursor: nil)])
    let manifest = await missing.run()
    #expect(manifest.outcome == .partial && manifest.reason == "hasMore=true without cursor")
}

@Test func challengePageIsBlockedAndUndecodablePageIsRecordedFirst() async throws {
    let html = try await Harness([HTTPExchange(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>challenge</html>".utf8))])
    #expect(await html.run().outcome == .blocked)
    #expect(html.exchanges("list").first?.payload == Data("<html>challenge</html>".utf8))

    let odd = try await Harness([HTTPExchange(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"shape":"new"}"#.utf8))])
    let manifest = await odd.run()
    #expect(manifest.outcome == .partial && manifest.reason == "list page not recognized")
    #expect(odd.exchanges("list").first?.payload == Data(#"{"shape":"new"}"#.utf8))
}

@Test func signingInAgainDuringAJobStopsIt() async throws {
    let replacement = FakeTransport([ok, me()])
    let h = try await Harness(
        [listReply(page1, hasMore: false, cursor: nil), detailReply("e1"), detailReply("e2")], extraTransports: [replacement])
    let provider = h.provider
    let account = h.account
    await h.sleeps.setHook(at: 1) {
        _ = try await provider.signIn(account: account, email: "e", password: "p")
        try await provider.persist(account: account, principal: principalA)
    }
    let manifest = await h.run()
    #expect(manifest.outcome == .sessionReplaced)
    #expect(replacement.requestCount == 2, "the job never used the new session")
}

@Test(arguments: [
    (HTTPExchange(status: 401, body: Data()), SyncOutcome.needsSignIn, false, AccountAuthState?.some(.needsSignIn)),
    (HTTPExchange(status: 403, body: Data()), SyncOutcome.blocked, true, .blocked),
    (HTTPExchange(status: 200, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8)), SyncOutcome.blocked, true, .blocked),
    (HTTPExchange(status: 503, body: Data()), SyncOutcome.partial, true, nil),
    (me("user-B", "principal-B"), SyncOutcome.needsSignIn, false, .quarantined),
])
func identityOutcomesAtJobStart(
    _ reply: HTTPExchange, _ outcome: SyncOutcome, _ keepsSavedSession: Bool, _ sessionState: AccountAuthState?
) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
    let journal = try JournalWriter.open(at: root, options: JournalOptions(durability: .fsync))
    let vault = MemoryVault()
    let account = AccountID()
    try vault.save(StoredSession(principal: principalA, cookies: Data("c".utf8)), account: account)
    let transport = FakeTransport([me(), reply])
    let factory = TransportFactory([transport])
    let provider = ArenaAccountSessions(vault: vault, makeTransport: { factory.make() })
    _ = await provider.restore(account: account, expected: principalA)
    let record = AccountRecord(id: account, displayName: "A", principal: principalA, createdAt: Date(), credentialGeneration: 1)
    let manifest = await ArenaHistorySync(sessions: provider, sleep: { _ in }).sync(
        account: record.context, principal: principalA, journal: journal, journalRoot: root, objects: testObjects(root), options: .testing(),
        progress: { _ in })
    #expect(manifest.outcome == outcome)
    #expect(manifest.sessionState == sessionState, "the account's state follows (review 2026-10-18, finding 6)")
    #expect(transport.requestCount == 2, "nothing but identity was requested")
    #expect((vault[account] != nil) == keepsSavedSession)
    let kinds = try JournalReader(root: root).readAll().map(\.envelope.kind)
    #expect(kinds == ["job.started", "exchange", "job.finished"], "the identity response itself is evidence")
}

@Test func cancellationStopsAndIsRecorded() async throws {
    let h = try await Harness([listReply(page1, hasMore: false, cursor: nil), detailReply("e1"), detailReply("e2")])
    await h.sleeps.setHook(at: 1) { throw CancellationError() }
    let manifest = await h.run()
    #expect(manifest.outcome == .cancelled)
    #expect(h.records.last?.envelope.metadata["outcome"] == .string("cancelled"))
}

@Test func newestFirstCheckRequiresOrderedTimestamps() {
    let newer = "2026-09-24T10:00:00Z"
    let older = "2026-09-23T10:00:00Z"
    #expect(SyncJob.isNewestFirst([ListEntry(id: "a", type: "evaluation", updatedAt: newer), ListEntry(id: "b", type: "evaluation", updatedAt: older)]))
    #expect(!SyncJob.isNewestFirst([ListEntry(id: "a", type: "evaluation", updatedAt: older), ListEntry(id: "b", type: "evaluation", updatedAt: newer)]))
    #expect(!SyncJob.isNewestFirst([ListEntry(id: "a", type: "agentic", updatedAt: nil)]))
}


// MARK: - Review follow-ups (Phase 3 review)

@Test func conversationsWithoutUpdatedAtAreAlwaysRefetched() async throws {
    let unstamped = [("e1", "evaluation", String?.none), ("e2", "evaluation", "2026-09-24T10:00:00Z")]
    let h = try await Harness([listReply(unstamped, hasMore: false, cursor: nil), detailReply("e1"), detailReply("e2")])
    #expect(await h.run().detailsFetched == 2)
    h.script([listReply(unstamped, hasMore: false, cursor: nil), detailReply("e1")])
    let manifest = await h.run()
    #expect(manifest.detailsFetched == 1 && manifest.detailsUnchanged == 1)
    #expect(manifest.warnings.contains { $0.contains("without updatedAt") })
}

@Test func notFoundIsRememberedUntilTheEntryChanges() async throws {
    let h = try await Harness([listReply(page1, hasMore: false, cursor: nil), HTTPExchange(status: 404, body: Data()), detailReply("e2")])
    let first = await h.run()
    #expect(first.outcome == .completed && first.detailsAbsent == 1 && first.detailsFailed == 0)
    h.script([listReply(page1, hasMore: false, cursor: nil)])
    let second = await h.run(.testing(fullPass: true))
    #expect(second.detailsFetched == 0 && second.detailsAbsent == 0)
    #expect(h.exchanges("detail").count == 2, "known-absent conversation not requested again")
    let changed = [("e1", "evaluation", "2026-09-26T10:00:00Z"), page1[1]]
    h.script([listReply(changed, hasMore: false, cursor: nil), detailReply("e1")])
    #expect(await h.run().detailsFetched == 1)
}

@Test func failedDetailsMakeTheJobPartial() async throws {
    let h = try await Harness([
        listReply(page1, hasMore: false, cursor: nil),
        HTTPExchange(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"id":"other"}"#.utf8)),
        detailReply("e2"),
    ])
    let manifest = await h.run()
    #expect(manifest.outcome == .partial && manifest.detailsFailed == 1 && manifest.detailsFetched == 1)
    #expect(manifest.reason?.contains("1 detail request(s) failed") == true)
}

@Test func detailServerErrorStopsTheQueueResumably() async throws {
    let h = try await Harness([listReply(page1, hasMore: false, cursor: nil), HTTPExchange(status: 500, body: Data())])
    let manifest = await h.run()
    #expect(manifest.outcome == .partial && manifest.reason == "HTTP 500")
    #expect(!h.transport.paths.contains("/api/evaluation/e2"))
}

@Test func newestFirstUsesInstantsNotStrings() {
    func entries(_ stamps: [String]) -> [ListEntry] { stamps.map { ListEntry(id: $0, type: "evaluation", updatedAt: $0) } }
    // String order says newest-first, time order does not.
    #expect(!SyncJob.isNewestFirst(entries(["2026-09-24T10:00:00Z", "2026-09-24T10:00:00.500Z"])))
    #expect(!SyncJob.isNewestFirst(entries(["2026-09-24T10:00:00+02:00", "2026-09-24T09:00:00Z"])))
    #expect(SyncJob.isNewestFirst(entries(["2026-09-24T10:00:00.500Z", "2026-09-24T10:00:00Z", "2026-09-24T10:00:00Z"])))
    #expect(!SyncJob.isNewestFirst(entries(["not a date"])))
}

@Test func oneBadEntryDoesNotDiscardThePage() async throws {
    let body = Data(#"{"entries":[{"id":"e1","type":"evaluation","updatedAt":"2026-09-24T10:00:00Z"},{"type":"evaluation"},{"id":"e2","type":"evaluation","updatedAt":"2026-09-23T10:00:00Z"}],"pagination":{"hasMore":false,"cursor":null},"partial":false,"failedSources":[]}"#.utf8)
    let h = try await Harness([HTTPExchange(status: 200, headers: ["Content-Type": "application/json"], body: body), detailReply("e1"), detailReply("e2")])
    let manifest = await h.run()
    #expect(manifest.outcome == .completed && manifest.entriesListed == 2 && manifest.detailsFetched == 2)
    #expect(manifest.warnings.contains { $0.contains("1 entry(ies) without a usable id") })
}

@Test func jsonContainingAngleBracketIsNotAChallenge() async throws {
    let h = try await Harness([HTTPExchange(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"note":"<b>new shape</b>"}"#.utf8))])
    let manifest = await h.run()
    #expect(manifest.outcome == .partial && manifest.reason == "list page not recognized")
}

@Test func requestSpacingCannotBeLoweredBelowPolicy() {
    var options = SyncOptions(requestSpacing: .milliseconds(10))
    #expect(options.requestSpacing == .seconds(1))
    options.setRequestSpacing(.milliseconds(1))
    #expect(options.requestSpacing == .seconds(1))
    options.setRequestSpacing(.seconds(3))
    #expect(options.requestSpacing == .seconds(3))
}

@Test func observedPostgresTimestampsParseExactly() throws {
    // Observed shapes (N-012): 4–6 fraction digits, space separator, hour-only offset.
    // Mixed fraction lengths under the same "+00" offset keep string and time order in agreement...
    let short = try #require(SourceInstant("2026-09-24 10:00:00.1234+00"))
    let long = try #require(SourceInstant("2026-09-24 10:00:00.123401+00"))
    #expect(short < long)
    // ...but a different offset breaks string order, which is why instants are parsed.
    let plusTwo = try #require(SourceInstant("2026-09-24 11:00:00.0000+02"))  // 09:00Z
    let utc = try #require(SourceInstant("2026-09-24 10:00:00.0000+00"))  // 10:00Z
    #expect(plusTwo < utc)
    #expect("2026-09-24 11:00:00.0000+02" > "2026-09-24 10:00:00.0000+00")
    #expect(SourceInstant("2026-09-24 12:00:00.0000+02") == SourceInstant("2026-09-24T10:00:00Z"))
    #expect(SourceInstant("2026-09-24T10:00:00.5-01:30") == SourceInstant("2026-09-24 11:30:00.500000+00"))
    for bad in ["2026-09-24", "2026-13-01 00:00:00+00", "yesterday", "2026-09-24 10:00:00"] {
        #expect(SourceInstant(bad) == nil, "\(bad)")
    }
    let entries = ["2026-09-24 10:00:00.0000+00", "2026-09-24 11:00:00.0000+02"].map {
        ListEntry(id: $0, type: "evaluation", updatedAt: $0)
    }
    #expect(SyncJob.isNewestFirst(entries))
    #expect(!SyncJob.isNewestFirst(entries.reversed()))
}

// MARK: - Review 2026-10-18, finding 5

/// A list page with explicit pagination and completeness fields (nil omits the key).
private func rawListReply(
    _ entries: [(String, String, String?)], hasMore: Bool?, cursor: String? = nil, partial: Bool? = false,
    failedSources: [String] = []
) -> HTTPExchange {
    let items = entries.map { id, type, updated in
        #"{"id":"\#(id)","type":"\#(type)""# + (updated.map { #","updatedAt":"\#($0)""# } ?? "") + "}"
    }.joined(separator: ",")
    var pagination = [#""limit":20"#, #""cursor":\#(cursor.map { "\"\($0)\"" } ?? "null")"#]
    if let hasMore { pagination.append(#""hasMore":\#(hasMore)"#) }
    var top = [#""entries":[\#(items)]"#, #""pagination":{\#(pagination.joined(separator: ","))}"#]
    if let partial { top.append(#""partial":\#(partial)"#) }
    top.append(#""failedSources":[\#(failedSources.map { "\"\($0)\"" }.joined(separator: ","))]"#)
    return HTTPExchange(status: 200, headers: ["Content-Type": "application/json"], body: Data("{\(top.joined(separator: ","))}".utf8))
}

@Test(arguments: [
    ("partial and failed source on an empty page", rawListReply([], hasMore: false, partial: true, failedSources: ["arena"])),
    ("failed source only", rawListReply([], hasMore: false, failedSources: ["arena"])),
    ("partial absent", rawListReply([], hasMore: false, partial: nil)),
    ("hasMore absent", rawListReply([], hasMore: nil)),
])
func listingThatIsNotProvenCompleteIsNotCompleted(_ name: String, _ page: HTTPExchange) async throws {
    let h = try await Harness([page])
    let manifest = await h.run()
    #expect(manifest.outcome == .partial, "\(name)")
    #expect(manifest.reason?.hasPrefix("listing not proven complete") == true, "\(name)")
    #expect(h.records.last?.envelope.kind == JournalKind.jobFinished)
}

@Test func aPartialUnchangedPageDoesNotEndTheListingEarly() async throws {
    let h = try await Harness([
        listReply(page1, hasMore: true, cursor: "c1"), listReply(page2, hasMore: false, cursor: nil),
        detailReply("e1"), detailReply("e2"), detailReply("e3"),
    ])
    #expect(await h.run().outcome == .completed)
    // Same entries, but the server says the page is partial: entries could be missing from it.
    h.script([
        rawListReply(page1, hasMore: true, cursor: "c1", partial: true), listReply(page2, hasMore: false, cursor: nil),
    ])
    let manifest = await h.run()
    #expect(manifest.pagesListed == 2, "listing went on past the partial page")
    #expect(manifest.listingEnd?.hasPrefix("caught up: page 2") == true, "the complete page 2 may end it")
    #expect(manifest.outcome == .partial && manifest.reason?.contains("page 1: partial=true") == true)
}

@Test func aResumedJobKeepsItsRecordedPagesIncompleteness() async throws {
    let h = try await Harness([listReply(page2, hasMore: false, cursor: nil), detailReply("e1"), detailReply("e2"), detailReply("e3")])
    let crashed = UUID()
    _ = try h.journal.append(
        JournalDraft(kind: JournalKind.jobStarted, accountID: h.account.rawValue, jobID: crashed, metadata: ["job_kind": .string("history_sync")]))
    _ = try h.journal.append(
        JournalDraft(
            kind: "exchange", payload: rawListReply(page1, hasMore: true, cursor: "c1", partial: true).body,
            accountID: h.account.rawValue, jobID: crashed,
            metadata: ["role": .string("list"), "status": .integer(200), "transfer_end": .string("complete")]))
    let manifest = await h.run()
    #expect(manifest.resumedJobID == crashed && manifest.detailsFetched == 3)
    #expect(manifest.outcome == .partial)
    #expect(manifest.reason?.contains("page 1: partial=true, failedSources=0 (resumed)") == true)
}

@Test func aResumedJobWhoseLastPageHadNoHasMoreIsNotCompleted() async throws {
    let h = try await Harness([detailReply("e1"), detailReply("e2")])
    let crashed = UUID()
    _ = try h.journal.append(
        JournalDraft(kind: JournalKind.jobStarted, accountID: h.account.rawValue, jobID: crashed, metadata: ["job_kind": .string("history_sync")]))
    _ = try h.journal.append(
        JournalDraft(
            kind: "exchange", payload: rawListReply(page1, hasMore: nil).body, accountID: h.account.rawValue, jobID: crashed,
            metadata: ["role": .string("list"), "status": .integer(200), "transfer_end": .string("complete")]))
    let manifest = await h.run()
    #expect(manifest.listingEnd == "hasMore absent (resumed)")
    #expect(manifest.outcome == .partial)
}

// MARK: - Unfinished conversations and Refresh (Docs/sync-refresh-2026-10-20.md)

private func detailReply(_ id: String, statuses: [String?]) -> HTTPExchange {
    let messages = statuses.enumerated().map { index, status in
        #"{"id":"m\#(index)","content":"private text""# + (status.map { #","status":"\#($0)""# } ?? "") + "}"
    }.joined(separator: ",")
    return HTTPExchange(
        status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"id":"\#(id)","messages":[\#(messages)]}"#.utf8))
}

/// N-020: the prompt done, both responses still generating.
private let generating: [String?] = ["success", "pending", "pending"]
private let finished: [String?] = ["success", "success", "success"]

extension Harness {
    func refresh(_ id: String) async -> SyncManifest {
        let sleeps = self.sleeps
        let engine = ArenaHistorySync(sessions: provider, sleep: { try await sleeps.sleep($0) })
        return await engine.refresh(
            account: record.context, principal: principalA, journal: journal, journalRoot: root, objects: testObjects(root), conversationID: id,
            options: .testing())
    }

    func details(_ id: String) -> [JournalRecord] {
        exchanges("detail").filter { $0.envelope.metadata["entry_id"] == .string(id) }
    }
}

@Test func anUnfinishedConversationIsFetchedAgainWhileTheListIsUnchanged() async throws {
    let h = try await Harness([listReply(page1, hasMore: false, cursor: nil), detailReply("e1", statuses: generating), detailReply("e2")])
    #expect(await h.run().detailsFetched == 2)
    h.script([listReply(page1, hasMore: false, cursor: nil), detailReply("e1", statuses: finished)])
    let second = await h.run()
    #expect(second.outcome == .completed)
    #expect(second.detailsFetched == 1 && second.detailsRefetchedUnfinished == 1 && second.unfinishedLeft == 0)
    #expect(h.details("e1").count == 2 && h.details("e2").count == 1)
    #expect(h.details("e1").last?.envelope.metadata["source_updated_at"] == .string(page1[0].2))
    #expect(h.details("e1").last?.envelope.metadata["source_updated_at_origin"] == nil, "listed by this job")
    // Finished now: nothing more is fetched.
    h.script([listReply(page1, hasMore: false, cursor: nil)])
    let before = h.transport.requestCount
    let third = await h.run()
    #expect(third.detailsFetched == 0 && third.detailsRefetchedUnfinished == 0)
    #expect(h.transport.requestCount - before == 2)  // identity + one list page
}

@Test func anUnfinishedConversationTheListingDoesNotReachIsFetchedByID() async throws {
    let h = try await Harness([
        listReply(page1, hasMore: true, cursor: "c1"), listReply(page2, hasMore: false, cursor: nil),
        detailReply("e1"), detailReply("e2"), detailReply("e3", statuses: generating),
    ])
    #expect(await h.run().detailsFetched == 3)
    h.script([listReply(page1, hasMore: true, cursor: "c1"), detailReply("e3", statuses: finished)])
    let second = await h.run()
    #expect(second.outcome == .completed)
    #expect(second.pagesListed == 1 && second.listingEnd?.hasPrefix("caught up") == true)
    #expect(second.detailsFetched == 1 && second.detailsRefetchedUnfinished == 1)
    let refetched = try #require(h.details("e3").last)
    #expect(refetched.envelope.metadata["source_updated_at"] == .string(page2[0].2))
    #expect(refetched.envelope.metadata["source_updated_at_origin"] == .string("last_listed"))
    #expect(refetched.envelope.metadata["entry_type"] == .string("evaluation"))
    #expect(refetched.envelope.metadata["entry_type_origin"] == .string("last_listed"))
    #expect(h.transport.paths.suffix(2) == ["/api/history/unified", "/api/evaluation/e3"])
}

@Test func anUnfinishedConversationIsFetchedAtMostThreeTimesForOneUpdatedAt() async throws {
    let h = try await Harness([listReply(page1, hasMore: false, cursor: nil), detailReply("e1", statuses: generating), detailReply("e2")])
    _ = await h.run()
    for _ in 0..<2 {
        h.script([listReply(page1, hasMore: false, cursor: nil), detailReply("e1", statuses: generating)])
        #expect(await h.run().detailsRefetchedUnfinished == 1)
    }
    // Three unfinished snapshots in a row: left alone until the entry changes or the user refreshes.
    h.script([listReply(page1, hasMore: false, cursor: nil)])
    let left = await h.run()
    #expect(left.outcome == .completed && left.detailsFetched == 0 && left.unfinishedLeft == 1)
    #expect(h.details("e1").count == 3)
    // A new `updatedAt`: fetched by the ordinary rule, and the count starts again.
    let changed = [("e1", "evaluation", "2026-09-25T10:00:00Z"), page1[1]]
    h.script([listReply(changed, hasMore: false, cursor: nil), detailReply("e1", statuses: generating)])
    let moved = await h.run()
    #expect(moved.detailsFetched == 1 && moved.detailsRefetchedUnfinished == 0 && moved.unfinishedLeft == 0)
    h.script([listReply(changed, hasMore: false, cursor: nil), detailReply("e1", statuses: generating)])
    #expect(await h.run().detailsRefetchedUnfinished == 1)
}

@Test func anUnknownStatusIsNotTreatedAsUnfinished() async throws {
    let h = try await Harness([
        listReply(page1, hasMore: false, cursor: nil), detailReply("e1", statuses: ["success", "queued_somehow", nil]),
        detailReply("e2", statuses: ["success", "stopped", "failed"]),
    ])
    _ = await h.run()
    h.script([listReply(page1, hasMore: false, cursor: nil)])
    let before = h.transport.requestCount
    let second = await h.run()
    #expect(second.outcome == .completed && second.detailsFetched == 0 && second.unfinishedLeft == 0)
    #expect(h.transport.requestCount - before == 2)  // identity + one list page
}

@Test func anUnfinishedConversationAnswered404IsNotFetchedAgain() async throws {
    let h = try await Harness([listReply(page1, hasMore: false, cursor: nil), detailReply("e1", statuses: generating), detailReply("e2")])
    _ = await h.run()
    h.script([listReply(page1, hasMore: false, cursor: nil), HTTPExchange(status: 404, body: Data())])
    let absent = await h.run()
    // Requested again for being unfinished, but no snapshot arrived: not counted as fetched again.
    #expect(absent.detailsAbsent == 1 && absent.detailsFetched == 0 && absent.detailsRefetchedUnfinished == 0)
    h.script([listReply(page1, hasMore: false, cursor: nil)])
    let before = h.transport.requestCount
    let third = await h.run()
    #expect(third.outcome == .completed && third.detailsFetched == 0 && third.detailsAbsent == 0 && third.unfinishedLeft == 0)
    #expect(h.transport.requestCount - before == 2)  // identity + one list page
}

@Test func aRefreshVerifiesIdentityThenFetchesOneDetail() async throws {
    let h = try await Harness([listReply(page1, hasMore: false, cursor: nil), detailReply("e1", statuses: generating), detailReply("e2")])
    _ = await h.run()
    h.script([detailReply("e1", statuses: finished)])
    let records = h.records.count
    let requests = h.transport.requestCount
    let pauses = await h.sleeps.durations.count
    let manifest = await h.refresh("e1")
    #expect(manifest.outcome == .completed && manifest.detailsFetched == 1 && manifest.pagesListed == 0)
    #expect(h.transport.requestCount - requests == 2)
    #expect(await h.sleeps.durations.count - pauses == 1, "the request spacing before the detail")
    #expect(h.transport.paths.suffix(2) == ["/api/me", "/api/evaluation/e1"])
    let added = Array(h.records.dropFirst(records))
    #expect(added.map(\.envelope.kind) == ["job.started", "exchange", "session.verified", "exchange", "job.finished"])
    #expect(added[0].envelope.metadata == ["job_kind": .string("conversation_refresh")])
    #expect(added[4].envelope.metadata["job_kind"] == .string("conversation_refresh"))
    let detail = added[3].envelope.metadata
    #expect(detail["role"] == .string("detail") && detail["entry_id"] == .string("e1"))
    #expect(detail["entry_type"] == .string("evaluation") && detail["entry_type_origin"] == .string("last_listed"))
    #expect(detail["source_updated_at"] == .string(page1[0].2))
    #expect(detail["source_updated_at_origin"] == .string("last_listed"))
    #expect(added.allSatisfy { $0.envelope.accountID == h.account.rawValue && $0.envelope.jobID == added[0].envelope.jobID })
    // Finished by the refresh, and named after the listed `updatedAt`: the next sync fetches nothing.
    h.script([listReply(page1, hasMore: false, cursor: nil)])
    let next = await h.run()
    #expect(next.outcome == .completed && next.detailsFetched == 0 && next.unfinishedLeft == 0)
}

@Test func aRefreshRecordsAbsenceAndStopsOnRefusal() async throws {
    let gone = try await Harness([listReply(page1, hasMore: false, cursor: nil), detailReply("e1"), detailReply("e2")])
    _ = await gone.run()
    gone.script([HTTPExchange(status: 404, body: Data())])
    let absent = await gone.refresh("e1")
    #expect(absent.outcome == .completed && absent.detailsAbsent == 1 && absent.detailsFetched == 0)

    let refused = try await Harness([listReply(page1, hasMore: false, cursor: nil), detailReply("e1"), detailReply("e2")])
    _ = await refused.run()
    refused.script([HTTPExchange(status: 403, body: Data())])
    let blocked = await refused.refresh("e1")
    #expect(blocked.outcome == .blocked && blocked.sessionState == .blocked)
    #expect(refused.records.last?.envelope.metadata["outcome"] == .string("blocked"))
}

@Test func aRefreshOfAnythingButAListedConversationSendsAndWritesNothing() async throws {
    let h = try await Harness([listReply(page2, hasMore: false, cursor: nil), detailReply("e3")])
    _ = await h.run()
    let records = h.records.count
    let requests = h.transport.requestCount
    for id in ["a1", "never-listed"] {
        let manifest = await h.refresh(id)
        #expect(manifest.outcome == .partial && manifest.reason?.hasPrefix("refused") == true)
    }
    #expect(h.transport.requestCount == requests && h.records.count == records)
}

@Test func aRefreshLeavesAnInterruptedSyncToBeResumedAndClosesAnInterruptedRefresh() async throws {
    let h = try await Harness([listReply(page1, hasMore: false, cursor: nil), detailReply("e1"), detailReply("e2")])
    _ = await h.run()
    // A sync and a refresh, both killed after their start records.
    let sync = UUID()
    let refresh = UUID()
    _ = try h.journal.append(
        JournalDraft(kind: JournalKind.jobStarted, accountID: h.account.rawValue, jobID: sync, metadata: ["job_kind": .string("history_sync")]))
    _ = try h.journal.append(
        JournalDraft(
            kind: JournalKind.jobStarted, accountID: h.account.rawValue, jobID: refresh,
            metadata: ["job_kind": .string("conversation_refresh")]))
    h.script([detailReply("e1")])
    #expect(await h.refresh("e1").outcome == .completed)
    let closed = h.records.filter { $0.envelope.kind == JournalKind.jobFinished }
    #expect(closed.contains { $0.envelope.jobID == refresh && $0.envelope.metadata["outcome"] == .string("interrupted") })
    #expect(!closed.contains { $0.envelope.jobID == sync }, "left for the next sync")
    h.script([listReply(page1, hasMore: false, cursor: nil)])
    #expect(await h.run().resumedJobID == sync)
}

// Review 2026-10-20 (Docs/reviews/2026-10-20-sync-refresh.md).

@Test func anUnlistedUnfinishedConversationStopsAtTheLimitToo() async throws {
    let h = try await Harness([
        listReply(page1, hasMore: true, cursor: "c1"), listReply(page2, hasMore: false, cursor: nil),
        detailReply("e1"), detailReply("e2"), detailReply("e3", statuses: generating),
    ])
    _ = await h.run()
    for _ in 0..<2 {
        h.script([listReply(page1, hasMore: true, cursor: "c1"), detailReply("e3", statuses: generating)])
        #expect(await h.run().detailsRefetchedUnfinished == 1)
    }
    h.script([listReply(page1, hasMore: true, cursor: "c1")])
    let left = await h.run()
    #expect(left.outcome == .completed && left.detailsFetched == 0 && left.unfinishedLeft == 1)
    #expect(h.details("e3").count == 3)
}

@Test func aSyncStoppedWhileListingStillCountsTheUnfinishedItLeft() async throws {
    let h = try await Harness([listReply(page1, hasMore: false, cursor: nil), detailReply("e1", statuses: generating), detailReply("e2")])
    _ = await h.run()
    for _ in 0..<2 {
        h.script([listReply(page1, hasMore: false, cursor: nil), detailReply("e1", statuses: generating)])
        _ = await h.run()
    }
    h.script([HTTPExchange(status: 403, body: Data())])
    let blocked = await h.run()
    #expect(blocked.outcome == .blocked && blocked.unfinishedLeft == 1)
}

@Test func refreshedUnfinishedSnapshotsCountTowardTheLimit() async throws {
    let h = try await Harness([listReply(page1, hasMore: false, cursor: nil), detailReply("e1", statuses: generating), detailReply("e2")])
    _ = await h.run()
    for _ in 0..<2 {
        h.script([detailReply("e1", statuses: generating)])
        #expect(await h.refresh("e1").detailsFetched == 1)
    }
    h.script([listReply(page1, hasMore: false, cursor: nil)])
    let next = await h.run()
    #expect(next.outcome == .completed && next.detailsFetched == 0 && next.unfinishedLeft == 1)
}

/// Documented exception: without `updatedAt` a change can't be detected, so the earlier rule
/// fetches the conversation on every sync whatever its state; it isn't counted as unfinished.
@Test func withoutUpdatedAtAnUnfinishedConversationKeepsTheAlwaysFetchRule() async throws {
    let undated: [(String, String, String?)] = [("e1", "evaluation", nil)]
    let h = try await Harness([listReply(undated, hasMore: false, cursor: nil), detailReply("e1", statuses: generating)])
    _ = await h.run()
    for _ in 0..<3 {
        h.script([listReply(undated, hasMore: false, cursor: nil), detailReply("e1", statuses: generating)])
        let manifest = await h.run()
        #expect(manifest.outcome == .completed && manifest.detailsFetched == 1)
        #expect(manifest.detailsRefetchedUnfinished == 0 && manifest.unfinishedLeft == 0)
    }
    // A refresh names no `updatedAt` it didn't have.
    h.script([detailReply("e1")])
    _ = await h.refresh("e1")
    let metadata = try #require(h.details("e1").last).envelope.metadata
    #expect(metadata["source_updated_at"] == nil && metadata["source_updated_at_origin"] == nil)
    #expect(metadata["entry_type_origin"] == .string("last_listed"))
}

@Test func aSyncClosesAnInterruptedRefresh() async throws {
    let h = try await Harness([listReply(page1, hasMore: false, cursor: nil), detailReply("e1"), detailReply("e2")])
    _ = await h.run()
    let refresh = UUID()
    _ = try h.journal.append(
        JournalDraft(
            kind: JournalKind.jobStarted, accountID: h.account.rawValue, jobID: refresh,
            metadata: ["job_kind": .string("conversation_refresh")]))
    h.script([listReply(page1, hasMore: false, cursor: nil)])
    let manifest = await h.run()
    #expect(manifest.outcome == .completed && manifest.resumedJobID == nil)
    let closed = try #require(h.records.first { $0.envelope.kind == JournalKind.jobFinished && $0.envelope.jobID == refresh })
    #expect(closed.envelope.metadata == ["job_kind": .string("conversation_refresh"), "outcome": .string("interrupted")])
}

// Re-review 2026-10-20 (Docs/reviews/2026-10-20-sync-refresh.md).

/// Without `updatedAt` there is no run to count: an unfinished conversation the listing doesn't
/// reach is not fetched by ID, and nothing claims it was fetched for being unfinished or left at
/// the limit. Listed, it keeps the always-fetch rule (the test above).
@Test func anUnlistedConversationWithoutUpdatedAtIsNotTrackedAsUnfinished() async throws {
    let undated: [(String, String, String?)] = [("e3", "evaluation", nil)]
    let h = try await Harness([
        listReply(page1, hasMore: true, cursor: "c1"), listReply(undated, hasMore: false, cursor: nil),
        detailReply("e1"), detailReply("e2"), detailReply("e3", statuses: generating),
    ])
    #expect(await h.run().detailsFetched == 3)
    let requests = h.transport.requestCount
    h.script([listReply(page1, hasMore: true, cursor: "c1")])
    let next = await h.run()
    #expect(next.outcome == .completed && next.pagesListed == 1)
    #expect(next.detailsFetched == 0 && next.detailsRefetchedUnfinished == 0 && next.unfinishedLeft == 0)
    #expect(h.transport.requestCount == requests + 2, "identity and one list page")
}

/// A conversation at the limit that this job lists with a new `updatedAt` is no longer held by the
/// limit, even when the job stops before fetching it.
@Test func aChangedUpdatedAtIsNotCountedAsLeftWhenTheSyncStopsBeforeDetails() async throws {
    let h = try await Harness([listReply(page1, hasMore: false, cursor: nil), detailReply("e1", statuses: generating), detailReply("e2")])
    _ = await h.run()
    for _ in 0..<2 {
        h.script([listReply(page1, hasMore: false, cursor: nil), detailReply("e1", statuses: generating)])
        _ = await h.run()
    }
    let changed: [(String, String, String?)] = [("e1", "evaluation", "2026-09-25T10:00:00Z"), page1[1]]
    h.script([listReply(changed, hasMore: true, cursor: "c1"), HTTPExchange(status: 403, body: Data())])
    let blocked = await h.run()
    #expect(blocked.outcome == .blocked && blocked.pagesListed == 1)
    #expect(blocked.unfinishedLeft == 0)
}

// Third review 2026-10-20 (Docs/reviews/2026-10-20-sync-refresh.md).

/// If the listing stops stating `updatedAt` for an unfinished conversation (drift), it is fetched
/// by ID once more; that snapshot has no `updatedAt`, so it starts no count, and nothing more is
/// fetched by ID.
@Test func anUnfinishedConversationWhoseListingLostUpdatedAtIsFetchedByIDOnceMore() async throws {
    let h = try await Harness([
        listReply(page1, hasMore: true, cursor: "c1"), listReply(page2, hasMore: false, cursor: nil),
        detailReply("e1"), detailReply("e2"), detailReply("e3", statuses: generating),
    ])
    _ = await h.run()
    // A full pass lists e3 without `updatedAt`, then stops on its detail (HTTP 500).
    let undated: [(String, String, String?)] = [("e3", "evaluation", nil), page2[1]]
    h.script([listReply(page1, hasMore: true, cursor: "c1"), listReply(undated, hasMore: false, cursor: nil), HTTPExchange(status: 500, body: Data())])
    #expect(await h.run(.testing(fullPass: true)).outcome == .partial)
    h.script([listReply(page1, hasMore: true, cursor: "c1"), detailReply("e3", statuses: generating)])
    let once = await h.run()
    #expect(once.outcome == .completed && once.detailsFetched == 1 && once.detailsRefetchedUnfinished == 1)
    #expect(try #require(h.details("e3").last).envelope.metadata["source_updated_at"] == nil)
    h.script([listReply(page1, hasMore: true, cursor: "c1")])
    let after = await h.run()
    #expect(after.outcome == .completed && after.detailsFetched == 0 && after.unfinishedLeft == 0)
}

// MARK: - Agent pages (N-022)

private let agentList = [("e1", "evaluation", "2026-09-24T10:00:00Z"), ("a1", "agentic", "2026-09-23T10:00:00Z")]

@Test func anAgentConversationIsFetchedFromItsPageWithoutItsToken() async throws {
    let h = try await Harness([listReply(agentList, hasMore: false, cursor: nil), detailReply("e1"), agentReply(agentPage("a1"))])
    let manifest = await h.run()
    #expect(manifest.outcome == .completed)
    #expect(manifest.detailsFetched == 2 && manifest.listOnlyEntries == 0 && manifest.detailsFailed == 0)
    #expect(h.transport.paths.suffix(2) == ["/api/evaluation/e1", "/agent/a1"])
    let page = try #require(h.exchanges("agent_detail").first)
    #expect(page.envelope.transformations == ["credential_omitted", "token_omitted"])
    #expect(page.envelope.metadata["tokens_omitted"] == .integer(1))
    #expect(page.envelope.metadata["route"] == .string("/agent/{id}") && page.envelope.metadata["entry_type"] == .string("agentic"))
    #expect(page.payload.range(of: Data(agentToken.utf8)) == nil)
    #expect(page.payload == AgentPage.withoutTokens(agentPage("a1")).body, "every other byte kept")

    // The journaled page (without its token) is the snapshot: an unchanged listing fetches nothing.
    h.script([listReply(agentList, hasMore: false, cursor: nil)])
    let next = await h.run()
    #expect(next.outcome == .completed && next.detailsFetched == 0 && next.detailsUnchanged == 2)

    // A Refresh fetches the page again.
    h.script([agentReply(agentPage("a1"))])
    let refreshed = await h.refresh("a1")
    #expect(refreshed.outcome == .completed && refreshed.detailsFetched == 1)
    #expect(h.transport.paths.last == "/agent/a1")
}

@Test func anUnrecognizedAgentPageIsAWarningAndAChallengeStops() async throws {
    let other = [("a1", "agentic", "2026-09-23T10:00:00Z")]
    let drift = try await Harness([listReply(other, hasMore: false, cursor: nil), agentReply(Data("<html>new layout</html>".utf8))])
    let changed = await drift.run()
    #expect(changed.outcome != .blocked && changed.detailsFailed == 1 && changed.detailsFetched == 0)
    #expect(changed.warnings.contains { $0.hasPrefix("agent page HTTP 200 without a recognized transcript") })
    #expect(drift.exchanges("agent_detail").count == 1, "the page is journaled before it is judged")

    let mismatch = try await Harness([listReply(other, hasMore: false, cursor: nil), agentReply(agentPage("zz"))])
    #expect(await mismatch.run().detailsFailed == 1, "a page naming another conversation is not its snapshot")

    let gone = try await Harness([listReply(other, hasMore: false, cursor: nil), agentReply(Data(), status: 404)])
    let absent = await gone.run()
    #expect(absent.detailsAbsent == 1 && absent.detailsFetched == 0)
    gone.script([listReply(other, hasMore: false, cursor: nil)])
    #expect(await gone.run().detailsAbsent == 0, "a 404 for the same version is remembered")

    let challenged = try await Harness([
        listReply(other, hasMore: false, cursor: nil), agentReply(Data("<title>Just a moment...</title>".utf8)),
    ])
    #expect(await challenged.run().outcome == .blocked)
}
