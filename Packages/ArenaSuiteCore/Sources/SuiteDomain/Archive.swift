import Foundation

// Provider-neutral projection vocabulary (plan v3 §8). Produced by a versioned decoder from journal
// records; consumed by the rebuildable index. Every value traces back to a `RecordRef`.

/// The journal record a projected value came from.
public struct RecordRef: Hashable, Codable, Sendable {
    public let account: AccountID
    public let sequence: UInt64
    public let segment: Int
    public let offset: Int
    public let length: Int

    public init(account: AccountID, sequence: UInt64, segment: Int, offset: Int, length: Int) {
        self.account = account
        self.sequence = sequence
        self.segment = segment
        self.offset = offset
        self.length = length
    }
}

/// Conversation fields as the server stated them. Timestamps are kept verbatim; `updatedOrder` is an
/// exact sortable instant (microseconds since 1970) when the decoder could parse `updatedAt`.
public struct ConversationFacts: Equatable, Sendable {
    public var remoteID: String
    public var kind: String
    public var title: String?
    public var mode: String?
    public var modality: String?
    public var visibility: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var updatedOrder: Int64?
    public var archivedAt: String?
    public var deletedAt: String?

    public init(
        remoteID: String, kind: String, title: String? = nil, mode: String? = nil, modality: String? = nil,
        visibility: String? = nil, createdAt: String? = nil, updatedAt: String? = nil, updatedOrder: Int64? = nil,
        archivedAt: String? = nil, deletedAt: String? = nil
    ) {
        self.remoteID = remoteID
        self.kind = kind
        self.title = title
        self.mode = mode
        self.modality = modality
        self.visibility = visibility
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedOrder = updatedOrder
        self.archivedAt = archivedAt
        self.deletedAt = deletedAt
    }
}

public enum BlockKind: String, Codable, Sendable, CaseIterable {
    case text, reasoning, toolCall = "tool_call", toolResult = "tool_result", sources, opaque
}

/// One content block. `payload` holds structured parts (tool arguments/results, sources) as compact
/// JSON with sorted keys; `pointer` locates the block in the source record's body.
public struct ArchivedBlock: Equatable, Sendable {
    public var kind: BlockKind
    public var text: String?
    public var toolName: String?
    public var toolCallID: String?
    public var payload: String?
    public var pointer: String

    public init(kind: BlockKind, text: String? = nil, toolName: String? = nil, toolCallID: String? = nil, payload: String? = nil, pointer: String) {
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.toolCallID = toolCallID
        self.payload = payload
        self.pointer = pointer
    }
}

public struct ArchivedAttachment: Equatable, Sendable {
    public var name: String?
    public var contentType: String?
    /// Attachment URLs may be signed; the index keeps only whether one exists. The journal has the rest.
    public var hasURL: Bool

    public init(name: String?, contentType: String?, hasURL: Bool) {
        self.name = name
        self.contentType = contentType
        self.hasURL = hasURL
    }
}

public struct ArchivedMessage: Equatable, Sendable {
    public var remoteID: String
    public var role: String?
    public var status: String?
    /// Response lane as exposed (e.g. participant position `a`/`b`); never merged.
    public var lane: String?
    public var parentIDs: [String]
    public var modelRemoteID: String?
    public var createdAt: String?
    public var updatedAt: String?
    public var failureReason: String?
    public var blocks: [ArchivedBlock]
    public var attachments: [ArchivedAttachment]

    public init(
        remoteID: String, role: String?, status: String?, lane: String?, parentIDs: [String], modelRemoteID: String?,
        createdAt: String?, updatedAt: String?, failureReason: String?, blocks: [ArchivedBlock],
        attachments: [ArchivedAttachment]
    ) {
        self.remoteID = remoteID
        self.role = role
        self.status = status
        self.lane = lane
        self.parentIDs = parentIDs
        self.modelRemoteID = modelRemoteID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.failureReason = failureReason
        self.blocks = blocks
        self.attachments = attachments
    }
}

/// A model identity claim with its source. Claims are never upgraded to verified identity and
/// conflicting claims coexist (plan v3 §5 invariant 9).
public struct ModelClaim: Hashable, Sendable {
    /// Open set: values written by a newer decoder survive a round trip through older code.
    public struct Subject: RawRepresentable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let conversation = Subject(rawValue: "conversation")
        public static let message = Subject(rawValue: "message")
        public static let feedback = Subject(rawValue: "feedback")
    }
    public var subject: Subject
    public var subjectID: String
    /// Lane or side the claim is about (`a`, `b`, …) when stated; nil otherwise.
    public var role: String?
    public var modelID: String
    public var displayName: String?
    public var organization: String?
    public var provider: String?
    /// e.g. `history_list`, `detail_revealed`, `message_model_id`, `pairwise_feedback`.
    public var source: String
    /// Journal sequence of the record the claim was observed in. Set by the index; nil while decoding.
    public var recordSequence: UInt64?

    public init(
        subject: Subject, subjectID: String, role: String?, modelID: String, displayName: String? = nil,
        organization: String? = nil, provider: String? = nil, source: String, recordSequence: UInt64? = nil
    ) {
        self.subject = subject
        self.subjectID = subjectID
        self.role = role
        self.modelID = modelID
        self.displayName = displayName
        self.organization = organization
        self.provider = provider
        self.source = source
        self.recordSequence = recordSequence
    }
}

/// A pairwise preference the user recorded on Arena, as the server reports it.
public struct ArchivedFeedback: Equatable, Sendable {
    public var remoteID: String
    public var value: String?
    public var messageA: String?
    public var messageB: String?

    public init(remoteID: String, value: String?, messageA: String?, messageB: String?) {
        self.remoteID = remoteID
        self.value = value
        self.messageA = messageA
        self.messageB = messageB
    }
}

public struct ConversationSnapshot: Equatable, Sendable {
    public var facts: ConversationFacts
    public var messages: [ArchivedMessage]
    public var lastMessageIDs: [String]
    public var claims: [ModelClaim]
    public var feedback: [ArchivedFeedback]

    public init(facts: ConversationFacts, messages: [ArchivedMessage], lastMessageIDs: [String], claims: [ModelClaim], feedback: [ArchivedFeedback]) {
        self.facts = facts
        self.messages = messages
        self.lastMessageIDs = lastMessageIDs
        self.claims = claims
        self.feedback = feedback
    }
}

/// What one journal record contributes to the projection.
public enum ArchiveEvent: Equatable, Sendable {
    /// A conversation seen in a history list page (with the list's model claims).
    case listed(ConversationFacts, claims: [ModelClaim])
    /// A complete, valid detail response.
    case snapshot(ConversationSnapshot)
    /// The server answered 404 for this conversation's detail.
    case absent(remoteID: String)
    /// A structural observation that needs attention (never a silent drop).
    case warning(code: String, detail: String)
    /// A local note beside a recorded vote (a `local.control` record); the latest for a pair wins.
    case voteNote(VoteNote)
}

/// Decoder output for one record: events plus every key path the decoder did not recognize.
public struct DecodedRecord: Equatable, Sendable {
    public var events: [ArchiveEvent]
    /// Unrecognized JSON key paths (e.g. `$.messages[].newField`) with occurrence counts.
    public var unknownFields: [String: Int]

    public init(events: [ArchiveEvent] = [], unknownFields: [String: Int] = [:]) {
        self.events = events
        self.unknownFields = unknownFields
    }
}
