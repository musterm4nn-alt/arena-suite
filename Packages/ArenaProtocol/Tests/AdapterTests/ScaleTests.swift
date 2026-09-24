import ApplicationActions
import ArchiveIndex
import CaptureJournal
import Foundation
import SuiteDomain
import Testing

@testable import ArenaAdapter

/// Plan v3 §13 test sizing: a synthetic history 10× the measured real one (Phase 3/4: 57
/// conversations, 110 records, ~6.8 MB of journals) must replay, search, verify and back up within
/// recorded budgets. Opt-in because it writes ~70 MB:
/// `ARENA_SUITE_SCALE_TEST=1 swift test --package-path Packages/ArenaProtocol --filter scale`
@Test(.enabled(if: ProcessInfo.processInfo.environment["ARENA_SUITE_SCALE_TEST"] != nil))
func scaleTenTimesRealHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("scale-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let accounts = [AccountID(), AccountID(), AccountID()]
    let journals = JournalStore(archiveRoot: root)
    let words = ["archive", "lane", "model", "vote", "prompt", "answer", "table", "swift", "journal", "digest"]
    var bytes = 0
    var records = 0
    // 570 conversations (10 × 57), 1 100 records (10 × 110), ~68 MB of bodies.
    for (n, account) in accounts.enumerated() {
        let writer = try await journals.writer(for: account)
        for i in 0..<190 {
            var messages: [String] = []
            for m in 0..<6 {
                let text = (0..<1_800).map { words[($0 * 7 + i + m) % words.count] }.joined(separator: " ") + " needle\(i % 50)"
                let role = m % 3 == 0 ? "user" : "assistant"
                let lane = m % 3 == 1 ? ",\"participantPosition\":\"a\"" : (m % 3 == 2 ? ",\"participantPosition\":\"b\"" : "")
                messages.append(#"{"id":"m\#(n)-\#(i)-\#(m)","role":"\#(role)","status":"success"\#(lane),"content":"\#(text)","parentMessageIds":[]}"#)
            }
            let body = Data(#"{"id":"c\#(n)-\#(i)","title":"Conversation \#(i)","mode":"battle","updatedAt":"2026-09-24 10:00:00.000000+00","messages":[\#(messages.joined(separator: ","))]}"#.utf8)
            let copies = i % 10 == 0 ? 1 : 2  // most conversations fetched twice, as after incremental syncs
            for _ in 0..<copies {
                _ = try writer.append(JournalDraft(kind: "exchange", payload: body, accountID: account.rawValue,
                    metadata: ["role": .string("detail"), "status": .integer(200), "transfer_end": .string("complete"),
                               "entry_id": .string("c\(n)-\(i)"), "entry_type": .string("evaluation")]))
                bytes += body.count
                records += 1
            }
        }
        try writer.synchronize()
        await journals.close(account)
    }
    let index = try ArchiveIndex(url: root.appendingPathComponent("index/archive.sqlite"))
    let service = ArchiveService(index: index, journals: journals, decoder: ArenaArchiveDecoder(), accounts: { accounts })
    let clock = ContinuousClock()
    func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

    let replay = try await clock.measure { for a in accounts { _ = try await service.project(a) } }
    var searchWorst = Duration.zero
    for word in ["needle7", "journal digest", "answer", "nothing-matches-this"] {
        let t = try clock.measure { _ = try service.search(word, account: nil, includeReasoningAndTools: false, limit: 200) }
        searchWorst = max(searchWorst, t)
    }
    let verifier = VerificationService(archive: service, journals: journals, accounts: { accounts },
        scratch: root.appendingPathComponent("verify-scratch"))
    var report: VerificationReport?
    let verify = await clock.measure { report = await verifier.run() }
    let out = root.appendingPathComponent("backups")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let backups = BackupService(archiveRoot: root, decoder: ArenaArchiveDecoder(), appVersion: "scale")
    let backup = try await clock.measure { _ = try await backups.create(in: out) }
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let peakMB = Double(usage.ru_maxrss) / 1_048_576

    print(String(format: "scale: %d records, %.1f MB bodies, %d conversations", records, Double(bytes) / 1e6,
        try service.conversations(account: nil).count))
    print(String(format: "scale: replay %.2f s, worst search %.3f s, verify %.2f s, backup+replay %.2f s, peak RSS %.0f MB",
        seconds(replay), seconds(searchWorst), seconds(verify), seconds(backup), peakMB))
    #expect(report?.isClean == true)
    #expect(try service.conversations(account: nil).count == 570)
    // Budgets (recorded in Docs/phase7-release-2026-09-24.md).
    #expect(seconds(replay) < 60)
    #expect(seconds(searchWorst) < 1.0)
    #expect(seconds(verify) < 90)
    #expect(seconds(backup) < 90)
    #expect(peakMB < 1_500)
}
