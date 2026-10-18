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
    /// nil in read-only mode: nothing can be projected, rebuilt or replayed.
    private let decoder: (any ArchiveDecoding)?
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

    /// Read-only access to an index opened with `ArchiveIndex(readingExistingAt:)` (plan v3 §14,
    /// read-only MCP). Queries, raw evidence and exports work; `project`, `rebuild` and
    /// `checkAgainstJournal` throw `ArchiveServiceError.readOnly`. The decoder version reported
    /// with evidence is the one recorded in the index, i.e. the one that built this projection.
    public init(readOnly index: ArchiveIndex, journals: JournalStore) {
        self.index = index
        self.journals = journals
        self.decoder = nil
        self.accounts = { [] }
    }

    private func requireDecoder() throws -> any ArchiveDecoding {
        guard let decoder else { throw ArchiveServiceError.readOnly }
        return decoder
    }

    /// Applies this account's journal from its checkpoint. If the stored projection version differs
    /// from the decoder's (and is not nil), rebuilds every account instead.
    public func project(_ account: AccountID) async throws -> Int {
        let decoder = try requireDecoder()
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
        _ = try requireDecoder()
        try index.reset()
        var counts: [AccountID: Int] = [:]
        for account in requested ?? accounts() {
            counts[account] = try await applyRecords(account: account)
        }
        return counts
    }

    /// `limit`: apply nothing past this sequence (for replays that must match a given checkpoint).
    private func applyRecords(account: AccountID, through limit: UInt64? = nil) async throws -> Int {
        let decoder = try requireDecoder()
        let checkpoint = try index.checkpoint(for: account)
        let root = journals.root(for: account)
        var pending: [(RecordRef, DecodedRecord)] = []
        var lastSequence = checkpoint
        var applied = 0
        try JournalReader(root: root).forEach { record in
            let sequence = record.envelope.sequence
            guard sequence > checkpoint, sequence <= (limit ?? .max) else { return }
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

    // MARK: Replay checks (plan v3 §13, Phase 7)

    /// Replays `accounts` from `journals` into a throwaway index under `scratch`, each account only
    /// through its entry in `limits` (all records if absent), and returns that index's content
    /// digest and counts. Never touches the live index. `scratch` is removed afterwards.
    public static func replay(
        journals: JournalStore, accounts: [AccountID], limits: [AccountID: UInt64]? = nil,
        decoder: any ArchiveDecoding, scratch: URL
    ) async throws -> (digest: String, counts: [String: Int]) {
        try? FileManager.default.removeItem(at: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let service = ArchiveService(
            index: try ArchiveIndex(url: scratch.appendingPathComponent("replay.sqlite")), journals: journals,
            decoder: decoder, accounts: { accounts })
        try await service.replayAll(accounts: accounts, limits: limits)
        return (try service.contentDigest(), try service.counts())
    }

    private func replayAll(accounts: [AccountID], limits: [AccountID: UInt64]?) async throws {
        _ = try requireDecoder()
        try index.reset()
        for account in accounts {
            let limit = limits.map { $0[account] ?? 0 }
            if limit == 0 { continue }
            _ = try await applyRecords(account: account, through: limit)
        }
    }

    /// Replays this archive's journals into a scratch index up to the live index's checkpoints and
    /// compares digests: equal means the live index is exactly what the journal produces.
    public func checkAgainstJournal(scratch: URL) async throws -> IndexCheck {
        let decoder = try requireDecoder()
        let live = try index.digestAndCheckpoints()
        let known = Set(accounts()).union(live.checkpoints.keys)
        let replayed = try await Self.replay(
            journals: journals, accounts: known.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString },
            limits: live.checkpoints, decoder: decoder, scratch: scratch)
        return IndexCheck(
            liveDigest: live.digest, replayDigest: replayed.digest, checkpoints: live.checkpoints,
            decoderVersion: decoder.version)
    }

    public nonisolated var decoderVersion: String {
        // Read-only: the version recorded by the projection; "unprojected" if nothing was projected.
        decoder?.version ?? (try? index.projectionVersion()).flatMap { $0 } ?? "unprojected"
    }

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
        return try await rawEvidence(at: ref)
    }

    /// The journal record at `ref`, read and digest-checked from `ref.account`'s journal. nil when
    /// the record there does not carry `ref.sequence`.
    public func rawEvidence(at ref: RecordRef) async throws -> RawEvidence? {
        let record = try JournalReader(root: journals.root(for: ref.account)).read(
            at: JournalLocation(segment: ref.segment, offset: ref.offset, length: ref.length))
        guard record.envelope.sequence == ref.sequence else { return nil }
        return RawEvidence(
            location: ref, envelope: record.envelopeBytes, payload: record.payload,
            digest: record.digest.map { String(format: "%02x", $0) }.joined(), decoderVersion: decoderVersion)
    }

    /// One frozen view of the projection for dataset building (plan v3 §14).
    public nonisolated func datasetSource(accounts: Set<AccountID>? = nil) throws -> DatasetSource {
        try index.datasetSource(accounts: accounts)
    }

    public nonisolated func counts() throws -> [String: Int] {
        try index.counts()
    }

    public nonisolated func contentDigest() throws -> String {
        try index.contentDigest()
    }
}

public enum ArchiveServiceError: Error, Equatable, Sendable {
    /// The service was opened read-only and was asked to project, rebuild or replay.
    case readOnly
}

/// Result of `ArchiveService.checkAgainstJournal`.
public struct IndexCheck: Sendable, Equatable {
    public let liveDigest: String
    public let replayDigest: String
    /// Live index checkpoint per account (the replay stopped at the same sequences).
    public let checkpoints: [AccountID: UInt64]
    public let decoderVersion: String
    public var matches: Bool { liveDigest == replayDigest }
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
