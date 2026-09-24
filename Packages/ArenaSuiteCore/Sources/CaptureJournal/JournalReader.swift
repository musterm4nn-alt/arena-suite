import Foundation

/// Read-only access. Safe to use while a writer is open: an incomplete record at the end of the
/// final segment is reported as `incompleteTail`, not as an error.
public struct JournalReader: Sendable {
    private let layout: JournalLayout

    public init(root: URL) { layout = JournalLayout(root: root) }

    public struct Summary: Sendable, Equatable {
        public let recordCount: Int
        public let lastSequence: UInt64?
        /// Start of unparseable bytes at the end of the final segment, if any.
        public let incompleteTail: JournalLocation?
    }

    /// Visits every valid record in sequence order.
    @discardableResult
    public func forEach(_ body: (JournalRecord) throws -> Void) throws -> Summary {
        let numbers = try layout.segmentNumbers()
        var expected: UInt64 = 1
        var count = 0
        var tail: JournalLocation?
        for (index, number) in numbers.enumerated() {
            guard number == index + 1 else { throw JournalError.segmentGap(expected: index + 1, found: number) }
            let data = try Data(contentsOf: layout.segmentURL(number), options: .mappedIfSafe)
            let scan = SegmentScanner.scan(data, expectedFirstSequence: expected)
            if let problem = scan.problem {
                guard number == numbers.last else {
                    throw JournalError.corruptSealedSegment(segment: number, reason: problem.description)
                }
                if problem == .unsupportedMagic { throw JournalError.unsupportedFormat(segment: number, offset: scan.validEnd) }
                tail = JournalLocation(segment: number, offset: scan.validEnd, length: data.count - scan.validEnd)
            }
            for record in scan.records {
                try body(Self.materialize(record, data: data, segment: number))
                count += 1
            }
            if let last = scan.records.last { expected = last.envelope.sequence + 1 }
        }
        return Summary(recordCount: count, lastSequence: expected > 1 ? expected - 1 : nil, incompleteTail: tail)
    }

    public func readAll() throws -> [JournalRecord] {
        var records: [JournalRecord] = []
        try forEach { records.append($0) }
        return records
    }

    /// Reads and fully validates one record by location.
    public func read(at location: JournalLocation) throws -> JournalRecord {
        let data = try Data(contentsOf: layout.segmentURL(location.segment), options: .mappedIfSafe)
        guard location.offset >= 0, location.length > 0, location.offset + location.length <= data.count else {
            throw JournalError.recordNotFound
        }
        let slice = data.subdata(in: location.offset..<location.offset + location.length)
        let scan = SegmentScanner.scan(slice, expectedFirstSequence: nil)
        guard scan.problem == nil, let record = scan.records.first, record.length == location.length else {
            throw JournalError.recordNotFound
        }
        return Self.materialize(record, data: slice, segment: location.segment, baseOffset: location.offset)
    }

    private static func materialize(_ record: ScannedRecord, data: Data, segment: Int, baseOffset: Int = 0)
        -> JournalRecord
    {
        JournalRecord(
            location: JournalLocation(segment: segment, offset: baseOffset + record.offset, length: record.length),
            envelope: record.envelope,
            envelopeBytes: data.subdata(in: record.envelopeRange),
            payload: data.subdata(in: record.payloadRange),
            digest: record.digest)
    }
}

public struct JournalVerificationReport: Sendable, Equatable {
    public struct Issue: Sendable, Equatable {
        public let segment: Int?
        public let offset: Int?
        public let detail: String
    }
    public let segmentsChecked: Int
    public let recordsChecked: Int
    public let lastSequence: UInt64?
    public let issues: [Issue]
    public var isClean: Bool { issues.isEmpty }
}

/// Non-mutating verification. Never repairs anything.
public enum JournalVerifier {
    public static func verify(root: URL) throws -> JournalVerificationReport {
        let layout = JournalLayout(root: root)
        var issues: [JournalVerificationReport.Issue] = []
        func issue(_ segment: Int?, _ offset: Int?, _ detail: String) {
            issues.append(.init(segment: segment, offset: offset, detail: detail))
        }
        for url in try layout.temporaryFiles() { issue(nil, nil, "leftover temporary file \(url.lastPathComponent)") }
        let numbers = try layout.segmentNumbers()
        var expected: UInt64 = 1
        var records = 0
        for (index, number) in numbers.enumerated() {
            if number != index + 1 { issue(number, nil, "segment numbering gap; expected \(index + 1)") }
            let data = try Data(contentsOf: layout.segmentURL(number), options: .mappedIfSafe)
            let scan = SegmentScanner.scan(data, expectedFirstSequence: expected)
            records += scan.records.count
            if let problem = scan.problem {
                issue(number, scan.validEnd, "\(problem.description); \(data.count - scan.validEnd) bytes after last valid record")
            }
            let manifestURL = layout.manifestURL(number)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                if let manifest = try? SealManifest.load(manifestURL, segment: number) {
                    if manifest.byteSize != UInt64(data.count) || manifest.sha256 != sha256Hex(data) {
                        issue(number, nil, "segment differs from its seal manifest")
                    }
                    if manifest.recordCount != UInt64(scan.records.count)
                        || manifest.firstSequence != scan.records.first?.envelope.sequence
                        || manifest.lastSequence != scan.records.last?.envelope.sequence
                    {
                        issue(number, nil, "seal manifest disagrees with records")
                    }
                } else {
                    issue(number, nil, "unreadable seal manifest")
                }
            } else if number != numbers.last {
                issue(number, nil, "non-final segment is not sealed")
            }
            if let last = scan.records.last { expected = last.envelope.sequence + 1 }
        }
        return JournalVerificationReport(
            segmentsChecked: numbers.count, recordsChecked: records, lastSequence: expected > 1 ? expected - 1 : nil,
            issues: issues)
    }
}
