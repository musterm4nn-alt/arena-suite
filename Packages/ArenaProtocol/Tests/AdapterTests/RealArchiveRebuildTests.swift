import ApplicationActions
import ArchiveIndex
import Foundation
import SuiteDomain
import Testing

@testable import ArenaAdapter

/// Phase 4 definition of done on a real archive. Read-only on the journals; the index is temporary.
/// `ARENA_SUITE_REAL_ARCHIVE=~/Library/Application\ Support/Arena\ Suite/Archive swift test --package-path Packages/ArenaProtocol --filter realArchive`
/// Prints counts and unknown field paths only — never content.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ARENA_SUITE_REAL_ARCHIVE"] != nil))
func realArchiveRebuildIsIdentical() async throws {
    let archive = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARENA_SUITE_REAL_ARCHIVE"]!)
    let accounts = try FileManager.default.contentsOfDirectory(atPath: archive.appendingPathComponent("accounts").path)
        .compactMap { UUID(uuidString: $0) }.map { AccountID(rawValue: $0) }.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    #expect(!accounts.isEmpty)
    let indexURL = FileManager.default.temporaryDirectory.appendingPathComponent("real-index-\(UUID().uuidString)/archive.sqlite")
    let index = try ArchiveIndex(url: indexURL)
    let service = ArchiveService(
        index: index, journals: JournalStore(archiveRoot: archive), decoder: ArenaArchiveDecoder(), accounts: { accounts })
    var applied = 0
    for account in accounts { applied += try await service.project(account) }
    let first = try index.contentDigest()
    let counts = try index.counts()
    #expect(try await service.project(accounts[0]) == 0, "incremental replay applies nothing new")
    try await service.rebuild(accounts: accounts)
    let second = try index.contentDigest()
    #expect(first == second, "rebuild must reproduce identical content")
    #expect(try index.counts() == counts)
    let unknown = try index.unknownFields(account: nil)
    print("real archive: records applied \(applied); rows \(counts.sorted { $0.key < $1.key }); digest stable \(first == second)")
    print("unknown field paths: \(unknown.map { "\($0.path)×\($0.count)" })")
    let conversations = try index.conversations(account: nil)
    print("conversations \(conversations.count), with snapshot \(conversations.filter { $0.latestSnapshotSequence != nil }.count)")
    #expect(try index.search("the", account: nil, includeReasoningAndTools: false, limit: 5).count > 0)
    // Telemetry under `metadata` (plan §12) and encrypted reasoning never reach the index.
    for marker in ["recaptchaV3Score", "arenaLionScoreCurrent", "hashedClientIp", "reasoningEncryptedContent", "cf_client_asn"] {
        #expect(try index.search(marker, account: nil, includeReasoningAndTools: true, limit: 1).isEmpty, "\(marker)")
    }
}

/// Phase 6 on a real archive: every archived conversation, all formats, twice, into a temp folder.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ARENA_SUITE_REAL_ARCHIVE"] != nil))
func realArchiveExportsAreDeterministicAndTelemetryFree() async throws {
    let archive = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARENA_SUITE_REAL_ARCHIVE"]!)
    let accounts = try FileManager.default.contentsOfDirectory(atPath: archive.appendingPathComponent("accounts").path)
        .compactMap { UUID(uuidString: $0) }.map { AccountID(rawValue: $0) }
    let index = try ArchiveIndex(url: FileManager.default.temporaryDirectory.appendingPathComponent("real-export-\(UUID().uuidString)/archive.sqlite"))
    let service = ArchiveService(index: index, journals: JournalStore(archiveRoot: archive), decoder: ArenaArchiveDecoder(), accounts: { accounts })
    for account in accounts { _ = try await service.project(account) }
    let exports = ExportService(archive: service)
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("real-exports-\(UUID().uuidString)")
    let markers = ["recaptchaV3Score", "arenaLionScoreCurrent", "hashedClientIp", "cf_client_asn", "ja4_browser_ratio_1h"]
    var files = 0
    for conversation in try service.conversations(account: nil) where conversation.latestSnapshotSequence != nil {
        for format in ExportFormat.allCases {
            let options = ExportOptions(format: format)
            let first = try await exports.export(account: conversation.account, remoteID: conversation.remoteID, snapshot: nil, options: options, to: out)
            let second = try await exports.export(account: conversation.account, remoteID: conversation.remoteID, snapshot: nil, options: options, to: out)
            #expect(first.sha256 == second.sha256, "deterministic \(format)")
            let data = try Data(contentsOf: first.url)
            var text = String(decoding: data, as: UTF8.self)
            if format == .rawJSON, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let record = (root["records"] as? [[String: Any]])?.first, let encoded = record["payload_base64"] as? String,
                let payload = Data(base64Encoded: encoded)
            {
                text += String(decoding: payload, as: UTF8.self)
            }
            if format != .markdown { #expect((try? JSONSerialization.jsonObject(with: data)) != nil, "valid JSON \(format)") }
            for marker in markers { #expect(!text.contains(marker), "\(marker) in \(format)") }
            files += 2
        }
    }
    print("real archive exports: \(files) files, all deterministic and telemetry-free")
    try? FileManager.default.removeItem(at: out)
}

/// Phase 7 on a real archive: verify the live index against the journals, then back up, check,
/// restore into a temporary root and confirm the restored archive is equal. Read-only on the real
/// archive; the backup and restore live in temporary folders. Prints counts and digests only.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ARENA_SUITE_REAL_ARCHIVE"] != nil))
func realArchiveVerifiesAndBacksUpToAnEqualArchive() async throws {
    let archive = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARENA_SUITE_REAL_ARCHIVE"]!)
    let journals = JournalStore(archiveRoot: archive)
    let accounts = journals.accountsOnDisk()
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("real-backup-\(UUID().uuidString)")
    let live = ArchiveService(
        index: try ArchiveIndex(url: archive.appendingPathComponent("index/archive.sqlite")), journals: journals,
        decoder: ArenaArchiveDecoder(), accounts: { accounts })
    let verification = await VerificationService(
        archive: live, journals: journals, accounts: { accounts }, scratch: temp.appendingPathComponent("verify")
    ).run()
    print("verify: clean \(verification.isClean); records \(verification.journals.map(\.records)); index matches \(verification.index?.matches == true)")
    #expect(verification.isClean)

    let backups = BackupService(archiveRoot: archive, decoder: ArenaArchiveDecoder(), appVersion: "test")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    let backup = try await backups.create(in: temp)
    let check = try await backups.check(backup)
    let restoredRoot = temp.appendingPathComponent("restored")
    let restored = try await BackupService(archiveRoot: restoredRoot, decoder: ArenaArchiveDecoder(), appVersion: "test")
        .restore(from: backup)
    let replayOfSource = try await ArchiveService.replay(
        journals: journals, accounts: accounts, decoder: ArenaArchiveDecoder(), scratch: temp.appendingPathComponent("replay"))
    print("backup: accounts \(check.accounts), records \(check.records); restored digest equal \(restored.replayDigest == replayOfSource.digest)")
    #expect(restored.replayDigest == replayOfSource.digest)
    for account in accounts {
        let a = try FileManager.default.contentsOfDirectory(atPath: journals.root(for: account).appendingPathComponent("segments").path)
        for name in a where name.hasSuffix(".asj") || name.hasSuffix(".seal.json") {
            let original = try Data(contentsOf: journals.root(for: account).appendingPathComponent("segments/\(name)"))
            let copy = try Data(contentsOf: JournalStore(archiveRoot: restoredRoot).root(for: account).appendingPathComponent("segments/\(name)"))
            #expect(original == copy, "segment bytes equal")
        }
    }
    try FileManager.default.removeItem(at: temp)
}
