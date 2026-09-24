import ApplicationActions
import CaptureJournal
import Foundation
import SuiteDomain

// Arena response decoder (plan v3 §10, N-012). Reads journal records and produces neutral events;
// never writes SQL. Declared boundary: `JSONSerialization` keeps the first of duplicate keys (observed
// on macOS 27) and
// represents numbers as `NSNumber`, so re-serialized payloads may differ from the raw bytes for
// such input; the journal keeps the exact bytes. Every unknown key is counted by JSON path so protocol drift is visible, and
// `metadata` subtrees (anti-abuse telemetry, plan v3 §12) are never projected nor reported.

public struct ArenaArchiveDecoder: ArchiveDecoding {
    public let version = "arena-decoder/1"

    public init() {}

    public func decode(_ record: JournalRecord, account: AccountID) -> DecodedRecord {
        let envelope = record.envelope
        guard envelope.kind == "exchange" else { return DecodedRecord() }
        let role = envelope.metadata["role"]?.stringValue
        let status = envelope.metadata["status"]?.intValue
        if role == "detail", status == 404 {
            guard let entryID = envelope.metadata["entry_id"]?.stringValue else { return DecodedRecord() }
            return DecodedRecord(events: [.absent(remoteID: entryID)])
        }
        guard status == 200, envelope.metadata["transfer_end"] == .string("complete") else {
            return DecodedRecord()
        }
        guard let json = try? JSONSerialization.jsonObject(with: record.payload) else {
            return DecodedRecord(events: [.warning(code: "body_unrecognized", detail: role ?? "unknown")])
        }
        switch role {
        case "list": return Self.decodeList(json)
        case "detail": return Self.decodeDetail(json, metadata: envelope.metadata)
        default: return DecodedRecord()
        }
    }

    // MARK: List

    private static let listTopKeys: Set<String> = ["entries", "pagination", "partial", "failedSources"]
    private static let listEntryKeys: Set<String> = [
        "id", "type", "title", "createdAt", "updatedAt", "mode", "modality", "modelAId", "modelBId",
        "modelAOrganization", "modelBOrganization", "archivedAt", "codingSessionStatus", "productMode",
    ]
    private static let paginationKeys: Set<String> = ["hasMore", "cursor", "limit"]

    private static func decodeList(_ json: Any) -> DecodedRecord {
        var f = Findings()
        guard let object = json as? [String: Any] else {
            f.warn("list_unrecognized", "$")
            return f.record([])
        }
        f.checkKeys(object, known: listTopKeys, path: "$")
        guard let rawEntries = object["entries"] as? [Any] else {
            f.warn("list_unrecognized", "$.entries")
            return f.record([])
        }
        var events: [ArchiveEvent] = []
        for raw in rawEntries {
            let path = "$.entries[]"
            guard let entry = raw as? [String: Any] else {
                f.warn("element_skipped", path)
                continue
            }
            f.checkKeys(entry, known: listEntryKeys, path: path)
            guard let id = f.string(entry, "id", path), !id.isEmpty else {
                f.warn("element_skipped", "\(path).id")
                continue
            }
            let updatedAt = f.string(entry, "updatedAt", path)
            let facts = ConversationFacts(
                remoteID: id, kind: f.string(entry, "type", path) ?? "[unknown]", title: f.string(entry, "title", path),
                mode: f.string(entry, "mode", path), modality: f.string(entry, "modality", path), visibility: nil,
                createdAt: f.string(entry, "createdAt", path), updatedAt: updatedAt,
                updatedOrder: updatedAt.flatMap { SourceInstant($0)?.microseconds },
                archivedAt: f.string(entry, "archivedAt", path), deletedAt: nil)
            var claims: [ModelClaim] = []
            for side in ["A", "B"] {
                if let model = f.string(entry, "model\(side)Id", path) {
                    claims.append(
                        ModelClaim(
                            subject: .conversation, subjectID: id, role: side.lowercased(), modelID: model,
                            organization: f.string(entry, "model\(side)Organization", path), source: "history_list"))
                }
            }
            events.append(.listed(facts, claims: claims))
        }
        if let pagination = object["pagination"] as? [String: Any] {
            f.checkKeys(pagination, known: paginationKeys, path: "$.pagination")
        }
        return f.record(events)
    }

    // MARK: Detail

    private static let detailTopKeys: Set<String> = [
        "id", "userId", "title", "mode", "visibility", "lastMessageIds", "archivedAt", "deletedAt",
        "deletionPendingProcessing", "createdAt", "updatedAt", "messages", "maskedEvaluations",
        "pairwiseFeedbacks", "pointwiseFeedbacks", "revealedModels",
    ]
    private static let messageKeys: Set<String> = [
        "id", "role", "status", "content", "reasoning", "sources", "createdAt", "updatedAt", "evaluationId",
        "evaluationSessionId", "experimental_attachments", "failureReason", "metadata", "modelId",
        "parentMessageIds", "participantPosition", "activeWorkflowRunId", "pairwiseFeedbackId",
    ]
    private static let contentBlockKeys: Set<String> = [
        "type", "text", "toolCallId", "toolName", "args", "result", "providerOptions",
    ]
    private static let attachmentKeys: Set<String> = ["name", "contentType", "url"]
    private static let revealedModelKeys: Set<String> = [
        "id", "name", "displayName", "publicName", "organization", "provider", "capabilities", "userSelectable",
    ]
    private static let maskedEvaluationKeys: Set<String> = ["id", "arenaId", "modality", "metadata"]
    private static let pairwiseFeedbackKeys: Set<String> = [
        "id", "arenaId", "messageAId", "messageBId", "modelAId", "modelBId", "value",
    ]

    private static func decodeDetail(_ json: Any, metadata: [String: JournalValue]) -> DecodedRecord {
        var f = Findings()
        guard let object = json as? [String: Any] else {
            f.warn("detail_unrecognized", "$")
            return f.record([])
        }
        f.checkKeys(object, known: detailTopKeys, path: "$")
        guard let id = f.string(object, "id", "$"), !id.isEmpty else {
            f.warn("detail_unrecognized", "$.id")
            return f.record([])
        }
        let updatedAt = f.string(object, "updatedAt", "$")
        let facts = ConversationFacts(
            remoteID: id, kind: metadata["entry_type"]?.stringValue ?? "evaluation", title: f.string(object, "title", "$"),
            mode: f.string(object, "mode", "$"), modality: nil, visibility: f.string(object, "visibility", "$"),
            createdAt: f.string(object, "createdAt", "$"), updatedAt: updatedAt,
            updatedOrder: updatedAt.flatMap { SourceInstant($0)?.microseconds },
            archivedAt: f.string(object, "archivedAt", "$"), deletedAt: f.string(object, "deletedAt", "$"))
        let lastMessageIDs = f.strings(object["lastMessageIds"], "$.lastMessageIds")

        var claims: [ModelClaim] = []
        var messages: [ArchivedMessage] = []
        var seenMessageIDs = Set<String>()
        for raw in f.array(object["messages"], "$.messages") {
            let path = "$.messages[]"
            guard let message = raw as? [String: Any] else {
                f.warn("element_skipped", path)
                continue
            }
            f.checkKeys(message, known: messageKeys, path: path)
            guard let messageID = f.string(message, "id", path), !messageID.isEmpty else {
                f.warn("element_skipped", "\(path).id")
                continue
            }
            // A repeated id cannot key two messages in one snapshot; record it, keep the first.
            guard seenMessageIDs.insert(messageID).inserted else {
                f.warn("duplicate_message_id", "\(path).id")
                continue
            }
            let lane = f.string(message, "participantPosition", path)
            var blocks = decodeBlocks(message["content"], &f)
            if let reasoning = message["reasoning"], !(reasoning is NSNull) {
                if let text = reasoning as? String {
                    blocks.append(ArchivedBlock(kind: .reasoning, text: text, pointer: "\(path).reasoning"))
                } else {
                    // Structured reasoning is kept, not dropped.
                    f.warn("type_mismatch", "\(path).reasoning")
                    blocks.append(ArchivedBlock(kind: .opaque, payload: canonicalJSON(reasoning), pointer: "\(path).reasoning"))
                }
            }
            if let sources = message["sources"], !(sources is NSNull) {
                if !(sources is [Any]) { f.warn("type_mismatch", "\(path).sources") }
                if (sources as? [Any])?.isEmpty != true {
                    blocks.append(ArchivedBlock(kind: .sources, payload: canonicalJSON(sources), pointer: "\(path).sources"))
                }
            }
            let attachments = decodeAttachments(message["experimental_attachments"], &f)
            let modelRemoteID = f.string(message, "modelId", path)
            if let modelRemoteID {
                claims.append(
                    ModelClaim(subject: .message, subjectID: messageID, role: lane, modelID: modelRemoteID, source: "message_model_id"))
            }
            messages.append(
                ArchivedMessage(
                    remoteID: messageID, role: f.string(message, "role", path), status: f.string(message, "status", path),
                    lane: lane, parentIDs: f.strings(message["parentMessageIds"], "\(path).parentMessageIds"),
                    modelRemoteID: modelRemoteID, createdAt: f.string(message, "createdAt", path),
                    updatedAt: f.string(message, "updatedAt", path), failureReason: f.string(message, "failureReason", path),
                    blocks: blocks, attachments: attachments))
        }

        for raw in f.array(object["revealedModels"], "$.revealedModels") {
            let path = "$.revealedModels[]"
            guard let model = raw as? [String: Any] else {
                f.warn("element_skipped", path)
                continue
            }
            f.checkKeys(model, known: revealedModelKeys, path: path)
            guard let modelID = f.string(model, "id", path) else {
                f.warn("element_skipped", "\(path).id")
                continue
            }
            claims.append(
                ModelClaim(
                    subject: .conversation, subjectID: id, role: nil, modelID: modelID,
                    displayName: f.string(model, "displayName", path), organization: f.string(model, "organization", path),
                    provider: f.string(model, "provider", path), source: "detail_revealed"))
        }

        var feedback: [ArchivedFeedback] = []
        for raw in f.array(object["pairwiseFeedbacks"], "$.pairwiseFeedbacks") {
            let path = "$.pairwiseFeedbacks[]"
            guard let item = raw as? [String: Any] else {
                f.warn("element_skipped", path)
                continue
            }
            f.checkKeys(item, known: pairwiseFeedbackKeys, path: path)
            guard let feedbackID = f.string(item, "id", path) else {
                f.warn("element_skipped", "\(path).id")
                continue
            }
            feedback.append(
                ArchivedFeedback(
                    remoteID: feedbackID, value: f.string(item, "value", path),
                    messageA: f.string(item, "messageAId", path), messageB: f.string(item, "messageBId", path)))
            for side in ["A", "B"] {
                if let model = f.string(item, "model\(side)Id", path) {
                    claims.append(
                        ModelClaim(subject: .feedback, subjectID: feedbackID, role: side.lowercased(), modelID: model, source: "pairwise_feedback"))
                }
            }
        }

        // Known, not projected: keys are checked, nothing is emitted.
        for raw in f.array(object["maskedEvaluations"], "$.maskedEvaluations") {
            if let item = raw as? [String: Any] {
                f.checkKeys(item, known: maskedEvaluationKeys, path: "$.maskedEvaluations[]")
            } else {
                f.warn("element_skipped", "$.maskedEvaluations[]")
            }
        }
        // Not projected; every key inside is reported as unknown.
        for raw in f.array(object["pointwiseFeedbacks"], "$.pointwiseFeedbacks") {
            f.reportUnknownSubtree(raw, path: "$.pointwiseFeedbacks[]")
        }

        let snapshot = ConversationSnapshot(
            facts: facts, messages: messages, lastMessageIDs: lastMessageIDs, claims: claims, feedback: feedback)
        return f.record([.snapshot(snapshot)])
    }

    // MARK: Blocks / attachments

    private static func decodeBlocks(_ content: Any?, _ f: inout Findings) -> [ArchivedBlock] {
        guard let content, !(content is NSNull) else { return [] }
        if let text = content as? String {
            return [ArchivedBlock(kind: .text, text: text, pointer: "$.messages[].content")]
        }
        guard let parts = content as? [Any] else {
            f.warn("type_mismatch", "$.messages[].content")
            return [ArchivedBlock(kind: .opaque, payload: canonicalJSON(content), pointer: "$.messages[].content")]
        }
        var blocks: [ArchivedBlock] = []
        for (index, raw) in parts.enumerated() {
            let pointer = "$.messages[].content[\(index)]"
            guard let part = raw as? [String: Any] else {
                blocks.append(ArchivedBlock(kind: .opaque, payload: canonicalJSON(raw), pointer: pointer))
                continue
            }
            let path = "$.messages[].content[]"
            f.checkKeys(part, known: contentBlockKeys, path: path)
            switch part["type"] as? String ?? "" {
            case "text":
                blocks.append(ArchivedBlock(kind: .text, text: f.string(part, "text", path), pointer: pointer))
            case "reasoning":
                blocks.append(ArchivedBlock(kind: .reasoning, text: f.string(part, "text", path), pointer: pointer))
            case "tool-call":
                blocks.append(
                    ArchivedBlock(
                        kind: .toolCall, toolName: f.string(part, "toolName", path), toolCallID: f.string(part, "toolCallId", path),
                        payload: canonicalJSON(part["args"]), pointer: pointer))
            case "tool-result":
                blocks.append(
                    ArchivedBlock(
                        kind: .toolResult, toolName: f.string(part, "toolName", path), toolCallID: f.string(part, "toolCallId", path),
                        payload: canonicalJSON(part["result"]), pointer: pointer))
            default:
                // `providerOptions` (encrypted reasoning) is never projected, even inside opaque blocks.
                var visible = part
                visible["providerOptions"] = nil
                blocks.append(ArchivedBlock(kind: .opaque, payload: canonicalJSON(visible), pointer: pointer))
            }
        }
        return blocks
    }

    private static func decodeAttachments(_ raw: Any?, _ f: inout Findings) -> [ArchivedAttachment] {
        var attachments: [ArchivedAttachment] = []
        let path = "$.messages[].experimental_attachments[]"
        for item in f.array(raw, "$.messages[].experimental_attachments") {
            guard let object = item as? [String: Any] else {
                f.warn("element_skipped", path)
                continue
            }
            f.checkKeys(object, known: attachmentKeys, path: path)
            let url = f.string(object, "url", path)
            attachments.append(
                ArchivedAttachment(
                    name: f.string(object, "name", path), contentType: f.string(object, "contentType", path),
                    hasURL: !(url ?? "").isEmpty))
        }
        return attachments
    }

    // MARK: Findings

    /// Collects unknown key paths and structural warnings for one record. Nothing observed is
    /// dropped silently: every element that cannot be projected and every value of an unexpected
    /// JSON type becomes a counted warning naming its path (plan v3 §5 invariant 3).
    private struct Findings {
        var unknown: [String: Int] = [:]
        var warnings: [String: Int] = [:]  // "code|path" → count, emitted in sorted order

        mutating func warn(_ code: String, _ path: String) { warnings["\(code)|\(path)", default: 0] += 1 }

        mutating func checkKeys(_ object: [String: Any], known: Set<String>, path: String) {
            for key in object.keys where key != "metadata" && !known.contains(key) {
                unknown["\(path).\(key)", default: 0] += 1
            }
        }

        /// A string field. Absent or JSON null → nil; any other type → nil plus a warning.
        mutating func string(_ object: [String: Any], _ key: String, _ path: String) -> String? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            if let text = value as? String { return text }
            warn("type_mismatch", "\(path).\(key)")
            return nil
        }

        /// An array of strings. Non-string elements or a non-array value are warned, never silently emptied.
        mutating func strings(_ value: Any?, _ path: String) -> [String] {
            let items = array(value, path)
            let strings = items.compactMap { $0 as? String }
            if strings.count != items.count { warn("type_mismatch", "\(path)[]") }
            return strings
        }

        /// An array. Absent or null → []; any other type → [] plus a warning.
        mutating func array(_ value: Any?, _ path: String) -> [Any] {
            guard let value, !(value is NSNull) else { return [] }
            if let items = value as? [Any] { return items }
            warn("type_mismatch", path)
            return []
        }

        mutating func reportUnknownSubtree(_ value: Any, path: String) {
            if let object = value as? [String: Any] {
                for (key, sub) in object where key != "metadata" {
                    unknown["\(path).\(key)", default: 0] += 1
                    reportUnknownSubtree(sub, path: "\(path).\(key)")
                }
            } else if let items = value as? [Any] {
                for element in items { reportUnknownSubtree(element, path: "\(path)[]") }
            }
        }

        func record(_ events: [ArchiveEvent]) -> DecodedRecord {
            let warningEvents = warnings.keys.sorted().map { key -> ArchiveEvent in
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                return .warning(code: parts[0], detail: "\(parts[1]) ×\(warnings[key]!)")
            }
            return DecodedRecord(events: events + warningEvents, unknownFields: unknown)
        }
    }

    // MARK: Canonical JSON

    private static func canonicalJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension JournalValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .integer(let value) = self { return Int(value) }
        return nil
    }
}
