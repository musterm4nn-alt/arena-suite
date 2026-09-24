import ArchiveIndex
import CryptoKit
import Foundation
import SuiteDomain

/// Plan v3 §12. Exports read one frozen conversation snapshot (a journal record plus the index
/// projection of it). Output contains no export time, so the same input always yields the same bytes.
public enum ExportFormat: String, CaseIterable, Sendable {
    case rawJSON = "raw-json"
    case normalizedJSON = "normalized-json"
    case markdown

    public var fileExtension: String { self == .markdown ? "md" : "json" }
    public var label: String {
        switch self {
        case .rawJSON: "Raw JSON"
        case .normalizedJSON: "Normalized JSON"
        case .markdown: "Markdown"
        }
    }
}

public struct ExportOptions: Sendable, Equatable {
    public var format: ExportFormat
    /// Raw JSON only: keep response bodies byte-exact, including Arena's per-message `metadata`
    /// telemetry. Off by default: those subtrees are masked and the change is declared.
    public var includeExactRawBodies: Bool

    public init(format: ExportFormat, includeExactRawBodies: Bool = false) {
        self.format = format
        self.includeExactRawBodies = includeExactRawBodies
    }
}

public struct ExportResult: Sendable, Equatable {
    public let url: URL
    public let byteCount: Int
    public let sha256: String
}

public enum ExportError: Error, Equatable, Sendable {
    case conversationNotFound
    case noSnapshot
    case rawRecordUnavailable
    case cancelled
    case writeFailed(String)
}

public struct ExportService: Sendable {
    public static let redactionPolicy = "mask-metadata/1"
    private let archive: ArchiveService

    public init(archive: ArchiveService) { self.archive = archive }

    /// Renders and writes atomically into `directory` without overwriting anything.
    public func export(
        account: AccountID, remoteID: String, snapshot: UInt64?, options: ExportOptions, to directory: URL
    ) async throws -> ExportResult {
        let rendered = try await render(account: account, remoteID: remoteID, snapshot: snapshot, options: options)
        try Task.checkCancellation()
        let url = try Self.write(rendered.data, baseName: rendered.baseName, extension: options.format.fileExtension, into: directory)
        return ExportResult(url: url, byteCount: rendered.data.count, sha256: Self.hex(SHA256.hash(data: rendered.data)))
    }

    public func render(
        account: AccountID, remoteID: String, snapshot: UInt64?, options: ExportOptions
    ) async throws -> (data: Data, baseName: String) {
        guard let detail = try archive.conversation(account: account, remoteID: remoteID, snapshot: snapshot) else {
            throw ExportError.conversationNotFound
        }
        guard let sequence = snapshot ?? detail.summary.latestSnapshotSequence else { throw ExportError.noSnapshot }
        guard let evidence = try await archive.rawEvidence(account: account, snapshotSequence: sequence) else {
            throw ExportError.rawRecordUnavailable
        }
        let base = Self.baseName(title: detail.summary.title, remoteID: remoteID, sequence: sequence)
        switch options.format {
        case .rawJSON: return (try Self.rawJSON(detail: detail, evidence: evidence, exact: options.includeExactRawBodies), base)
        case .normalizedJSON: return (try Self.normalizedJSON(detail: detail, evidence: evidence), base)
        case .markdown: return (Data(Self.markdown(detail: detail, evidence: evidence).utf8), base)
        }
    }

    // MARK: Raw JSON

    static func rawJSON(detail: ConversationDetail, evidence: RawEvidence, exact: Bool) throws -> Data {
        let original = evidence.payload
        let exported = exact ? original : maskMetadata(original)
        let transformed = exported != original
        var record: [String: Any] = [
            "sequence": String(evidence.location.sequence),
            "location": [
                "segment": evidence.location.segment, "offset": evidence.location.offset, "length": evidence.location.length,
            ],
            "record_digest": evidence.digest,
            "envelope": (try? JSONSerialization.jsonObject(with: evidence.envelope)) ?? NSNull(),
            "payload_base64": exported.base64EncodedString(),
            "original_payload_sha256": hex(SHA256.hash(data: original)),
            "exported_payload_sha256": hex(SHA256.hash(data: exported)),
            "byte_fidelity": transformed ? "transformed" : "exact_at_declared_observation_layer",
        ]
        record["transformations"] =
            transformed
            ? [["scope": "every JSON subtree under a key named metadata", "reason": "Arena per-message anti-abuse telemetry (plan v3 §12)",
                "policy": redactionPolicy, "mapping": "value replaced by the string [omitted: telemetry]; body re-serialized with sorted keys; original bytes remain in the journal"]]
            : []
        let root: [String: Any] = [
            "schema": "arena-suite.raw-export/1",
            "scope": scope(detail: detail, evidence: evidence),
            "redaction_policy": exact ? "none" : redactionPolicy,
            "sensitivity": exact ? ["contains Arena per-message metadata telemetry about the account holder"] : [],
            "records": [record],
        ]
        return try canonical(root)
    }

    /// Replaces the value of every `metadata` key (at any depth) with a marker; nothing else changes.
    static func maskMetadata(_ body: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { return body }
        var masked = false
        func walk(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (key, child) in dictionary {
                    if key == "metadata", !(child is NSNull) {
                        out[key] = "[omitted: telemetry]"
                        masked = true
                    } else {
                        out[key] = walk(child)
                    }
                }
                return out
            }
            if let array = value as? [Any] { return array.map(walk) }
            return value
        }
        let result = walk(object)
        guard masked, let data = try? canonical(result) else { return body }
        return data
    }

    // MARK: Normalized JSON

    static func normalizedJSON(detail: ConversationDetail, evidence: RawEvidence) throws -> Data {
        func value(_ string: String?) -> Any { string ?? NSNull() }
        let messages: [[String: Any]] = detail.messages.enumerated().map { index, message in
            [
                "ordinal": index, "id": message.remoteID, "role": value(message.role), "status": value(message.status),
                "lane": value(message.lane), "parent_ids": message.parentIDs, "model_id": value(message.modelRemoteID),
                "created_at": value(message.createdAt),
                "blocks": message.blocks.enumerated().map { blockIndex, block -> [String: Any] in
                    [
                        "ordinal": blockIndex, "kind": block.kind.rawValue, "text": value(block.text),
                        "tool_name": value(block.toolName), "tool_call_id": value(block.toolCallID),
                        "payload": value(block.payload), "source_pointer": block.pointer,
                    ]
                },
                "attachments": message.attachments.map { ["name": value($0.name), "content_type": value($0.contentType), "has_url": $0.hasURL] },
            ]
        }
        let root: [String: Any] = [
            "schema": "arena-suite.normalized/1",
            "scope": scope(detail: detail, evidence: evidence),
            "conversation": [
                "remote_id": detail.summary.remoteID, "kind": detail.summary.kind, "title": value(detail.summary.title),
                "mode": value(detail.summary.mode), "modality": value(detail.summary.modality),
                "updated_at": value(detail.summary.updatedAt), "absent_on_server": detail.summary.isAbsent,
            ],
            "messages": messages,
            "model_claims": detail.claims.map {
                [
                    "subject": $0.subject.rawValue, "subject_id": $0.subjectID, "role": value($0.role), "model_id": $0.modelID,
                    "display_name": value($0.displayName), "organization": value($0.organization), "provider": value($0.provider),
                    "source": $0.source, "verified_identity": false,
                ] as [String: Any]
            }.sorted { canonicalString($0) < canonicalString($1) },
            "feedback": detail.feedback.map {
                ["id": $0.remoteID, "value": value($0.value), "message_a": value($0.messageA), "message_b": value($0.messageB)] as [String: Any]
            }.sorted { canonicalString($0) < canonicalString($1) },
            "excluded": ["per-message metadata telemetry", "encrypted reasoning (providerOptions)", "attachment URLs", "raw bytes (see raw export)"],
        ]
        return try canonical(root)
    }

    // MARK: Markdown

    static func markdown(detail: ConversationDetail, evidence: RawEvidence) -> String {
        let layout = TranscriptLayout(detail)
        let names = Dictionary(
            detail.claims.filter { $0.source == "detail_revealed" }.compactMap { claim in claim.displayName.map { (claim.modelID, $0) } },
            uniquingKeysWith: { first, _ in first })
        var out = "# \(oneLine(detail.summary.title ?? "Untitled"))\n\n"
        out += "_\([detail.summary.kind, detail.summary.mode, detail.summary.modality].compactMap { $0 }.joined(separator: " · "))_\n\n"
        for (index, turn) in layout.turns.enumerated() {
            out += "## Turn \(index + 1)\n\n"
            if let prompt = turn.prompt { out += "### You\n\n" + body(prompt) }
            for lane in turn.lanes {
                for entry in lane.messages {
                    let model = entry.message.modelRemoteID.map { names[$0] ?? $0 }
                    out += "### " + (lane.lane.map { "Lane \($0.uppercased())" } ?? "Response (lane not exposed)") + (model.map { " · \(oneLine($0))" } ?? "") + "\n\n"
                    if !entry.otherParents.isEmpty { out += "_Replies to \(entry.otherParents.joined(separator: ", "))_\n\n" }
                    out += body(entry.message)
                }
            }
            for message in turn.otherRoles { out += "### Role: \(message.role ?? "not stated")\n\n" + body(message) }
            for vote in turn.votes { out += "_Vote: \(vote.value ?? "unknown")_\n\n" }
        }
        for vote in layout.unmatchedVotes { out += "_Vote not tied to a single turn: \(vote.value ?? "unknown")_\n\n" }
        out += "---\n\n"
        out += "Exported from the Arena Suite archive. Source: journal record \(evidence.location.sequence), SHA-256 `\(evidence.digest)`, decoder `\(evidence.decoderVersion)`. "
        out += "This Markdown view is lossy: raw bytes, timing, per-message metadata, encrypted reasoning and attachment files are not included. "
        out += "Model names are claims from Arena, not verified identity.\n"
        return out
    }

    private static func body(_ message: DetailMessage) -> String {
        var out = ""
        if let status = message.status, status != "success" { out += "_Status: \(status)_\n\n" }
        for block in message.blocks {
            switch block.kind {
            case .text: out += (block.text ?? "") + "\n\n"
            case .reasoning: out += "> **Reasoning**\n>\n" + quoted(block.text ?? "") + "\n\n"
            case .toolCall: out += "**Tool call** `\(oneLine(block.toolName ?? "unknown"))`\n\n" + fenced(block.payload ?? "", language: "json")
            case .toolResult: out += "**Tool result** `\(oneLine(block.toolName ?? block.toolCallID ?? ""))`\n\n" + fenced(block.payload ?? "", language: "json")
            case .sources: out += "**Sources**\n\n" + fenced(block.payload ?? "", language: "json")
            case .opaque: out += "**Unrecognized block** (kept as-is)\n\n" + fenced(block.payload ?? "", language: "json")
            }
        }
        for attachment in message.attachments {
            out += "_Attachment: \(oneLine(attachment.name ?? "unnamed"))\(attachment.contentType.map { " (\($0))" } ?? "")_\n\n"
        }
        return out
    }

    /// A fence longer than any backtick run inside the content, so embedded fences cannot close it.
    public static func fenced(_ text: String, language: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language)\n\(text)\n\(fence)\n\n"
    }

    private static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    // MARK: Shared

    private static func scope(detail: ConversationDetail, evidence: RawEvidence) -> [String: Any] {
        [
            "account_id": detail.summary.account.rawValue.uuidString, "conversation_remote_id": detail.summary.remoteID,
            "snapshot_sequence": String(evidence.location.sequence), "record_digest": evidence.digest,
            "decoder": evidence.decoderVersion, "observation_layer": "foundation_decoded_entity",
            "credential_handling": "credentials never recorded; Set-Cookie values omitted at capture",
        ]
    }

    static func canonical(_ object: Any) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes, .fragmentsAllowed])
        data.append(0x0A)
        return data
    }

    private static func canonicalString(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    static func baseName(title: String?, remoteID: String, sequence: UInt64) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String((title ?? "Untitled").unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
            .split(separator: " ").joined(separator: " ")
        let short = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        return "\(short.isEmpty ? "Untitled" : short) \(remoteID.prefix(8)) r\(sequence)"
    }

    /// Temp file in the destination (same volume) → full sync → hard link to the first free name →
    /// remove the temp file. `link` never replaces an existing file, so nothing is overwritten, and a
    /// failure or cancellation leaves no partially written file under a final name.
    public static func write(_ data: Data, baseName: String, extension ext: String, into directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".arena-suite-export-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw ExportError.writeFailed("create temp file (errno \(errno))") }
        defer { unlink(temporary.path) }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let result = Foundation.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += result
            }
            return true
        }
        let synced = written && (fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0)
        close(fd)
        guard synced else { throw ExportError.writeFailed("write or sync failed") }
        for attempt in 1...1_000 {
            let name = attempt == 1 ? "\(baseName).\(ext)" : "\(baseName) \(attempt).\(ext)"
            let target = directory.appendingPathComponent(name)
            if link(temporary.path, target.path) == 0 { return target }
            guard errno == EEXIST else { throw ExportError.writeFailed("link (errno \(errno))") }
        }
        throw ExportError.writeFailed("no free file name")
    }
}
