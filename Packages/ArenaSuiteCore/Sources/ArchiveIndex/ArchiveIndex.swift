import CryptoKit
import Foundation
import GRDB
import SuiteDomain

// Rebuildable SQLite projection (plan v3 §8, §10). GRDB stays behind this typed API; every stored
// value traces back to a journal `RecordRef`. The append-only journal is authoritative: this index
// can be deleted and replayed to identical entity IDs and content hashes (`contentDigest`).

// MARK: - Query results

public struct ConversationSummary: Sendable, Equatable {
    public let account: AccountID
    public let remoteID: String
    public let kind: String
    public let title: String?
    public let mode: String?
    public let modality: String?
    public let updatedAt: String?
    /// `updatedAt` as the decoder parsed it (microseconds since 1970), the key the list is sorted
    /// by; nil when it could not be parsed. Views group by this rather than parsing again.
    public let updatedOrder: Int64?
    public let snapshotCount: Int
    public let latestSnapshotSequence: UInt64?
    public let messageCount: Int
    public let isAbsent: Bool

    public init(
        account: AccountID, remoteID: String, kind: String, title: String?, mode: String?, modality: String?,
        updatedAt: String?, snapshotCount: Int, latestSnapshotSequence: UInt64?, messageCount: Int, isAbsent: Bool,
        updatedOrder: Int64? = nil
    ) {
        self.account = account
        self.remoteID = remoteID
        self.kind = kind
        self.title = title
        self.mode = mode
        self.modality = modality
        self.updatedAt = updatedAt
        self.updatedOrder = updatedOrder
        self.snapshotCount = snapshotCount
        self.latestSnapshotSequence = latestSnapshotSequence
        self.messageCount = messageCount
        self.isAbsent = isAbsent
    }
}

public struct DetailBlock: Sendable, Equatable {
    public let kind: BlockKind
    public let text: String?
    public let toolName: String?
    public let toolCallID: String?
    public let payload: String?
    /// JSON path of the block inside its snapshot's raw body (for the evidence inspector).
    public let pointer: String

    public init(kind: BlockKind, text: String?, toolName: String?, toolCallID: String?, payload: String?, pointer: String = "") {
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.payload = payload
        self.pointer = pointer
    }
}

public struct DetailMessage: Sendable, Equatable {
    public let remoteID: String
    public let role: String?
    public let status: String?
    public let lane: String?
    public let parentIDs: [String]
    public let modelRemoteID: String?
    public let createdAt: String?
    public let blocks: [DetailBlock]
    public let attachments: [ArchivedAttachment]

    public init(
        remoteID: String, role: String?, status: String?, lane: String?, parentIDs: [String], modelRemoteID: String?,
        createdAt: String?, blocks: [DetailBlock], attachments: [ArchivedAttachment]
    ) {
        self.remoteID = remoteID
        self.role = role
        self.status = status
        self.lane = lane
        self.parentIDs = parentIDs
        self.modelRemoteID = modelRemoteID
        self.createdAt = createdAt
        self.blocks = blocks
        self.attachments = attachments
    }
}

public struct ConversationDetail: Sendable, Equatable {
    public let summary: ConversationSummary
    public let snapshotSequences: [UInt64]
    public let messages: [DetailMessage]
    public let claims: [ModelClaim]
    public let feedback: [ArchivedFeedback]

    public init(
        summary: ConversationSummary, snapshotSequences: [UInt64], messages: [DetailMessage], claims: [ModelClaim],
        feedback: [ArchivedFeedback]
    ) {
        self.summary = summary
        self.snapshotSequences = snapshotSequences
        self.messages = messages
        self.claims = claims
        self.feedback = feedback
    }
}

public struct SearchHit: Sendable, Equatable {
    public let account: AccountID
    public let conversationID: String
    public let title: String?
    public let messageID: String
    public let kind: String
    public let snippet: String

    public init(account: AccountID, conversationID: String, title: String?, messageID: String, kind: String, snippet: String) {
        self.account = account
        self.conversationID = conversationID
        self.title = title
        self.messageID = messageID
        self.kind = kind
        self.snippet = snippet
    }
}

public struct IndexWarning: Sendable, Equatable, Hashable {
    public let sequence: UInt64
    public let code: String
    public let detail: String
}

public struct UnknownFieldCount: Sendable, Equatable, Hashable {
    public let path: String
    public let count: Int

    public init(path: String, count: Int) {
        self.path = path
        self.count = count
    }
}

// MARK: - Index

public final class ArchiveIndex: Sendable {
    private let pool: DatabasePool

    public enum OpenError: Error, Equatable {
        case symlink(String)
        case permissions(String, Int32)
    }

    /// Opens (creating if needed) the index at `url`. On every open the directory is tightened to
    /// 0700 and the database with its `-wal`/`-shm` files to 0600 (plan v3 §2); symlinks are refused
    /// and any failure throws rather than leaving private content readable.
    public init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try Self.tighten(directory.path, to: 0o700, directory: true)
        for suffix in ["", "-wal", "-shm"] { try Self.tighten(url.path + suffix, to: 0o600, directory: false) }
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        try Self.migrator.migrate(pool)
        self.pool = pool
        for suffix in ["", "-wal", "-shm"] { try Self.tighten(url.path + suffix, to: 0o600, directory: false) }
    }

    public enum ReadOnlyOpenError: Error, Equatable {
        case missing(String)
        case notOwnerOnly(String)
        case schemaNotReady
    }

    /// Opens an existing index for reading only (plan v3 §14, read-only MCP): SQLite refuses every
    /// write on this connection, and nothing is created, migrated or re-permissioned. Symlinks and
    /// files readable by others are refused rather than tightened, because tightening is a write.
    public init(readingExistingAt url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try Self.check(directory.path, mode: 0o700, directory: true, required: true)
        try Self.check(url.path, mode: 0o600, directory: false, required: true)
        for suffix in ["-wal", "-shm"] { try Self.check(url.path + suffix, mode: 0o600, directory: false, required: false) }
        var configuration = Configuration()
        configuration.readonly = true
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        guard try pool.read({ try Self.migrator.hasCompletedMigrations($0) }) else {
            throw ReadOnlyOpenError.schemaNotReady
        }
        self.pool = pool
    }

    /// Like `tighten`, but only checks: `required` paths must exist, and none may be a symlink,
    /// the wrong type, or carry permission bits beyond `mode`.
    static func check(_ path: String, mode: mode_t, directory: Bool, required: Bool) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT {
                if required { throw ReadOnlyOpenError.missing(path) }
                return
            }
            throw OpenError.permissions(path, errno)
        }
        let type = info.st_mode & S_IFMT
        guard type != S_IFLNK else { throw OpenError.symlink(path) }
        guard type == (directory ? S_IFDIR : S_IFREG) else { throw OpenError.permissions(path, EFTYPE) }
        guard info.st_mode & 0o7777 & ~mode == 0 else { throw ReadOnlyOpenError.notOwnerOnly(path) }
    }

    /// Missing paths are fine (created later); existing ones must be the right type, not symlinks,
    /// and end up with exactly `mode`.
    static func tighten(_ path: String, to mode: mode_t, directory: Bool) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw OpenError.permissions(path, errno)
        }
        let type = info.st_mode & S_IFMT
        guard type != S_IFLNK else { throw OpenError.symlink(path) }
        guard type == (directory ? S_IFDIR : S_IFREG) else { throw OpenError.permissions(path, EFTYPE) }
        if info.st_mode & 0o7777 != mode, chmod(path, mode) != 0 { throw OpenError.permissions(path, errno) }
    }

    // MARK: Schema

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in try createSchema(db) }
        return migrator
    }()

    /// Every user table this module owns, in digest order. FTS shadow tables and SQLite internals
    /// are never named here and are therefore never hashed.
    private static let digestTables = [
        "meta", "checkpoints", "conversations", "snapshots", "messages", "message_parents", "blocks",
        "attachments", "model_claims", "feedback", "unknown_fields", "warnings", "search",
    ]

    /// Full primary key of each table; `search` (FTS5) has no primary key, so all its columns.
    private static let digestOrder: [String: String] = [
        "meta": "key",
        "checkpoints": "account_id",
        "conversations": "account_id, remote_id",
        "snapshots": "account_id, seq",
        "messages": "account_id, snapshot_seq, remote_id",
        "message_parents": "account_id, snapshot_seq, message_id, ordinal",
        "blocks": "account_id, snapshot_seq, message_id, ordinal",
        "attachments": "account_id, snapshot_seq, message_id, ordinal",
        "model_claims": "account_id, seq, subject, subject_id, role, source, model_id",
        "feedback": "account_id, snapshot_seq, remote_id",
        "unknown_fields": "account_id, path",
        "warnings": "account_id, seq, ordinal",
        "search": "text, account_id, conversation_id, snapshot_seq, message_id, kind",
    ]

    private static func createSchema(_ db: Database) throws {
        try db.create(table: "meta") { t in
            t.primaryKey("key", .text)
            t.column("value", .text)
        }
        try db.create(table: "checkpoints") { t in
            t.primaryKey("account_id", .text)
            t.column("last_sequence", .integer).notNull()
        }
        try db.create(table: "conversations") { t in
            t.column("account_id", .text).notNull()
            t.column("remote_id", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("title", .text)
            t.column("mode", .text)
            t.column("modality", .text)
            t.column("visibility", .text)
            t.column("created_at", .text)
            t.column("updated_at", .text)
            t.column("updated_order", .integer)
            t.column("archived_at", .text)
            t.column("deleted_at", .text)
            t.column("first_seen_seq", .integer).notNull()
            t.column("last_seen_seq", .integer).notNull()
            t.column("latest_snapshot_seq", .integer)
            t.column("absent_seq", .integer)
            t.primaryKey(["account_id", "remote_id"])
        }
        try db.create(table: "snapshots") { t in
            t.column("account_id", .text).notNull()
            t.column("seq", .integer).notNull()
            t.column("remote_id", .text).notNull()
            t.column("segment", .integer).notNull()
            t.column("record_offset", .integer).notNull()
            t.column("record_length", .integer).notNull()
            t.column("updated_at", .text)
            t.column("title", .text)
            t.column("message_count", .integer).notNull()
            t.column("last_message_ids", .text)
            t.primaryKey(["account_id", "seq"])
        }
        try db.create(table: "messages") { t in
            t.column("account_id", .text).notNull()
            t.column("snapshot_seq", .integer).notNull()
            t.column("remote_id", .text).notNull()
            t.column("conversation_id", .text).notNull()
            t.column("ordinal", .integer).notNull()
            t.column("role", .text)
            t.column("status", .text)
            t.column("lane", .text)
            t.column("model_remote_id", .text)
            t.column("created_at", .text)
            t.column("updated_at", .text)
            t.column("failure_reason", .text)
            t.primaryKey(["account_id", "snapshot_seq", "remote_id"])
        }
        try db.create(table: "message_parents") { t in
            t.column("account_id", .text).notNull()
            t.column("snapshot_seq", .integer).notNull()
            t.column("message_id", .text).notNull()
            t.column("ordinal", .integer).notNull()
            t.column("parent_id", .text).notNull()
            t.primaryKey(["account_id", "snapshot_seq", "message_id", "ordinal"])
        }
        try db.create(table: "blocks") { t in
            t.column("account_id", .text).notNull()
            t.column("snapshot_seq", .integer).notNull()
            t.column("message_id", .text).notNull()
            t.column("ordinal", .integer).notNull()
            t.column("kind", .text).notNull()
            t.column("text", .text)
            t.column("tool_name", .text)
            t.column("tool_call_id", .text)
            t.column("payload", .text)
            t.column("pointer", .text).notNull()
            t.primaryKey(["account_id", "snapshot_seq", "message_id", "ordinal"])
        }
        try db.create(table: "attachments") { t in
            t.column("account_id", .text).notNull()
            t.column("snapshot_seq", .integer).notNull()
            t.column("message_id", .text).notNull()
            t.column("ordinal", .integer).notNull()
            t.column("name", .text)
            t.column("content_type", .text)
            t.column("has_url", .integer).notNull()
            t.primaryKey(["account_id", "snapshot_seq", "message_id", "ordinal"])
        }
        try db.create(table: "model_claims") { t in
            t.column("account_id", .text).notNull()
            t.column("seq", .integer).notNull()
            t.column("conversation_id", .text).notNull()
            t.column("subject", .text).notNull()
            t.column("subject_id", .text).notNull()
            t.column("role", .text).notNull().defaults(to: "")
            t.column("model_id", .text).notNull()
            t.column("display_name", .text)
            t.column("organization", .text)
            t.column("provider", .text)
            t.column("source", .text).notNull()
            t.primaryKey(["account_id", "seq", "subject", "subject_id", "role", "source", "model_id"])
        }
        try db.create(table: "feedback") { t in
            t.column("account_id", .text).notNull()
            t.column("snapshot_seq", .integer).notNull()
            t.column("remote_id", .text).notNull()
            t.column("value", .text)
            t.column("message_a", .text)
            t.column("message_b", .text)
            t.primaryKey(["account_id", "snapshot_seq", "remote_id"])
        }
        try db.create(table: "unknown_fields") { t in
            t.column("account_id", .text).notNull()
            t.column("path", .text).notNull()
            t.column("count", .integer).notNull()
            t.column("first_seq", .integer).notNull()
            t.column("last_seq", .integer).notNull()
            t.primaryKey(["account_id", "path"])
        }
        try db.create(table: "warnings") { t in
            t.column("account_id", .text).notNull()
            t.column("seq", .integer).notNull()
            t.column("ordinal", .integer).notNull()
            t.column("code", .text).notNull()
            t.column("detail", .text)
            t.primaryKey(["account_id", "seq", "ordinal"])
        }
        try db.create(virtualTable: "search", using: FTS5()) { t in
            t.column("text")
            t.column("account_id").notIndexed()
            t.column("conversation_id").notIndexed()
            t.column("snapshot_seq").notIndexed()
            t.column("message_id").notIndexed()
            t.column("kind").notIndexed()
            t.tokenizer = .unicode61(diacritics: .remove)
        }
    }

    /// Drops and recreates every table in one transaction. Used to rebuild from the journal.
    public func reset() throws {
        try pool.write { db in
            for table in Self.digestTables {
                try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
            }
            try Self.createSchema(db)
        }
    }

    // MARK: Checkpoint / version

    public func checkpoint(for account: AccountID) throws -> UInt64 {
        try pool.read { db in try Self.checkpoint(db, accountID: account.rawValue.uuidString) }
    }

    private static func checkpoint(_ db: Database, accountID: String) throws -> UInt64 {
        let row = try Row.fetchOne(
            db, sql: "SELECT last_sequence FROM checkpoints WHERE account_id = :account",
            arguments: args(["account": accountID]))
        guard let row else { return 0 }
        let value: Int64 = row["last_sequence"]
        return UInt64(value)
    }

    public func projectionVersion() throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'decoder_version'")
        }
    }

    // MARK: Apply

    /// Applies decoded records in one write transaction, then advances the checkpoint and records
    /// the decoder version. Records at or below the account's current checkpoint are skipped.
    public func apply(
        account: AccountID, records: [(RecordRef, DecodedRecord)], through sequence: UInt64, decoderVersion: String
    ) throws {
        try pool.write { db in
            let accountID = account.rawValue.uuidString
            let checkpoint = try Self.checkpoint(db, accountID: accountID)
            for (ref, decoded) in records where ref.sequence > checkpoint {
                try Self.apply(decoded, ref: ref, accountID: accountID, db: db)
            }
            // MAX keeps a stale replay from regressing the checkpoint (idempotent replays).
            try db.execute(
                sql: """
                    INSERT INTO checkpoints (account_id, last_sequence) VALUES (:account, :sequence)
                    ON CONFLICT(account_id) DO UPDATE SET
                      last_sequence = MAX(checkpoints.last_sequence, excluded.last_sequence)
                    """,
                arguments: args(["account": accountID, "sequence": Int64(sequence)]))
            try db.execute(
                sql: """
                    INSERT INTO meta (key, value) VALUES ('decoder_version', :version)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: args(["version": decoderVersion]))
        }
    }

    private static func apply(_ decoded: DecodedRecord, ref: RecordRef, accountID: String, db: Database) throws {
        let seq = Int64(ref.sequence)
        var warningOrdinal = 0
        for event in decoded.events {
            switch event {
            case .listed(let facts, let claims):
                try upsertConversation(db, accountID: accountID, facts: facts, seq: seq, snapshot: false)
                for claim in claims {
                    try insertClaim(db, accountID: accountID, seq: seq, conversationID: facts.remoteID, claim: claim)
                }
            case .snapshot(let snapshot):
                try insertSnapshot(db, accountID: accountID, ref: ref, snapshot: snapshot, seq: seq)
                try upsertConversation(db, accountID: accountID, facts: snapshot.facts, seq: seq, snapshot: true)
                for claim in snapshot.claims {
                    try insertClaim(
                        db, accountID: accountID, seq: seq, conversationID: snapshot.facts.remoteID, claim: claim)
                }
                try replaceSearch(db, accountID: accountID, snapshot: snapshot, seq: seq)
            case .absent(let remoteID):
                try db.execute(
                    sql: """
                        INSERT INTO conversations
                          (account_id, remote_id, kind, first_seen_seq, last_seen_seq, absent_seq)
                        VALUES (:account, :remote, '[unknown]', :seq, :seq, :seq)
                        ON CONFLICT(account_id, remote_id) DO UPDATE SET
                          absent_seq = excluded.absent_seq, last_seen_seq = excluded.last_seen_seq
                        """,
                    arguments: args(["account": accountID, "remote": remoteID, "seq": seq]))
            case .warning(let code, let detail):
                try db.execute(
                    sql: """
                        INSERT INTO warnings (account_id, seq, ordinal, code, detail)
                        VALUES (:account, :seq, :ordinal, :code, :detail)
                        """,
                    arguments: args([
                        "account": accountID, "seq": seq, "ordinal": warningOrdinal, "code": code, "detail": detail,
                    ]))
                warningOrdinal += 1
            }
        }
        for (path, count) in decoded.unknownFields {
            try db.execute(
                sql: """
                    INSERT INTO unknown_fields (account_id, path, count, first_seq, last_seq)
                    VALUES (:account, :path, :count, :seq, :seq)
                    ON CONFLICT(account_id, path) DO UPDATE SET
                      count = unknown_fields.count + excluded.count,
                      first_seq = MIN(unknown_fields.first_seq, excluded.first_seq),
                      last_seq = MAX(unknown_fields.last_seq, excluded.last_seq)
                    """,
                arguments: args(["account": accountID, "path": path, "count": count, "seq": seq]))
        }
    }

    private static let conversationColumns =
        "account_id, remote_id, kind, title, mode, modality, visibility, created_at, updated_at, updated_order, archived_at, deleted_at, first_seen_seq, last_seen_seq, latest_snapshot_seq, absent_seq"

    private static func upsertConversation(
        _ db: Database, accountID: String, facts: ConversationFacts, seq: Int64, snapshot: Bool
    ) throws {
        let latest = snapshot ? "excluded.latest_snapshot_seq" : "conversations.latest_snapshot_seq"
        // Listing or a snapshot is a presence observation: it supersedes an earlier 404.
        let absent = "NULL"
        try db.execute(
            sql: """
                INSERT INTO conversations (\(conversationColumns))
                VALUES (:account, :remote, :kind, :title, :mode, :modality, :visibility, :created, :updated,
                        :updated_order, :archived, :deleted, :seq, :seq, :latest, :absent)
                ON CONFLICT(account_id, remote_id) DO UPDATE SET
                  kind = excluded.kind,
                  title = COALESCE(excluded.title, conversations.title),
                  mode = COALESCE(excluded.mode, conversations.mode),
                  modality = COALESCE(excluded.modality, conversations.modality),
                  visibility = COALESCE(excluded.visibility, conversations.visibility),
                  created_at = COALESCE(excluded.created_at, conversations.created_at),
                  updated_at = COALESCE(excluded.updated_at, conversations.updated_at),
                  updated_order = COALESCE(excluded.updated_order, conversations.updated_order),
                  archived_at = COALESCE(excluded.archived_at, conversations.archived_at),
                  deleted_at = COALESCE(excluded.deleted_at, conversations.deleted_at),
                  last_seen_seq = excluded.last_seen_seq,
                  latest_snapshot_seq = \(latest),
                  absent_seq = \(absent)
                """,
            arguments: args([
                "account": accountID,
                "remote": facts.remoteID,
                "kind": facts.kind,
                "title": facts.title as Any,
                "mode": facts.mode as Any,
                "modality": facts.modality as Any,
                "visibility": facts.visibility as Any,
                "created": facts.createdAt as Any,
                "updated": facts.updatedAt as Any,
                "updated_order": facts.updatedOrder as Any,
                "archived": facts.archivedAt as Any,
                "deleted": facts.deletedAt as Any,
                "seq": seq,
                "latest": snapshot ? seq : (Optional<Int64>.none as Any),
                "absent": Optional<Int64>.none as Any,
            ]))
    }

    private static func insertSnapshot(
        _ db: Database, accountID: String, ref: RecordRef, snapshot: ConversationSnapshot, seq: Int64
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lastMessageIDs = String(data: (try? encoder.encode(snapshot.lastMessageIDs)) ?? Data("[]".utf8), encoding: .utf8)
        try db.execute(
            sql: """
                INSERT INTO snapshots
                  (account_id, seq, remote_id, segment, record_offset, record_length, updated_at, title,
                   message_count, last_message_ids)
                VALUES (:account, :seq, :remote, :segment, :offset, :length, :updated, :title, :count, :last_ids)
                """,
            arguments: args([
                "account": accountID,
                "seq": seq,
                "remote": snapshot.facts.remoteID,
                "segment": ref.segment,
                "offset": ref.offset,
                "length": ref.length,
                "updated": snapshot.facts.updatedAt as Any,
                "title": snapshot.facts.title as Any,
                "count": snapshot.messages.count,
                "last_ids": lastMessageIDs as Any,
            ]))
        for (ordinal, message) in snapshot.messages.enumerated() {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO messages
                      (account_id, snapshot_seq, remote_id, conversation_id, ordinal, role, status, lane,
                       model_remote_id, created_at, updated_at, failure_reason)
                    VALUES (:account, :seq, :remote, :conversation, :ordinal, :role, :status, :lane, :model,
                            :created, :updated, :failure)
                    """,
                arguments: args([
                    "account": accountID,
                    "seq": seq,
                    "remote": message.remoteID,
                    "conversation": snapshot.facts.remoteID,
                    "ordinal": ordinal,
                    "role": message.role as Any,
                    "status": message.status as Any,
                    "lane": message.lane as Any,
                    "model": message.modelRemoteID as Any,
                    "created": message.createdAt as Any,
                    "updated": message.updatedAt as Any,
                    "failure": message.failureReason as Any,
                ]))
            for (parentOrdinal, parentID) in message.parentIDs.enumerated() {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO message_parents (account_id, snapshot_seq, message_id, ordinal, parent_id)
                        VALUES (:account, :seq, :message, :ordinal, :parent)
                        """,
                    arguments: args([
                        "account": accountID, "seq": seq, "message": message.remoteID, "ordinal": parentOrdinal,
                        "parent": parentID,
                    ]))
            }
            for (blockOrdinal, block) in message.blocks.enumerated() {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO blocks
                          (account_id, snapshot_seq, message_id, ordinal, kind, text, tool_name, tool_call_id,
                           payload, pointer)
                        VALUES (:account, :seq, :message, :ordinal, :kind, :text, :tool, :call, :payload, :pointer)
                        """,
                    arguments: args([
                        "account": accountID, "seq": seq, "message": message.remoteID, "ordinal": blockOrdinal,
                        "kind": block.kind.rawValue, "text": block.text as Any, "tool": block.toolName as Any,
                        "call": block.toolCallID as Any, "payload": block.payload as Any, "pointer": block.pointer,
                    ]))
            }
            for (attachmentOrdinal, attachment) in message.attachments.enumerated() {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO attachments
                          (account_id, snapshot_seq, message_id, ordinal, name, content_type, has_url)
                        VALUES (:account, :seq, :message, :ordinal, :name, :content_type, :has_url)
                        """,
                    arguments: args([
                        "account": accountID, "seq": seq, "message": message.remoteID, "ordinal": attachmentOrdinal,
                        "name": attachment.name as Any, "content_type": attachment.contentType as Any,
                        "has_url": attachment.hasURL ? 1 : 0,
                    ]))
            }
        }
        for feedback in snapshot.feedback {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO feedback
                      (account_id, snapshot_seq, remote_id, value, message_a, message_b)
                    VALUES (:account, :seq, :remote, :value, :message_a, :message_b)
                    """,
                arguments: args([
                    "account": accountID, "seq": seq, "remote": feedback.remoteID, "value": feedback.value as Any,
                    "message_a": feedback.messageA as Any, "message_b": feedback.messageB as Any,
                ]))
        }
    }

    private static func insertClaim(
        _ db: Database, accountID: String, seq: Int64, conversationID: String, claim: ModelClaim
    ) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO model_claims
                  (account_id, seq, conversation_id, subject, subject_id, role, model_id, display_name,
                   organization, provider, source)
                VALUES (:account, :seq, :conversation, :subject, :subject_id, :role, :model_id, :display,
                        :organization, :provider, :source)
                """,
            arguments: args([
                "account": accountID, "seq": seq, "conversation": conversationID, "subject": claim.subject.rawValue,
                "subject_id": claim.subjectID, "role": claim.role ?? "", "model_id": claim.modelID,
                "display": claim.displayName as Any, "organization": claim.organization as Any,
                "provider": claim.provider as Any, "source": claim.source,
            ]))
    }

    private static func replaceSearch(
        _ db: Database, accountID: String, snapshot: ConversationSnapshot, seq: Int64
    ) throws {
        try db.execute(
            sql: "DELETE FROM search WHERE account_id = :account AND conversation_id = :conversation",
            arguments: args(["account": accountID, "conversation": snapshot.facts.remoteID]))
        for message in snapshot.messages {
            for block in message.blocks {
                guard let indexable = indexableText(for: block), !indexable.isEmpty else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO search (text, account_id, conversation_id, snapshot_seq, message_id, kind)
                        VALUES (:text, :account, :conversation, :seq, :message, :kind)
                        """,
                    arguments: args([
                        "text": indexable, "account": accountID, "conversation": snapshot.facts.remoteID,
                        "seq": seq, "message": message.remoteID, "kind": block.kind.rawValue,
                    ]))
            }
        }
    }

    private static func indexableText(for block: ArchivedBlock) -> String? {
        switch block.kind {
        case .text, .reasoning: return block.text
        case .toolCall, .toolResult, .sources: return block.payload
        case .opaque: return nil
        }
    }

    // MARK: Queries

    public func conversations(account: AccountID?) throws -> [ConversationSummary] {
        try pool.read { db in
            var sql = Self.summarySelect
            if account != nil { sql += " WHERE c.account_id = :account" }
            sql += " ORDER BY c.updated_order DESC NULLS LAST, c.account_id, c.remote_id"
            let rows = try Row.fetchAll(
                db, sql: sql,
                arguments: args(account.map { ["account": $0.rawValue.uuidString] } ?? [:]))
            return rows.compactMap(Self.summary(from:))
        }
    }

    public func conversation(account: AccountID, remoteID: String, snapshot: UInt64? = nil) throws -> ConversationDetail? {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db, sql: Self.summarySelect + " WHERE c.account_id = :account AND c.remote_id = :remote",
                arguments: args(["account": account.rawValue.uuidString, "remote": remoteID]))
            guard let summary = rows.compactMap(Self.summary(from:)).first else { return nil }

            let sequences = try UInt64.fetchAll(
                db, sql: "SELECT seq FROM snapshots WHERE account_id = :account AND remote_id = :remote ORDER BY seq",
                arguments: args(["account": account.rawValue.uuidString, "remote": remoteID]))
            let target = snapshot ?? summary.latestSnapshotSequence
            var messages: [DetailMessage] = []
            if let target {
                let messageRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT remote_id, role, status, lane, model_remote_id, created_at
                        FROM messages
                        WHERE account_id = :account AND snapshot_seq = :seq
                        ORDER BY ordinal
                        """,
                    arguments: args(["account": account.rawValue.uuidString, "seq": Int64(target)]))
                for row in messageRows {
                    let messageID: String = row["remote_id"]
                    messages.append(
                        DetailMessage(
                            remoteID: messageID,
                            role: row["role"],
                            status: row["status"],
                            lane: row["lane"],
                            parentIDs: try Self.parents(db, accountID: account.rawValue.uuidString, seq: target, messageID: messageID),
                            modelRemoteID: row["model_remote_id"],
                            createdAt: row["created_at"],
                            blocks: try Self.blocks(db, accountID: account.rawValue.uuidString, seq: target, messageID: messageID),
                            attachments: try Self.attachments(db, accountID: account.rawValue.uuidString, seq: target, messageID: messageID)))
                }
            }

            let claimRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT subject, subject_id, role, model_id, display_name, organization, provider, source
                    FROM model_claims
                    WHERE account_id = :account AND conversation_id = :remote
                    ORDER BY seq, subject, subject_id, role, source, model_id
                    """,
                arguments: args(["account": account.rawValue.uuidString, "remote": remoteID]))
            let claims = claimRows.compactMap { row -> ModelClaim? in
                // Subjects are an open set: a kind written by a newer decoder is returned, not dropped.
                let subject = ModelClaim.Subject(rawValue: row["subject"])
                let role: String = row["role"]
                return ModelClaim(
                    subject: subject, subjectID: row["subject_id"], role: role.isEmpty ? nil : role,
                    modelID: row["model_id"], displayName: row["display_name"], organization: row["organization"],
                    provider: row["provider"], source: row["source"])
            }

            var feedback: [ArchivedFeedback] = []
            if let target {
                let feedbackRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT remote_id, value, message_a, message_b FROM feedback
                        WHERE account_id = :account AND snapshot_seq = :seq ORDER BY remote_id
                        """,
                    arguments: args(["account": account.rawValue.uuidString, "seq": Int64(target)]))
                feedback = feedbackRows.map {
                    ArchivedFeedback(
                        remoteID: $0["remote_id"], value: $0["value"], messageA: $0["message_a"],
                        messageB: $0["message_b"])
                }
            }

            return ConversationDetail(
                summary: summary, snapshotSequences: sequences, messages: messages, claims: claims, feedback: feedback)
        }
    }

    public func search(
        _ text: String, account: AccountID?, includeReasoningAndTools: Bool, limit: Int
    ) throws -> [SearchHit] {
        guard limit > 0, let pattern = FTS5Pattern(matchingAllTokensIn: text) else { return [] }
        let limit = min(limit, 1_000)
        return try pool.read { db in
            var sql = """
                SELECT search.account_id AS account_id, search.conversation_id AS conversation_id,
                       c.title AS title, search.message_id AS message_id, search.kind AS kind,
                       snippet(search, 0, '[', ']', '...', 12) AS snippet
                FROM search
                LEFT JOIN conversations c
                  ON c.account_id = search.account_id AND c.remote_id = search.conversation_id
                WHERE search MATCH ?
                """
            var arguments: [any DatabaseValueConvertible?] = [pattern]
            if let account {
                sql += " AND search.account_id = ?"
                arguments.append(account.rawValue.uuidString)
            }
            if !includeReasoningAndTools {
                sql += " AND search.kind = 'text'"
            }
            sql += " ORDER BY search.account_id, search.conversation_id, search.message_id, search.kind LIMIT ?"
            arguments.append(limit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return rows.compactMap { row -> SearchHit? in
                let accountID: String = row["account_id"]
                guard let uuid = UUID(uuidString: accountID) else { return nil }
                return SearchHit(
                    account: AccountID(rawValue: uuid), conversationID: row["conversation_id"], title: row["title"],
                    messageID: row["message_id"], kind: row["kind"], snippet: row["snippet"])
            }
        }
    }

    /// Where a snapshot's raw evidence lives in the account journal.
    public func snapshotLocation(account: AccountID, sequence: UInt64) throws -> RecordRef? {
        try pool.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT segment, record_offset, record_length FROM snapshots WHERE account_id = ? AND seq = ?",
                    arguments: [account.rawValue.uuidString, Int64(sequence)])
            else { return nil }
            return RecordRef(
                account: account, sequence: sequence, segment: row["segment"], offset: row["record_offset"],
                length: row["record_length"])
        }
    }

    public func warnings(account: AccountID?) throws -> [IndexWarning] {
        try pool.read { db in
            var sql = "SELECT account_id, seq, code, detail FROM warnings"
            var arguments: [any DatabaseValueConvertible] = []
            if let account {
                sql += " WHERE account_id = ?"
                arguments.append(account.rawValue.uuidString)
            }
            sql += " ORDER BY account_id, seq, ordinal"
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map {
                IndexWarning(sequence: UInt64($0["seq"] as Int64), code: $0["code"], detail: $0["detail"])
            }
        }
    }

    public func unknownFields(account: AccountID?) throws -> [UnknownFieldCount] {
        try pool.read { db in
            var sql = "SELECT path, count FROM unknown_fields"
            if account != nil { sql += " WHERE account_id = :account" }
            sql += " ORDER BY path"
            let rows = try Row.fetchAll(
                db, sql: sql, arguments: args(account.map { ["account": $0.rawValue.uuidString] } ?? [:]))
            return rows.map { UnknownFieldCount(path: $0["path"], count: $0["count"]) }
        }
    }

    // MARK: Dataset source (plan v3 §14)

    /// Everything a dataset build reads, in one read transaction, so the checkpoints, the content
    /// digest and every row describe the same projection. `accounts` limits the conversations
    /// (nil = all); checkpoints, claims and votes always cover every account.
    public func datasetSource(accounts: Set<AccountID>? = nil) throws -> DatasetSource {
        try pool.read { db in
            let decoderVersion = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'decoder_version'")
            let digest = try Self.contentDigest(db)

            var unknown: [String: [UnknownFieldRange]] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT account_id, path, count, first_seq, last_seq FROM unknown_fields ORDER BY account_id, path")
            {
                let first: Int64 = row["first_seq"]
                let last: Int64 = row["last_seq"]
                unknown[row["account_id"], default: []].append(
                    UnknownFieldRange(
                        path: row["path"], count: row["count"], firstSequence: UInt64(max(0, first)),
                        lastSequence: UInt64(max(0, last))))
            }
            var sourceAccounts: [DatasetSourceAccount] = []
            for row in try Row.fetchAll(db, sql: "SELECT account_id, last_sequence FROM checkpoints ORDER BY account_id") {
                let text: String = row["account_id"]
                guard let account = Self.accountID(text) else { continue }
                let value: Int64 = row["last_sequence"]
                sourceAccounts.append(
                    DatasetSourceAccount(account: account, checkpoint: UInt64(max(0, value)), unknownFields: unknown[text] ?? []))
            }

            var conversations: [DatasetSourceConversation] = []
            for row in try Row.fetchAll(db, sql: Self.datasetConversationSelect) {
                guard let summary = Self.summary(from: row) else { continue }
                if let accounts, !accounts.contains(summary.account) { continue }
                let accountID = summary.account.rawValue.uuidString
                var location: RecordRef?
                var messages: [DetailMessage] = []
                var warnings: [IndexWarning] = []
                if let sequence = summary.latestSnapshotSequence {
                    if let segment: Int = row["snapshot_segment"], let offset: Int = row["snapshot_offset"],
                        let length: Int = row["snapshot_length"]
                    {
                        location = RecordRef(account: summary.account, sequence: sequence, segment: segment, offset: offset, length: length)
                    }
                    messages = try Self.snapshotMessages(db, accountID: accountID, seq: sequence)
                    warnings = try Row.fetchAll(
                        db, sql: "SELECT seq, code, detail FROM warnings WHERE account_id = ? AND seq = ? ORDER BY ordinal",
                        arguments: [accountID, Int64(sequence)]
                    ).map { IndexWarning(sequence: UInt64($0["seq"] as Int64), code: $0["code"], detail: $0["detail"]) }
                }
                conversations.append(
                    DatasetSourceConversation(
                        summary: summary, updatedOrder: row["updated_order"], snapshotLocation: location, messages: messages,
                        snapshotWarnings: warnings))
            }

            let claims = try Row.fetchAll(
                db,
                sql: """
                    SELECT account_id, seq, conversation_id, subject, subject_id, role, model_id, display_name,
                           organization, provider, source
                    FROM model_claims ORDER BY account_id, seq, subject, subject_id, role, source, model_id
                    """
            ).compactMap { row -> SequencedClaim? in
                guard let account = Self.accountID(row["account_id"]) else { return nil }
                let sequence: Int64 = row["seq"]
                let role: String = row["role"]
                return SequencedClaim(
                    account: account, sequence: UInt64(max(0, sequence)), conversationID: row["conversation_id"],
                    claim: ModelClaim(
                        subject: ModelClaim.Subject(rawValue: row["subject"]), subjectID: row["subject_id"],
                        role: role.isEmpty ? nil : role, modelID: row["model_id"], displayName: row["display_name"],
                        organization: row["organization"], provider: row["provider"], source: row["source"]))
            }
            let feedback = try Row.fetchAll(
                db,
                sql: """
                    SELECT f.account_id AS account_id, f.snapshot_seq AS snapshot_seq, s.remote_id AS conversation_id,
                           f.remote_id AS remote_id, f.value AS value, f.message_a AS message_a, f.message_b AS message_b
                    FROM feedback f JOIN snapshots s ON s.account_id = f.account_id AND s.seq = f.snapshot_seq
                    ORDER BY f.account_id, f.snapshot_seq, f.remote_id
                    """
            ).compactMap { row -> SequencedFeedback? in
                guard let account = Self.accountID(row["account_id"]) else { return nil }
                let sequence: Int64 = row["snapshot_seq"]
                return SequencedFeedback(
                    account: account, sequence: UInt64(max(0, sequence)), conversationID: row["conversation_id"],
                    feedback: ArchivedFeedback(
                        remoteID: row["remote_id"], value: row["value"], messageA: row["message_a"], messageB: row["message_b"]))
            }
            return DatasetSource(
                decoderVersion: decoderVersion, contentDigest: digest, accounts: sourceAccounts,
                conversations: conversations, claims: claims, feedback: feedback)
        }
    }

    private static let datasetConversationSelect = """
        SELECT c.account_id AS account_id, c.remote_id AS remote_id, c.kind AS kind, c.title AS title,
               c.mode AS mode, c.modality AS modality, c.updated_at AS updated_at, c.updated_order AS updated_order,
               c.latest_snapshot_seq AS latest_snapshot_seq, c.absent_seq AS absent_seq,
               latest.segment AS snapshot_segment, latest.record_offset AS snapshot_offset,
               latest.record_length AS snapshot_length,
               (SELECT COUNT(*) FROM snapshots s
                  WHERE s.account_id = c.account_id AND s.remote_id = c.remote_id) AS snapshot_count,
               (SELECT COUNT(*) FROM messages m
                  WHERE m.account_id = c.account_id AND m.snapshot_seq = c.latest_snapshot_seq) AS message_count
        FROM conversations c
        LEFT JOIN snapshots latest ON latest.account_id = c.account_id AND latest.seq = c.latest_snapshot_seq
        ORDER BY c.account_id, c.remote_id
        """

    /// One snapshot's messages with parents, blocks and attachments, in four queries rather than
    /// three per message. Same values and order as `conversation(account:remoteID:snapshot:)`.
    private static func snapshotMessages(_ db: Database, accountID: String, seq: UInt64) throws -> [DetailMessage] {
        let arguments: StatementArguments = [accountID, Int64(seq)]
        var parents: [String: [String]] = [:]
        for row in try Row.fetchAll(
            db,
            sql: "SELECT message_id, parent_id FROM message_parents WHERE account_id = ? AND snapshot_seq = ? ORDER BY message_id, ordinal",
            arguments: arguments)
        {
            parents[row["message_id"], default: []].append(row["parent_id"])
        }
        var blocks: [String: [DetailBlock]] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT message_id, kind, text, tool_name, tool_call_id, payload, pointer FROM blocks
                WHERE account_id = ? AND snapshot_seq = ? ORDER BY message_id, ordinal
                """,
            arguments: arguments)
        {
            let kind: String = row["kind"]
            blocks[row["message_id"], default: []].append(
                DetailBlock(
                    kind: BlockKind(rawValue: kind) ?? .opaque, text: row["text"], toolName: row["tool_name"],
                    toolCallID: row["tool_call_id"], payload: row["payload"], pointer: row["pointer"] ?? ""))
        }
        var attachments: [String: [ArchivedAttachment]] = [:]
        for row in try Row.fetchAll(
            db,
            sql: """
                SELECT message_id, name, content_type, has_url FROM attachments
                WHERE account_id = ? AND snapshot_seq = ? ORDER BY message_id, ordinal
                """,
            arguments: arguments)
        {
            let hasURL: Int = row["has_url"]
            attachments[row["message_id"], default: []].append(
                ArchivedAttachment(name: row["name"], contentType: row["content_type"], hasURL: hasURL != 0))
        }
        return try Row.fetchAll(
            db,
            sql: """
                SELECT remote_id, role, status, lane, model_remote_id, created_at FROM messages
                WHERE account_id = ? AND snapshot_seq = ? ORDER BY ordinal
                """,
            arguments: arguments
        ).map { row in
            let id: String = row["remote_id"]
            return DetailMessage(
                remoteID: id, role: row["role"], status: row["status"], lane: row["lane"], parentIDs: parents[id] ?? [],
                modelRemoteID: row["model_remote_id"], createdAt: row["created_at"], blocks: blocks[id] ?? [],
                attachments: attachments[id] ?? [])
        }
    }

    private static func accountID(_ text: String) -> AccountID? {
        UUID(uuidString: text).map { AccountID(rawValue: $0) }
    }

    public func counts() throws -> [String: Int] {
        try pool.read { db in
            var counts: [String: Int] = [:]
            for table in Self.digestTables {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return counts
        }
    }

    /// Owned tables as SQLite reports them, excluding SQLite internals, GRDB's migration table and
    /// FTS5 shadow tables. Used to keep `digestTables` honest.
    public func tableNames() throws -> [String] {
        try pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'search_%'
                      AND name != 'grdb_migrations'
                    ORDER BY name
                    """)
        }
    }

    /// SHA-256 over every row of every owned table, in a fixed order, each ordered by its full
    /// primary key. Identical content produces an identical digest.
    public func contentDigest() throws -> String {
        try pool.read { db in try Self.contentDigest(db) }
    }

    /// Content digest and every account's checkpoint, read in one transaction so a concurrent
    /// projection cannot make them disagree.
    public func digestAndCheckpoints() throws -> (digest: String, checkpoints: [AccountID: UInt64]) {
        try pool.read { db in
            var checkpoints: [AccountID: UInt64] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT account_id, last_sequence FROM checkpoints") {
                guard let text: String = row["account_id"], let uuid = UUID(uuidString: text),
                    let value: Int64 = row["last_sequence"], value >= 0
                else { continue }
                checkpoints[AccountID(rawValue: uuid)] = UInt64(value)
            }
            return (try Self.contentDigest(db), checkpoints)
        }
    }

    private static func contentDigest(_ db: Database) throws -> String {
        var hasher = SHA256()
        for table in Self.digestTables {
            hasher.update(data: Self.tagged(.text, Data(table.utf8)))
            let order = Self.digestOrder[table] ?? ""
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY \(order)")
            for row in rows {
                for index in 0..<row.count {
                    Self.hash(row[index]?.databaseValue ?? .null, into: &hasher)
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Row mapping

    private static let summarySelect = """
        SELECT c.account_id AS account_id, c.remote_id AS remote_id, c.kind AS kind, c.title AS title,
               c.mode AS mode, c.modality AS modality, c.updated_at AS updated_at, c.updated_order AS updated_order,
               c.latest_snapshot_seq AS latest_snapshot_seq, c.absent_seq AS absent_seq,
               (SELECT COUNT(*) FROM snapshots s
                  WHERE s.account_id = c.account_id AND s.remote_id = c.remote_id) AS snapshot_count,
               (SELECT COUNT(*) FROM messages m
                  WHERE m.account_id = c.account_id AND m.snapshot_seq = c.latest_snapshot_seq) AS message_count
        FROM conversations c
        """

    private static func summary(from row: Row) -> ConversationSummary? {
        let accountID: String = row["account_id"]
        guard let uuid = UUID(uuidString: accountID) else { return nil }
        let latest: Int64? = row["latest_snapshot_seq"]
        let absent: Int64? = row["absent_seq"]
        return ConversationSummary(
            account: AccountID(rawValue: uuid), remoteID: row["remote_id"], kind: row["kind"], title: row["title"],
            mode: row["mode"], modality: row["modality"], updatedAt: row["updated_at"],
            snapshotCount: row["snapshot_count"], latestSnapshotSequence: latest.map { UInt64($0) },
            messageCount: row["message_count"], isAbsent: absent != nil, updatedOrder: row["updated_order"])
    }

    private static func parents(_ db: Database, accountID: String, seq: UInt64, messageID: String) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
                SELECT parent_id FROM message_parents
                WHERE account_id = :account AND snapshot_seq = :seq AND message_id = :message ORDER BY ordinal
                """,
            arguments: args(["account": accountID, "seq": Int64(seq), "message": messageID]))
    }

    private static func blocks(_ db: Database, accountID: String, seq: UInt64, messageID: String) throws -> [DetailBlock] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT kind, text, tool_name, tool_call_id, payload, pointer FROM blocks
                WHERE account_id = :account AND snapshot_seq = :seq AND message_id = :message ORDER BY ordinal
                """,
            arguments: args(["account": accountID, "seq": Int64(seq), "message": messageID])
        ).map { row in
            let kind: String = row["kind"]
            return DetailBlock(
                kind: BlockKind(rawValue: kind) ?? .opaque, text: row["text"], toolName: row["tool_name"],
                toolCallID: row["tool_call_id"], payload: row["payload"], pointer: row["pointer"] ?? "")
        }
    }

    private static func attachments(
        _ db: Database, accountID: String, seq: UInt64, messageID: String
    ) throws -> [ArchivedAttachment] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT name, content_type, has_url FROM attachments
                WHERE account_id = :account AND snapshot_seq = :seq AND message_id = :message ORDER BY ordinal
                """,
            arguments: args(["account": accountID, "seq": Int64(seq), "message": messageID])
        ).map { row in
            let hasURL: Int = row["has_url"]
            return ArchivedAttachment(name: row["name"], contentType: row["content_type"], hasURL: hasURL != 0)
        }
    }

    // MARK: Digest helpers

    private enum ValueTag: UInt8 {
        case null = 0
        case integer = 1
        case real = 2
        case text = 3
        case blob = 4
    }

    private static func tagged(_ tag: ValueTag, _ payload: Data) -> Data {
        var data = Data([tag.rawValue])
        withUnsafeBytes(of: UInt64(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    private static func hash(_ value: DatabaseValue, into hasher: inout SHA256) {
        switch value.storage {
        case .null:
            hasher.update(data: tagged(.null, Data()))
        case .int64(let value):
            var data = Data([ValueTag.integer.rawValue])
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            hasher.update(data: data)
        case .double(let value):
            var data = Data([ValueTag.real.rawValue])
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            hasher.update(data: data)
        case .string(let value):
            hasher.update(data: tagged(.text, Data(value.utf8)))
        case .blob(let value):
            hasher.update(data: tagged(.blob, value))
        }
    }

}

/// Builds named statement arguments from `Any` values (optionals encode as NULL).
private func args(_ values: [String: Any]) -> StatementArguments {
    StatementArguments(values) ?? StatementArguments()
}
