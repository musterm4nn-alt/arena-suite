import Foundation

/// What a pairwise vote's value says once interpreted. The values themselves are Arena's and stay
/// as recorded; only the adapter knows which value means what (`VoteVocabulary`).
public enum VoteOutcome: String, Sendable, Codable, CaseIterable {
    /// The response in lane A was preferred.
    case preferA = "prefer_a"
    /// The response in lane B was preferred.
    case preferB = "prefer_b"
    case tie
    /// Neither response was good.
    case bothBad = "both_bad"
}

/// How to read recorded vote values. A value that is not in `outcomes` stays uninterpreted.
public struct VoteVocabulary: Sendable, Equatable {
    public let outcomes: [String: VoteOutcome]
    /// Where the vocabulary comes from (a ledger entry), named wherever it is applied.
    public let evidence: String

    public init(outcomes: [String: VoteOutcome], evidence: String) {
        self.outcomes = outcomes
        self.evidence = evidence
    }

    public func outcome(_ value: String?) -> VoteOutcome? { value.flatMap { outcomes[$0] } }
}

/// Your own note beside a vote Arena recorded (Docs/vote-notes-2026-10-20.md). It lives only in this
/// archive, as a `local.control` record, and is never sent to Arena. Keyed by account, conversation
/// and the vote's message pair; A and B are the vote's `messageA` and `messageB`.
public struct VoteNote: Equatable, Sendable {
    public var conversationID: String
    public var messageA: String
    public var messageB: String
    /// nil: the note was removed.
    public var choice: VoteOutcome?
    /// The recorded vote it was written beside (provenance only).
    public var voteID: String?
    /// The record's wall time, ISO 8601 UTC with milliseconds.
    public var notedAt: String?
    /// The journal record that set it (nil before it is recorded).
    public var recordSequence: UInt64?

    public init(
        conversationID: String, messageA: String, messageB: String, choice: VoteOutcome?, voteID: String?,
        notedAt: String? = nil, recordSequence: UInt64? = nil
    ) {
        self.conversationID = conversationID
        self.messageA = messageA
        self.messageB = messageB
        self.choice = choice
        self.voteID = voteID
        self.notedAt = notedAt
        self.recordSequence = recordSequence
    }
}
