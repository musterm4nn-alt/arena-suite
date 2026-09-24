import ApplicationActions
import ArchiveIndex
import CaptureJournal
import Foundation
import SuiteDomain
import Testing

@testable import ArenaAdapter

// Phase 7: verify job, backup/restore, diagnostics (plan v3 §13).

private func detail(_ id: String, _ text: String) -> Data {
    Data(#"""
    {"id":"\#(id)","title":"Secret title \#(id)","mode":"battle","updatedAt":"2026-09-24 10:00:00.000000+00",
     "messages":[
      {"id":"\#(id)-u","role":"user","status":"success","content":"\#(text)","parentMessageIds":[],"metadata":{"hashedClientIp":"ip-secret"}},
      {"id":"\#(id)-a","role":"assistant","status":"success","participantPosition":"a","modelId":"m-a","parentMessageIds":["\#(id)-u"],"content":"Reply \#(text)","newTopLevelThing":1}
     ]}
    """#.utf8)
}

private struct Archive {
    let root: URL
    let accounts: [AccountID]
    let journals: JournalStore
    let service: ArchiveService

    /// Two accounts; the first uses tiny segments so it has sealed segments.
    init(conversations: Int = 6) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("maint-\(UUID().uuidString)", isDirectory: true)
        accounts = [AccountID(), AccountID()]
        journals = JournalStore(archiveRoot: root)
        for (n, account) in accounts.enumerated() {
            let options = JournalOptions(maximumSegmentBytes: n == 0 ? 2048 : 64 << 20, durability: .fsync)
            let writer = try JournalWriter.open(at: journals.root(for: account), options: options)
            for i in 0..<conversations {
                _ = try writer.append(
                    JournalDraft(
                        kind: "exchange", payload: detail("conv\(n)x\(i)", "Hello private words \(i)"),
                        accountID: account.rawValue,
                        metadata: [
                            "role": .string("detail"), "status": .integer(200), "transfer_end": .string("complete"),
                            "entry_id": .string("conv\(n)x\(i)"), "entry_type": .string("evaluation"),
                        ]))
            }
            try writer.close()
        }
        try AccountRegistryStore(url: root.appendingPathComponent("accounts/registry.json")).save(
            accounts.enumerated().map { n, id in
                AccountRecord(
                    id: id, displayName: "Person \(n)", principal: PrincipalIdentity(namespace: "arena", claims: ["id": "user-\(n)"]),
                    createdAt: Date(timeIntervalSince1970: 0), credentialGeneration: 1)
            })
        let index = try ArchiveIndex(url: root.appendingPathComponent("index/archive.sqlite"))
        let known = accounts
        service = ArchiveService(index: index, journals: journals, decoder: ArenaArchiveDecoder(), accounts: { known })
        for account in accounts { _ = try await service.project(account) }
    }

    var backups: BackupService { BackupService(archiveRoot: root, decoder: ArenaArchiveDecoder(), appVersion: "test") }

    func segmentFiles(_ account: AccountID) throws -> [String: Data] {
        let segments = journals.root(for: account).appendingPathComponent("segments")
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: segments.path) {
            files[name] = try Data(contentsOf: segments.appendingPathComponent(name))
        }
        return files
    }
}

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
}

@Test func backupRestoresToAnEqualArchive() async throws {
    let source = try await Archive()
    #expect(try source.segmentFiles(source.accounts[0]).keys.contains { $0.hasSuffix(".seal.json") }, "has sealed segments")
    let out = scratch()
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let backup = try await source.backups.create(in: out)
    #expect(backup.lastPathComponent.hasPrefix("Arena Suite Backup "))
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == [backup.lastPathComponent], "no staging left")
    let mode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
    #expect(mode == 0o700)

    let check = try await source.backups.check(backup)
    #expect(check.accounts == 2)

    // Restore into a fresh archive root.
    let targetRoot = scratch()
    let target = BackupService(archiveRoot: targetRoot, decoder: ArenaArchiveDecoder(), appVersion: "test")
    let restored = try await target.restore(from: backup)
    #expect(restored.replayDigest == check.replayDigest)
    let targetJournals = JournalStore(archiveRoot: targetRoot)
    #expect(targetJournals.accountsOnDisk() == source.journals.accountsOnDisk())
    for account in source.accounts {
        #expect(try Data(contentsOf: targetJournals.root(for: account).appendingPathComponent("segments/000001.asj"))
            == Data(contentsOf: source.journals.root(for: account).appendingPathComponent("segments/000001.asj")))
        #expect(JournalVerifierIsClean(targetJournals.root(for: account)))
    }
    #expect(try Data(contentsOf: targetRoot.appendingPathComponent("accounts/registry.json"))
        == Data(contentsOf: source.root.appendingPathComponent("accounts/registry.json")))
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: targetRoot.path).contains { $0.hasPrefix(".restore") }))

    // The index built from the restored journals equals the source's live index.
    let index = try ArchiveIndex(url: targetRoot.appendingPathComponent("index/archive.sqlite"))
    let accounts = source.accounts
    let rebuilt = ArchiveService(index: index, journals: targetJournals, decoder: ArenaArchiveDecoder(), accounts: { accounts })
    try await rebuilt.rebuild()
    #expect(try rebuilt.contentDigest() == source.service.contentDigest())
    #expect(try rebuilt.contentDigest() == check.replayDigest)

    // A restored journal opens for writing and keeps appending after the restored records.
    let writer = try JournalWriter.open(at: targetJournals.root(for: source.accounts[1]))
    let receipt = try writer.append(JournalDraft(kind: "local.control", payload: Data(), accountID: source.accounts[1].rawValue))
    #expect(receipt.sequence == 7)
    try writer.close()
}

private func JournalVerifierIsClean(_ root: URL) -> Bool {
    (try? JournalVerifier.verify(root: root).isClean) ?? false
}

@Test func backupCopiesOnlyCompleteRecordsOfTheActiveSegment() async throws {
    let source = try await Archive(conversations: 2)
    let active = source.journals.root(for: source.accounts[1]).appendingPathComponent("segments/000001.asj")
    let before = try Data(contentsOf: active)
    // Half-written record at the end, as during a concurrent append.
    let handle = try FileHandle(forWritingTo: active)
    try handle.seekToEnd()
    try handle.write(contentsOf: before.prefix(40))
    try handle.close()
    let out = scratch()
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let backup = try await source.backups.create(in: out)
    let copied = backup.appendingPathComponent("accounts/\(source.accounts[1].rawValue.uuidString)/journal/segments/000001.asj")
    #expect(try Data(contentsOf: copied) == before)
    #expect(try Data(contentsOf: active).count == before.count + 40, "source untouched")
    _ = try await source.backups.check(backup)
}

@Test func backupCheckRejectsChangedMissingAndExtraFiles() async throws {
    let source = try await Archive(conversations: 3)
    let out = scratch()
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let backup = try await source.backups.create(in: out)
    let segment = backup.appendingPathComponent("accounts/\(source.accounts[1].rawValue.uuidString)/journal/segments/000001.asj")
    let original = try Data(contentsOf: segment)

    var changed = original
    changed[changed.count - 5] ^= 0xFF
    try changed.write(to: segment)
    await #expect(throws: BackupError.self) { try await source.backups.check(backup) }

    try original.write(to: segment)
    try Data("x".utf8).write(to: backup.appendingPathComponent("accounts/extra.txt"))
    await #expect(throws: BackupError.fileMismatch("unexpected accounts/extra.txt")) { try await source.backups.check(backup) }
    try FileManager.default.removeItem(at: backup.appendingPathComponent("accounts/extra.txt"))

    try Data().write(to: backup.appendingPathComponent(".DS_Store"))
    _ = try await source.backups.check(backup)  // Finder metadata is tolerated

    try FileManager.default.removeItem(at: segment)
    await #expect(throws: BackupError.self) { try await source.backups.check(backup) }
    await #expect(throws: BackupError.notABackup) { try await source.backups.check(out) }
}

@Test func restoreRefusesAnArchiveThatAlreadyHasAccounts() async throws {
    let source = try await Archive(conversations: 1)
    let out = scratch()
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let backup = try await source.backups.create(in: out)
    let before = try source.segmentFiles(source.accounts[1])
    await #expect(throws: BackupError.targetNotEmpty) { try await source.backups.restore(from: backup) }
    #expect(try source.segmentFiles(source.accounts[1]) == before)
}

@Test func cancelledBackupLeavesNothing() async throws {
    let source = try await Archive(conversations: 2)
    let out = scratch()
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let task = Task { try await source.backups.create(in: out) }
    task.cancel()
    await #expect(throws: BackupError.cancelled) { try await task.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
}

@Test func verifyJobFindsACleanArchiveAndReportsDamage() async throws {
    let source = try await Archive(conversations: 6)
    let verifier = VerificationService(
        archive: source.service, journals: source.journals, accounts: { source.accounts }, scratch: scratch())
    let clean = await verifier.run()
    #expect(clean.isClean)
    #expect(clean.journals.map(\.records) == [6, 6])
    #expect(clean.index?.matches == true)

    // Records appended after the last projection do not count as a mismatch.
    let writer = try JournalWriter.open(at: source.journals.root(for: source.accounts[1]))
    _ = try writer.append(JournalDraft(kind: "local.control", payload: Data(), accountID: source.accounts[1].rawValue))
    try writer.close()
    #expect(await verifier.run().isClean)

    // A flipped byte inside a sealed segment is reported, not repaired.
    let sealed = source.journals.root(for: source.accounts[0]).appendingPathComponent("segments/000001.asj")
    var bytes = try Data(contentsOf: sealed)
    bytes[bytes.count / 2] ^= 0x01
    try bytes.write(to: sealed)
    let damaged = await verifier.run()
    #expect(!damaged.isClean)
    #expect(damaged.journals[0].issues.contains { $0.contains("segment 1") })
    #expect(try Data(contentsOf: sealed) == bytes, "verify never repairs")
}

@Test func verifyJobDetectsAnIndexThatDiffersFromTheJournal() async throws {
    let source = try await Archive(conversations: 2)
    // Same live index, but compared with copies of the journals where one lost its last record.
    let other = scratch()
    for account in source.accounts {
        let copy = other.appendingPathComponent("accounts/\(account.rawValue.uuidString)/journal")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        _ = try JournalCopy.copy(from: source.journals.root(for: account), to: copy)
    }
    let shortened = JournalStore(archiveRoot: other).root(for: source.accounts[1])
    let last = try #require(try JournalReader(root: shortened).readAll().last)
    let segment = shortened.appendingPathComponent("segments/000001.asj")
    try Data(contentsOf: segment).prefix(last.location.offset).write(to: segment)
    let accounts = source.accounts
    let mismatched = ArchiveService(
        index: try ArchiveIndex(url: source.root.appendingPathComponent("index/archive.sqlite")),
        journals: JournalStore(archiveRoot: other), decoder: ArenaArchiveDecoder(), accounts: { accounts })
    #expect(try await !mismatched.checkAgainstJournal(scratch: scratch()).matches)
}

@Test func diagnosticsHoldNoContentOrIdentifiers() async throws {
    let source = try await Archive(conversations: 3)
    let verification = await VerificationService(
        archive: source.service, journals: source.journals, accounts: { source.accounts }, scratch: scratch()
    ).run()
    let diagnostics = DiagnosticsService(
        archive: source.service, journals: source.journals,
        environment: .init(appVersion: "1.0 (1)", osVersion: "macOS test"))
    let data = diagnostics.report(
        accounts: [(source.accounts[0], .signedIn), (source.accounts[1], .needsSignIn)], verification: verification)
    let text = String(decoding: data, as: UTF8.self)
    for secret in ["Hello", "private", "Secret", "Reply", "conv0x", "Person", "user-0", "ip-secret", "hashedClientIp", "m-a",
        source.root.path, NSUserName()] + source.accounts.map(\.rawValue.uuidString)
    {
        #expect(!text.contains(secret), "diagnostics leak: \(secret)")
    }
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["format"] as? String == DiagnosticsService.format)
    let accounts = try #require(json["accounts"] as? [[String: Any]])
    #expect(accounts.map { $0["account"] as? String } == ["account-1", "account-2"])
    #expect(((accounts[0]["journal"] as? [String: Any])?["records"] as? Int) == 3)
    #expect(text.contains("newTopLevelThing"), "unknown field paths are reported")
    #expect((json["verification"] as? [String: Any])?["clean"] as? Bool == true)

    let folder = scratch()
    let url = try diagnostics.write(data, to: folder)
    #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) == 0o600)
    #expect(try diagnostics.write(data, to: folder) != url, "never overwrites")
}

@Test func diagnosticTokensRejectFreeText() {
    #expect(DiagnosticsService.token("complete") == "complete")
    #expect(DiagnosticsService.token("Hello world") == "(other)")
    #expect(DiagnosticsService.keyPath("$.messages[].newField") == "$.messages[].newField")
    #expect(DiagnosticsService.keyPath("$.messages[].a b") == "(other)")
}

@Test func restoreRechecksTheRegistryAndOnlyTargetsAnEmptyArchive() async throws {
    let source = try await Archive(conversations: 1)
    let out = scratch()
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let backup = try await source.backups.create(in: out)

    // A registry changed in the backup is refused, and nothing is installed.
    let registry = backup.appendingPathComponent("accounts/registry.json")
    let original = try Data(contentsOf: registry)
    try Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "Person 0", with: "Person X").utf8).write(to: registry)
    let targetRoot = scratch()
    let target = BackupService(archiveRoot: targetRoot, decoder: ArenaArchiveDecoder(), appVersion: "test")
    await #expect(throws: BackupError.fileMismatch("changed accounts/registry.json")) { try await target.restore(from: backup) }
    #expect(!FileManager.default.fileExists(atPath: targetRoot.appendingPathComponent("accounts").path))
    try original.write(to: registry)

    // An archive whose accounts were all removed (empty registry) is a valid target; a leftover
    // staging folder from an interrupted restore is swept.
    try AccountRegistryStore(url: targetRoot.appendingPathComponent("accounts/registry.json")).save([])
    try FileManager.default.createDirectory(at: targetRoot.appendingPathComponent(".restore-stale"), withIntermediateDirectories: true)
    #expect(target.canRestore)
    _ = try await target.restore(from: backup)
    #expect(try Data(contentsOf: targetRoot.appendingPathComponent("accounts/registry.json")) == original)
    #expect(!(try FileManager.default.contentsOfDirectory(atPath: targetRoot.path).contains { $0.hasPrefix(".restore") }))

    // Journals kept from removed accounts block a restore even with an empty registry.
    let kept = scratch()
    let keptJournal = JournalStore(archiveRoot: kept).root(for: AccountID())
    try FileManager.default.createDirectory(at: keptJournal, withIntermediateDirectories: true)
    let keptTarget = BackupService(archiveRoot: kept, decoder: ArenaArchiveDecoder(), appVersion: "test")
    #expect(!keptTarget.canRestore)
    await #expect(throws: BackupError.targetNotEmpty) { try await keptTarget.restore(from: backup) }
}

@Test func journalCopyRejectsASealWithWrongSequences() async throws {
    let source = try await Archive(conversations: 6)
    let segments = source.journals.root(for: source.accounts[0]).appendingPathComponent("segments")
    let seal = segments.appendingPathComponent("000002.seal.json")
    var manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: seal)) as? [String: Any])
    manifest["first_sequence"] = "1"
    try JSONSerialization.data(withJSONObject: manifest).write(to: seal)
    #expect(throws: JournalError.self) { _ = try JournalCopy.copy(from: source.journals.root(for: source.accounts[0]), to: scratch()) }
}

@Test func diagnosticsWritesNeverOverwriteEvenConcurrently() async throws {
    let source = try await Archive(conversations: 1)
    let diagnostics = DiagnosticsService(
        archive: source.service, journals: source.journals, environment: .init(appVersion: "t", osVersion: "t"))
    let folder = scratch()
    let now = Date(timeIntervalSince1970: 1_000_000)
    let urls = try await withThrowingTaskGroup(of: URL.self) { group in
        for n in 0..<8 { group.addTask { try diagnostics.write(Data("\(n)".utf8), to: folder, now: now) } }
        return try await group.reduce(into: [URL]()) { $0.append($1) }
    }
    #expect(Set(urls).count == 8)
    let contents = try Set(urls.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) })
    #expect(contents.count == 8, "no file was replaced")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { $0.hasSuffix(".json") }, "no temp files left")
}
