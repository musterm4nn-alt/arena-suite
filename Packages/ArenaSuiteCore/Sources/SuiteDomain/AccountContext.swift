import Foundation

public struct AccountID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// An observed identity claim, not a verified account registry entry.
/// Native acceptance still requires the live identity gate in Docs/phase-0.md.
public struct PrincipalClaim: Equatable, Codable, Sendable {
    public let namespace: String
    public let opaqueID: String
    public let evidence: EvidenceReference

    public init(namespace: String, opaqueID: String, evidence: EvidenceReference) {
        self.namespace = namespace
        self.opaqueID = opaqueID
        self.evidence = evidence
    }
}

/// Value snapshot captured at operation creation. Contains no credential material.
public struct AccountContext: Equatable, Codable, Sendable {
    public let accountID: AccountID
    public let principal: PrincipalClaim?
    public let credentialGeneration: UInt64

    public init(accountID: AccountID, principal: PrincipalClaim?, credentialGeneration: UInt64) {
        self.accountID = accountID
        self.principal = principal
        self.credentialGeneration = credentialGeneration
    }
}

public struct OperationContext: Equatable, Sendable {
    public let operationID: UUID
    public let account: AccountContext

    public init(operationID: UUID = UUID(), account: AccountContext) {
        self.operationID = operationID
        self.account = account
    }
}
