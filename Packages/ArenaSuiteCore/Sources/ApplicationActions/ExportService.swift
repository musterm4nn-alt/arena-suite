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
    /// One JSON record per line: a header, the messages, model claims and feedback of Normalized
    /// JSON, then a footer with counts (Docs/export-options-2026-10-20.md).
    case jsonl

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .jsonl: "jsonl"
        case .rawJSON, .normalizedJSON: "json"
        }
    }

    public var label: String {
        switch self {
        case .rawJSON: "Raw JSON"
        case .normalizedJSON: "Normalized JSON"
        case .markdown: "Markdown"
        case .jsonl: "JSONL"
        }
    }

    /// Raw JSON is one recorded response body, so it is always the whole conversation.
    public var supportsLastAnswer: Bool { self != .rawJSON }
}

/// How much of the snapshot an export holds.
public enum ExportScope: String, CaseIterable, Sendable {
    case wholeConversation = "whole-conversation"
    /// The messages Arena lists as the conversation's last (`lastMessageIds`) and the prompts they
    /// reply to, with the votes and claims about them.
    case lastAnswer = "last-answer"

    public var label: String {
        switch self {
        case .wholeConversation: "Whole conversation"
        case .lastAnswer: "Last answer, with its prompt"
        }
    }
}

public struct ExportOptions: Sendable, Equatable {
    public var format: ExportFormat
    public var scope: ExportScope
    /// Raw JSON only: keep response bodies byte-exact, including Arena's per-message `metadata`
    /// telemetry. Off by default: those subtrees are masked and the change is declared.
    public var includeExactRawBodies: Bool

    public init(format: ExportFormat, scope: ExportScope = .wholeConversation, includeExactRawBodies: Bool = false) {
        self.format = format
        self.scope = scope
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
    /// The sequence is not one of this conversation's snapshots.
    case snapshotNotInConversation(UInt64)
    case noSnapshot
    case rawRecordUnavailable
    /// The scope does not apply to the format (the last answer of a raw record).
    case scopeNotAvailable
    /// Arena's last-message list (`lastMessageIds`) for this snapshot is empty or was not in the
    /// response.
    case noLastAnswer
    /// Arena lists a last message that this snapshot does not hold.
    case lastMessageNotInSnapshot
    /// The index could not read the snapshot's stored last-message list (a damaged index).
    case lastMessagesUnreadable
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
        guard !Task.isCancelled else { throw ExportError.cancelled }
        let url = try Self.write(rendered.data, baseName: rendered.baseName, extension: options.format.fileExtension, into: directory)
        // Cancelled while writing: remove the finished file so a cancelled export leaves nothing.
        guard !Task.isCancelled else {
            unlink(url.path)
            throw ExportError.cancelled
        }
        return ExportResult(url: url, byteCount: rendered.data.count, sha256: Self.hex(SHA256.hash(data: rendered.data)))
    }

    /// `snapshot` nil exports the latest snapshot. Either way the export is the frozen view of one
    /// record (`ArchiveIndex.conversation`): the same sequence always yields the same bytes, however
    /// much was synced since.
    public func render(
        account: AccountID, remoteID: String, snapshot: UInt64?, options: ExportOptions
    ) async throws -> (data: Data, baseName: String) {
        let sequence: UInt64
        if let snapshot {
            sequence = snapshot
        } else {
            guard let live = try archive.conversation(account: account, remoteID: remoteID, snapshot: nil) else {
                throw ExportError.conversationNotFound
            }
            guard let latest = live.summary.latestSnapshotSequence else { throw ExportError.noSnapshot }
            sequence = latest
        }
        let detail: ConversationDetail
        do {
            guard let frozen = try archive.conversation(account: account, remoteID: remoteID, snapshot: sequence) else {
                throw ExportError.conversationNotFound
            }
            detail = frozen
        } catch ArchiveIndex.QueryError.snapshotNotInConversation(let foreign) {
            throw ExportError.snapshotNotInConversation(foreign)
        }
        var answer: LastAnswer?
        var base = Self.baseName(title: detail.summary.title, remoteID: remoteID, sequence: sequence)
        if options.scope == .lastAnswer {
            guard options.format.supportsLastAnswer else { throw ExportError.scopeNotAvailable }
            answer = try Self.lastAnswer(of: detail)
            base += " last answer"
        }
        guard let evidence = try await archive.rawEvidence(account: account, snapshotSequence: sequence) else {
            throw ExportError.rawRecordUnavailable
        }
        switch options.format {
        case .rawJSON: return (try Self.rawJSON(detail: detail, evidence: evidence, exact: options.includeExactRawBodies), base)
        case .normalizedJSON: return (try Self.normalizedJSON(detail: detail, evidence: evidence, lastAnswer: answer), base)
        case .markdown: return (Data(Self.markdown(detail: detail, evidence: evidence, lastAnswer: answer).utf8), base)
        case .jsonl: return (try Self.jsonl(detail: detail, evidence: evidence, lastAnswer: answer), base)
        }
    }

    // MARK: Last answer

    /// A last-answer excerpt of one snapshot, and what an export says about how it was chosen.
    public struct LastAnswer: Sendable {
        /// The excerpt: the kept messages in snapshot order, with their votes and claims.
        public let detail: ConversationDetail
        /// Each kept message's position in the whole snapshot, in `detail.messages` order.
        public let ordinals: [Int]
        /// Arena's list, as recorded.
        public let lastMessageIDs: [String]
        /// Messages a listed message replies to that this snapshot does not hold, sorted. Their role
        /// is unknown, so the export names them rather than claim or deny a missing prompt.
        public let parentsNotInSnapshot: [String]
        /// Messages a listed message replies to that the snapshot holds without a stated role,
        /// sorted. Not included (they may not be prompts) and named, not guessed about.
        public let parentsWithUnknownRole: [String]
    }

    /// The part of `detail` an export of its last answer holds: the messages Arena lists as last
    /// (`lastMessageIds`), the `user` messages they reply to, the votes that reference only those
    /// messages, and the claims about them, about the whole conversation, or about a subject this
    /// version does not know (kept, not guessed). Message order is the snapshot's. Nothing is
    /// inferred: an empty, unreadable or dangling list is refused.
    public static func lastAnswer(of detail: ConversationDetail) throws -> LastAnswer {
        guard let listed = detail.lastMessageIDs else { throw ExportError.lastMessagesUnreadable }
        let byID = Dictionary(detail.messages.map { ($0.remoteID, $0) }, uniquingKeysWith: { first, _ in first })
        let last = Set(listed)
        guard !last.isEmpty else { throw ExportError.noLastAnswer }
        guard last.allSatisfy({ byID[$0] != nil }) else { throw ExportError.lastMessageNotInSnapshot }
        var kept = last
        var missing = Set<String>()
        var unknownRole = Set<String>()
        for id in last {
            for parent in byID[id]?.parentIDs ?? [] {
                guard let message = byID[parent] else {
                    missing.insert(parent)
                    continue
                }
                switch message.role {
                case "user"?: kept.insert(parent)
                case nil: unknownRole.insert(parent)
                default: break  // A stated other role: not a prompt.
                }
            }
        }
        unknownRole.subtract(kept)
        let votes = detail.feedback.filter { vote in
            let referenced = [vote.messageA, vote.messageB].compactMap { $0 }
            return !referenced.isEmpty && referenced.allSatisfy(kept.contains)
        }
        let voteIDs = Set(votes.map(\.remoteID))
        let claims = detail.claims.filter { claim in
            if claim.subject == .message { return kept.contains(claim.subjectID) }
            if claim.subject == .feedback { return voteIDs.contains(claim.subjectID) }
            return true
        }
        let ordinals = detail.messages.indices.filter { kept.contains(detail.messages[$0].remoteID) }
        let part = ConversationDetail(
            summary: detail.summary, snapshotSequences: detail.snapshotSequences, messages: ordinals.map { detail.messages[$0] },
            claims: claims, feedback: votes, snapshotSequence: detail.snapshotSequence, isFrozen: detail.isFrozen,
            lastMessageIDs: detail.lastMessageIDs)
        return LastAnswer(
            detail: part, ordinals: ordinals, lastMessageIDs: listed, parentsNotInSnapshot: missing.sorted(),
            parentsWithUnknownRole: unknownRole.sorted())
    }

    /// What a last-answer export says about how it was chosen.
    static func selection(_ answer: LastAnswer) -> [String: Any] {
        [
            "scope": ExportScope.lastAnswer.rawValue,
            "basis": "the messages Arena lists as this conversation's last in this snapshot (lastMessageIds), and the user messages they reply to",
            "feedback_basis": "votes whose referenced messages are all included",
            "model_claim_basis": "claims about the included messages and votes, about the whole conversation, and claims whose subject kind this version does not know (kept, not guessed)",
            "ordinal_basis": "a message's ordinal is its position in the whole snapshot",
            "last_message_ids": answer.lastMessageIDs,
            "parents_not_in_snapshot": answer.parentsNotInSnapshot,
            "parents_with_unknown_role": answer.parentsWithUnknownRole,
        ]
    }

    // MARK: Raw JSON

    public static func rawJSON(detail: ConversationDetail, evidence: RawEvidence, exact: Bool) throws -> Data {
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
                "policy": redactionPolicy,
                "mapping": "value of every key spelled metadata in any letter case, at any depth, replaced by the string [omitted: telemetry]; the whole body is re-parsed and re-serialized (sorted keys, pretty-printed), so number formatting, string escapes and duplicate keys may differ from the original; the original bytes remain in the journal"]]
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

    /// Replaces the value of every key spelled `metadata` in any letter case (at any depth, inside arrays
    /// too) with a marker. The body is re-serialized, which is declared in the transformation.
    public static func maskMetadata(_ body: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { return body }
        var masked = false
        func walk(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (key, child) in dictionary {
                    if key.lowercased() == "metadata", !(child is NSNull) {
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

    /// `lastAnswer`, an excerpt of `detail`, is rendered in its place, with its selection.
    static func normalizedJSON(detail: ConversationDetail, evidence: RawEvidence, lastAnswer: LastAnswer? = nil) throws -> Data {
        let parts = normalizedParts(detail: lastAnswer?.detail ?? detail, ordinals: lastAnswer?.ordinals, evidence: evidence)
        var root: [String: Any] = [
            "schema": "arena-suite.normalized/1",
            "scope": parts.scope,
            "conversation": parts.conversation,
            "messages": parts.messages,
            "model_claims": parts.claims,
            "feedback": parts.feedback,
            "excluded": parts.excluded,
        ]
        if let lastAnswer { root["selection"] = selection(lastAnswer) }
        return try canonical(root)
    }

    // MARK: JSONL

    /// One canonical JSON object per line (sorted keys, no line breaks inside a record): a header with
    /// the scope, conversation and exclusions; one line per message in snapshot order; one per model
    /// claim and per feedback item, in Normalized JSON's order; a footer with the counts.
    /// `lastAnswer`, an excerpt of `detail`, is rendered in its place, with its selection.
    static func jsonl(detail: ConversationDetail, evidence: RawEvidence, lastAnswer: LastAnswer? = nil) throws -> Data {
        let parts = normalizedParts(detail: lastAnswer?.detail ?? detail, ordinals: lastAnswer?.ordinals, evidence: evidence)
        var header: [String: Any] = [
            "type": "header", "schema": "arena-suite.jsonl/1", "scope": parts.scope, "conversation": parts.conversation,
            "excluded": parts.excluded,
        ]
        if let lastAnswer { header["selection"] = selection(lastAnswer) }
        var records: [[String: Any]] = [header]
        records += parts.messages.map { ["type": "message", "message": $0] }
        records += parts.claims.map { ["type": "model_claim", "model_claim": $0] }
        records += parts.feedback.map { ["type": "feedback", "feedback": $0] }
        records.append([
            "type": "footer",
            "counts": ["messages": parts.messages.count, "model_claims": parts.claims.count, "feedback": parts.feedback.count],
        ])
        var data = Data()
        for record in records {
            data.append(lineSafe(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])))
            data.append(0x0A)
        }
        return data
    }

    /// Writes U+0085, U+2028 and U+2029 as `\u` escapes. JSON allows them raw inside strings, and
    /// Foundation leaves them raw, but some line readers end a line there. They occur only inside
    /// strings (JSON's structure is ASCII), so the parsed value is unchanged.
    static func lineSafe(_ json: Data) -> Data {
        guard json.contains(0xC2) || json.contains(0xE2) else { return json }
        var out = Data()
        out.reserveCapacity(json.count)
        let bytes = [UInt8](json)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0xC2, index + 1 < bytes.count, bytes[index + 1] == 0x85 {
                out.append(contentsOf: Array("\\u0085".utf8))
                index += 2
            } else if bytes[index] == 0xE2, index + 2 < bytes.count, bytes[index + 1] == 0x80, bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9 {
                out.append(contentsOf: Array((bytes[index + 2] == 0xA8 ? "\\u2028" : "\\u2029").utf8))
                index += 3
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return out
    }

    /// The entities Normalized JSON and JSONL share. `ordinals` are the messages' positions in the
    /// whole snapshot when `detail` is an excerpt of it.
    private static func normalizedParts(detail: ConversationDetail, ordinals: [Int]?, evidence: RawEvidence) -> (
        scope: [String: Any], conversation: [String: Any], messages: [[String: Any]], claims: [[String: Any]],
        feedback: [[String: Any]], excluded: [String]
    ) {
        func value(_ string: String?) -> Any { string ?? NSNull() }
        let messages: [[String: Any]] = detail.messages.enumerated().map { index, message in
            [
                "ordinal": ordinals?[index] ?? index, "id": message.remoteID, "role": value(message.role), "status": value(message.status),
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
        return (
            scope: scope(detail: detail, evidence: evidence),
            conversation: [
                "remote_id": detail.summary.remoteID, "kind": detail.summary.kind, "title": value(detail.summary.title),
                "mode": value(detail.summary.mode), "modality": value(detail.summary.modality),
                "updated_at": value(detail.summary.updatedAt), "absent_on_server": detail.summary.isAbsent,
            ],
            messages: messages,
            claims: detail.claims.map {
                [
                    "subject": $0.subject.rawValue, "subject_id": $0.subjectID, "role": value($0.role), "model_id": $0.modelID,
                    "display_name": value($0.displayName), "organization": value($0.organization), "provider": value($0.provider),
                    "source": $0.source, "verified_identity": false,
                    "record_sequence": $0.recordSequence.map { String($0) } ?? NSNull(),
                ] as [String: Any]
            }.sorted { canonicalString($0) < canonicalString($1) },
            feedback: detail.feedback.map {
                ["id": $0.remoteID, "value": value($0.value), "message_a": value($0.messageA), "message_b": value($0.messageB)] as [String: Any]
            }.sorted { canonicalString($0) < canonicalString($1) },
            excluded: [
                "metadata telemetry at any depth (masked as [omitted: telemetry])", "encrypted reasoning (providerOptions, any depth)",
                "attachment URLs", "raw bytes (see raw export)",
            ])
    }

    // MARK: Markdown

    /// `lastAnswer`, an excerpt of `detail`, is rendered in its place, with a line saying how it was
    /// chosen and no turn numbers.
    static func markdown(detail whole: ConversationDetail, evidence: RawEvidence, lastAnswer: LastAnswer? = nil) -> String {
        let detail = lastAnswer?.detail ?? whole
        let layout = TranscriptLayout(detail)
        // Claims come in record order: the latest name observed (up to this snapshot) wins.
        let names = Dictionary(
            detail.claims.filter { $0.source == "detail_revealed" }.compactMap { claim in claim.displayName.map { (claim.modelID, $0) } },
            uniquingKeysWith: { _, latest in latest })
        var out = "# \(inline(detail.summary.title ?? "Untitled"))\n\n"
        out += "_\(inline([detail.summary.kind, detail.summary.mode, detail.summary.modality].compactMap { $0 }.joined(separator: " · ")))_\n\n"
        if let lastAnswer {
            out += "_Last answer, with its prompt: the messages Arena lists as this conversation's last, and the prompts they reply to._\n\n"
            if !lastAnswer.parentsNotInSnapshot.isEmpty {
                out += "_Not in this snapshot, so not included: \(inline(lastAnswer.parentsNotInSnapshot.joined(separator: ", "))), which a last message replies to._\n\n"
            }
            if !lastAnswer.parentsWithUnknownRole.isEmpty {
                out += "_Role not stated, so not included: \(inline(lastAnswer.parentsWithUnknownRole.joined(separator: ", "))), which a last message replies to._\n\n"
            }
        }
        for (index, turn) in layout.turns.enumerated() {
            // An excerpt does not number its turns: they are not the conversation's first.
            if lastAnswer == nil { out += "## Turn \(index + 1)\n\n" }
            if let prompt = turn.prompt { out += "### You\n\n" + body(prompt) }
            for lane in turn.lanes {
                for entry in lane.messages {
                    let model = entry.message.modelRemoteID.map { names[$0] ?? $0 }
                    out += "### " + (lane.lane.map { "Lane \(inline($0.uppercased()))" } ?? "Response (lane not exposed)") + (model.map { " · \(inline($0))" } ?? "") + "\n\n"
                    if !entry.otherParents.isEmpty { out += "_Replies to \(inline(entry.otherParents.joined(separator: ", ")))_\n\n" }
                    out += body(entry.message)
                }
            }
            for message in turn.otherRoles { out += "### Role: \(inline(message.role ?? "not stated"))\n\n" + body(message) }
            for vote in turn.votes { out += "_Vote: \(inline(vote.value ?? "unknown"))_\n\n" }
        }
        for vote in layout.unmatchedVotes { out += "_Vote not tied to a single turn: \(inline(vote.value ?? "unknown"))_\n\n" }
        out += "---\n\n"
        out += "Exported from the Arena Suite archive. Source: journal record \(evidence.location.sequence), SHA-256 `\(evidence.digest)`, decoder `\(evidence.decoderVersion)`. "
        out += "This Markdown view is lossy: raw bytes, timing, per-message metadata, encrypted reasoning and attachment files are not included. "
        out += "Model names are claims from Arena, not verified identity.\n"
        return out
    }

    private static func body(_ message: DetailMessage) -> String {
        var out = ""
        if let status = message.status, status != "success" { out += "_Status: \(inline(status))_\n\n" }
        for block in message.blocks {
            switch block.kind {
            case .text: out += prose(block.text ?? "") + "\n\n"
            case .reasoning: out += "> **Reasoning**\n>\n" + quoted(prose(block.text ?? "")) + "\n\n"
            case .toolCall: out += "**Tool call** " + inline(block.toolName ?? "unknown") + "\n\n" + fenced(block.payload ?? "", language: "json")
            case .toolResult: out += "**Tool result** " + inline(block.toolName ?? block.toolCallID ?? "") + "\n\n" + fenced(block.payload ?? "", language: "json")
            case .sources: out += "**Sources**\n\n" + fenced(block.payload ?? "", language: "json")
            case .opaque: out += "**Unrecognized block** (kept as-is)\n\n" + fenced(block.payload ?? "", language: "json")
            }
        }
        for attachment in message.attachments {
            out += "_Attachment: \(inline(attachment.name ?? "unnamed"))\(attachment.contentType.map { " (\(inline($0)))" } ?? "")_\n\n"
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

    /// Conversation text is untrusted: every ASCII punctuation character that Markdown or HTML could
    /// interpret is backslash-escaped, so text renders literally and cannot open fences, headings,
    /// lists, links, images or HTML. Line breaks are kept as hard breaks.
    public static func prose(_ text: String) -> String {
        let special = Set("\\`*_{}[]()#+-.!<>|~=:\"'&$^@%")
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            if special.contains(character) { out.append("\\") }
            out.append(character)
        }
        return out.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "  \n")
    }

    /// Single-line untrusted value (titles, names, votes): escaped and without line breaks.
    public static func inline(_ text: String) -> String { prose(oneLine(text)) }

    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "  \n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)  " }.joined(separator: "\n")
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
            "facts_scope": "observed in journal records up to and including snapshot_sequence",
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

    public static func baseName(title: String?, remoteID: String, sequence: UInt64) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String((title ?? "Untitled").unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
            .split(separator: " ").joined(separator: " ")
        let short = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        let idAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let idPart = String(remoteID.unicodeScalars.filter { idAllowed.contains($0) }.prefix(8).map(Character.init))
        return "\(short.isEmpty ? "Untitled" : short) \(idPart.isEmpty ? "id" : idPart) r\(sequence)"
    }

    /// Temp file in the destination (same volume) → full sync → hard link to the first free name →
    /// remove the temp file. `link` never replaces an existing file, so nothing is overwritten, and a
    /// failure or cancellation leaves no partially written file under a final name.
    public static func write(_ data: Data, baseName: String, extension ext: String, into directory: URL) throws -> URL {
        guard !baseName.contains("/"), !baseName.contains("\0"), !baseName.hasPrefix("."), !ext.contains("/") else {
            throw ExportError.writeFailed("unsafe file name")
        }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        // Remove temp files left by an export that was killed mid-write.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix(".arena-suite-export-") && name.hasSuffix(".tmp") {
            unlink(directory.appendingPathComponent(name).path)
        }
        let temporary = directory.appendingPathComponent(".arena-suite-export-\(UUID().uuidString).tmp")
        // Owner-only, like the rest of the archive: exports contain private conversations.
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
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
            guard target.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
                throw ExportError.writeFailed("file name escapes the destination")
            }
            if link(temporary.path, target.path) == 0 { return target }
            guard errno == EEXIST else { throw ExportError.writeFailed("link (errno \(errno))") }
        }
        throw ExportError.writeFailed("no free file name")
    }
}
