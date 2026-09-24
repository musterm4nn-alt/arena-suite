import Foundation

/// Evidence classification is not a claim of universal or current server support.
public enum EvidenceKind: String, Codable, CaseIterable, Sendable {
    case verifiedObservation = "verified_observation"
    case repositoryEvidence = "repository_evidence"
    case designDecision = "design_decision"
    case assumption
    case needsProtocolVerification = "NEEDS PROTOCOL VERIFICATION"
}

public struct EvidenceReference: Codable, Equatable, Sendable {
    public let kind: EvidenceKind
    /// A ledger/fixture ID or pinned source reference; never credentials or payload text.
    public let reference: String
    public let scope: String
    public let observedAt: Date?

    public init(kind: EvidenceKind, reference: String, scope: String, observedAt: Date? = nil) {
        self.kind = kind
        self.reference = reference
        self.scope = scope
        self.observedAt = observedAt
    }
}
