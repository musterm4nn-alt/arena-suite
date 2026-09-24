import Foundation
import SuiteDomain

public enum CapabilityState: String, Codable, Sendable {
    case supported, unsupported, unknown
}

public struct CapabilityAssessment: Sendable {
    public let state: CapabilityState
    public let evidence: [EvidenceReference]
    public let lastValidatedAt: Date?

    public init(state: CapabilityState, evidence: [EvidenceReference], lastValidatedAt: Date?) {
        self.state = state
        self.evidence = evidence
        self.lastValidatedAt = lastValidatedAt
    }
}

/// Capability names are local application vocabulary, not Arena wire fields.
public enum Phase0Capability: String, CaseIterable, Sendable {
    case authenticate, refreshSession, verifyIdentity, createConversation, sendPrompt
    case streamResponse, stopRemoteGeneration, listHistory, getHistoryDetail
    case continueConversation, uploadAttachment, downloadWorkspace, revealModels
}

/// Only the capability seam is defined until observed contracts justify request/decoder APIs.
public protocol ArenaProtocolAdapter: Sendable {
    func capabilities(for account: AccountContext) async -> [Phase0Capability: CapabilityAssessment]
}

/// An inventory of unanswered research questions, not a transport implementation.
public enum Phase0CapabilityInventory {
    public static var assessments: [Phase0Capability: CapabilityAssessment] {
        Dictionary(
            uniqueKeysWithValues: Phase0Capability.allCases.map { capability in
                (
                    capability,
                    CapabilityAssessment(
                        state: .unknown,
                        evidence: [
                            EvidenceReference(
                                kind: .needsProtocolVerification,
                                reference: "Docs/protocol-ledger.md#\(capability.rawValue)",
                                scope: "Arena live and native behavior"
                            )
                        ],
                        lastValidatedAt: nil
                    )
                )
            })
    }
}
