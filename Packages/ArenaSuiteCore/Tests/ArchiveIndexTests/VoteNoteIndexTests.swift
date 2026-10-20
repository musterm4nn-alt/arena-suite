import ArchiveIndex
import Foundation
import SuiteDomain
import Testing

// Local vote notes in the index (Docs/vote-notes-2026-10-20.md).

private func tempIndexURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("index-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("index.sqlite")
}

private let fixedAccount = AccountID(rawValue: UUID(uuidString: "6F1D2C3B-0000-4000-8000-000000000001")!)

private func ref(_ sequence: UInt64) -> RecordRef {
    RecordRef(account: fixedAccount, sequence: sequence, segment: 1, offset: Int(sequence) * 100, length: 90)
}

/// One battle with a vote, a listing, a warning and an unknown path: a fixed archive whose digest is
/// pinned below.
private func fixedArchive(_ index: ArchiveIndex) throws {
    let messages = [
        ArchivedMessage(
            remoteID: "u1", role: "user", status: "success", lane: nil, parentIDs: [], modelRemoteID: nil,
            createdAt: "2026-10-01", updatedAt: nil, failureReason: nil,
            blocks: [ArchivedBlock(kind: .text, text: "Which is better?", pointer: "$.messages[0].content")], attachments: []),
        ArchivedMessage(
            remoteID: "a1", role: "assistant", status: "success", lane: "a", parentIDs: ["u1"], modelRemoteID: "m-a",
            createdAt: nil, updatedAt: nil, failureReason: nil,
            blocks: [ArchivedBlock(kind: .text, text: "Answer A", pointer: "$.messages[1].content")], attachments: []),
        ArchivedMessage(
            remoteID: "b1", role: "assistant", status: "success", lane: "b", parentIDs: ["u1"], modelRemoteID: "m-b",
            createdAt: nil, updatedAt: nil, failureReason: nil,
            blocks: [ArchivedBlock(kind: .text, text: "Answer B", pointer: "$.messages[2].content")], attachments: []),
    ]
    let snapshot = ConversationSnapshot(
        facts: ConversationFacts(remoteID: "c1", kind: "evaluation", title: "Fixed", updatedAt: "2026-10-01 10:00:00"),
        messages: messages, lastMessageIDs: ["a1", "b1"],
        claims: [ModelClaim(subject: .message, subjectID: "a1", role: "a", modelID: "m-a", source: "message_model_id")],
        feedback: [ArchivedFeedback(remoteID: "f1", value: "model_b", messageA: "a1", messageB: "b1")])
    try index.apply(
        account: fixedAccount,
        records: [
            (ref(1), DecodedRecord(events: [.listed(ConversationFacts(remoteID: "c1", kind: "evaluation"), claims: [])])),
            (ref(2), DecodedRecord(events: [.snapshot(snapshot), .warning(code: "w", detail: "d")], unknownFields: ["$.x": 2])),
        ],
        through: 2, decoderVersion: "test/1")
}

/// Computed with the index before vote notes existed (commit 544194b). An archive without notes
/// must keep it, or every older backup would fail its replay check.
private let digestBeforeVoteNotes = "ee5a1c87655751a27c2cbc33e9861ef7f0b178e5588d91419bc8741edbe97810"

@Test func archiveWithoutNotesKeepsItsDigest() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    try fixedArchive(index)
    let digest = try index.contentDigest()
    #expect(digest == digestBeforeVoteNotes)
    #expect(try index.localControlVersion() == nil)
}

@Test func aRebuiltArchiveWithoutNotesKeepsItsDigest() throws {
    let index = try ArchiveIndex(url: tempIndexURL())
    try fixedArchive(index)
    try index.reset()
    try fixedArchive(index)
    #expect(try index.contentDigest() == digestBeforeVoteNotes)
}

private func note(_ choice: VoteOutcome?, a: String = "a1", b: String = "b1") -> ArchiveEvent {
    .voteNote(VoteNote(conversationID: "c1", messageA: a, messageB: b, choice: choice, voteID: "f1", notedAt: "2026-10-20T12:00:00.000Z"))
}

private func archive(then records: [[ArchiveEvent]]) throws -> ArchiveIndex {
    let index = try ArchiveIndex(url: tempIndexURL())
    try fixedArchive(index)
    for (offset, events) in records.enumerated() {
        let sequence = UInt64(3 + offset)
        try index.apply(
            account: fixedAccount, records: [(ref(sequence), DecodedRecord(events: events))], through: sequence,
            decoderVersion: "test/1")
    }
    return index
}

/// At the index level: an empty notes table adds nothing. Through ArchiveService, once a local record
/// was projected `meta.local_control_version` stays, so removing every note does not bring back the
/// digest from before; archives that never had a local record keep it (the pinned tests).
@Test func anEmptyNotesTableIsLeftOutOfTheDigest() throws {
    let plain = try archive(then: [[], []])
    let noted = try archive(then: [[note(.preferA)], []])
    let removed = try archive(then: [[note(.preferA)], [note(nil)]])
    #expect(try noted.contentDigest() != plain.contentDigest(), "a note is covered by the digest")
    #expect(try removed.contentDigest() == plain.contentDigest(), "an empty notes table is left out")
    #expect(try noted.counts()["vote_notes"] == 1 && plain.counts()["vote_notes"] == 0)
}

@Test func notesAreKeyedByAccountConversationAndMessagePair() throws {
    let index = try archive(then: [[note(.preferA)], [note(.tie, a: "b1", b: "a1")], [note(.bothBad)]])
    let notes = try index.voteNotes(account: fixedAccount, conversationID: "c1")
    #expect(notes.map(\.choice) == [.bothBad, .tie], "latest per pair, ordered by message A")
    #expect(notes.map(\.recordSequence) == [5, 4])
    #expect(try index.voteNotes(account: AccountID(), conversationID: "c1").isEmpty)
    #expect(try index.voteNotes(account: fixedAccount, conversationID: "c2").isEmpty)
}

/// An index written before vote notes (only migration v1) gains the table on open and keeps its digest.
@Test func anIndexFromBeforeVoteNotesIsUpgraded() throws {
    let url = tempIndexURL()
    do {
        let index = try ArchiveIndex(url: url)
        try fixedArchive(index)
    }
    let sqlite = Process()
    sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    sqlite.arguments = [url.path, "DROP TABLE vote_notes; DELETE FROM grdb_migrations WHERE identifier = 'v2';"]
    try sqlite.run()
    sqlite.waitUntilExit()
    #expect(sqlite.terminationStatus == 0)
    // Read-only openers (MCP) wait for the app to migrate it.
    #expect(throws: ArchiveIndex.ReadOnlyOpenError.schemaNotReady) { _ = try ArchiveIndex(readingExistingAt: url) }

    let upgraded = try ArchiveIndex(url: url)
    #expect(try upgraded.tableNames().contains("vote_notes"))
    #expect(try upgraded.contentDigest() == digestBeforeVoteNotes)
    try upgraded.apply(
        account: fixedAccount, records: [(ref(3), DecodedRecord(events: [note(.preferB)]))], through: 3, decoderVersion: "test/1")
    #expect(try upgraded.voteNotes(account: fixedAccount, conversationID: "c1").map(\.choice) == [.preferB])
    #expect(try ArchiveIndex(readingExistingAt: url).voteNotes(account: fixedAccount, conversationID: "c1").count == 1)
}

/// A stored choice this build does not know is reported, never skipped as if there were no note.
@Test func anUnknownStoredChoiceIsReported() throws {
    let url = tempIndexURL()
    let index = try ArchiveIndex(url: url)
    try fixedArchive(index)
    try index.apply(
        account: fixedAccount, records: [(ref(3), DecodedRecord(events: [note(.preferA)]))], through: 3, decoderVersion: "test/1")
    let sqlite = Process()
    sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    sqlite.arguments = [url.path, "UPDATE vote_notes SET choice = 'prefer_c';"]
    try sqlite.run()
    sqlite.waitUntilExit()
    #expect(throws: ArchiveIndex.QueryError.unreadableVoteNote) {
        _ = try index.voteNotes(account: fixedAccount, conversationID: "c1")
    }
}
