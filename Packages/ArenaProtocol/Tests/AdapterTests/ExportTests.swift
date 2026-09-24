import ApplicationActions
import ArchiveIndex
import CaptureJournal
import Foundation
import SuiteDomain
import Testing

@testable import ArenaAdapter

private let detailBody = Data(#"""
{"id":"c1","title":"Export \"test\"/1","mode":"battle","updatedAt":"2026-09-24 10:00:00.000000+00",
 "lastMessageIds":["a1","b1"],
 "messages":[
  {"id":"u1","role":"user","status":"success","content":"Hello","parentMessageIds":[],"metadata":{"botScore":0.9,"hashedClientIp":"abc"}},
  {"id":"a1","role":"assistant","status":"success","participantPosition":"a","modelId":"m-a","parentMessageIds":["u1"],
   "content":[{"type":"reasoning","text":"think"},{"type":"text","text":"Answer with ``` fence"},{"type":"tool-call","toolName":"run","toolCallId":"t1","args":{"cmd":"ls"}}],
   "metadata":{"recaptchaV3Score":1}},
  {"id":"b1","role":"assistant","status":"success","participantPosition":"b","modelId":"m-b","parentMessageIds":["u1"],"content":"Other"}
 ],
 "revealedModels":[{"id":"m-a","displayName":"Model A"},{"id":"m-b","displayName":"Model B"}],
 "pairwiseFeedbacks":[{"id":"f1","messageAId":"a1","messageBId":"b1","modelAId":"m-a","modelBId":"m-b","value":"a"}]}
"""#.utf8)

private struct ExportHarness {
    let archiveRoot: URL
    let account = AccountID()
    let service: ArchiveService
    let exports: ExportService
    let output: URL

    init() async throws {
        archiveRoot = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        let journals = JournalStore(archiveRoot: archiveRoot)
        let writer = try await journals.writer(for: account)
        _ = try writer.append(
            JournalDraft(
                kind: "exchange", payload: detailBody, accountID: account.rawValue,
                metadata: [
                    "role": .string("detail"), "status": .integer(200), "transfer_end": .string("complete"),
                    "entry_id": .string("c1"), "entry_type": .string("evaluation"),
                ]))
        try writer.synchronize()
        let index = try ArchiveIndex(url: archiveRoot.appendingPathComponent("index/archive.sqlite"))
        let account = self.account
        service = ArchiveService(index: index, journals: journals, decoder: ArenaArchiveDecoder(), accounts: { [account] })
        _ = try await service.project(account)
        exports = ExportService(archive: service)
        output = archiveRoot.appendingPathComponent("out")
    }

    func export(_ format: ExportFormat, exact: Bool = false) async throws -> ExportResult {
        try await exports.export(
            account: account, remoteID: "c1", snapshot: nil, options: ExportOptions(format: format, includeExactRawBodies: exact),
            to: output)
    }
}

@Test(arguments: ExportFormat.allCases)
func exportsAreDeterministicAndNeverOverwrite(_ format: ExportFormat) async throws {
    let h = try await ExportHarness()
    let first = try await h.export(format)
    let second = try await h.export(format)
    #expect(first.sha256 == second.sha256)
    #expect(try Data(contentsOf: first.url) == Data(contentsOf: second.url))
    #expect(first.url != second.url)
    #expect(second.url.lastPathComponent.hasSuffix(" 2.\(format.fileExtension)"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: h.output.path).filter { $0.hasPrefix(".") }.isEmpty, "no temp files left")
}

@Test func rawExportMasksTelemetryByDefaultAndDeclaresIt() async throws {
    let h = try await ExportHarness()
    let data = try Data(contentsOf: try await h.export(.rawJSON).url)
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(root["redaction_policy"] as? String == ExportService.redactionPolicy)
    let record = try #require((root["records"] as? [[String: Any]])?.first)
    #expect(record["byte_fidelity"] as? String == "transformed")
    #expect((record["transformations"] as? [Any])?.count == 1)
    #expect(record["original_payload_sha256"] as? String != record["exported_payload_sha256"] as? String)
    let encoded = try #require(record["payload_base64"] as? String)
    let payload = String(decoding: try #require(Data(base64Encoded: encoded)), as: UTF8.self)
    for secret in ["botScore", "hashedClientIp", "recaptchaV3Score"] { #expect(!payload.contains(secret)) }
    #expect(payload.contains("[omitted: telemetry]") && payload.contains("Answer with"))
}

@Test func rawExportCanKeepExactBodiesOnRequest() async throws {
    let h = try await ExportHarness()
    let data = try Data(contentsOf: try await h.export(.rawJSON, exact: true).url)
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let record = try #require((root["records"] as? [[String: Any]])?.first)
    let encoded = try #require(record["payload_base64"] as? String)
    #expect(Data(base64Encoded: encoded) == detailBody)
    #expect(record["byte_fidelity"] as? String == "exact_at_declared_observation_layer")
    #expect((root["sensitivity"] as? [String])?.isEmpty == false)
}

@Test func normalizedExportCarriesProvenanceAndNoTelemetry() async throws {
    let h = try await ExportHarness()
    let text = String(decoding: try Data(contentsOf: try await h.export(.normalizedJSON).url), as: UTF8.self)
    #expect(!text.contains("botScore") && !text.contains("recaptcha"))
    let root = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect((root["messages"] as? [Any])?.count == 3)
    #expect((root["model_claims"] as? [[String: Any]])?.allSatisfy { $0["verified_identity"] as? Bool == false } == true)
    #expect((root["scope"] as? [String: Any])?["snapshot_sequence"] as? String == "1")
}

@Test func markdownKeepsLanesVotesAndCannotBeBrokenByFences() async throws {
    let h = try await ExportHarness()
    let text = String(decoding: try Data(contentsOf: try await h.export(.markdown).url), as: UTF8.self)
    #expect(text.contains("### Lane A · Model A") && text.contains("### Lane B · Model B"))
    #expect(text.contains("_Vote: a_"))
    #expect(text.contains("Answer with ``` fence"))
    #expect(text.contains("journal record 1"))
    #expect(!text.contains("botScore"))
    let fenced = ExportService.fenced("a ```` b", language: "json")
    #expect(fenced.hasPrefix("`````json\n") && fenced.hasSuffix("\n`````\n\n"))
}

@Test func failedWriteLeavesNoFile() throws {
    let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("blocker-\(UUID().uuidString)")
    try Data("file".utf8).write(to: blocker)  // a file where the directory should be
    #expect(throws: (any Error).self) {
        _ = try ExportService.write(Data("x".utf8), baseName: "n", extension: "md", into: blocker.appendingPathComponent("sub"))
    }
    #expect(try Data(contentsOf: blocker) == Data("file".utf8))
}
