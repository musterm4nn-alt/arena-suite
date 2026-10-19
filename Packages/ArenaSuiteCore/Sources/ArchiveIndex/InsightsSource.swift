import Foundation
import SuiteDomain

// What the Insights page reads (Docs/insights-2026-10-19.md): the latest snapshot of each
// conversation, without message bodies, in one read transaction.

public struct InsightsConversation: Sendable, Equatable {
    public let account: AccountID
    public let remoteID: String
    public let kind: String
    public let mode: String?
    /// `updatedAt` as exact microseconds since 1970, when the decoder could parse it.
    public let updatedOrder: Int64?
    public let latestSnapshotSequence: UInt64?

    public init(account: AccountID, remoteID: String, kind: String, mode: String?, updatedOrder: Int64?, latestSnapshotSequence: UInt64?) {
        self.account = account
        self.remoteID = remoteID
        self.kind = kind
        self.mode = mode
        self.updatedOrder = updatedOrder
        self.latestSnapshotSequence = latestSnapshotSequence
    }
}

/// A message of a latest snapshot, without its content: what Insights counts (its role) and the
/// model the message itself claims (used to attribute votes).
public struct InsightsMessage: Sendable, Equatable {
    public let account: AccountID
    /// The snapshot's journal sequence.
    public let sequence: UInt64
    public let remoteID: String
    public let role: String?
    public let modelRemoteID: String?

    public init(account: AccountID, sequence: UInt64, remoteID: String, role: String?, modelRemoteID: String?) {
        self.account = account
        self.sequence = sequence
        self.remoteID = remoteID
        self.role = role
        self.modelRemoteID = modelRemoteID
    }
}

public struct InsightsSource: Sendable, Equatable {
    /// Decoder that built this projection; nil if nothing was projected.
    public let decoderVersion: String?
    /// Conversations of the requested accounts, ordered by account ID and remote ID.
    public let conversations: [InsightsConversation]
    /// Messages of those conversations' latest snapshots, in snapshot order.
    public let messages: [InsightsMessage]
    /// Votes recorded in those latest snapshots.
    public let votes: [SequencedFeedback]
    /// Claims recorded in those latest snapshots' records (the detail's own claims).
    public let claims: [SequencedClaim]
    /// Every claim that carries a display name, from any record of these conversations (earlier
    /// snapshots included), so a name once revealed is not lost when a later snapshot omits it.
    public let namedClaims: [SequencedClaim]

    public init(
        decoderVersion: String?, conversations: [InsightsConversation], messages: [InsightsMessage],
        votes: [SequencedFeedback], claims: [SequencedClaim], namedClaims: [SequencedClaim]
    ) {
        self.decoderVersion = decoderVersion
        self.conversations = conversations
        self.messages = messages
        self.votes = votes
        self.claims = claims
        self.namedClaims = namedClaims
    }
}
