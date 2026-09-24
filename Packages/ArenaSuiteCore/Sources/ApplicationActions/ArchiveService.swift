import ArchiveIndex
import CaptureJournal
import Foundation
import SuiteDomain

/// Decodes one journal record into neutral events. One versioned decoder per observed response
/// shape; the version tags the projection generation (plan v3 §10).
public protocol ArchiveDecoding: Sendable {
    var version: String { get }
    func decode(_ record: JournalRecord, account: AccountID) -> DecodedRecord
}

/// Replays journals into the rebuildable index (plan v3 §10). The journal is authoritative: this
/// service can delete the projection and rebuild it to identical entity IDs and content hashes.
public actor ArchiveService {
    private let index: ArchiveIndex
    private let journals: JournalStore
    private let decoder: any ArchiveDecoding
    private let accounts: @Sendable () -> [AccountID]

    public init(
        index: ArchiveIndex, journals: JournalStore, decoder: any ArchiveDecoding,
        accounts: @escaping @Sendable () -> [AccountID]
    ) {
        self.index = index
        self.journals = journals
        self.decoder = decoder
        self.accounts = accounts
    }

    /// Applies this account's journal from its checkpoint. If the stored projection version differs
    /// from the decoder's (and is not nil), rebuilds every account instead.
    public func project(_ account: AccountID) async throws -> Int {
        if let stored = try index.projectionVersion(), stored != decoder.version {
            let counts = try await rebuildAll()
            return counts[account] ?? 0
        }
        return try await applyRecords(account: account)
    }

    /// Deletes and recreates every projection table, then replays all accounts.
    public func rebuild() async throws {
        _ = try await rebuildAll()
    }

    public func rebuild(accounts: [AccountID]) async throws {
        _ = try await rebuildAll(accounts: accounts)
    }

    private func rebuildAll(accounts requested: [AccountID]? = nil) async throws -> [AccountID: Int] {
        try index.reset()
        var counts: [AccountID: Int] = [:]
        for account in requested ?? accounts() {
            counts[account] = try await applyRecords(account: account)
        }
        return counts
    }

    private func applyRecords(account: AccountID) async throws -> Int {
        let checkpoint = try index.checkpoint(for: account)
        let root = await journals.root(for: account)
        var pending: [(RecordRef, DecodedRecord)] = []
        var lastSequence = checkpoint
        var applied = 0
        try JournalReader(root: root).forEach { record in
            let sequence = record.envelope.sequence
            guard sequence > checkpoint else { return }
            let decoded = decoder.decode(record, account: account)
            pending.append(
                (
                    RecordRef(
                        account: account, sequence: sequence, segment: record.location.segment,
                        offset: record.location.offset, length: record.location.length),
                    decoded
                ))
            lastSequence = sequence
            if pending.count == Self.batchSize {
                try index.apply(
                    account: account, records: pending, through: lastSequence, decoderVersion: decoder.version)
                applied += pending.count
                pending.removeAll(keepingCapacity: true)
            }
        }
        if !pending.isEmpty {
            try index.apply(
                account: account, records: pending, through: lastSequence, decoderVersion: decoder.version)
            applied += pending.count
        }
        return applied
    }

    private static let batchSize = 200

    // MARK: Pass-through queries

    public nonisolated func checkpoint(for account: AccountID) throws -> UInt64 {
        try index.checkpoint(for: account)
    }

    public nonisolated func projectionVersion() throws -> String? {
        try index.projectionVersion()
    }

    public nonisolated func conversations(account: AccountID?) throws -> [ConversationSummary] {
        try index.conversations(account: account)
    }

    public nonisolated func conversation(
        account: AccountID, remoteID: String, snapshot: UInt64? = nil
    ) throws -> ConversationDetail? {
        try index.conversation(account: account, remoteID: remoteID, snapshot: snapshot)
    }

    public nonisolated func search(
        _ text: String, account: AccountID?, includeReasoningAndTools: Bool, limit: Int
    ) throws -> [SearchHit] {
        try index.search(
            text, account: account, includeReasoningAndTools: includeReasoningAndTools, limit: limit)
    }

    public nonisolated func unknownFields(account: AccountID?) throws -> [UnknownFieldCount] {
        try index.unknownFields(account: account)
    }

    public nonisolated func warnings(account: AccountID?) throws -> [IndexWarning] {
        try index.warnings(account: account)
    }

    /// The exact journal record behind a snapshot, read and digest-checked from the journal
    /// (never from the index). For the evidence inspector.
    public func rawEvidence(account: AccountID, snapshotSequence: UInt64) async throws -> RawEvidence? {
        guard let ref = try index.snapshotLocation(account: account, sequence: snapshotSequence) else { return nil }
        let root = await journals.root(for: account)
        let record = try JournalReader(root: root).read(
            at: JournalLocation(segment: ref.segment, offset: ref.offset, length: ref.length))
        guard record.envelope.sequence == snapshotSequence else { return nil }
        return RawEvidence(
            location: ref, envelope: record.envelopeBytes, payload: record.payload,
            digest: record.digest.map { String(format: "%02x", $0) }.joined(), decoderVersion: decoder.version)
    }

    public nonisolated func counts() throws -> [String: Int] {
        try index.counts()
    }

    public nonisolated func contentDigest() throws -> String {
        try index.contentDigest()
    }
}

public struct RawEvidence: Sendable, Equatable {
    public let location: RecordRef
    /// Stored envelope bytes (UTF-8 JSON); contains no credentials (plan v3 §7).
    public let envelope: Data
    /// Response body exactly as recorded. May contain `metadata` telemetry: show it only on request.
    public let payload: Data
    public let digest: String
    public let decoderVersion: String

    public init(location: RecordRef, envelope: Data, payload: Data, digest: String, decoderVersion: String) {
        self.location = location
        self.envelope = envelope
        self.payload = payload
        self.digest = digest
        self.decoderVersion = decoderVersion
    }
}
