import Darwin
import Foundation

public struct QuarantinedRange: Sendable, Equatable {
    public let segment: Int
    public let offset: Int
    public let length: Int
    public let file: String
    public let reason: String
}

public struct JournalRecoveryReport: Sendable, Equatable {
    /// Highest valid sequence after recovery, or nil for an empty journal.
    public let lastSequence: UInt64?
    public let quarantined: [QuarantinedRange]
    public let sealedDuringRecovery: [Int]
    public let removedTemporaryFiles: [String]
    /// Jobs with `job.started` and no later `job.finished`, in start order.
    public let unterminatedJobIDs: [UUID]
}

struct ActiveSegmentState: Sendable {
    let number: Int
    let size: Int
    let firstSequence: UInt64?
    let recordCount: UInt64
}

struct RecoveryOutcome: Sendable {
    let report: JournalRecoveryReport
    let lastSegmentNumber: Int
    let active: ActiveSegmentState?
}

enum JournalRecovery {
    /// Validates the journal and repairs a torn tail in the final unsealed segment.
    /// Caller must hold the journal lock.
    static func recover(_ layout: JournalLayout, io: JournalIO, fullSync: Bool) throws -> RecoveryOutcome {
        var removed: [String] = []
        for url in try layout.temporaryFiles() {
            try FileManager.default.removeItem(at: url)
            removed.append(url.lastPathComponent)
        }

        let numbers = try layout.segmentNumbers()
        for (index, number) in numbers.enumerated() where number != index + 1 {
            throw JournalError.segmentGap(expected: index + 1, found: number)
        }

        var lastSequence: UInt64 = 0
        var quarantined: [QuarantinedRange] = []
        var sealed: [Int] = []
        var jobs = JobTracker()
        var active: ActiveSegmentState?

        for number in numbers {
            let url = layout.segmentURL(number)
            // Read, not mapped: this file may be truncated below.
            let data = try Data(contentsOf: url)
            let isLast = number == numbers.last
            let hasManifest = FileManager.default.fileExists(atPath: layout.manifestURL(number).path)

            if hasManifest {
                let manifest = try SealManifest.load(layout.manifestURL(number), segment: number)
                guard manifest.byteSize == UInt64(data.count), manifest.sha256 == sha256Hex(data) else {
                    throw JournalError.corruptSealedSegment(segment: number, reason: "size or SHA-256 differs from seal")
                }
                let scan = SegmentScanner.scan(data, expectedFirstSequence: lastSequence + 1)
                guard scan.problem == nil, let first = scan.records.first, let last = scan.records.last,
                    first.envelope.sequence == manifest.firstSequence, last.envelope.sequence == manifest.lastSequence,
                    UInt64(scan.records.count) == manifest.recordCount
                else {
                    throw JournalError.corruptSealedSegment(
                        segment: number, reason: scan.problem?.description ?? "records disagree with seal")
                }
                scan.records.forEach { jobs.observe($0.envelope) }
                lastSequence = last.envelope.sequence
                continue
            }

            let scan = SegmentScanner.scan(data, expectedFirstSequence: lastSequence + 1)
            scan.records.forEach { jobs.observe($0.envelope) }

            if !isLast {
                guard scan.problem == nil, let first = scan.records.first, let last = scan.records.last else {
                    throw JournalError.corruptSealedSegment(
                        segment: number, reason: "unsealed non-final segment is damaged or empty")
                }
                try seal(
                    layout, io: io, number: number, data: data, first: first.envelope.sequence,
                    last: last.envelope.sequence, count: UInt64(scan.records.count), fullSync: fullSync)
                sealed.append(number)
                lastSequence = last.envelope.sequence
                continue
            }

            if let problem = scan.problem {
                if problem == .unsupportedMagic { throw JournalError.unsupportedFormat(segment: number, offset: scan.validEnd) }
                let tail = data.subdata(in: data.startIndex + scan.validEnd..<data.endIndex)
                let file = try quarantine(tail, layout: layout, io: io, segment: number, offset: scan.validEnd, fullSync: fullSync)
                try truncateSegment(url, to: scan.validEnd, io: io, fullSync: fullSync)
                quarantined.append(
                    QuarantinedRange(
                        segment: number, offset: scan.validEnd, length: tail.count, file: file,
                        reason: problem.description))
            }
            if let last = scan.records.last { lastSequence = last.envelope.sequence }
            active = ActiveSegmentState(
                number: number, size: scan.validEnd, firstSequence: scan.records.first?.envelope.sequence,
                recordCount: UInt64(scan.records.count))
        }

        let report = JournalRecoveryReport(
            lastSequence: lastSequence == 0 ? nil : lastSequence, quarantined: quarantined,
            sealedDuringRecovery: sealed, removedTemporaryFiles: removed.sorted(),
            unterminatedJobIDs: jobs.unterminated)
        return RecoveryOutcome(report: report, lastSegmentNumber: numbers.last ?? 0, active: active)
    }

    static func seal(
        _ layout: JournalLayout, io: JournalIO, number: Int, data: Data, first: UInt64, last: UInt64, count: UInt64,
        fullSync: Bool, beforeRename: () -> Void = {}
    ) throws {
        let manifest = SealManifest(
            segment: number, byteSize: UInt64(data.count), firstSequence: first, lastSequence: last,
            recordCount: count, sha256: sha256Hex(data))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(manifest) else { throw JournalError.encodingFailed }
        try io.writeAtomically(
            bytes, to: layout.manifestURL(number), temporary: layout.temporaryManifestURL(number), full: fullSync,
            beforeRename: beforeRename)
    }

    /// Idempotent: a crash between quarantine and truncation re-finds the same bytes and reuses the file.
    private static func quarantine(
        _ bytes: Data, layout: JournalLayout, io: JournalIO, segment: Int, offset: Int, fullSync: Bool
    ) throws -> String {
        try FileManager.default.createDirectory(
            at: layout.quarantine, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let base = JournalLayout.name(segment) + "-" + String(format: "%010d", offset)
        var suffix = 1
        while true {
            let name = base + (suffix == 1 ? "" : "-\(suffix)") + ".tail"
            let url = layout.quarantine.appendingPathComponent(name)
            if let existing = try? Data(contentsOf: url) {
                if existing == bytes { return name }
                suffix += 1
                continue
            }
            try io.writeAtomically(
                bytes, to: url, temporary: layout.quarantine.appendingPathComponent(name + ".tmp"), full: fullSync,
                beforeRename: {})
            return name
        }
    }

    private static func truncateSegment(_ url: URL, to length: Int, io: JournalIO, fullSync: Bool) throws {
        let fd = open(url.path, O_WRONLY)
        guard fd >= 0 else { throw JournalError.io(operation: "open for truncation", errno: errno) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(length)) == 0 else { throw JournalError.io(operation: "truncate", errno: errno) }
        try io.synchronize(fd, full: fullSync, operation: "sync truncated segment")
    }
}

struct JobTracker {
    private var open: [UUID] = []

    mutating func observe(_ envelope: JournalEnvelope) {
        guard let job = envelope.jobID else { return }
        switch envelope.kind {
        case JournalKind.jobStarted: if !open.contains(job) { open.append(job) }
        case JournalKind.jobFinished: open.removeAll { $0 == job }
        default: break
        }
    }

    var unterminated: [UUID] { open }
}
