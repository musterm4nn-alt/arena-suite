import ApplicationActions
import ArchiveIndex
import ArenaAdapter
import CaptureJournal
import Foundation
import SuiteDomain
import Testing

// Local vote notes end to end (Docs/vote-notes-2026-10-20.md): recorded as `local.control`, decoded by
// the app, projected, kept through rebuild, backup and restore, and gated by maintenance.

private func battle(_ id: String) -> Data {
    Data(#"""
    {"id":"\#(id)","title":"Private title","mode":"battle","updatedAt":"2026-09-24 10:00:00.000000+00",
     "messages":[
      {"id":"\#(id)-u","role":"user","status":"success","content":"Private question","parentMessageIds":[]},
      {"id":"\#(id)-a","role":"assistant","status":"success","participantPosition":"a","modelId":"m-a","parentMessageIds":["\#(id)-u"],"content":"Private answer A"},
      {"id":"\#(id)-b","role":"assistant","status":"success","participantPosition":"b","modelId":"m-b","parentMessageIds":["\#(id)-u"],"content":"Private answer B"}
     ],
     "pairwiseFeedbacks":[{"id":"\#(id)-f","messageAId":"\#(id)-a","messageBId":"\#(id)-b","modelAId":"m-a","modelBId":"m-b","value":"model_a"}]}
    """#.utf8)
}

private actor NoSessions: AccountSessionProviding {
    func signIn(account: AccountID, email: String, password: String) async throws -> PrincipalIdentity {
        PrincipalIdentity(namespace: "arena", claims: ["id": email])
    }
    func persist(account: AccountID, principal: PrincipalIdentity) async throws {}
    func restore(account: AccountID, expected: PrincipalIdentity) async -> SessionCheck { .verified }
    func verify(account: AccountID, expected: PrincipalIdentity) async -> SessionCheck { .verified }
    func discard(account: AccountID) async {}
    func forget(account: AccountID) async throws {}
}

/// Appends `job.started`, waits until released, then appends `job.finished`: a sync that is running.
private actor HeldSync: HistorySyncing {
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var waiting = false

    func release() {
        gate?.resume()
        gate = nil
    }

    nonisolated func sync(
        account: AccountContext, principal: PrincipalIdentity, journal: JournalWriter, journalRoot: URL,
        options: SyncOptions, progress: @escaping @Sendable (SyncProgress) -> Void
    ) async -> SyncManifest {
        let job = UUID()
        _ = try? journal.append(JournalDraft(kind: JournalKind.jobStarted, accountID: account.accountID.rawValue, jobID: job))
        await hold()
        _ = try? journal.append(JournalDraft(kind: JournalKind.jobFinished, accountID: account.accountID.rawValue, jobID: job))
        _ = try? journal.synchronize()
        return SyncManifest(jobID: job, accountID: account.accountID, outcome: .completed)
    }

    nonisolated func refresh(
        account: AccountContext, principal: PrincipalIdentity, journal: JournalWriter, journalRoot: URL,
        conversationID: String, options: SyncOptions
    ) async -> SyncManifest {
        await noteRefresh(conversationID)
        return SyncManifest(jobID: UUID(), accountID: account.accountID, outcome: .completed)
    }

    private(set) var refreshed: [String] = []
    private func noteRefresh(_ id: String) { refreshed.append(id) }

    private func hold() async {
        waiting = true
        await withCheckedContinuation { gate = $0 }
        waiting = false
    }
}

/// Two accounts in the registry, each with conversation "c1" (one vote); the second also has "d1".
/// `removed` has "c1" in its kept journal and in the index, but is not in the registry.
private struct NoteArchive {
    let root: URL
    let accounts: [AccountID]
    let removed: AccountID
    let journals: JournalStore
    let index: ArchiveIndex
    let archive: ArchiveService
    let accountService: AccountService
    let sync: HistorySyncService
    let notes: VoteNoteService
    let engine: HeldSync

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString)", isDirectory: true)
        accounts = [AccountID(), AccountID()]
        removed = AccountID()
        journals = JournalStore(archiveRoot: root)
        for account in accounts + [removed] {
            let writer = try JournalWriter.open(at: journals.root(for: account))
            for conversation in account == accounts[1] ? ["c1", "d1"] : ["c1"] {
                _ = try writer.append(
                    JournalDraft(
                        kind: "exchange", payload: battle(conversation), accountID: account.rawValue,
                        metadata: [
                            "role": .string("detail"), "status": .integer(200), "transfer_end": .string("complete"),
                            "entry_id": .string(conversation), "entry_type": .string("evaluation"),
                        ]))
            }
            try writer.close()
        }
        let registry = AccountRegistryStore(url: root.appendingPathComponent("accounts/registry.json"))
        try registry.save(
            accounts.enumerated().map { n, id in
                AccountRecord(
                    id: id, displayName: "Person \(n)", principal: PrincipalIdentity(namespace: "arena", claims: ["id": "u\(n)"]),
                    createdAt: Date(timeIntervalSince1970: 0), credentialGeneration: 1)
            })
        accountService = AccountService(registry: registry, sessions: NoSessions())
        try await accountService.load()
        let known = accounts + [removed]
        index = try ArchiveIndex(url: root.appendingPathComponent("index/archive.sqlite"))
        archive = ArchiveService(index: index, journals: journals, decoder: ArenaArchiveDecoder(), accounts: { known })
        for account in known { _ = try await archive.project(account) }
        engine = HeldSync()
        sync = HistorySyncService(accounts: accountService, journals: journals, engine: engine)
        notes = VoteNoteService(sync: sync, archive: archive)
    }

    func vote(_ account: AccountID, _ conversation: String = "c1") throws -> ArchivedFeedback {
        try #require(try archive.conversation(account: account, remoteID: conversation)?.feedback.first)
    }

    /// The snapshot the transcript of `conversation` shows.
    func snapshot(_ account: AccountID, _ conversation: String = "c1") throws -> UInt64 {
        try #require(try archive.conversation(account: account, remoteID: conversation)?.snapshotSequence)
    }

    func localRecords(_ account: AccountID) throws -> [JournalRecord] {
        try JournalReader(root: journals.root(for: account)).readAll().filter { $0.envelope.kind == LocalControl.kind }
    }
}

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("scratch-\(UUID().uuidString)", isDirectory: true)
}

@Test func aNoteIsRecordedExactlyThenProjected() async throws {
    let a = try await NoteArchive()
    let account = a.accounts[0]
    let vote = try a.vote(account)
    #expect(vote.messageA == "c1-a" && vote.messageB == "c1-b")

    try await a.notes.set(.preferB, beside: vote, account: account, conversation: "c1", snapshot: try a.snapshot(account))

    let records = try a.localRecords(account)
    let record = try #require(records.first)
    #expect(records.count == 1)
    #expect(record.envelope.accountID == account.rawValue && record.envelope.jobID == nil)
    #expect(record.envelope.payloadRepresentation == "local_control_json")
    #expect(record.envelope.transformations.isEmpty && record.envelope.metadata.isEmpty)
    // IDs and the choice only: no text, title or model.
    #expect(
        String(decoding: record.payload, as: UTF8.self)
            == #"{"choice":"prefer_b","conversation_id":"c1","format":"arena-suite.local-control","message_a":"c1-a","message_b":"c1-b","origin":"ui","type":"vote_note","version":1,"vote_id":"c1-f"}"#)
    // Flushed before `set` returned.
    let writer = try await a.journals.writer(for: account)
    #expect(writer.synchronizedSequence == record.envelope.sequence)

    let notes = try a.archive.voteNotes(account: account, conversationID: "c1")
    #expect(notes.count == 1)
    #expect(notes.first?.choice == .preferB && notes.first?.voteID == "c1-f")
    #expect(notes.first?.recordSequence == record.envelope.sequence)
    #expect(notes.first?.notedAt?.wholeMatch(of: /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z/) != nil)
    // Arena's recorded vote is untouched.
    #expect(try a.vote(account) == vote)
}

@Test func theLatestNoteWinsAndRemovalDeletesIt() async throws {
    let a = try await NoteArchive()
    let account = a.accounts[0]
    let vote = try a.vote(account)
    try await a.notes.set(.preferA, beside: vote, account: account, conversation: "c1", snapshot: try a.snapshot(account))
    try await a.notes.set(.tie, beside: vote, account: account, conversation: "c1", snapshot: try a.snapshot(account))
    #expect(try a.archive.voteNotes(account: account, conversationID: "c1").map(\.choice) == [.tie])
    try await a.notes.set(nil, beside: vote, account: account, conversation: "c1", snapshot: try a.snapshot(account))
    #expect(try a.archive.voteNotes(account: account, conversationID: "c1").isEmpty)
    // Every note stays in the journal.
    #expect(try a.localRecords(account).count == 3)
    // Removing a note that does not exist records the removal and changes nothing else.
    try await a.notes.set(nil, beside: vote, account: account, conversation: "c1", snapshot: try a.snapshot(account))
    #expect(try a.archive.voteNotes(account: account, conversationID: "c1").isEmpty)
}

@Test func theNoteGoesToTheAccountPassedIn() async throws {
    let a = try await NoteArchive()
    let vote = try a.vote(a.accounts[1])
    try await a.notes.set(.bothBad, beside: vote, account: a.accounts[1], conversation: "c1", snapshot: try a.snapshot(a.accounts[1]))
    #expect(try a.archive.voteNotes(account: a.accounts[0], conversationID: "c1").isEmpty)
    #expect(try a.localRecords(a.accounts[0]).isEmpty)
    #expect(try a.archive.voteNotes(account: a.accounts[1], conversationID: "c1").map(\.choice) == [.bothBad])
}

@Test func notesSurviveARebuildAndTheIndexCheckMatches() async throws {
    let a = try await NoteArchive()
    let account = a.accounts[0]
    try await a.notes.set(.preferB, beside: try a.vote(account), account: account, conversation: "c1", snapshot: try a.snapshot(account))
    let before = try a.archive.voteNotes(account: account, conversationID: "c1")
    try await a.archive.rebuild()
    #expect(try a.archive.voteNotes(account: account, conversationID: "c1") == before)
    #expect(try await a.archive.checkAgainstJournal(scratch: scratch()).matches)
}

@Test func notesSurviveABackupAndARestore() async throws {
    let a = try await NoteArchive()
    let account = a.accounts[0]
    try await a.notes.set(.tie, beside: try a.vote(account), account: account, conversation: "c1", snapshot: try a.snapshot(account))
    let out = scratch()
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let backups = BackupService(archiveRoot: a.root, decoder: ArenaArchiveDecoder(), appVersion: "test")
    let backup = try await backups.create(in: out)
    let check = try await backups.check(backup)
    #expect(check.replayDigest == (try a.archive.contentDigest()), "the backup's replay covers the note")

    let targetRoot = scratch()
    _ = try await BackupService(archiveRoot: targetRoot, decoder: ArenaArchiveDecoder(), appVersion: "test").restore(from: backup)
    let accounts = a.accounts
    let restored = ArchiveService(
        index: try ArchiveIndex(url: targetRoot.appendingPathComponent("index/archive.sqlite")),
        journals: JournalStore(archiveRoot: targetRoot), decoder: ArenaArchiveDecoder(), accounts: { accounts })
    try await restored.rebuild()
    #expect(try restored.voteNotes(account: account, conversationID: "c1").map(\.choice) == [.tie])
    #expect(try restored.contentDigest() == check.replayDigest)
}

@Test func noteWritesWaitForMaintenance() async throws {
    let a = try await NoteArchive()
    let account = a.accounts[0]
    let vote = try a.vote(account)
    try await a.sync.beginMaintenance()
    await #expect(throws: AccountError.busy) {
        try await a.notes.set(.preferA, beside: vote, account: account, conversation: "c1", snapshot: try a.snapshot(account))
    }
    #expect(try a.localRecords(account).isEmpty)
    await a.sync.endMaintenance()
    try await a.notes.set(.preferA, beside: vote, account: account, conversation: "c1", snapshot: try a.snapshot(account))
    #expect(try a.localRecords(account).count == 1)
}

@Test func notesAreRefusedForAnAccountNotInTheApp() async throws {
    let a = try await NoteArchive()
    let before = try JournalReader(root: a.journals.root(for: a.removed)).readAll().count
    await #expect(throws: AccountError.unknownAccount) {
        try await a.notes.set(
            .preferA, beside: try a.vote(a.removed), account: a.removed, conversation: "c1", snapshot: try a.snapshot(a.removed))
    }
    #expect(try JournalReader(root: a.journals.root(for: a.removed)).readAll().count == before, "the kept journal is not extended")
}

/// The review's finding 1: a vote from one transcript can never be noted under another account or
/// conversation (for instance the selection, while its transcript is still loading).
@Test func aNoteIsRefusedOutsideTheTranscriptItWasShownIn() async throws {
    let a = try await NoteArchive()
    let other = try a.vote(a.accounts[1], "d1")
    // Shown in account 1's "d1", written as account 0's "c1".
    await #expect(throws: VoteNoteError.voteNotInConversation) {
        try await a.notes.set(.preferA, beside: other, account: a.accounts[0], conversation: "c1", snapshot: try a.snapshot(a.accounts[0]))
    }
    // The right account, the wrong conversation, or a snapshot that is not that conversation's.
    await #expect(throws: VoteNoteError.voteNotInConversation) {
        try await a.notes.set(.preferA, beside: other, account: a.accounts[1], conversation: "c1", snapshot: try a.snapshot(a.accounts[1], "d1"))
    }
    await #expect(throws: VoteNoteError.voteNotInConversation) {
        try await a.notes.set(.preferA, beside: other, account: a.accounts[1], conversation: "d1", snapshot: try a.snapshot(a.accounts[1]))
    }
    // A vote that is not the recorded one (another value, or messages that are not its own).
    var altered = try a.vote(a.accounts[0])
    altered.value = "model_b"
    var foreign = try a.vote(a.accounts[0])
    foreign.messageB = "d1-b"
    for vote in [altered, foreign] {
        await #expect(throws: VoteNoteError.voteNotInConversation) {
            try await a.notes.set(.preferA, beside: vote, account: a.accounts[0], conversation: "c1", snapshot: try a.snapshot(a.accounts[0]))
        }
    }
    #expect(try a.localRecords(a.accounts[0]).isEmpty && a.localRecords(a.accounts[1]).isEmpty)
    // Shown where it belongs, it is recorded.
    try await a.notes.set(.preferA, beside: other, account: a.accounts[1], conversation: "d1", snapshot: try a.snapshot(a.accounts[1], "d1"))
    #expect(try a.archive.voteNotes(account: a.accounts[1], conversationID: "d1").map(\.choice) == [.preferA])
}

/// The review's finding 2: local records read by another local decoder version are projected again.
@Test func aDifferentLocalVersionRebuildsTheIndex() async throws {
    let a = try await NoteArchive()
    let account = a.accounts[0]
    #expect(try a.index.localControlVersion() == nil, "no local record projected yet")
    try await a.notes.set(.tie, beside: try a.vote(account), account: account, conversation: "c1", snapshot: try a.snapshot(account))
    #expect(try a.index.localControlVersion() == LocalControl.version)
    // As if an earlier local decoder had read the note and not projected it.
    let sqlite = Process()
    sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    sqlite.arguments = [
        a.root.appendingPathComponent("index/archive.sqlite").path,
        "DELETE FROM vote_notes; UPDATE meta SET value = 'local-control/0' WHERE key = 'local_control_version';",
    ]
    try sqlite.run()
    sqlite.waitUntilExit()
    #expect(try a.archive.voteNotes(account: account, conversationID: "c1").isEmpty)
    _ = try await a.archive.project(account)
    #expect(try a.archive.voteNotes(account: account, conversationID: "c1").map(\.choice) == [.tie])
    #expect(try a.index.localControlVersion() == LocalControl.version)
}

/// Exports, Insights and the history filters show Arena's recorded votes only.
@Test func aNoteChangesNoExportInsightOrFilter() async throws {
    let a = try await NoteArchive()
    let account = a.accounts[0]
    let exports = ExportService(archive: a.archive)
    let insights = InsightsService(archive: a.archive, vocabulary: ArenaArchiveDecoder.voteVocabulary)
    func snapshot() async throws -> ([Data], ArchiveInsights, HistoryFacets) {
        var rendered: [Data] = []
        for format in ExportFormat.allCases {
            rendered.append(try await exports.render(account: account, remoteID: "c1", snapshot: nil, options: ExportOptions(format: format)).data)
        }
        return (rendered, try insights.insights(), try a.archive.historyFacets(account: nil))
    }
    let before = try await snapshot()
    try await a.notes.set(.preferB, beside: try a.vote(account), account: account, conversation: "c1", snapshot: try a.snapshot(account))
    let after = try await snapshot()
    #expect(after.0 == before.0 && after.1 == before.1 && after.2 == before.2)
}

@Test func onlyLocalRecordsForTheNamedAccountGoThroughAppendLocal() async throws {
    let a = try await NoteArchive()
    let account = a.accounts[0]
    let note = VoteNote(conversationID: "c1", messageA: "c1-a", messageB: "c1-b", choice: .tie, voteID: nil)
    let other = try LocalControl.draft(note, account: a.accounts[1])
    await #expect(throws: LocalWriteError.notALocalRecord) { _ = try await a.sync.appendLocal(other, account: account) }
    var exchange = try LocalControl.draft(note, account: account)
    exchange.kind = "exchange"
    await #expect(throws: LocalWriteError.notALocalRecord) { _ = try await a.sync.appendLocal(exchange, account: account) }
    var inJob = try LocalControl.draft(note, account: account)
    inJob.jobID = UUID()
    await #expect(throws: LocalWriteError.notALocalRecord) { _ = try await a.sync.appendLocal(inJob, account: account) }
    #expect(try a.localRecords(account).isEmpty)
}

@Test func aVoteWithoutTwoMessagesTakesNoNote() async throws {
    let a = try await NoteArchive()
    let account = a.accounts[0]
    for vote in [
        ArchivedFeedback(remoteID: "f", value: "model_a", messageA: "x", messageB: nil),
        ArchivedFeedback(remoteID: "f", value: "model_a", messageA: "x", messageB: "x"),
        ArchivedFeedback(remoteID: "f", value: "model_a", messageA: "", messageB: "y"),
    ] {
        await #expect(throws: VoteNoteError.voteWithoutTwoMessages) {
            try await a.notes.set(.preferA, beside: vote, account: account, conversation: "c1", snapshot: try a.snapshot(account))
        }
    }
    #expect(try a.localRecords(account).isEmpty)
}

/// A sync of the same account may run while a note is written: the shared writer serializes the
/// appends, the job still ends cleanly, and the note is projected.
@Test func aNoteCanBeWrittenWhileThatAccountSyncs() async throws {
    let a = try await NoteArchive()
    let account = a.accounts[0]
    let vote = try a.vote(account)
    await a.accountService.restoreAll()
    let job = Task { try await a.sync.sync(account) }
    while await !a.engine.waiting { await Task.yield() }
    try await a.notes.set(.preferB, beside: vote, account: account, conversation: "c1", snapshot: try a.snapshot(account))
    await a.engine.release()
    #expect(try await job.value.outcome == .completed)
    let kinds = try JournalReader(root: a.journals.root(for: account)).readAll().map(\.envelope.kind)
    #expect(kinds == ["exchange", JournalKind.jobStarted, LocalControl.kind, JournalKind.jobFinished])
    await a.journals.close(account)
    let reopened = try JournalWriter.open(at: a.journals.root(for: account))
    #expect(reopened.recoveryReport.unterminatedJobIDs.isEmpty)
    try reopened.close()
    _ = try await a.archive.project(account)
    #expect(try a.archive.voteNotes(account: account, conversationID: "c1").map(\.choice) == [.preferB])
}

// MARK: Decoding

/// Writes raw `local.control` payloads (as another app version might) and projects them.
private func project(
    _ payloads: [Data], envelopeAccount: AccountID? = nil, representation: String = "local_control_json",
    transformations: [String] = []
) async throws
    -> (archive: NoteArchive, account: AccountID, decoded: [DecodedRecord])
{
    let a = try await NoteArchive()
    let account = a.accounts[0]
    let writer = try await a.journals.writer(for: account)
    for payload in payloads {
        _ = try writer.append(
            JournalDraft(
                kind: LocalControl.kind, payload: payload, accountID: (envelopeAccount ?? account).rawValue,
                payloadRepresentation: representation, transformations: transformations))
    }
    try writer.synchronize()
    _ = try await a.archive.project(account)
    let decoded = try a.localRecords(account).map { LocalControl.decode($0, account: account) }
    return (a, account, decoded)
}

/// A valid version 1 note with `changes` applied and the keys in `removing` left out.
private func body(_ changes: [String: Any], removing: [String] = []) -> Data {
    var object: [String: Any] = [
        "format": "arena-suite.local-control", "type": "vote_note", "version": 1, "origin": "ui",
        "conversation_id": "c1", "message_a": "c1-a", "message_b": "c1-b", "choice": "prefer_a", "vote_id": "c1-f",
    ]
    object.merge(changes) { _, new in new }
    for key in removing { object.removeValue(forKey: key) }
    return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func warnings(_ decoded: [DecodedRecord]) -> [String] {
    decoded.flatMap(\.events).compactMap { if case .warning(let code, let detail) = $0 { "\(code): \(detail)" } else { nil } }
}

@Test func unrecognizedLocalRecordsBecomeWarningsAndStayInTheJournal() async throws {
    let payloads = [
        body(["type": "tag"]),
        body(["version": 2]),
        body(["version": true]),
        body(["format": "someone-else"]),
        body(["type": "Has Spaces And c1-a"]),
        body(["type": "6f1d2c3b-0000-4000-8000-000000000001"]),
        body(["type": "c1"]),
    ]
    let (a, account, decoded) = try await project(payloads)
    #expect(
        warnings(decoded) == [
            "local_control_unrecognized: tag version 1",
            "local_control_unrecognized: vote_note version 2",
            "local_control_unrecognized: vote_note version ?",
            "local_control_unrecognized: vote_note version 1",
            "local_control_unrecognized: ? version 1",
            "local_control_unrecognized: ? version 1",
            "local_control_unrecognized: ? version 1",
        ])
    let indexed = try a.archive.warnings(account: account).map(\.code)
    #expect(indexed == Array(repeating: "local_control_unrecognized", count: 7))
    #expect(try a.archive.voteNotes(account: account, conversationID: "c1").isEmpty)
    #expect(try a.localRecords(account).map(\.payload) == payloads, "the journal keeps the bytes")
}

@Test func malformedVoteNotesBecomeWarningsWithoutIDs() async throws {
    let payloads = [
        Data("not json".utf8),
        Data(#"{"format":"arena-suite.local-control","type":"vote_note""#.utf8),
        Data("[1,2]".utf8),
        body([:], removing: ["message_b"]),
        body(["message_b": "c1-a"]),
        body(["conversation_id": ""]),
        body(["choice": "model_a"]),
        body([:], removing: ["choice"]),
        body(["choice": 3]),
        body(["origin": "mcp"]),
        body(["vote_id": 7]),
    ]
    let (a, account, decoded) = try await project(payloads)
    let found = warnings(decoded)
    #expect(found.count == payloads.count)
    #expect(found.allSatisfy { $0.hasPrefix("local_control_malformed: ") })
    #expect(!found.contains { $0.contains("c1") }, "warning details never repeat IDs")
    #expect(try a.archive.voteNotes(account: account, conversationID: "c1").isEmpty)
}

@Test func aNoteRecordedForAnotherAccountIsNotProjected() async throws {
    let (a, account, decoded) = try await project([body([:])], envelopeAccount: AccountID())
    #expect(warnings(decoded) == ["local_control_malformed: vote_note for another account"])
    #expect(try a.archive.voteNotes(account: account, conversationID: "c1").isEmpty)
}

@Test func extraKeysAreCountedAndANullChoiceRemoves() async throws {
    let (a, account, decoded) = try await project([body(["mood": "good"]), body(["choice": NSNull()]), body(["choice": "both_bad"])])
    #expect(warnings(decoded).isEmpty)
    #expect(decoded[0].unknownFields == ["local.control:$.mood": 1])
    #expect(try a.archive.unknownFields(account: account).contains { $0.path == "local.control:$.mood" })
    #expect(try a.archive.voteNotes(account: account, conversationID: "c1").map(\.choice) == [.bothBad])
}

@Test func anotherRepresentationOrATransformationIsNotReadAsANote() async throws {
    for (representation, transformations) in [("base64", [String]()), ("local_control_json", ["credential_omitted"])] {
        let (a, account, decoded) = try await project([body([:])], representation: representation, transformations: transformations)
        #expect(warnings(decoded) == ["local_control_unrecognized: payload representation or transformations"])
        #expect(try a.archive.voteNotes(account: account, conversationID: "c1").isEmpty)
    }
}

// MARK: - Refresh's index check (Docs/sync-refresh-2026-10-20.md), on this fixture

@Test func aRefreshIsRefusedForAConversationTheIndexDoesNotHoldForThatAccount() async throws {
    let a = try await NoteArchive()
    await a.accountService.restoreAll()
    let refresh = ConversationRefreshService(sync: a.sync, archive: a.archive, kinds: ArenaHistorySync.refreshableKinds)
    // "d1" is only in the second account; "x" in neither.
    for (account, conversation) in [(a.accounts[0], "d1"), (a.accounts[0], "x"), (a.accounts[1], "x")] {
        await #expect(throws: RefreshError.notRefreshable) { _ = try await refresh.refresh(account: account, conversation: conversation) }
    }
    #expect(await a.engine.refreshed.isEmpty)
    #expect(try await refresh.refresh(account: a.accounts[1], conversation: "d1").outcome == .completed)
    #expect(await a.engine.refreshed == ["d1"])
}

@Test func aRefreshIsRefusedForAKindArenaCannotFetchAgain() async throws {
    let a = try await NoteArchive()
    await a.accountService.restoreAll()
    // A snapshot of another kind (as a future decoder might record it): in the index, not refreshable.
    let writer = try await a.journals.writer(for: a.accounts[0])
    _ = try writer.append(
        JournalDraft(
            kind: "exchange", payload: battle("g1"), accountID: a.accounts[0].rawValue,
            metadata: [
                "role": .string("detail"), "status": .integer(200), "transfer_end": .string("complete"),
                "entry_id": .string("g1"), "entry_type": .string("agentic"),
            ]))
    try writer.synchronize()
    _ = try await a.archive.project(a.accounts[0])
    let held = try #require(try a.archive.conversation(account: a.accounts[0], remoteID: "g1")?.summary)
    #expect(held.kind == "agentic" && held.latestSnapshotSequence != nil)
    let refresh = ConversationRefreshService(sync: a.sync, archive: a.archive, kinds: ArenaHistorySync.refreshableKinds)
    #expect(!refresh.canRefresh(kind: held.kind, latestSnapshot: held.latestSnapshotSequence))
    await #expect(throws: RefreshError.notRefreshable) { _ = try await refresh.refresh(account: a.accounts[0], conversation: "g1") }
    #expect(await a.engine.refreshed.isEmpty)
}

@Test func aRefreshIsRefusedWhenTheIndexCannotBeRead() async throws {
    let a = try await NoteArchive()
    await a.accountService.restoreAll()
    let sqlite = Process()
    sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    sqlite.arguments = [a.root.appendingPathComponent("index/archive.sqlite").path, "DROP TABLE conversations;"]
    try sqlite.run()
    sqlite.waitUntilExit()
    #expect(sqlite.terminationStatus == 0)
    let refresh = ConversationRefreshService(sync: a.sync, archive: a.archive, kinds: ArenaHistorySync.refreshableKinds)
    await #expect(throws: RefreshError.indexUnreadable) { _ = try await refresh.refresh(account: a.accounts[0], conversation: "c1") }
    #expect(await a.engine.refreshed.isEmpty)
}
