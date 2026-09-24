import Foundation

/// Server-issued identity claims that establish who an account is (plan v3 §5, invariant 6).
/// Accounts are compared by these claims, never by email.
public struct PrincipalIdentity: Hashable, Codable, Sendable {
    /// Provider namespace, e.g. "arena".
    public let namespace: String
    /// Claim name → opaque value (e.g. `id`, `supabaseUserId`). All must match to be the same principal.
    public let claims: [String: String]

    public init(namespace: String, claims: [String: String]) {
        self.namespace = namespace
        self.claims = claims
    }
}

extension PrincipalIdentity: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "PrincipalIdentity(\(namespace), redacted)" }
    public var debugDescription: String { description }
}

/// Runtime authentication state of a local account. Not persisted: recomputed on each launch.
public enum AccountAuthState: String, Codable, Sendable {
    /// Not yet checked in this session.
    case unverified
    /// A saved session was verified against the account's principal.
    case signedIn
    /// No usable session (none saved, or the server rejected it). Sign in again.
    case needsSignIn
    /// The server returned a different principal. The session is discarded; nothing is written.
    case quarantined
    /// Verification failed for a transport reason; retry later.
    case unreachable
    /// Arena refused the request (403 or a challenge page). Nothing is retried; the saved session is kept.
    case blocked
}

/// A persisted local account. Holds no credentials or email; the Keychain holds session material.
public struct AccountRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: AccountID
    public var displayName: String
    public let principal: PrincipalIdentity
    public let createdAt: Date
    /// Increments on every successful sign-in, so operations can tell which session they used.
    public var credentialGeneration: UInt64

    public init(id: AccountID, displayName: String, principal: PrincipalIdentity, createdAt: Date, credentialGeneration: UInt64) {
        self.id = id
        self.displayName = displayName
        self.principal = principal
        self.createdAt = createdAt
        self.credentialGeneration = credentialGeneration
    }

    /// The immutable context captured when an operation starts (plan v3 §5, invariant 5).
    public var context: AccountContext {
        AccountContext(
            accountID: id,
            principal: PrincipalClaim(
                namespace: principal.namespace,
                opaqueID: principal.claims.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                    .joined(separator: "&"),
                evidence: EvidenceReference(
                    kind: .verifiedObservation, reference: "account-registry", scope: "server identity claims")),
            credentialGeneration: credentialGeneration)
    }
}
