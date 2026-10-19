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
