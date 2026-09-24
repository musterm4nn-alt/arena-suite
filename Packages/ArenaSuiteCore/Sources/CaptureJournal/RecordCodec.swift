import CryptoKit
import Foundation

public enum JournalError: Error, Equatable, Sendable {
    case alreadyOpen
    case closed
    /// A previous write or sync failed; reopen the journal to run recovery.
    case writerFailed
    case envelopeTooLarge(Int)
    case payloadTooLarge(Int)
    case io(operation: String, errno: Int32)
    case corruptSealedSegment(segment: Int, reason: String)
    case segmentGap(expected: Int, found: Int)
    case unsupportedFormat(segment: Int, offset: Int)
    case invalidManifest(segment: Int)
    case encodingFailed
    case recordNotFound
}

/// Physical location of a record. Stable for the life of the journal.
public struct JournalLocation: Sendable, Equatable, Hashable, Codable {
    public let segment: Int
    public let offset: Int
    public let length: Int
}

public struct AppendReceipt: Sendable, Equatable {
    public let sequence: UInt64
    public let recordID: UUID
    public let location: JournalLocation
    /// Hex SHA-256 record digest as stored in the trailer.
    public let digest: String
}

public struct JournalRecord: Sendable {
    public let location: JournalLocation
    public let envelope: JournalEnvelope
    public let envelopeBytes: Data
    public let payload: Data
    public let digest: Data
}

enum RecordCodec {
    static let magic: [UInt8] = Array("ASJ1".utf8)
    static let headerSize = 16
    static let digestSize = 32
    static let maximumEnvelopeBytes = 65_536
    static let maximumPayloadBytes = 33_554_432
    static let domain = Data("ASJ1-record-v1".utf8) + Data([0])

    static func header(envelopeLength: Int, payloadLength: Int) -> Data {
        var data = Data(magic)
        withUnsafeBytes(of: UInt32(envelopeLength).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(payloadLength).littleEndian) { data.append(contentsOf: $0) }
        return data
    }

    static func digest(header: Data, envelope: Data, payload: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: domain)
        hasher.update(data: header.subdata(in: header.startIndex + 4..<header.startIndex + headerSize))
        hasher.update(data: envelope)
        hasher.update(data: payload)
        return Data(hasher.finalize())
    }

    static func validateSizes(envelope: Int, payload: Int) throws {
        guard envelope >= 1 && envelope <= maximumEnvelopeBytes else { throw JournalError.envelopeTooLarge(envelope) }
        guard payload <= maximumPayloadBytes else { throw JournalError.payloadTooLarge(payload) }
    }
}

enum TailProblem: Equatable, Sendable {
    case truncated
    case badMagic
    case unsupportedMagic
    case lengthOutOfRange
    case digestMismatch
    case envelopeUndecodable
    case sequenceDiscontinuity(expected: UInt64, found: UInt64)

    var description: String {
        switch self {
        case .truncated: "truncated record"
        case .badMagic: "bad magic"
        case .unsupportedMagic: "unsupported format magic"
        case .lengthOutOfRange: "length out of range"
        case .digestMismatch: "digest mismatch"
        case .envelopeUndecodable: "undecodable envelope"
        case .sequenceDiscontinuity(let expected, let found): "sequence \(found) where \(expected) was expected"
        }
    }
}

struct ScannedRecord: Sendable {
    let offset: Int
    let length: Int
    let envelope: JournalEnvelope
    let envelopeRange: Range<Int>
    let payloadRange: Range<Int>
    let digest: Data
}

struct SegmentScan: Sendable {
    let records: [ScannedRecord]
    /// End offset of the last valid record.
    let validEnd: Int
    let problem: TailProblem?
}

enum SegmentScanner {
    /// Parses records from offset 0, stopping at the first invalid or incomplete record.
    /// Pass nil to skip sequence-continuity checks (single-record reads).
    static func scan(_ data: Data, expectedFirstSequence: UInt64?) -> SegmentScan {
        let decoder = JSONDecoder()
        var records: [ScannedRecord] = []
        var offset = 0
        var expected = expectedFirstSequence
        let count = data.count
        let base = data.startIndex
        while offset < count {
            guard count - offset >= RecordCodec.headerSize else {
                return SegmentScan(records: records, validEnd: offset, problem: .truncated)
            }
            let header = data.subdata(in: base + offset..<base + offset + RecordCodec.headerSize)
            let magic = Array(header.prefix(4))
            if magic != RecordCodec.magic {
                let isOtherVersion = Array(magic.prefix(3)) == Array("ASJ".utf8)
                return SegmentScan(
                    records: records, validEnd: offset, problem: isOtherVersion ? .unsupportedMagic : .badMagic)
            }
            let envelopeLength = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))) }
            let payloadLength64 = header.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
            guard envelopeLength >= 1, envelopeLength <= RecordCodec.maximumEnvelopeBytes,
                payloadLength64 <= UInt64(RecordCodec.maximumPayloadBytes)
            else {
                return SegmentScan(records: records, validEnd: offset, problem: .lengthOutOfRange)
            }
            let payloadLength = Int(payloadLength64)
            let total = RecordCodec.headerSize + envelopeLength + payloadLength + RecordCodec.digestSize
            guard count - offset >= total else {
                return SegmentScan(records: records, validEnd: offset, problem: .truncated)
            }
            let envelopeStart = offset + RecordCodec.headerSize
            let payloadStart = envelopeStart + envelopeLength
            let digestStart = payloadStart + payloadLength
            let envelopeBytes = data.subdata(in: base + envelopeStart..<base + payloadStart)
            let payload = data.subdata(in: base + payloadStart..<base + digestStart)
            let stored = data.subdata(in: base + digestStart..<base + digestStart + RecordCodec.digestSize)
            guard RecordCodec.digest(header: header, envelope: envelopeBytes, payload: payload) == stored else {
                return SegmentScan(records: records, validEnd: offset, problem: .digestMismatch)
            }
            guard let envelope = try? decoder.decode(JournalEnvelope.self, from: envelopeBytes) else {
                return SegmentScan(records: records, validEnd: offset, problem: .envelopeUndecodable)
            }
            if let expected, envelope.sequence != expected {
                return SegmentScan(
                    records: records, validEnd: offset,
                    problem: .sequenceDiscontinuity(expected: expected, found: envelope.sequence))
            }
            records.append(
                ScannedRecord(
                    offset: offset, length: total, envelope: envelope, envelopeRange: envelopeStart..<payloadStart,
                    payloadRange: payloadStart..<digestStart, digest: stored))
            expected = envelope.sequence + 1
            offset += total
        }
        return SegmentScan(records: records, validEnd: offset, problem: nil)
    }
}
