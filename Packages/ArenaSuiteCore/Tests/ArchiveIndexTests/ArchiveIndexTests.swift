import ArchiveIndex
import Foundation
import SuiteDomain
import Testing

// Synthetic events exercise the reducer directly: snapshot history, claims, absence, FTS, unknown
// counting, idempotent replay, and reset-then-replay digest stability (plan v3 §10, Phase 4).

private func tempIndexURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("index-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("index.sqlite")
}

private func recordRef(_ account: AccountID, _ sequence: UInt64) -> RecordRef {
    RecordRef(account: account, sequence: sequence, segment: 1, offset: Int(sequence), length: 64)
}

private func facts(
    _ remoteID: String, kind: String = "evaluation", title: String? = nil, updatedAt: String? = nil
) -> ConversationFacts {
    ConversationFacts(remoteID: remoteID, kind: kind, title: title, updatedAt: updatedAt)
}

private func message(
    _ id: String, role: String? = nil, lane: String? = nil, parents: [String] = [], blocks: [ArchivedBlock] = []
) -> ArchivedMessage {
    ArchivedMessage(
        remoteID: id, role: role, status: nil, lane: lane, parentIDs: parents, modelRemoteID: nil, createdAt: nil,
        updatedAt: nil, failureReason: nil, blocks: blocks, attachments: [])
}

private func snapshot(
    _ remoteID: String, title: String? = nil, messages: [ArchivedMessage] = [], claims: [ModelClaim] = [],
    feedback: [ArchivedFeedback] = []
) -> ArchiveEvent {
    .snapshot(
        ConversationSnapshot(
            facts: facts(remoteID, title: title), messages: messages, lastMessageIDs: [], claims: claims,
            feedback: feedback))
}

@discardableResult
private func apply(
    _ index: ArchiveIndex, account: AccountID, _ sequence: UInt64, _ events: [ArchiveEvent],
    unknown: [String: Int] = [:]
) throws -> Int {
    try index.apply(
        account: account,
        records: [(recordRef(account, sequence), DecodedRecord(events: events, unknownFields: unknown))],
        through: sequence, decoderVersion: "test/1")
    return events.count
}

@Test func latestSnapshotWinsAndHistoryIsKept() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let account = AccountID()
    try apply(index, account: account, 1, [
        snapshot("c1", title: "first", messages: [message("m1", blocks: [ArchivedBlock(kind: .text, text: "alpha", pointer: "$")])])
    ])
    try apply(index, account: account, 2, [
        snapshot("c1", title: "second", messages: [message("m2", blocks: [ArchivedBlock(kind: .text, text: "beta", pointer: "$")])])
    ])

    let summaries = try index.conversations(account: account)
    #expect(summaries.count == 1)
    let summary = try #require(summaries.first)
    #expect(summary.title == "second")
    #expect(summary.snapshotCount == 2)
    #expect(summary.latestSnapshotSequence == 2)
    #expect(summary.messageCount == 1)

    let detail = try #require(try index.conversation(account: account, remoteID: "c1"))
    #expect(detail.snapshotSequences == [1, 2])
    #expect(detail.messages.map(\.remoteID) == ["m2"])

    let first = try #require(try index.conversation(account: account, remoteID: "c1", snapshot: 1))
    #expect(first.messages.map(\.remoteID) == ["m1"])
}

@Test func listingCarriesTheParsedUpdateInstantInListOrder() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let account = AccountID()
    func dated(_ id: String, _ text: String?, _ order: Int64?) -> ArchiveEvent {
        .snapshot(ConversationSnapshot(
            facts: ConversationFacts(remoteID: id, kind: "evaluation", updatedAt: text, updatedOrder: order),
            messages: [], lastMessageIDs: [], claims: [], feedback: []))
    }
    // One snapshot per journal record, as the decoder emits them.
    try apply(index, account: account, 1, [dated("old", "2026-09-01 10:00:00+00", 1_788_256_800_000_000)])
    try apply(index, account: account, 2, [dated("unparsed", "not a time", nil)])
    try apply(index, account: account, 3, [dated("new", "2026-10-01 10:00:00+00", 1_790_848_800_000_000)])
    let summaries = try index.conversations(account: account)
    // Newest first by the decoder's instant; an unparsed time sorts last and keeps its text.
    #expect(summaries.map(\.remoteID) == ["new", "old", "unparsed"])
    #expect(summaries.map(\.updatedOrder) == [1_790_848_800_000_000, 1_788_256_800_000_000, nil])
    #expect(summaries.last?.updatedAt == "not a time")
    #expect(try index.conversation(account: account, remoteID: "new")?.summary.updatedOrder == 1_790_848_800_000_000)
}

@Test func claimsCoexistWithProvenance() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let account = AccountID()
    let listed = ModelClaim(
        subject: .conversation, subjectID: "c1", role: "a", modelID: "model-a", organization: "OrgA",
        source: "history_list")
    try apply(index, account: account, 1, [.listed(facts("c1"), claims: [listed])])
    let revealed = ModelClaim(
        subject: .conversation, subjectID: "c1", role: nil, modelID: "model-r", source: "detail_revealed")
    let messageClaim = ModelClaim(
        subject: .message, subjectID: "m1", role: "a", modelID: "model-m", source: "message_model_id")
    try apply(index, account: account, 2, [
        snapshot("c1", messages: [message("m1", lane: "a")], claims: [revealed, messageClaim])
    ])

    let detail = try #require(try index.conversation(account: account, remoteID: "c1"))
    #expect(detail.claims.count == 3)
    #expect(Set(detail.claims.map(\.source)) == ["history_list", "detail_revealed", "message_model_id"])
    let listedClaim = try #require(detail.claims.first { $0.source == "history_list" })
    #expect(listedClaim.organization == "OrgA" && listedClaim.role == "a")
}

@Test func absentIsRecordedNotDeleted() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let account = AccountID()
    try apply(index, account: account, 1, [
        snapshot("c1", messages: [message("m1", blocks: [ArchivedBlock(kind: .text, text: "kept", pointer: "$")])])
    ])
    try apply(index, account: account, 2, [.absent(remoteID: "c1")])

    let summary = try #require(try index.conversations(account: account).first)
    #expect(summary.isAbsent)
    let detail = try #require(try index.conversation(account: account, remoteID: "c1"))
    #expect(detail.messages.count == 1, "absence never deletes local evidence")
}

@Test func searchFindsTextAndCanExcludeReasoning() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let account = AccountID()
    let blocks = [
        ArchivedBlock(kind: .text, text: "the quick brown fox", pointer: "$"),
        ArchivedBlock(kind: .reasoning, text: "secret reasoning", pointer: "$"),
    ]
    try apply(index, account: account, 1, [snapshot("c1", title: "Conversation", messages: [message("m1", blocks: blocks)])])

    let textHits = try index.search("quick", account: account, includeReasoningAndTools: false, limit: 10)
    #expect(textHits.count == 1)
    #expect(textHits.first?.kind == "text")
    #expect(textHits.first?.conversationID == "c1")
    #expect(textHits.first?.title == "Conversation")
    #expect(textHits.first?.snippet.contains("[quick]") == true)

    let reasoningHits = try index.search("secret", account: account, includeReasoningAndTools: false, limit: 10)
    #expect(reasoningHits.isEmpty)
    let all = try index.search("secret", account: account, includeReasoningAndTools: true, limit: 10)
    #expect(all.count == 1 && all.first?.kind == "reasoning")
}

@Test func searchReturnsEmptyForGarbagePatterns() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let account = AccountID()
    try apply(index, account: account, 1, [
        snapshot("c1", messages: [message("m1", blocks: [ArchivedBlock(kind: .text, text: "hello world", pointer: "$")])])
    ])
    let punctuation = try index.search("!!!", account: account, includeReasoningAndTools: true, limit: 10)
    let whitespace = try index.search("   ", account: account, includeReasoningAndTools: true, limit: 10)
    #expect(punctuation.isEmpty)
    #expect(whitespace.isEmpty)
}

@Test func unknownFieldCountsAccumulate() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let account = AccountID()
    try apply(index, account: account, 1, [.absent(remoteID: "c1")], unknown: ["$.messages[].newKey": 2, "$.entries[].foo": 1])
    try apply(index, account: account, 2, [.absent(remoteID: "c2")], unknown: ["$.messages[].newKey": 3])

    let counts = try index.unknownFields(account: account)
    let byPath = Dictionary(uniqueKeysWithValues: counts.map { ($0.path, $0.count) })
    #expect(byPath["$.messages[].newKey"] == 5)
    #expect(byPath["$.entries[].foo"] == 1)
}

@Test func replayedSequencesAreIgnored() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let account = AccountID()
    let events: [ArchiveEvent] = [
        snapshot("c1", messages: [message("m1", blocks: [ArchivedBlock(kind: .text, text: "once", pointer: "$")])])
    ]
    try apply(index, account: account, 1, events)
    let digest = try index.contentDigest()
    let counts = try index.counts()

    try apply(index, account: account, 1, events)  // same sequence replayed
    let replayedDigest = try index.contentDigest()
    let replayedCounts = try index.counts()
    let replayedCheckpoint = try index.checkpoint(for: account)
    #expect(replayedDigest == digest)
    #expect(replayedCounts == counts)
    #expect(replayedCheckpoint == 1)
}

@Test func resetThenReapplyProducesIdenticalDigest() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let account = AccountID()
    let events: [(UInt64, [ArchiveEvent])] = [
        (1, [.listed(facts("c1", title: "listed"), claims: [ModelClaim(subject: .conversation, subjectID: "c1", role: "a", modelID: "m-a", source: "history_list")])]),
        (2, [snapshot("c1", title: "snap", messages: [
            message("m1", lane: "a", parents: [], blocks: [ArchivedBlock(kind: .text, text: "alpha beta", pointer: "$")]),
            message("m2", lane: "b", parents: ["m1"], blocks: [
                ArchivedBlock(kind: .toolCall, toolName: "t", toolCallID: "tc", payload: "{\"a\":1}", pointer: "$")
            ]),
        ], claims: [ModelClaim(subject: .message, subjectID: "m2", role: "b", modelID: "m-b", source: "message_model_id")], feedback: [ArchivedFeedback(remoteID: "f1", value: "a", messageA: "m1", messageB: "m2")])]),
        (3, [.warning(code: "detail_unrecognized", detail: "x")]),
    ]
    for (seq, events) in events { try apply(index, account: account, seq, events, unknown: ["$.messages[].newKey": Int(seq)]) }
    let before = try index.contentDigest()

    try index.reset()
    let afterReset = try index.checkpoint(for: account)
    let afterResetConversations = try index.conversations(account: account)
    #expect(afterReset == 0)
    #expect(afterResetConversations.isEmpty)
    for (seq, events) in events { try apply(index, account: account, seq, events, unknown: ["$.messages[].newKey": Int(seq)]) }

    let after = try index.contentDigest()
    let version = try index.projectionVersion()
    #expect(after == before)
    #expect(version == "test/1")
}

@Test func databaseFileIsOwnerOnly() throws {
    let url = tempIndexURL()
    let index = try ArchiveIndex(url: url)
    let account = AccountID()
    try apply(index, account: account, 1, [.absent(remoteID: "c1")])
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o777 == 0o600)
}

@Test func schemaTablesMatchDigestCoverage() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let tables = Set(try index.tableNames())
    let counted = Set(try index.counts().keys)
    #expect(tables == counted, "every owned table must be covered by counts()/contentDigest()")
    #expect(tables.contains("search"))
    #expect(!tables.contains { $0.hasPrefix("search_") || $0.hasPrefix("sqlite_") || $0 == "grdb_migrations" })
}

@Test func warningsAreRecordedAndCounted() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let account = AccountID()
    try apply(index, account: account, 1, [
        .warning(code: "detail_unrecognized", detail: "x"),
        .warning(code: "duplicate_message_id", detail: "m1"),
    ])
    let counts = try index.counts()
    #expect(counts["warnings"] == 2)
}

// MARK: - Review follow-ups (Phase 4 review)

private func mode(_ path: String) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@Test func existingIndexPermissionsAreTightenedAndSymlinksRefused() throws {
    let url = tempIndexURL()
    _ = try ArchiveIndex(url: url)
    let directory = url.deletingLastPathComponent().path
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    _ = try ArchiveIndex(url: url)
    #expect(try mode(directory) == 0o700 && mode(url.path) == 0o600)
    for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: url.path + suffix) {
        #expect(try mode(url.path + suffix) == 0o600)
    }
    let linked = tempIndexURL()
    try FileManager.default.createDirectory(at: linked.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: linked.path, withDestinationPath: url.path)
    #expect(throws: ArchiveIndex.OpenError.symlink(linked.path)) { _ = try ArchiveIndex(url: linked) }
}

@Test func listingAfterAbsenceClearsItAndAbsenceBumpsLastSeen() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let account = AccountID()
    try apply(index, account: account, 1, [snapshot("c1")])
    try apply(index, account: account, 2, [.absent(remoteID: "c1")])
    #expect(try index.conversations(account: account).first?.isAbsent == true)
    try apply(index, account: account, 3, [.listed(facts("c1"), claims: [])])
    #expect(try index.conversations(account: account).first?.isAbsent == false)
    try apply(index, account: account, 4, [.absent(remoteID: "c1")])
    #expect(try index.conversations(account: account).first?.isAbsent == true)
}

@Test func newerSnapshotReplacesSearchRows() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let account = AccountID()
    try apply(index, account: account, 1, [snapshot("c1", messages: [message("m1", blocks: [ArchivedBlock(kind: .text, text: "alpha", pointer: "$")])])])
    try apply(index, account: account, 2, [snapshot("c1", messages: [message("m1", blocks: [ArchivedBlock(kind: .text, text: "beta", pointer: "$")])])])
    #expect(try index.search("alpha", account: nil, includeReasoningAndTools: true, limit: 10).isEmpty)
    #expect(try index.search("beta", account: nil, includeReasoningAndTools: true, limit: 10).count == 1)
}

@Test func unknownClaimSubjectsSurviveTheReadPath() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let account = AccountID()
    let future = ModelClaim(subject: .init(rawValue: "reaction"), subjectID: "r1", role: nil, modelID: "model-x", source: "future")
    try apply(index, account: account, 1, [snapshot("c1", claims: [future])])
    #expect(try index.conversation(account: account, remoteID: "c1")?.claims.contains(future) == true)
}

@Test func searchLimitIsClampedAndOrderIncludesAccount() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    let (a, b) = (AccountID(), AccountID())
    for account in [a, b] {
        try apply(index, account: account, 1, [snapshot("same", messages: [message("m", blocks: [ArchivedBlock(kind: .text, text: "gamma", pointer: "$")])])])
    }
    #expect(try index.search("gamma", account: nil, includeReasoningAndTools: true, limit: -1).isEmpty)
    let accounts = try index.conversations(account: nil).map { $0.account.rawValue.uuidString }
    #expect(accounts == accounts.sorted())
}

@Test func batchBoundariesDoNotChangeTheDigest() throws {
    let account = AccountID()
    let events = (1...250).map { i in
        [snapshot("c\(i % 7)", messages: [message("m\(i)", blocks: [ArchivedBlock(kind: .text, text: "word\(i)", pointer: "$")])])]
    }
    let single = try ArchiveIndex(url: tempIndexURL())
    try single.apply(
        account: account, records: events.enumerated().map { (recordRef(account, UInt64($0.offset + 1)), DecodedRecord(events: $0.element)) },
        through: 250, decoderVersion: "test/1")
    let split = try ArchiveIndex(url: tempIndexURL())
    for chunk in stride(from: 0, to: 250, by: 37) {
        let slice = events[chunk..<min(chunk + 37, 250)]
        try split.apply(
            account: account, records: slice.enumerated().map { (recordRef(account, UInt64(chunk + $0.offset + 1)), DecodedRecord(events: $0.element)) },
            through: UInt64(min(chunk + 37, 250)), decoderVersion: "test/1")
    }
    // A crash after a committed batch replays from the checkpoint: re-applying old records is a no-op.
    try split.apply(account: account, records: [(recordRef(account, 10), DecodedRecord(events: events[9]))], through: 10, decoderVersion: "test/1")
    #expect(try single.contentDigest() == split.contentDigest())
    #expect(try split.checkpoint(for: account) == 250)
}
