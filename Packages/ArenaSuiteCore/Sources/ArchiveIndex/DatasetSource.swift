import Foundation
import SuiteDomain

// One frozen view of the projection for dataset building (plan v3 §14, v2 §12): everything is read
// in a single read transaction, so checkpoints, the content digest and every row agree even while
// the app projects new journal records.

/// A model claim with the account and journal record it came from.
public struct SequencedClaim: Sendable, Equatable {
    public let account: AccountID
    public let sequence: UInt64
    public let conversationID: String
    public let claim: ModelClaim

    public init(account: AccountID, sequence: UInt64, conversationID: String, claim: ModelClaim) {
        self.account = account
        self.sequence = sequence
        self.conversationID = conversationID
        self.claim = claim
    }
}

/// A pairwise vote as recorded in one snapshot.
public struct SequencedFeedback: Sendable, Equatable {
    public let account: AccountID
    /// Journal sequence of the snapshot that contained the vote.
    public let sequence: UInt64
    public let conversationID: String
    public let feedback: ArchivedFeedback

    public init(account: AccountID, sequence: UInt64, conversationID: String, feedback: ArchivedFeedback) {
        self.account = account
        self.sequence = sequence
        self.conversationID = conversationID
        self.feedback = feedback
    }
}

/// Unknown JSON paths are counted per account with the first and last record they appeared in; the
/// index does not keep which records in between had them.
public struct UnknownFieldRange: Sendable, Equatable {
    public let path: String
    public let count: Int
    public let firstSequence: UInt64
    public let lastSequence: UInt64

    public init(path: String, count: Int, firstSequence: UInt64, lastSequence: UInt64) {
        self.path = path
        self.count = count
        self.firstSequence = firstSequence
        self.lastSequence = lastSequence
    }
}

public struct DatasetSourceAccount: Sendable, Equatable {
    public let account: AccountID
    /// The journal sequence this account is projected through.
    public let checkpoint: UInt64
    public let unknownFields: [UnknownFieldRange]

    public init(account: AccountID, checkpoint: UInt64, unknownFields: [UnknownFieldRange]) {
        self.account = account
        self.checkpoint = checkpoint
        self.unknownFields = unknownFields
    }
}

public struct DatasetSourceConversation: Sendable, Equatable {
    public let summary: ConversationSummary
    /// `updatedAt` as exact microseconds since 1970, when the decoder could parse it.
    public let updatedOrder: Int64?
    /// Where the latest snapshot's record lives in the account journal; nil without a snapshot.
    public let snapshotLocation: RecordRef?
    /// Messages of the latest snapshot in snapshot order; empty when there is no snapshot.
    public let messages: [DetailMessage]
    /// Decoder warnings recorded for the latest snapshot's journal record.
    public let snapshotWarnings: [IndexWarning]

    public init(
        summary: ConversationSummary, updatedOrder: Int64?, snapshotLocation: RecordRef?, messages: [DetailMessage],
        snapshotWarnings: [IndexWarning]
    ) {
        self.summary = summary
        self.updatedOrder = updatedOrder
        self.snapshotLocation = snapshotLocation
        self.messages = messages
        self.snapshotWarnings = snapshotWarnings
    }
}

public struct DatasetSource: Sendable, Equatable {
    /// Decoder that built this projection; nil if nothing was projected.
    public let decoderVersion: String?
    /// `contentDigest()` of the whole index at the time of the read.
    public let contentDigest: String
    /// Every projected account, ordered by account ID.
    public let accounts: [DatasetSourceAccount]
    /// Conversations of the requested accounts, ordered by account ID and remote ID.
    public let conversations: [DatasetSourceConversation]
    /// Every claim in the index (all accounts, all records), in primary-key order.
    public let claims: [SequencedClaim]
    /// Every pairwise vote in the index (all accounts, all snapshots), in primary-key order.
    public let feedback: [SequencedFeedback]

    public init(
        decoderVersion: String?, contentDigest: String, accounts: [DatasetSourceAccount],
        conversations: [DatasetSourceConversation], claims: [SequencedClaim], feedback: [SequencedFeedback]
    ) {
        self.decoderVersion = decoderVersion
        self.contentDigest = contentDigest
        self.accounts = accounts
        self.conversations = conversations
        self.claims = claims
        self.feedback = feedback
    }
}
