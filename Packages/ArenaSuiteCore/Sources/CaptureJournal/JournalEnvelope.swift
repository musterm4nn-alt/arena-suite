import Foundation

/// Caller metadata value. Deliberately has no floating-point case: journal metadata must round-trip exactly.
public enum JournalValue: Sendable, Equatable, Codable {
    case string(String)
    case integer(Int64)
    case bool(Bool)
    case null
    case array([JournalValue])
    case object([String: JournalValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JournalValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JournalValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported journal value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// Wall time at millisecond precision plus an optional `mach_continuous_time()` reading.
/// Milliseconds are stored exactly so envelopes re-encode byte-identically.
public struct JournalTimestamp: Sendable, Equatable {
    public let wallMilliseconds: Int64
    public let monotonicTicks: UInt64?

    public init(wallMilliseconds: Int64, monotonicTicks: UInt64? = nil) {
        self.wallMilliseconds = wallMilliseconds
        self.monotonicTicks = monotonicTicks
    }

    public static func now() -> JournalTimestamp {
        let ticks = mach_continuous_time()
        let milliseconds = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        return JournalTimestamp(wallMilliseconds: milliseconds, monotonicTicks: ticks)
    }

    var iso8601: String {
        let seconds = Int(wallMilliseconds.floorDivided(by: 1000))
        let millis = Int(wallMilliseconds - Int64(seconds) * 1000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", parts.year!, parts.month!, parts.day!, parts.hour!,
            parts.minute!, parts.second!, millis)
    }

    static func parseWallMilliseconds(_ text: String) -> Int64? {
        let pattern = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{3})Z$/
        guard let match = text.wholeMatch(of: pattern) else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = Int(match.1)
        components.month = Int(match.2)
        components.day = Int(match.3)
        components.hour = Int(match.4)
        components.minute = Int(match.5)
        components.second = Int(match.6)
        guard let date = components.date, let millis = Int64(match.7) else { return nil }
        return Int64(date.timeIntervalSince1970) * 1000 + millis
    }
}

extension Int64 {
    fileprivate func floorDivided(by divisor: Int64) -> Int64 {
        let quotient = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }
}

/// Well-known record kinds. The journal treats kinds as opaque strings except for job tracking.
public enum JournalKind {
    public static let jobStarted = "job.started"
    public static let jobFinished = "job.finished"
    public static let journalRecovered = "journal.recovered"
}

/// The stored envelope. See `Docs/journal-format-v1.md`.
public struct JournalEnvelope: Sendable, Equatable, Codable {
    public let format: Int
    public let recordID: UUID
    public let sequence: UInt64
    public let kind: String
    public let accountID: UUID?
    public let jobID: UUID?
    public let timestamp: JournalTimestamp
    public let payloadRepresentation: String?
    public let transformations: [String]
    public let metadata: [String: JournalValue]

    public init(
        format: Int = 1, recordID: UUID, sequence: UInt64, kind: String, accountID: UUID?, jobID: UUID?,
        timestamp: JournalTimestamp, payloadRepresentation: String?, transformations: [String],
        metadata: [String: JournalValue]
    ) {
        self.format = format
        self.recordID = recordID
        self.sequence = sequence
        self.kind = kind
        self.accountID = accountID
        self.jobID = jobID
        self.timestamp = timestamp
        self.payloadRepresentation = payloadRepresentation
        self.transformations = transformations
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey {
        case format
        case recordID = "record_id"
        case sequence, kind
        case accountID = "account_id"
        case jobID = "job_id"
        case observedAt = "observed_at"
        case monotonicTicks = "monotonic_ticks"
        case payloadRepresentation = "payload_representation"
        case transformations, metadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(Int.self, forKey: .format)
        recordID = try container.decode(UUID.self, forKey: .recordID)
        guard let sequence = UInt64(try container.decode(String.self, forKey: .sequence)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sequence, in: container, debugDescription: "Sequence is not a decimal UInt64")
        }
        self.sequence = sequence
        kind = try container.decode(String.self, forKey: .kind)
        accountID = try container.decodeIfPresent(UUID.self, forKey: .accountID)
        jobID = try container.decodeIfPresent(UUID.self, forKey: .jobID)
        guard let wall = JournalTimestamp.parseWallMilliseconds(try container.decode(String.self, forKey: .observedAt))
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .observedAt, in: container, debugDescription: "observed_at is not ISO 8601 with milliseconds")
        }
        var ticks: UInt64?
        if let text = try container.decodeIfPresent(String.self, forKey: .monotonicTicks) {
            guard let value = UInt64(text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .monotonicTicks, in: container, debugDescription: "Ticks are not a decimal UInt64")
            }
            ticks = value
        }
        timestamp = JournalTimestamp(wallMilliseconds: wall, monotonicTicks: ticks)
        payloadRepresentation = try container.decodeIfPresent(String.self, forKey: .payloadRepresentation)
        transformations = try container.decode([String].self, forKey: .transformations)
        metadata = try container.decode([String: JournalValue].self, forKey: .metadata)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(recordID, forKey: .recordID)
        try container.encode(String(sequence), forKey: .sequence)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(accountID, forKey: .accountID)
        try container.encodeIfPresent(jobID, forKey: .jobID)
        try container.encode(timestamp.iso8601, forKey: .observedAt)
        try container.encodeIfPresent(timestamp.monotonicTicks.map(String.init), forKey: .monotonicTicks)
        try container.encodeIfPresent(payloadRepresentation, forKey: .payloadRepresentation)
        try container.encode(transformations, forKey: .transformations)
        try container.encode(metadata, forKey: .metadata)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// A record to append. The writer assigns the sequence number.
public struct JournalDraft: Sendable {
    public var kind: String
    public var payload: Data
    public var recordID: UUID
    public var accountID: UUID?
    public var jobID: UUID?
    public var timestamp: JournalTimestamp
    public var payloadRepresentation: String?
    public var transformations: [String]
    public var metadata: [String: JournalValue]

    public init(
        kind: String, payload: Data = Data(), recordID: UUID = UUID(), accountID: UUID? = nil, jobID: UUID? = nil,
        timestamp: JournalTimestamp = .now(), payloadRepresentation: String? = nil, transformations: [String] = [],
        metadata: [String: JournalValue] = [:]
    ) {
        self.kind = kind
        self.payload = payload
        self.recordID = recordID
        self.accountID = accountID
        self.jobID = jobID
        self.timestamp = timestamp
        self.payloadRepresentation = payloadRepresentation
        self.transformations = transformations
        self.metadata = metadata
    }
}
