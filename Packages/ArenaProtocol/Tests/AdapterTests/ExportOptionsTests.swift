import ApplicationActions
import ArchiveIndex
import CaptureJournal
import CryptoKit
import Foundation
import SQLite3
import SuiteDomain
import Testing

@testable import ArenaAdapter

// Export options (Docs/export-options-2026-10-20.md): JSONL, the "last answer" scope, and the
// rendering the app copies to the clipboard.

/// Two battle turns, one vote each. `last` is the recorded `lastMessageIds` value, verbatim;
/// `secondParent` is what the second turn's answer A replies to.
private func twoTurns(last: String = #"["a2","b2"]"#, secondParent: String = "u2", secondQuestion: String = "Second question") -> Data {
    Data(#"""
    {"id":"c1","title":"Two turns","mode":"battle","updatedAt":"2026-09-24 10:00:00.000000+00",
     "lastMessageIds":\#(last),
     "messages":[
      {"id":"u1","role":"user","status":"success","content":"First question","parentMessageIds":[]},
      {"id":"a1","role":"assistant","status":"success","participantPosition":"a","modelId":"m-a","parentMessageIds":["u1"],"content":"First A"},
      {"id":"b1","role":"assistant","status":"success","participantPosition":"b","modelId":"m-b","parentMessageIds":["u1"],"content":"First B"},
      {"id":"u2","role":"user","status":"success","content":"\#(secondQuestion)\nwith a second line","parentMessageIds":["a1"]},
      {"id":"a2","role":"assistant","status":"success","participantPosition":"a","modelId":"m-a","parentMessageIds":["\#(secondParent)"],"content":"Second A"},
      {"id":"b2","role":"assistant","status":"success","participantPosition":"b","modelId":"m-b","parentMessageIds":["u2"],"content":"Second B","metadata":{"botScore":0.9}}
     ],
     "revealedModels":[{"id":"m-a","displayName":"Model A"},{"id":"m-b","displayName":"Model B"}],
     "pairwiseFeedbacks":[
      {"id":"f1","messageAId":"a1","messageBId":"b1","modelAId":"m-a","modelBId":"m-b","value":"model_a"},
      {"id":"f2","messageAId":"a2","messageBId":"b2","modelAId":"m-a","modelBId":"m-b","value":"tie"}]}
    """#.utf8)
}

private struct Harness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-options-\(UUID().uuidString)")
    let account = AccountID()
    let journals: JournalStore
    let service: ArchiveService
    let exports: ExportService
    var output: URL { root.appendingPathComponent("out") }

    init(_ body: Data = twoTurns()) async throws {
        journals = JournalStore(archiveRoot: root)
        let account = self.account
        service = ArchiveService(
            index: try ArchiveIndex(url: root.appendingPathComponent("index/archive.sqlite")), journals: journals,
            decoder: ArenaArchiveDecoder(), accounts: { [account] })
        exports = ExportService(archive: service)
        try await append(body)
    }

    func append(_ body: Data) async throws {
        let writer = try await journals.writer(for: account)
        _ = try writer.append(
            JournalDraft(
                kind: "exchange", payload: body, accountID: account.rawValue,
                metadata: [
                    "role": .string("detail"), "status": .integer(200), "transfer_end": .string("complete"),
                    "entry_id": .string("c1"), "entry_type": .string("evaluation"),
                ]))
        try writer.synchronize()
        _ = try await service.project(account)
    }

    func render(_ format: ExportFormat, _ scope: ExportScope = .wholeConversation, snapshot: UInt64? = nil) async throws -> Data {
        try await exports.render(account: account, remoteID: "c1", snapshot: snapshot, options: ExportOptions(format: format, scope: scope)).data
    }

    /// Every format that has a last answer refuses it, in rendering and in export, and the
    /// destination folder (created first) stays empty.
    func expectRefusedWithoutWriting(_ refusal: ExportError) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for format in ExportFormat.allCases where format.supportsLastAnswer {
            await #expect(throws: refusal) { _ = try await render(format, .lastAnswer) }
            await #expect(throws: refusal) {
                _ = try await exports.export(
                    account: account, remoteID: "c1", snapshot: nil, options: ExportOptions(format: format, scope: .lastAnswer), to: output)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty, "nothing written")
    }

    func detail(snapshot: UInt64? = nil) throws -> ConversationDetail {
        try #require(try service.conversation(account: account, remoteID: "c1", snapshot: snapshot))
    }

    /// Sets every stored last-message list, as a damaged index would hold it (nil = NULL).
    func damageLastMessageIDs(_ value: String?) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        try #require(sqlite3_open(root.appendingPathComponent("index/archive.sqlite").path, &db) == SQLITE_OK)
        let sql = "UPDATE snapshots SET last_message_ids = " + (value.map { "'\($0)'" } ?? "NULL")
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
}

private func object(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func theDetailCarriesArenasLastMessagesPerSnapshot() async throws {
    let h = try await Harness()
    #expect(try h.detail().lastMessageIDs == ["a2", "b2"])
    try await h.append(twoTurns(last: #"["u2"]"#))
    #expect(try h.detail().lastMessageIDs == ["u2"], "the latest snapshot's list")
    #expect(try h.detail(snapshot: 1).lastMessageIDs == ["a2", "b2"], "a frozen snapshot keeps its own")
}

@Test func theLastAnswerHoldsTheLastMessagesTheirPromptAndOnlyTheirVotes() async throws {
    let h = try await Harness()
    let answer = try ExportService.lastAnswer(of: try h.detail())
    let part = answer.detail
    #expect(part.messages.map(\.remoteID) == ["u2", "a2", "b2"])
    #expect(answer.ordinals == [3, 4, 5] && answer.parentsNotInSnapshot.isEmpty)
    #expect(part.feedback.map(\.remoteID) == ["f2"], "the first turn's vote is not part of it")
    #expect(!part.claims.contains { [.message, .feedback].contains($0.subject) && ["u1", "a1", "b1", "f1"].contains($0.subjectID) })
    #expect(part.claims.contains { $0.source == "detail_revealed" }, "names revealed for the conversation stay")

    let normalized = try object(try await h.render(.normalizedJSON, .lastAnswer))
    #expect((normalized["messages"] as? [[String: Any]])?.map { $0["id"] as? String } == ["u2", "a2", "b2"])
    #expect((normalized["messages"] as? [[String: Any]])?.map { $0["ordinal"] as? Int } == [3, 4, 5], "positions in the whole snapshot")
    let selection = try #require(normalized["selection"] as? [String: Any])
    #expect(selection["parents_not_in_snapshot"] as? [String] == [] && selection["ordinal_basis"] != nil)
    #expect(selection["scope"] as? String == "last-answer" && selection["last_message_ids"] as? [String] == ["a2", "b2"])
    #expect((selection["basis"] as? String)?.contains("lastMessageIds") == true)
    #expect(try object(try await h.render(.normalizedJSON))["selection"] == nil, "a whole-conversation export has no selection")

    let markdown = String(decoding: try await h.render(.markdown, .lastAnswer), as: UTF8.self)
    #expect(markdown.contains("Second A") && markdown.contains("Second B") && markdown.contains("Second question"))
    #expect(!markdown.contains("First A") && !markdown.contains("First question") && !markdown.contains("model\\_a"))
    #expect(!markdown.contains("## Turn"), "an excerpt does not number its turns")
    #expect(markdown.contains("Last answer, with its prompt") && !markdown.contains("botScore"))
}

@Test func aPromptArenaListsAsLastIsItsOwnLastAnswer() async throws {
    // Arena lists the prompt itself as last when it got no answer (seen for flagged prompts).
    let h = try await Harness(twoTurns(last: #"["u2"]"#))
    let part = try ExportService.lastAnswer(of: try h.detail()).detail
    #expect(part.messages.map(\.remoteID) == ["u2"] && part.feedback.isEmpty)
}

@Test func aPromptMissingFromTheSnapshotIsNamedNotClaimed() async throws {
    let h = try await Harness(twoTurns(last: #"["a2"]"#, secondParent: "u9"))
    let answer = try ExportService.lastAnswer(of: try h.detail())
    #expect(answer.detail.messages.map(\.remoteID) == ["a2"] && answer.parentsNotInSnapshot == ["u9"])
    let selection = try #require(try object(try await h.render(.normalizedJSON, .lastAnswer))["selection"] as? [String: Any])
    #expect(selection["parents_not_in_snapshot"] as? [String] == ["u9"])
    let markdown = String(decoding: try await h.render(.markdown, .lastAnswer), as: UTF8.self)
    #expect(markdown.contains("Not in this snapshot, so not included: u9, which a last message replies to."))
    let complete = String(decoding: try await Harness().render(.markdown, .lastAnswer), as: UTF8.self)
    #expect(!complete.contains("Not in this snapshot"))
}

@Test func aParentWithoutAStatedRoleIsNamedNotGuessed() async throws {
    let body = String(decoding: twoTurns(), as: UTF8.self).replacingOccurrences(of: #"{"id":"u2","role":"user","#, with: #"{"id":"u2","#)
    let h = try await Harness(Data(body.utf8))
    let answer = try ExportService.lastAnswer(of: try h.detail())
    #expect(answer.detail.messages.map(\.remoteID) == ["a2", "b2"])
    #expect(answer.parentsWithUnknownRole == ["u2"] && answer.parentsNotInSnapshot.isEmpty)
    let header = try #require(try await h.render(.jsonl, .lastAnswer).split(separator: 0x0A).first)
    let selection = try #require(try object(Data(header))["selection"] as? [String: Any])
    #expect(selection["parents_with_unknown_role"] as? [String] == ["u2"])
    let markdown = String(decoding: try await h.render(.markdown, .lastAnswer), as: UTF8.self)
    #expect(markdown.contains("Role not stated, so not included: u2, which a last message replies to."))
    let complete = try await Harness()
    #expect(try ExportService.lastAnswer(of: try complete.detail()).parentsWithUnknownRole.isEmpty)
}

@Test func claimsOfUnknownSubjectsAreKeptNotGuessed() async throws {
    let h = try await Harness()
    let detail = try h.detail()
    let unknown = ModelClaim(subject: .init(rawValue: "attachment"), subjectID: "a1", role: nil, modelID: "m-x", source: "newer_decoder")
    let widened = ConversationDetail(
        summary: detail.summary, snapshotSequences: detail.snapshotSequences, messages: detail.messages,
        claims: detail.claims + [unknown], feedback: detail.feedback, snapshotSequence: detail.snapshotSequence,
        isFrozen: detail.isFrozen, lastMessageIDs: detail.lastMessageIDs)
    #expect(try ExportService.lastAnswer(of: widened).detail.claims.contains(unknown), "its subject may not be a1 the message")
}

@Test func aFrozenSnapshotsLastAnswerUsesItsOwnList() async throws {
    let h = try await Harness()
    try await h.append(twoTurns(last: #"["u2"]"#))
    func ids(_ data: Data) throws -> [String?] { try (object(data)["messages"] as? [[String: Any]] ?? []).map { $0["id"] as? String } }
    #expect(try ids(try await h.render(.normalizedJSON, .lastAnswer, snapshot: 1)) == ["u2", "a2", "b2"])
    #expect(try ids(try await h.render(.normalizedJSON, .lastAnswer)) == ["u2"])
}

@Test func noLastAnswerIsGuessed() async throws {
    let cases: [(String, ExportError)] = [
        ("[]", .noLastAnswer), (#"["gone"]"#, .lastMessageNotInSnapshot), (#"["a2","gone"]"#, .lastMessageNotInSnapshot),
    ]
    for (last, refusal) in cases {
        let h = try await Harness(twoTurns(last: last))
        try await h.expectRefusedWithoutWriting(refusal)
        _ = try await h.render(.markdown)
    }
    let h = try await Harness()
    await #expect(throws: ExportError.scopeNotAvailable) { _ = try await h.render(.rawJSON, .lastAnswer) }
    await #expect(throws: ExportError.scopeNotAvailable) {
        _ = try await h.exports.export(
            account: h.account, remoteID: "c1", snapshot: nil, options: ExportOptions(format: .rawJSON, scope: .lastAnswer), to: h.output)
    }
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: h.output.path)) ?? []).isEmpty, "nothing written")
}

@Test func anUnreadableStoredListIsNotAnEmptyOne() async throws {
    for damage in ["not-json", nil] {
        let h = try await Harness()
        try h.damageLastMessageIDs(damage)
        #expect(try h.detail().lastMessageIDs == nil)
        try await h.expectRefusedWithoutWriting(.lastMessagesUnreadable)
        _ = try await h.render(.jsonl)
    }
}

@Test func jsonlHasOneCanonicalRecordPerLineMatchingNormalizedJSON() async throws {
    let h = try await Harness()
    for scope in ExportScope.allCases {
        let data = try await h.render(.jsonl, scope)
        #expect(data.last == 0x0A)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        let records = try lines.map { try object(Data($0.utf8)) }
        let normalized = try object(try await h.render(.normalizedJSON, scope))

        let header = try #require(records.first), footer = try #require(records.last)
        #expect(header["type"] as? String == "header" && header["schema"] as? String == "arena-suite.jsonl/1")
        for key in ["scope", "conversation", "excluded"] {
            #expect((header[key] as? NSObject) == (normalized[key] as? NSObject), "header \(key) is Normalized JSON's")
        }
        #expect((header["selection"] as? NSObject) == (normalized["selection"] as? NSObject))

        func body(_ type: String) -> [NSObject] { records.filter { $0["type"] as? String == type }.compactMap { $0[type] as? NSObject } }
        #expect(body("message") == (normalized["messages"] as? [NSObject]), "messages in snapshot order")
        #expect(body("model_claim") == (normalized["model_claims"] as? [NSObject]))
        #expect(body("feedback") == (normalized["feedback"] as? [NSObject]))
        let counts = try #require(footer["counts"] as? [String: Int])
        #expect(footer["type"] as? String == "footer")
        #expect(counts == ["messages": body("message").count, "model_claims": body("model_claim").count, "feedback": body("feedback").count])
        #expect(records.count == 2 + counts.values.reduce(0, +), "nothing else")
        #expect(!String(decoding: data, as: UTF8.self).contains("botScore"))
    }
    let lastAnswer = try await h.render(.jsonl, .lastAnswer), whole = try await h.render(.jsonl)
    #expect(lastAnswer != whole)
}

@Test func jsonlEscapesCharactersThatSomeReadersTreatAsLineEnds() async throws {
    let question = "Next\u{85}line\u{2028}separator\u{2029}paragraph \u{2027}\u{202F}é"
    let h = try await Harness(twoTurns(secondQuestion: question))
    let data = try await h.render(.jsonl)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("\u{85}") && !text.contains("\u{2028}") && !text.contains("\u{2029}"))
    #expect(text.contains(#"Next\u0085line\u2028separator\u2029paragraph \#u{2027}\#u{202F}é"#), "neighbours stay raw")
    let lines = text.components(separatedBy: .newlines).dropLast()
    #expect(lines.count == text.split(separator: "\n").count, "no line ends inside a record")
    let prompt = try lines.compactMap { try object(Data($0.utf8))["message"] as? [String: Any] }.first { $0["id"] as? String == "u2" }
    let block = try #require((prompt?["blocks"] as? [[String: Any]])?.first)
    #expect(block["text"] as? String == question + "\nwith a second line", "the parsed value is unchanged")
}

/// Whole-conversation output is what it was before the last-answer scope and JSONL: SHA-256 of the
/// rendering with the record digest and account ID masked, taken from 6da813d on this fixture.
/// The output names the decoder; the digests were taken under `arena-decoder/2`, so the current
/// version is put back to that name (Docs/attachments-2026-10-20.md changed only the version).
/// Update only for a deliberate format change (and say so in its milestone).
@Test func wholeConversationExportsAreUnchanged() async throws {
    let h = try await Harness()
    let evidence = try #require(try await h.service.rawEvidence(account: h.account, snapshotSequence: 1))
    let golden: [ExportFormat: String] = [
        .normalizedJSON: "ae6e90f0906231377f5be3ac22edefcda2314c18566c2b85854fe2ada7f60279",
        .markdown: "72df1b2738c901ee4c9992d4edc61beda5d64443ceaa25bf515757aadfe707d7",
    ]
    #expect(evidence.decoderVersion == "arena-decoder/4")
    for (format, expected) in golden {
        let text = String(decoding: try await h.render(format), as: UTF8.self)
            .replacingOccurrences(of: evidence.digest, with: "<record digest>")
            .replacingOccurrences(of: h.account.rawValue.uuidString, with: "<account>")
            .replacingOccurrences(of: evidence.decoderVersion, with: "arena-decoder/2")
        #expect(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() == expected, "\(format)")
    }
}

@Test(arguments: [ExportFormat.markdown, .normalizedJSON, .jsonl])
func aLastAnswerFileIsNamedForItAndDeterministic(_ format: ExportFormat) async throws {
    let h = try await Harness()
    let options = ExportOptions(format: format, scope: .lastAnswer)
    let first = try await h.exports.export(account: h.account, remoteID: "c1", snapshot: nil, options: options, to: h.output)
    let second = try await h.exports.export(account: h.account, remoteID: "c1", snapshot: nil, options: options, to: h.output)
    #expect(first.url.lastPathComponent == "Two turns c1 r1 last answer.\(format.fileExtension)")
    #expect(first.sha256 == second.sha256 && first.url != second.url)
    let rendered = try await h.render(format, .lastAnswer)
    #expect(try Data(contentsOf: first.url) == rendered)
}
