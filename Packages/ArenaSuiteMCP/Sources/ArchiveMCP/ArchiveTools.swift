import ApplicationActions
import ArchiveIndex
import Foundation
import SuiteDomain

/// The read-only tools (plan v3 §14): list, search, get conversation, export. Everything goes
/// through ApplicationActions over an index opened read-only. There are no Arena network
/// actions, no sync, no voting or reveal, no file writes and no bulk operations; exact raw bodies
/// (which carry Arena `metadata` telemetry) are never returned, because only the app can ask
/// for the explicit confirmation they need.
public struct ArchiveTools: Sendable {
    public static let listLimitDefault = 50
    public static let listLimitMax = 200
    public static let searchLimitDefault = 20
    public static let searchLimitMax = 50
    public static let queryLengthMax = 500
    public static let identifierLengthMax = 256
    /// Larger rendered conversations are refused rather than truncated.
    public static let responseByteMax = 8 * 1024 * 1024

    private let archive: ArchiveService
    private let exports: ExportService
    private let registry: AccountRegistryStore

    public init(archive: ArchiveService, registry: AccountRegistryStore) {
        self.archive = archive
        self.exports = ExportService(archive: archive)
        self.registry = registry
    }

    /// Opens `<archiveRoot>/index/archive.sqlite` read-only. Throws if the index does not exist
    /// yet; nothing is created.
    public static func readOnly(archiveRoot: URL) throws -> ArchiveTools {
        let index = try ArchiveIndex(readingExistingAt: archiveRoot.appendingPathComponent("index/archive.sqlite"))
        return ArchiveTools(
            archive: ArchiveService(readOnly: index, journals: JournalStore(archiveRoot: archiveRoot)),
            registry: AccountRegistryStore(url: archiveRoot.appendingPathComponent("accounts/registry.json")))
    }

    public struct ToolError: Error, Equatable, Sendable {
        public let message: String
        init(_ message: String) { self.message = message }
    }

    // MARK: Definitions

    public static let definitions: [JSONValue] = [
        tool(
            "list_accounts",
            "List the accounts in the local Arena Suite archive, with how far each account's journal is indexed. Reads the local archive only; syncing happens only in the Arena Suite app.",
            properties: [:], required: []),
        tool(
            "list_conversations",
            "List archived conversations, newest first by Arena's updatedAt. Paged with offset/limit.",
            properties: [
                "account_id": accountProperty(required: false),
                "limit": ["type": "integer", "minimum": 1, "maximum": .int(Int64(listLimitMax)), "description": .string("Default \(listLimitDefault).")],
                "offset": ["type": "integer", "minimum": 0, "description": "Default 0."],
            ], required: []),
        tool(
            "search",
            "Full-text search over archived message text (all query words must match). Reasoning and tool blocks are excluded unless include_reasoning_and_tools is true.",
            properties: [
                "query": ["type": "string", "description": .string("Words to match; at most \(queryLengthMax) characters.")],
                "account_id": accountProperty(required: false),
                "include_reasoning_and_tools": ["type": "boolean", "description": "Default false."],
                "limit": ["type": "integer", "minimum": 1, "maximum": .int(Int64(searchLimitMax)), "description": .string("Default \(searchLimitDefault).")],
            ], required: ["query"]),
        tool(
            "get_conversation",
            "Get one archived conversation as Normalized JSON (arena-suite.normalized-export), with lanes, parent links, model claims and their provenance. Telemetry is never included.",
            properties: conversationProperties(), required: ["account_id", "conversation_id"]),
        tool(
            "export_conversation",
            "Render one archived conversation in an export format and return it inline (nothing is written to disk). raw_json always masks Arena metadata telemetry; exact raw bodies are only available from the app.",
            properties: conversationProperties().merging(
                ["format": ["type": "string", "enum": ["markdown", "normalized_json", "raw_json"]]], uniquingKeysWith: { $1 }),
            required: ["account_id", "conversation_id", "format"]),
    ]

    private static func tool(
        _ name: String, _ description: String, properties: [String: JSONValue], required: [String]
    ) -> JSONValue {
        [
            "name": .string(name), "description": .string(description),
            "inputSchema": [
                "type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
                "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ]
    }

    private static func accountProperty(required: Bool) -> JSONValue {
        ["type": "string", "description": .string(required ? "Account ID from list_accounts." : "Account ID from list_accounts; omit for all accounts.")]
    }

    private static func conversationProperties() -> [String: JSONValue] {
        [
            "account_id": accountProperty(required: true),
            "conversation_id": ["type": "string", "description": "conversation_id from list_conversations or search."],
            "snapshot": ["type": "string", "description": "Journal sequence of one of this conversation's snapshots; default latest. The result holds only what was observed up to that record."],
        ]
    }

    // MARK: Calls

    public func call(_ name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        guard let definition = Self.definitions.first(where: { $0["name"]?.stringValue == name }),
            case .object(let properties)? = definition["inputSchema"]?["properties"]
        else { throw ToolError("Unknown tool \(name).") }
        let allowed = Set(properties.keys)
        if let extra = arguments.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw ToolError("Unknown argument \(extra) for \(name).")
        }
        switch name {
        case "list_accounts": return try listAccounts()
        case "list_conversations": return try listConversations(arguments)
        case "search": return try search(arguments)
        case "get_conversation": return try await render(arguments, format: .normalizedJSON)
        default:
            guard let format = arguments["format"]?.stringValue.flatMap(Self.format(named:)) else {
                throw ToolError("format must be markdown, normalized_json or raw_json.")
            }
            return try await render(arguments, format: format)
        }
    }

    private static func format(named name: String) -> ExportFormat? {
        switch name {
        case "markdown": .markdown
        case "normalized_json": .normalizedJSON
        case "raw_json": .rawJSON
        default: nil
        }
    }

    private func listAccounts() throws -> JSONValue {
        let registered: [AccountRecord]
        do { registered = try registry.loadWithoutTightening() } catch {
            throw ToolError("The account registry could not be read without changing it (it must be owner-only and not a symlink).")
        }
        let conversations = try archive.conversations(account: nil)
        let indexed = Set(conversations.map(\.account))
        var rows: [JSONValue] = []
        // Registered accounts first (registry order), then removed accounts whose evidence is still indexed.
        let ids = registered.map(\.id) + indexed.subtracting(registered.map(\.id)).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        for id in ids {
            let name = registered.first { $0.id == id }?.displayName
            rows.append([
                "account_id": .string(id.rawValue.uuidString),
                "display_name": name.map { .string($0) } ?? .null,
                "registered": .bool(name != nil),
                "indexed_through_sequence": .string(String(try archive.checkpoint(for: id))),
                "conversation_count": .int(Int64(conversations.filter { $0.account == id }.count)),
            ])
        }
        return [
            "accounts": .array(rows),
            "decoder": .string(archive.decoderVersion),
            "scope": "the local index as of this call; it covers each journal through indexed_through_sequence. Syncing with Arena happens only in the app.",
        ]
    }

    private func listConversations(_ arguments: [String: JSONValue]) throws -> JSONValue {
        let account = try accountArgument(arguments, required: false)
        let limit = try bounded(arguments["limit"], name: "limit", default: Self.listLimitDefault, range: 1...Self.listLimitMax)
        let offset = try bounded(arguments["offset"], name: "offset", default: 0, range: 0...Int.max)
        let all = try archive.conversations(account: account)
        let page = all.dropFirst(offset).prefix(limit)
        return [
            "total": .int(Int64(all.count)),
            "offset": .int(Int64(offset)),
            "conversations": .array(page.map(Self.summary)),
            "scope": "conversations in the local index; kind \"agentic\" entries are archived list-only (no detail route observed).",
        ]
    }

    private static func summary(_ c: ConversationSummary) -> JSONValue {
        [
            "account_id": .string(c.account.rawValue.uuidString),
            "conversation_id": .string(c.remoteID),
            "kind": .string(c.kind),
            "title": c.title.map { .string($0) } ?? .null,
            "mode": c.mode.map { .string($0) } ?? .null,
            "modality": c.modality.map { .string($0) } ?? .null,
            "updated_at": c.updatedAt.map { .string($0) } ?? .null,
            "snapshot_count": .int(Int64(c.snapshotCount)),
            "latest_snapshot": c.latestSnapshotSequence.map { .string(String($0)) } ?? .null,
            "message_count": .int(Int64(c.messageCount)),
            "absent_from_latest_history_list": .bool(c.isAbsent),
        ]
    }

    private func search(_ arguments: [String: JSONValue]) throws -> JSONValue {
        guard let query = arguments["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("query must be a non-empty string.")
        }
        guard query.count <= Self.queryLengthMax else { throw ToolError("query is longer than \(Self.queryLengthMax) characters.") }
        let account = try accountArgument(arguments, required: false)
        let includeAll = try boolArgument(arguments, "include_reasoning_and_tools") ?? false
        let limit = try bounded(arguments["limit"], name: "limit", default: Self.searchLimitDefault, range: 1...Self.searchLimitMax)
        let hits = try archive.search(query, account: account, includeReasoningAndTools: includeAll, limit: limit)
        return [
            "hits": .array(
                hits.map {
                    [
                        "account_id": .string($0.account.rawValue.uuidString), "conversation_id": .string($0.conversationID),
                        "title": $0.title.map { .string($0) } ?? .null, "message_id": .string($0.messageID),
                        "kind": .string($0.kind), "snippet": .string($0.snippet),
                    ]
                }),
            "limit_reached": .bool(hits.count == limit),
            "scope": .string(includeAll ? "message text, reasoning and tool blocks" : "message text only"),
        ]
    }

    private func render(_ arguments: [String: JSONValue], format: ExportFormat) async throws -> JSONValue {
        guard let account = try accountArgument(arguments, required: true) else { throw ToolError("account_id is required.") }
        guard let remoteID = arguments["conversation_id"]?.stringValue, !remoteID.isEmpty,
            remoteID.utf8.count <= Self.identifierLengthMax
        else {
            throw ToolError("conversation_id must be a non-empty string of at most \(Self.identifierLengthMax) bytes.")
        }
        var snapshot: UInt64?
        if let value = arguments["snapshot"] {
            // Journal sequences are SQLite integers: at most Int64.max.
            guard let sequence = value.uint64Value, sequence > 0, Int64(exactly: sequence) != nil else {
                throw ToolError("snapshot must be a positive journal sequence of at most \(Int64.max).")
            }
            snapshot = sequence
        }
        let rendered: (data: Data, baseName: String)
        do {
            rendered = try await exports.render(
                account: account, remoteID: remoteID, snapshot: snapshot,
                options: ExportOptions(format: format, includeExactRawBodies: false))
        } catch ExportError.conversationNotFound {
            throw ToolError("No archived conversation \(remoteID) for account \(account.rawValue.uuidString)\(snapshot.map { " at snapshot \($0)" } ?? "").")
        } catch ExportError.snapshotNotInConversation(let sequence) {
            throw ToolError("Snapshot \(sequence) is not a snapshot of conversation \(remoteID); list_conversations shows the latest.")
        } catch ExportError.noSnapshot {
            throw ToolError("Conversation \(remoteID) has no archived detail snapshot (list-only entry).")
        } catch ExportError.rawRecordUnavailable {
            throw ToolError("The journal record behind this snapshot could not be read or failed its digest check.")
        }
        guard rendered.data.count <= Self.responseByteMax else {
            throw ToolError("The rendered conversation is \(rendered.data.count) bytes, over the \(Self.responseByteMax)-byte limit. Export it from the app instead.")
        }
        guard let text = String(data: rendered.data, encoding: .utf8) else { throw ToolError("The rendered conversation is not UTF-8.") }
        return .string(text)
    }

    // MARK: Arguments

    private func accountArgument(_ arguments: [String: JSONValue], required: Bool) throws -> AccountID? {
        guard let value = arguments["account_id"] else {
            if required { throw ToolError("account_id is required.") }
            return nil
        }
        guard let text = value.stringValue, let uuid = UUID(uuidString: text) else {
            throw ToolError("account_id must be an account ID from list_accounts.")
        }
        return AccountID(rawValue: uuid)
    }

    private func boolArgument(_ arguments: [String: JSONValue], _ name: String) throws -> Bool? {
        guard let value = arguments[name] else { return nil }
        guard let bool = value.boolValue else { throw ToolError("\(name) must be true or false.") }
        return bool
    }

    private func bounded(_ value: JSONValue?, name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value else { return fallback }
        guard let int = value.intValue, range.contains(int) else {
            throw ToolError("\(name) must be an integer in \(range.lowerBound)...\(range.upperBound == .max ? "" : String(range.upperBound)).")
        }
        return int
    }
}
