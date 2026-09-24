import ApplicationActions
import ArchiveIndex
import CaptureJournal
import Foundation
import SuiteDomain
import Testing

@testable import ArenaAdapter

// The decoder reads journal records and produces neutral events; the committed fixture proves the
// observed detail shape (N-012). The end-to-end test proves replay reproducibility (plan v3 §10).

private func fixtureDetailBody() throws -> Data {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let manifest = try Data(contentsOf: root.appendingPathComponent("Fixtures/SanitizedArena/native-detail.fixture.json"))
    let fields = try #require(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
    let unit = try #require((fields["units"] as? [[String: Any]])?.first)
    let encoded = try #require(unit["base64"] as? String)
    return try #require(Data(base64Encoded: encoded))
}

private func tempIndexURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("decoder-index-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("index.sqlite")
}

/// A real journal on disk: the fixture body is appended and read back as a `JournalRecord`.
private struct RecordHarness {
    let root: URL
    let writer: JournalWriter

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("decoder-\(UUID().uuidString)")
        writer = try JournalWriter.open(at: root, options: JournalOptions(durability: .fsync))
    }

    func record(
        payload: Data, metadata: [String: JournalValue], account: AccountID
    ) throws -> JournalRecord {
        _ = try writer.append(
            JournalDraft(kind: "exchange", payload: payload, accountID: account.rawValue, metadata: metadata))
        try writer.synchronize()
        let records = try JournalReader(root: root).readAll()
        return try #require(records.last)
    }
}

private let detailMetadata: [String: JournalValue] = [
    "role": .string("detail"), "status": .integer(200), "transfer_end": .string("complete"),
    "entry_type": .string("evaluation"),
]

@Test func decodesCommittedDetailFixture() throws {
    let account = AccountID()
    let harness = try RecordHarness()
    let record = try harness.record(payload: try fixtureDetailBody(), metadata: detailMetadata, account: account)
    let decoder = ArenaArchiveDecoder()
    #expect(decoder.version == "arena-decoder/1")

    let decoded = decoder.decode(record, account: account)
    #expect(decoded.unknownFields.isEmpty, "the fixture uses only known keys")
    let event = try #require(decoded.events.first)
    guard case .snapshot(let snapshot) = event else {
        Issue.record("expected a snapshot event")
        return
    }
    #expect(snapshot.facts.remoteID == "id-3")
    #expect(snapshot.messages.map(\.remoteID) == ["id-2", "id-4", "id-7", "id-8"])
    #expect(snapshot.messages.map(\.parentIDs) == [[], ["id-2"], ["id-4"], ["id-7"]])
    #expect(snapshot.messages.map(\.role) == ["user", "assistant", "user", "assistant"])
    #expect(snapshot.messages.allSatisfy { $0.lane == "[string]" })
    #expect(snapshot.lastMessageIDs == ["id-8"])

    let messageClaims = snapshot.claims.filter { $0.source == "message_model_id" }
    #expect(messageClaims.count == 2)
    #expect(messageClaims.allSatisfy { $0.subject == .message && $0.modelID == "id-5" })
    let revealed = snapshot.claims.filter { $0.source == "detail_revealed" }
    #expect(revealed.count == 1 && revealed.first?.subject == .conversation)

    #expect(snapshot.messages.allSatisfy { $0.blocks.count == 1 && $0.blocks[0].kind == .text })
    for message in snapshot.messages {
        for block in message.blocks {
            #expect(block.text?.contains("ja4") != true, "metadata must never become a block")
            #expect(block.payload?.contains("botScore") != true)
        }
    }

    #expect(decoder.decode(record, account: account) == decoded, "decoding is deterministic")
}

@Test func unknownMessageKeyIsCountedByPath() throws {
    let account = AccountID()
    let harness = try RecordHarness()
    let body = try fixtureDetailBody()
    var object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    var messages = try #require(object["messages"] as? [[String: Any]])
    messages[0]["newKey"] = 1
    object["messages"] = messages
    let mutated = try JSONSerialization.data(withJSONObject: object)

    let record = try harness.record(payload: mutated, metadata: detailMetadata, account: account)
    let decoded = ArenaArchiveDecoder().decode(record, account: account)
    #expect(decoded.unknownFields == ["$.messages[].newKey": 1])
}

@Test func structuredBlocksProjectAndSkipFreeFormSubtrees() throws {
    let account = AccountID()
    let harness = try RecordHarness()
    let body = Data(
        #"{"id":"c1","messages":[{"id":"m1","content":[{"type":"tool-call","toolName":"t","toolCallId":"tc","args":{"deep":{"key":1}},"providerOptions":{"encrypted":"x"}},{"type":"tool-result","toolCallId":"tc","result":{"ok":true}}]}]}"#
            .utf8)
    let record = try harness.record(payload: body, metadata: detailMetadata, account: account)
    let decoded = ArenaArchiveDecoder().decode(record, account: account)
    #expect(decoded.unknownFields.isEmpty, "args/result/providerOptions subtrees are free-form")
    guard case .snapshot(let snapshot)? = decoded.events.first else {
        Issue.record("expected a snapshot event")
        return
    }
    let blocks = try #require(snapshot.messages.first?.blocks)
    #expect(blocks.map(\.kind) == [.toolCall, .toolResult])
    #expect(blocks[0].toolName == "t" && blocks[0].toolCallID == "tc")
    #expect(blocks[0].payload == #"{"deep":{"key":1}}"#)
    #expect(blocks[1].payload == #"{"ok":true}"#)
}

@Test func unknownContentElementsBecomeOpaqueBlocks() throws {
    let account = AccountID()
    let harness = try RecordHarness()
    let body = Data(#"{"id":"c1","messages":[{"id":"m1","content":["plain",7,{"type":"weird","x":1}]}]}"#.utf8)
    let record = try harness.record(payload: body, metadata: detailMetadata, account: account)
    let decoded = ArenaArchiveDecoder().decode(record, account: account)
    #expect(decoded.unknownFields == ["$.messages[].content[].x": 1])
    guard case .snapshot(let snapshot)? = decoded.events.first else {
        Issue.record("expected a snapshot event")
        return
    }
    let blocks = try #require(snapshot.messages.first?.blocks)
    #expect(blocks.map(\.kind) == [.opaque, .opaque, .opaque], "non-dictionary elements are preserved, never dropped")
    #expect(blocks[0].payload == #""plain""#)
    #expect(blocks[1].payload == "7")
    #expect(blocks[2].payload == #"{"type":"weird","x":1}"#)
}

@Test func duplicateMessageIDIsRecordedAndDoesNotStallProjection() throws {
    let account = AccountID()
    let harness = try RecordHarness()
    let body = Data(#"{"id":"c1","messages":[{"id":"m1","content":"one"},{"id":"m1","content":"two"}]}"#.utf8)
    let record = try harness.record(payload: body, metadata: detailMetadata, account: account)
    let decoded = ArenaArchiveDecoder().decode(record, account: account)
    #expect(decoded.events.contains(.warning(code: "duplicate_message_id", detail: "$.messages[].id ×1")))
    guard case .snapshot(let snapshot)? = decoded.events.first else {
        Issue.record("expected a snapshot event")
        return
    }
    #expect(snapshot.messages.map(\.remoteID) == ["m1"])

    let index = try ArchiveIndex(url: tempIndexURL())
    let ref = RecordRef(account: account, sequence: 1, segment: 1, offset: 0, length: 0)
    try index.apply(account: account, records: [(ref, decoded)], through: 1, decoderVersion: "test/1")
    let detail = try index.conversation(account: account, remoteID: "c1")
    #expect(detail?.messages.count == 1)
}

@Test func metadataSubtreesAreNeverReportedAtAnyLevel() throws {
    let account = AccountID()
    let harness = try RecordHarness()
    let body = Data(
        #"{"id":"c1","metadata":{"botScore":1,"ja4":{"x":2}},"messages":[{"id":"m1","content":"hi","metadata":{"telemetry":true}}]}"#
            .utf8)
    let record = try harness.record(payload: body, metadata: detailMetadata, account: account)
    let decoded = ArenaArchiveDecoder().decode(record, account: account)
    #expect(decoded.unknownFields.isEmpty, "metadata is excluded, not reported as unknown")
    guard case .snapshot(let snapshot)? = decoded.events.first else {
        Issue.record("expected a snapshot event")
        return
    }
    #expect(snapshot.messages.first?.blocks.map(\.text) == ["hi"])
}

@Test func decodesListPageAndCountsUnknownEntryKeys() throws {
    let account = AccountID()
    let harness = try RecordHarness()
    let body = Data(
        #"{"entries":[{"id":"e1","type":"evaluation","title":"t","updatedAt":"2026-09-24 10:00:00.123456+00","modelAId":"mA","modelBId":"mB","modelAOrganization":"OA","newKey":1}],"pagination":{"hasMore":false,"cursor":null,"limit":20},"partial":false,"failedSources":[]}"#
            .utf8)
    let record = try harness.record(
        payload: body,
        metadata: ["role": .string("list"), "status": .integer(200), "transfer_end": .string("complete")],
        account: account)
    let decoded = ArenaArchiveDecoder().decode(record, account: account)
    #expect(decoded.unknownFields == ["$.entries[].newKey": 1])
    guard case .listed(let facts, let claims)? = decoded.events.first else {
        Issue.record("expected a listed event")
        return
    }
    #expect(facts.remoteID == "e1")
    #expect(facts.updatedOrder != nil, "observed PostgreSQL timestamp parses to microseconds")
    #expect(claims.count == 2)
    #expect(Set(claims.map(\.role)) == ["a", "b"])
    #expect(claims.allSatisfy { $0.source == "history_list" })
}

@Test func detailNotFoundBecomesAbsent() throws {
    let account = AccountID()
    let harness = try RecordHarness()
    let record = try harness.record(
        payload: Data(),
        metadata: [
            "role": .string("detail"), "status": .integer(404), "transfer_end": .string("complete"),
            "entry_id": .string("e1"),
        ],
        account: account)
    #expect(ArenaArchiveDecoder().decode(record, account: account).events == [.absent(remoteID: "e1")])
}

@Test func identityExchangeIsIgnored() throws {
    let account = AccountID()
    let harness = try RecordHarness()
    let record = try harness.record(
        payload: Data("{}".utf8),
        metadata: ["role": .string("identity"), "status": .integer(200), "transfer_end": .string("complete")],
        account: account)
    #expect(ArenaArchiveDecoder().decode(record, account: account).events.isEmpty)
}

@Test func detailWithoutStringIDWarnsWithoutSnapshot() throws {
    let account = AccountID()
    let harness = try RecordHarness()
    let record = try harness.record(
        payload: Data(#"{"messages":[]}"#.utf8), metadata: detailMetadata, account: account)
    let decoded = ArenaArchiveDecoder().decode(record, account: account)
    #expect(decoded.events == [.warning(code: "detail_unrecognized", detail: "$.id ×1")])
}

@Test func endToEndProjectionRebuildIsIdentical() async throws {
    let account = AccountID()
    let archiveRoot = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString)")
    let journals = JournalStore(archiveRoot: archiveRoot)
    let writer = try await journals.writer(for: account)

    let listBody = Data(
        #"{"entries":[{"id":"id-3","type":"evaluation","title":"t","updatedAt":"2026-09-24 10:00:00.123456+00","modelAId":"mA","modelBId":"mB"}],"pagination":{"hasMore":false,"cursor":null,"limit":20},"partial":false,"failedSources":[]}"#
            .utf8)
    let detailBody = try fixtureDetailBody()
    var changed = try #require(JSONSerialization.jsonObject(with: detailBody) as? [String: Any])
    changed["title"] = "changed title"
    let changedBody = try JSONSerialization.data(withJSONObject: changed)

    func append(_ body: Data, role: String, extra: [String: JournalValue]) throws {
        var metadata: [String: JournalValue] = ["role": .string(role), "transfer_end": .string("complete")]
        metadata.merge(extra) { _, new in new }
        _ = try writer.append(
            JournalDraft(kind: "exchange", payload: body, accountID: account.rawValue, metadata: metadata))
        try writer.synchronize()
    }
    try append(listBody, role: "list", extra: ["status": .integer(200)])
    try append(detailBody, role: "detail", extra: ["status": .integer(200), "entry_id": .string("id-3"), "entry_type": .string("evaluation")])
    try append(changedBody, role: "detail", extra: ["status": .integer(200), "entry_id": .string("id-3"), "entry_type": .string("evaluation")])
    try writer.close()

    let index = try ArchiveIndex(url: tempIndexURL())
    let service = ArchiveService(
        index: index, journals: journals, decoder: ArenaArchiveDecoder(), accounts: { [account] })
    let applied = try await service.project(account)
    let checkpoint = try service.checkpoint(for: account)
    #expect(applied == 3)
    #expect(checkpoint == 3)

    let maybeDetail = try service.conversation(account: account, remoteID: "id-3")
    let detail = try #require(maybeDetail)
    #expect(detail.snapshotSequences == [2, 3])
    #expect(detail.summary.title == "changed title")
    #expect(detail.messages.count == 4)
    let summaries = try service.conversations(account: account)
    #expect(summaries.count == 1)

    let before = try service.contentDigest()
    try await service.rebuild()
    let after = try service.contentDigest()
    let rebuiltCheckpoint = try service.checkpoint(for: account)
    #expect(after == before, "delete-and-replay reproduces identical content")
    #expect(rebuiltCheckpoint == 3)
}

/// Same decoding, different declared version, to exercise the rebuild-on-mismatch path.
private struct VersionedDecoder: ArchiveDecoding {
    let version: String
    func decode(_ record: JournalRecord, account: AccountID) -> DecodedRecord {
        ArenaArchiveDecoder().decode(record, account: account)
    }
}

@Test func projectionVersionMismatchRebuilds() async throws {
    let account = AccountID()
    let archiveRoot = FileManager.default.temporaryDirectory.appendingPathComponent("version-\(UUID().uuidString)")
    let journals = JournalStore(archiveRoot: archiveRoot)
    let writer = try await journals.writer(for: account)
    let listBody = Data(
        #"{"entries":[{"id":"id-3","type":"evaluation","updatedAt":"2026-09-24 10:00:00.123456+00"}],"pagination":{"hasMore":false,"cursor":null,"limit":20},"partial":false,"failedSources":[]}"#
            .utf8)
    func append(_ body: Data, role: String, extra: [String: JournalValue]) throws {
        var metadata: [String: JournalValue] = ["role": .string(role), "transfer_end": .string("complete")]
        metadata.merge(extra) { _, new in new }
        _ = try writer.append(
            JournalDraft(kind: "exchange", payload: body, accountID: account.rawValue, metadata: metadata))
        try writer.synchronize()
    }
    try append(listBody, role: "list", extra: ["status": .integer(200)])
    try append(
        try fixtureDetailBody(), role: "detail",
        extra: ["status": .integer(200), "entry_id": .string("id-3"), "entry_type": .string("evaluation")])
    try writer.close()

    let index = try ArchiveIndex(url: tempIndexURL())
    let first = ArchiveService(
        index: index, journals: journals, decoder: VersionedDecoder(version: "v1"), accounts: { [account] })
    let firstApplied = try await first.project(account)
    let firstVersion = try index.projectionVersion()
    #expect(firstApplied == 2)
    #expect(firstVersion == "v1")

    let second = ArchiveService(
        index: index, journals: journals, decoder: VersionedDecoder(version: "v2"), accounts: { [account] })
    let secondApplied = try await second.project(account)
    let secondVersion = try index.projectionVersion()
    #expect(secondApplied == 2, "a version mismatch rebuilds and replays the whole journal")
    #expect(secondVersion == "v2")
    let summaries = try second.conversations(account: account)
    #expect(summaries.count == 1)
}

// MARK: - Review follow-ups (Phase 4 review)

private func warnings(_ decoded: DecodedRecord) -> [String] {
    decoded.events.compactMap { if case .warning(let code, let detail) = $0 { "\(code) \(detail)" } else { nil } }
}

private let listMetadata: [String: JournalValue] = [
    "role": .string("list"), "status": .integer(200), "transfer_end": .string("complete"),
]

@Test func unprojectableListEntriesAreWarnedNotDropped() throws {
    let body = Data(#"{"entries":[{"id":"c1","type":"evaluation"},{"type":"evaluation"},{"id":123},"junk"],"pagination":{"hasMore":false,"cursor":null,"limit":20},"partial":false,"failedSources":[]}"#.utf8)
    let decoded = ArenaArchiveDecoder().decode(try RecordHarness().record(payload: body, metadata: listMetadata, account: AccountID()), account: AccountID())
    #expect(decoded.events.filter { if case .listed = $0 { true } else { false } }.count == 1)
    #expect(warnings(decoded).sorted() == ["element_skipped $.entries[] ×1", "element_skipped $.entries[].id ×2", "type_mismatch $.entries[].id ×1"])
}

@Test func typeMismatchesAreWarnedAndKeptWherePossible() throws {
    let body = Data(#"{"id":"c1","lastMessageIds":["m1",7],"messages":[{"id":"m1","parentMessageIds":"m0","reasoning":{"steps":["a"]},"sources":{"x":1},"experimental_attachments":{},"title":1},{"no":"id"},5],"revealedModels":{"id":"x"},"pairwiseFeedbacks":[{"value":"a"}],"pointwiseFeedbacks":[]}"#.utf8)
    let decoded = ArenaArchiveDecoder().decode(try RecordHarness().record(payload: body, metadata: detailMetadata, account: AccountID()), account: AccountID())
    guard case .snapshot(let snapshot) = decoded.events.first else { Issue.record("no snapshot"); return }
    #expect(snapshot.lastMessageIDs == ["m1"])
    let message = try #require(snapshot.messages.first)
    #expect(snapshot.messages.count == 1)
    #expect(message.parentIDs.isEmpty)
    #expect(message.blocks.map(\.kind) == [.opaque, .sources], "structured reasoning and sources are kept")
    #expect(Set(warnings(decoded)) == [
        "type_mismatch $.lastMessageIds[] ×1", "type_mismatch $.messages[].parentMessageIds ×1",
        "type_mismatch $.messages[].reasoning ×1", "type_mismatch $.messages[].sources ×1",
        "type_mismatch $.messages[].experimental_attachments ×1", "element_skipped $.messages[].id ×1",
        "element_skipped $.messages[] ×1", "type_mismatch $.revealedModels ×1",
        "element_skipped $.pairwiseFeedbacks[].id ×1",
    ])
    #expect(decoded.unknownFields["$.messages[].title"] == 1)
}

@Test func encryptedReasoningNeverReachesOpaqueBlocks() throws {
    let body = Data(#"{"id":"c1","messages":[{"id":"m1","content":[{"type":"new-kind","text":"hi","providerOptions":{"openai":{"reasoningEncryptedContent":"SECRET"}}}]}]}"#.utf8)
    let decoded = ArenaArchiveDecoder().decode(try RecordHarness().record(payload: body, metadata: detailMetadata, account: AccountID()), account: AccountID())
    guard case .snapshot(let snapshot) = decoded.events.first else { Issue.record("no snapshot"); return }
    let payload = try #require(snapshot.messages.first?.blocks.first?.payload)
    #expect(!payload.contains("SECRET") && payload.contains("new-kind"))
}

@Test func duplicateKeysAndLargeNumbersArePinnedBehavior() throws {
    // Declared boundary (observed on macOS 27): JSONSerialization keeps the FIRST of duplicate keys;
    // the journal keeps the exact bytes.
    let body = Data(#"{"id":"first","id":"c2","messages":[{"id":"m1","content":[{"type":"tool-call","toolName":"t","args":{"n":9007199254740993}}]}]}"#.utf8)
    let harness = try RecordHarness()
    let record = try harness.record(payload: body, metadata: detailMetadata, account: AccountID())
    guard case .snapshot(let snapshot) = ArenaArchiveDecoder().decode(record, account: AccountID()).events.first else {
        Issue.record("no snapshot"); return
    }
    #expect(snapshot.facts.remoteID == "first")
    #expect(record.payload == body)
}
