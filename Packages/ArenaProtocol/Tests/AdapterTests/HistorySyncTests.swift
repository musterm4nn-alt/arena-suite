import ApplicationActions
import CaptureJournal
import Foundation
import FoundationTransport
import SuiteDomain
import Testing

@testable import ArenaAdapter

// MARK: - Fixtures

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
private let page2 = [("e3", "evaluation", "2026-09-22T10:00:00Z"), ("a1", "agentic", "2026-09-21T10:00:00Z")]

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
            account: record.context, principal: principalA, journal: journal, journalRoot: root, options: options,
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
    #expect(manifest.entryTypes == ["evaluation": 3, "agentic": 1])
    #expect(manifest.detailsFetched == 3 && manifest.listOnlyEntries == 1 && manifest.detailsFailed == 0)
    #expect(manifest.listingEnd == "hasMore=false")

    let paths = h.transport.paths
    #expect(paths.filter { $0 == "/api/evaluation/a1" }.isEmpty, "agentic entries have no observed detail route")
    let queries = h.transport.requests.compactMap { $0.url?.query }
    #expect(queries == ["limit=20&includeArchived=true", "limit=20&includeArchived=true&cursor=cur%2Bsor%2F1"])

    let kinds = h.records.map(\.envelope.kind)
    #expect(kinds == ["job.started", "session.verified", "exchange", "exchange", "exchange", "exchange", "exchange", "job.finished"])
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

@Test func identityFailureAtStartWritesNothing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)")
    let journal = try JournalWriter.open(at: root, options: JournalOptions(durability: .fsync))
    let vault = MemoryVault()
    let account = AccountID()
    try vault.save(StoredSession(principal: principalA, cookies: Data("c".utf8)), account: account)
    let factory = TransportFactory([FakeTransport([me(), HTTPExchange(status: 401, body: Data())])])
    let provider = ArenaAccountSessions(vault: vault, makeTransport: { factory.make() })
    _ = await provider.restore(account: account, expected: principalA)
    let record = AccountRecord(id: account, displayName: "A", principal: principalA, createdAt: Date(), credentialGeneration: 1)
    let manifest = await ArenaHistorySync(sessions: provider, sleep: { _ in }).sync(
        account: record.context, principal: principalA, journal: journal, journalRoot: root, options: .testing(),
        progress: { _ in })
    #expect(manifest.outcome == .needsSignIn)
    #expect(try JournalReader(root: root).readAll().isEmpty)
}

@Test func cancellationStopsAndIsRecorded() async throws {
    let h = try await Harness([listReply(page1, hasMore: false, cursor: nil), detailReply("e1"), detailReply("e2")])
    await h.sleeps.setHook(at: 1) { throw CancellationError() }
    let manifest = await h.run()
    #expect(manifest.outcome == .cancelled)
    #expect(h.records.last?.envelope.metadata["outcome"] == .string("cancelled"))
}

@Test func newestFirstCheckRequiresOrderedTimestamps() {
    #expect(SyncJob.isNewestFirst([ListEntry(id: "a", type: "evaluation", updatedAt: "2"), ListEntry(id: "b", type: "evaluation", updatedAt: "1")]))
    #expect(!SyncJob.isNewestFirst([ListEntry(id: "a", type: "evaluation", updatedAt: "1"), ListEntry(id: "b", type: "evaluation", updatedAt: "2")]))
    #expect(!SyncJob.isNewestFirst([ListEntry(id: "a", type: "agentic", updatedAt: nil)]))
}
