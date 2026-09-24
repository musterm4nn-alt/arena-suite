import Foundation

/// One segment as copied by `JournalCopy`.
public struct CopiedSegment: Sendable, Equatable, Codable {
    public let segment: Int
    public let byteSize: UInt64
    public let sha256: String
    public let firstSequence: UInt64?
    public let lastSequence: UInt64?
    public let recordCount: UInt64
    /// True if the source segment was sealed and its seal manifest was copied with it.
    public let sealed: Bool

    private enum CodingKeys: String, CodingKey {
        case segment, sealed, sha256
        case byteSize = "byte_size"
        case firstSequence = "first_sequence"
        case lastSequence = "last_sequence"
        case recordCount = "record_count"
    }

    // Integers that can exceed 2^53 are strings, as in envelopes and seal manifests.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func number(_ key: CodingKeys) throws -> UInt64? {
            guard let text = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
            guard let value = UInt64(text) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Not a decimal UInt64")
            }
            return value
        }
        segment = try c.decode(Int.self, forKey: .segment)
        sealed = try c.decode(Bool.self, forKey: .sealed)
        sha256 = try c.decode(String.self, forKey: .sha256)
        guard let size = try number(.byteSize), let count = try number(.recordCount) else {
            throw DecodingError.dataCorruptedError(forKey: .byteSize, in: c, debugDescription: "Missing size or count")
        }
        byteSize = size
        recordCount = count
        firstSequence = try number(.firstSequence)
        lastSequence = try number(.lastSequence)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(segment, forKey: .segment)
        try c.encode(sealed, forKey: .sealed)
        try c.encode(sha256, forKey: .sha256)
        try c.encode(String(byteSize), forKey: .byteSize)
        try c.encode(String(recordCount), forKey: .recordCount)
        try c.encodeIfPresent(firstSequence.map(String.init), forKey: .firstSequence)
        try c.encodeIfPresent(lastSequence.map(String.init), forKey: .lastSequence)
    }

    init(segment: Int, byteSize: UInt64, sha256: String, firstSequence: UInt64?, lastSequence: UInt64?, recordCount: UInt64, sealed: Bool) {
        self.segment = segment
        self.byteSize = byteSize
        self.sha256 = sha256
        self.firstSequence = firstSequence
        self.lastSequence = lastSequence
        self.recordCount = recordCount
        self.sealed = sealed
    }
}

/// Copies a journal's acknowledged records to another directory without taking the writer's lock
/// (plan v3 §13, Phase 7 backup). Sealed segments are copied byte for byte and must match their seal
/// manifest; the final unsealed segment is copied up to its last complete record, so a record being
/// appended concurrently is never copied half-written. The destination is an ordinary journal: it
/// opens, verifies and replays like the source. Never modifies the source.
public enum JournalCopy {
    public static func copy(from source: URL, to destination: URL) throws -> [CopiedSegment] {
        let from = JournalLayout(root: source)
        let to = JournalLayout(root: destination)
        let numbers = try from.segmentNumbers()
        try FileManager.default.createDirectory(
            at: to.segments, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var copied: [CopiedSegment] = []
        var expected: UInt64 = 1
        for (index, number) in numbers.enumerated() {
            guard number == index + 1 else { throw JournalError.segmentGap(expected: index + 1, found: number) }
            let isLast = number == numbers.last
            let data = try Data(contentsOf: from.segmentURL(number))
            let scan = SegmentScanner.scan(data, expectedFirstSequence: expected)
            let manifestURL = from.manifestURL(number)
            var sealed = false
            var bytes = data
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                let manifest = try SealManifest.load(manifestURL, segment: number)
                guard scan.problem == nil, manifest.byteSize == UInt64(data.count), manifest.sha256 == sha256Hex(data),
                    manifest.recordCount == UInt64(scan.records.count)
                else {
                    throw JournalError.corruptSealedSegment(segment: number, reason: "differs from its seal manifest")
                }
                sealed = true
            } else {
                // Only the final segment may be unsealed; it may end in a record still being written.
                guard isLast else {
                    throw JournalError.corruptSealedSegment(segment: number, reason: "non-final segment is not sealed")
                }
                if let problem = scan.problem, problem == .unsupportedMagic {
                    throw JournalError.unsupportedFormat(segment: number, offset: scan.validEnd)
                }
                bytes = data.prefix(scan.validEnd)
            }
            // An empty unsealed segment carries nothing; the writer creates it again on open.
            if !sealed && scan.records.isEmpty { break }
            try write(bytes, to: to.segmentURL(number))
            if sealed { try write(try Data(contentsOf: manifestURL), to: to.manifestURL(number)) }
            copied.append(
                CopiedSegment(
                    segment: number, byteSize: UInt64(bytes.count), sha256: sha256Hex(bytes),
                    firstSequence: scan.records.first?.envelope.sequence,
                    lastSequence: scan.records.last?.envelope.sequence, recordCount: UInt64(scan.records.count),
                    sealed: sealed))
            if let last = scan.records.last { expected = last.envelope.sequence + 1 }
        }
        return copied
    }

    /// SHA-256 (lowercase hex) of a file's contents.
    public static func sha256(of url: URL) throws -> String {
        sha256Hex(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    private static func write(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw JournalError.io(operation: "write \(url.lastPathComponent)", errno: errno) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
}
