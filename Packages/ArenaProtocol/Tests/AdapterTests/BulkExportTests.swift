import ApplicationActions
import ArchiveIndex
import CaptureJournal
import CryptoKit
import Foundation
import SuiteDomain
import Testing

@testable import ArenaAdapter

// Bulk export of the filtered history (Docs/bulk-export-2026-10-21.md).

private func battle(_ id: String, last: String) -> Data {
    Data(#"""
    {"id":"\#(id)","title":"Title \#(id)","mode":"battle","updatedAt":"2026-09-24 10:00:00.000000+00","lastMessageIds":\#(last),
     "messages":[
      {"id":"\#(id)-u","role":"user","status":"success","content":"Question","parentMessageIds":[]},
      {"id":"\#(id)-a","role":"assistant","status":"success","participantPosition":"a","parentMessageIds":["\#(id)-u"],"content":"Answer"}]}
    """#.utf8)
}

private struct Archive {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-\(UUID().uuidString)")
    let account = AccountID()
    let journals: JournalStore
    let service: ArchiveService
    var output: URL { root.appendingPathComponent("out") }

    init() async throws {
        journals = JournalStore(archiveRoot: root)
        let account = self.account
        service = ArchiveService(
            index: try ArchiveIndex(url: root.appendingPathComponent("index/archive.sqlite")), journals: journals,
            decoder: ArenaArchiveDecoder(), accounts: { [account] })
        let writer = try await journals.writer(for: account)
        let list = #"{"entries":[{"id":"c1","type":"evaluation"},{"id":"c2","type":"evaluation"},{"id":"l1","type":"other"}],"pagination":{"hasMore":false},"partial":false,"failedSources":[]}"#
        _ = try writer.append(
            JournalDraft(
                kind: "exchange", payload: Data(list.utf8), accountID: account.rawValue,
                metadata: ["role": .string("list"), "status": .integer(200), "transfer_end": .string("complete")]))
        for (id, last) in [("c1", #"["c1-a"]"#), ("c2", "[]")] {
            _ = try writer.append(
                JournalDraft(
                    kind: "exchange", payload: battle(id, last: last), accountID: account.rawValue,
                    metadata: [
                        "role": .string("detail"), "status": .integer(200), "transfer_end": .string("complete"),
                        "entry_id": .string(id), "entry_type": .string("evaluation"),
                    ]))
        }
        try writer.synchronize()
        _ = try await service.project(account)
    }

    func targets(_ ids: [String]) -> [BulkExportService.Target] {
        ids.map { BulkExportService.Target(account: account, remoteID: $0) }
    }

    func listing() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: output.path).sorted() }
}

private let fixed = Date(timeIntervalSince1970: 1_792_560_000)

@Test func theListedConversationsAreExportedIntoOneNewFolderWithAManifest() async throws {
    let a = try await Archive()
    let result = try await BulkExportService(archive: a.service).export(
        a.targets(["c1", "c2", "l1", "missing", "c1"]), options: ExportOptions(format: .markdown), into: a.output, now: fixed)
    #expect(result.exported == 2)
    #expect(result.skipped.map(\.reason) == [.noSnapshot, .notInArchive], "duplicates are exported once")
    #expect(try a.listing() == [result.folder.lastPathComponent], "only the finished folder, nothing hidden left")
    #expect(result.folder.lastPathComponent.hasPrefix("Arena Suite export "))

    let files = try FileManager.default.contentsOfDirectory(atPath: result.folder.path).sorted()
    #expect(files.count == 3 && files.contains("manifest.json"))
    let manifest = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: result.folder.appendingPathComponent("manifest.json"))) as? [String: Any])
    #expect(manifest["schema"] as? String == "arena-suite-bulk-export/1")
    #expect(manifest["format"] as? String == "markdown" && manifest["scope"] as? String == "whole-conversation")
    #expect(manifest["conversations_requested"] as? Int == 4)
    let listed = try #require(manifest["files"] as? [[String: Any]])
    #expect(listed.map { $0["remote_id"] as? String } == ["c1", "c2"])
    let single = ExportService(archive: a.service)
    for entry in listed {
        let bytes = try Data(contentsOf: result.folder.appendingPathComponent(try #require(entry["file"] as? String)))
        #expect(entry["sha256"] as? String == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        let rendered = try await single.render(
            account: a.account, remoteID: try #require(entry["remote_id"] as? String), snapshot: nil, options: ExportOptions(format: .markdown))
        #expect(bytes == rendered.data, "the same bytes as a single export")
    }
    let skipped = try #require(manifest["skipped"] as? [[String: String]])
    #expect(skipped.map { $0["reason"] } == ["no_snapshot", "not_in_archive"])

    // A second export in the same second gets its own folder.
    let again = try await BulkExportService(archive: a.service).export(
        a.targets(["c1"]), options: ExportOptions(format: .jsonl), into: a.output, now: fixed)
    #expect(again.folder.lastPathComponent == result.folder.lastPathComponent + " 2")
}

@Test func aConversationWithoutALastAnswerIsSkippedNotFatal() async throws {
    let a = try await Archive()
    let result = try await BulkExportService(archive: a.service).export(
        a.targets(["c1", "c2"]), options: ExportOptions(format: .normalizedJSON, scope: .lastAnswer), into: a.output, now: fixed)
    #expect(result.exported == 1 && result.skipped == [.init(target: a.targets(["c2"])[0], reason: .noLastAnswer)])
}

@Test func refusedAndCancelledExportsLeaveNothing() async throws {
    let a = try await Archive()
    let service = BulkExportService(archive: a.service)
    await #expect(throws: ExportError.scopeNotAvailable) {
        _ = try await service.export(a.targets(["c1"]), options: ExportOptions(format: .rawJSON, scope: .lastAnswer), into: a.output)
    }
    #expect(!FileManager.default.fileExists(atPath: a.output.path))

    // A killed export's hidden folder is removed by the next one.
    try FileManager.default.createDirectory(
        at: a.output.appendingPathComponent(".arena-suite-bulk-old.partial"), withIntermediateDirectories: true)
    let targets = a.targets(["c1", "c2"])
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await service.export(targets, options: ExportOptions(format: .markdown), into: a.output)
    }
    await #expect(throws: ExportError.cancelled) { _ = try await task.value }
    #expect(try a.listing().isEmpty)
}
