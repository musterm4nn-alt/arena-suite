import Foundation
import SuiteDomain

// What the history filters read (Docs/history-filters-2026-10-19.md), besides the conversation list.

/// One conversation's latest snapshot, as the filters see it.
public struct ConversationFacet: Sendable, Equatable {
    public let account: AccountID
    public let remoteID: String
    /// Votes in the latest snapshot; 0 when there is none, or no snapshot.
    public let votes: Int
    /// Model IDs claimed in the latest snapshot's record for this conversation, from any source,
    /// sorted. Claims, not verified identity.
    public let models: [String]

    public init(account: AccountID, remoteID: String, votes: Int, models: [String]) {
        self.account = account
        self.remoteID = remoteID
        self.votes = votes
        self.models = models
    }
}

public struct HistoryFacetSource: Sendable, Equatable {
    /// Every conversation of the requested accounts, ordered by account ID and remote ID.
    public let conversations: [ConversationFacet]
    /// Every claim that carries a display name, from any record of those accounts.
    public let namedClaims: [SequencedClaim]

    public init(conversations: [ConversationFacet], namedClaims: [SequencedClaim]) {
        self.conversations = conversations
        self.namedClaims = namedClaims
    }
}
