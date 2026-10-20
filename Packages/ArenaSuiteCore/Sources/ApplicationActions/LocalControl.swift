import CaptureJournal
import Foundation
import SuiteDomain

/// Local user state kept in the journal as `local.control` records (plan v3 §7: state that must
/// survive an index rebuild). The app writes and decodes these; the Arena adapter never sees them.
/// Version 1 has one type, `vote_note` (Docs/vote-notes-2026-10-20.md).
public enum LocalControl {
    public static let kind = "local.control"
    /// The projection of local records, stored in the index beside the Arena decoder's version once
    /// a local record is projected. A different value rebuilds the index (plan v3 §10).
    public static let version = "local-control/1"
    static let format = "arena-suite.local-control"
    static let representation = "local_control_json"
    static let voteNoteType = "vote_note"

    /// The record that sets a note, or removes it when `note.choice` is nil. IDs and the choice only.
    public static func draft(_ note: VoteNote, account: AccountID) throws -> JournalDraft {
        var body: [String: Any] = [
            "format": format, "type": voteNoteType, "version": 1, "origin": "ui",
            "conversation_id": note.conversationID, "message_a": note.messageA, "message_b": note.messageB,
            "choice": note.choice?.rawValue ?? NSNull(),
        ]
        if let vote = note.voteID { body["vote_id"] = vote }
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        return JournalDraft(kind: kind, payload: payload, accountID: account.rawValue, payloadRepresentation: representation)
    }

    private static let voteNoteKeys: Set<String> = [
        "format", "type", "version", "origin", "conversation_id", "message_a", "message_b", "choice", "vote_id",
    ]

    /// One `local.control` record of `account`'s journal as projection events. A representation,
    /// format, type or version this app does not know is a `local_control_unrecognized` warning; a
    /// known one whose body is not as specified is `local_control_malformed`. Neither is dropped
    /// silently, and the warning detail never repeats IDs from the record.
    public static func decode(_ record: JournalRecord, account: AccountID) -> DecodedRecord {
        guard record.envelope.payloadRepresentation == representation, record.envelope.transformations.isEmpty else {
            return warning("local_control_unrecognized", "payload representation or transformations")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: record.payload)) as? [String: Any] else {
            return warning("local_control_malformed", "not a JSON object")
        }
        let type = object["type"] as? String
        let version = integer(object["version"])
        guard object["format"] as? String == format, type == voteNoteType, version == 1 else {
            return warning(
                "local_control_unrecognized",
                "\(type.flatMap(printable) ?? "?") version \(version.map(String.init) ?? "?")")
        }
        guard record.envelope.accountID == account.rawValue else {
            return warning("local_control_malformed", "vote_note for another account")
        }
        guard let conversation = nonEmpty(object["conversation_id"]), let a = nonEmpty(object["message_a"]),
            let b = nonEmpty(object["message_b"]), a != b
        else { return warning("local_control_malformed", "vote_note without a conversation and two messages") }
        guard object["origin"] as? String == "ui" else { return warning("local_control_malformed", "vote_note origin") }
        let choice: VoteOutcome?
        switch object["choice"] {
        case is NSNull: choice = nil
        case let text as String:
            guard let outcome = VoteOutcome(rawValue: text) else { return warning("local_control_malformed", "vote_note choice") }
            choice = outcome
        default: return warning("local_control_malformed", "vote_note choice")
        }
        let vote: String?
        switch object["vote_id"] {
        case nil: vote = nil
        case let text as String: vote = text
        default: return warning("local_control_malformed", "vote_note vote_id")
        }
        // Keys a later version 1 writer added are counted, like unknown protocol fields.
        var unknown: [String: Int] = [:]
        for key in object.keys where !voteNoteKeys.contains(key) {
            unknown["local.control:$.\(printable(key) ?? "[unprintable key]")", default: 0] += 1
        }
        let note = VoteNote(
            conversationID: conversation, messageA: a, messageB: b, choice: choice, voteID: vote,
            notedAt: iso8601(record.envelope.timestamp.wallMilliseconds), recordSequence: record.envelope.sequence)
        return DecodedRecord(events: [.voteNote(note)], unknownFields: unknown)
    }

    private static func warning(_ code: String, _ detail: String) -> DecodedRecord {
        DecodedRecord(events: [.warning(code: code, detail: detail)])
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    /// A JSON integer (not a boolean, not a fraction).
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let int = number.intValue
        return NSNumber(value: int) == number ? int : nil
    }

    /// A short name safe to show in a warning: lowercase letters, `_` and `.` only, so no ID (they
    /// carry digits or hyphens) is ever repeated.
    private static func printable(_ text: String) -> String? {
        text.wholeMatch(of: /[a-z][a-z_.]{0,39}/) != nil ? text : nil
    }

    /// `2026-10-20T12:00:00.123Z`, exact to the millisecond (no floating point).
    static func iso8601(_ milliseconds: Int64) -> String {
        let seconds = milliseconds >= 0 ? milliseconds / 1000 : (milliseconds - 999) / 1000
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let whole = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        return whole.dropLast() + String(format: ".%03dZ", Int(milliseconds - seconds * 1000))
    }
}

/// Sets and removes your notes beside recorded votes (Docs/vote-notes-2026-10-20.md). It has no
/// transport and no Arena route: a note is never sent to Arena.
public struct VoteNoteService: Sendable {
    private let sync: HistorySyncService
    private let archive: ArchiveService

    public init(sync: HistorySyncService, archive: ArchiveService) {
        self.sync = sync
        self.archive = archive
    }

    /// Records `choice` (nil removes the note) beside `vote`, flushed to the journal, then brings that
    /// account's index up to date. `account`, `conversation` and `snapshot` name the transcript the
    /// vote was shown in (never the window's current selection); the vote must be in that snapshot
    /// of the index, so a note can never land in another account or conversation.
    public func set(
        _ choice: VoteOutcome?, beside vote: ArchivedFeedback, account: AccountID, conversation: String, snapshot: UInt64
    ) async throws {
        guard let a = vote.messageA, let b = vote.messageB, !a.isEmpty, !b.isEmpty, a != b, !conversation.isEmpty else {
            throw VoteNoteError.voteWithoutTwoMessages
        }
        let shown = try? archive.conversation(account: account, remoteID: conversation, snapshot: snapshot)
        guard shown?.feedback.contains(vote) == true else { throw VoteNoteError.voteNotInConversation }
        let note = VoteNote(conversationID: conversation, messageA: a, messageB: b, choice: choice, voteID: vote.remoteID)
        _ = try await sync.appendLocal(try LocalControl.draft(note, account: account), account: account)
        do {
            _ = try await archive.project(account)
        } catch {
            throw VoteNoteError.savedButNotIndexed
        }
    }
}

public enum VoteNoteError: Error, Equatable, Sendable {
    /// The vote does not name two different messages, so a note would have nothing to sit beside.
    case voteWithoutTwoMessages
    /// The vote is not in that snapshot of that account's conversation in the index.
    case voteNotInConversation
    /// The note is in the journal, but the index could not be updated; the next update shows it.
    case savedButNotIndexed
}
