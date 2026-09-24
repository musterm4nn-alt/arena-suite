import Darwin
import Foundation

public struct JournalOptions: Sendable {
    public enum Durability: Sendable { case fullSync, fsync }

    /// A segment is sealed before a record would push it past this size (a single larger record
    /// still gets its own segment).
    public var maximumSegmentBytes: Int
    public var durability: Durability
    /// Payload bytes per `write` call. Smaller values only matter for fault-injection tests.
    public var payloadWriteChunk: Int

    public init(maximumSegmentBytes: Int = 64 << 20, durability: Durability = .fullSync, payloadWriteChunk: Int = 1 << 20) {
        precondition(maximumSegmentBytes > 0 && payloadWriteChunk > 0)
        self.maximumSegmentBytes = maximumSegmentBytes
        self.durability = durability
        self.payloadWriteChunk = payloadWriteChunk
    }
}

/// Single writer for one journal directory. Holds an exclusive lock for its lifetime.
///
/// All methods are synchronous and serialized; call them off the main thread. `append` returns
/// once every byte of the record is with the OS ("appended"); `synchronize` makes it durable
/// against power loss to the extent the storage honors `F_FULLFSYNC`.
public final class JournalWriter: @unchecked Sendable {
    public let root: URL
    public let recoveryReport: JournalRecoveryReport

    private struct ActiveSegment {
        let number: Int
        let fd: Int32
        var size: Int
        var firstSequence: UInt64?
        var recordCount: UInt64
    }

    private enum State { case open, failed, closed }

    private let layout: JournalLayout
    private let options: JournalOptions
    private let io: JournalIO
    private let encoder = JournalEnvelope.makeEncoder()
    private let mutex = NSLock()
    private var lockFD: Int32
    private var state = State.open
    private var nextSequence: UInt64
    private var lastAppended: UInt64?
    private var synchronizedThrough: UInt64?
    private var lastSegmentNumber: Int
    private var active: ActiveSegment?

    public static func open(at root: URL, options: JournalOptions = JournalOptions()) throws -> JournalWriter {
        try open(at: root, options: options, io: .system)
    }

    @_spi(JournalTesting)
    public static func open(at root: URL, options: JournalOptions, io: JournalIO) throws -> JournalWriter {
        let layout = JournalLayout(root: root)
        let privateDirectory: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: privateDirectory)
        try FileManager.default.createDirectory(
            at: layout.segments, withIntermediateDirectories: true, attributes: privateDirectory)
        let lockFD = Darwin.open(layout.lockFile.path, O_RDWR | O_CREAT, 0o600)
        guard lockFD >= 0 else { throw JournalError.io(operation: "open lock", errno: errno) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(lockFD)
            throw code == EWOULDBLOCK ? JournalError.alreadyOpen : JournalError.io(operation: "lock", errno: code)
        }
        let outcome: RecoveryOutcome
        do {
            outcome = try JournalRecovery.recover(layout, io: io, fullSync: options.durability == .fullSync)
        } catch {
            Darwin.close(lockFD)
            throw error
        }
        let writer = try JournalWriter(
            root: root, layout: layout, options: options, io: io, lockFD: lockFD, outcome: outcome)
        for range in outcome.report.quarantined {
            _ = try writer.append(
                JournalDraft(
                    kind: JournalKind.journalRecovered,
                    metadata: [
                        "segment": .integer(Int64(range.segment)), "offset": .integer(Int64(range.offset)),
                        "length": .integer(Int64(range.length)), "quarantine_file": .string(range.file),
                        "reason": .string(range.reason),
                    ]))
        }
        if !outcome.report.quarantined.isEmpty { _ = try writer.synchronize() }
        return writer
    }

    private init(
        root: URL, layout: JournalLayout, options: JournalOptions, io: JournalIO, lockFD: Int32,
        outcome: RecoveryOutcome
    ) throws {
        self.root = root
        self.layout = layout
        self.options = options
        self.io = io
        self.lockFD = lockFD
        self.recoveryReport = outcome.report
        self.nextSequence = (outcome.report.lastSequence ?? 0) + 1
        self.lastAppended = outcome.report.lastSequence
        self.synchronizedThrough = outcome.report.lastSequence
        self.lastSegmentNumber = outcome.lastSegmentNumber
        if let state = outcome.active {
            let fd = Darwin.open(layout.segmentURL(state.number).path, O_WRONLY | O_APPEND)
            guard fd >= 0 else {
                // deinit runs for a fully initialized instance and releases the lock exactly once.
                throw JournalError.io(operation: "open active segment", errno: errno)
            }
            active = ActiveSegment(
                number: state.number, fd: fd, size: state.size, firstSequence: state.firstSequence,
                recordCount: state.recordCount)
        }
    }

    deinit {
        if let active { Darwin.close(active.fd) }
        if lockFD >= 0 { Darwin.close(lockFD) }
    }

    /// Highest sequence covered by a successful `synchronize`, or nil.
    public var synchronizedSequence: UInt64? { mutex.withLock { synchronizedThrough } }

    public func append(_ draft: JournalDraft) throws -> AppendReceipt {
        try mutex.withLock {
            try requireOpen()
            let payload = Data(draft.payload)  // zero-based indices even if the caller passed a slice
            let sequence = nextSequence
            let envelope = JournalEnvelope(
                recordID: draft.recordID, sequence: sequence, kind: draft.kind, accountID: draft.accountID,
                jobID: draft.jobID, timestamp: draft.timestamp, payloadRepresentation: draft.payloadRepresentation,
                transformations: draft.transformations, metadata: draft.metadata)
            guard let envelopeBytes = try? encoder.encode(envelope) else { throw JournalError.encodingFailed }
            try RecordCodec.validateSizes(envelope: envelopeBytes.count, payload: payload.count)
            let header = RecordCodec.header(envelopeLength: envelopeBytes.count, payloadLength: payload.count)
            let digest = RecordCodec.digest(header: header, envelope: envelopeBytes, payload: payload)
            let length = header.count + envelopeBytes.count + payload.count + digest.count

            do {
                if let current = active, current.size > 0, current.size + length > options.maximumSegmentBytes {
                    try sealActive()
                }
                if active == nil { try createSegment() }
                guard var segment = active else { throw JournalError.closed }
                let offset = segment.size

                io.observe(JournalWritePoint(sequence: sequence, stage: .header))
                try io.writeAll(segment.fd, header, operation: "write header")
                io.observe(JournalWritePoint(sequence: sequence, stage: .envelope))
                try io.writeAll(segment.fd, envelopeBytes, operation: "write envelope")
                var chunkStart = 0
                while chunkStart < payload.count {
                    let chunkEnd = min(chunkStart + options.payloadWriteChunk, payload.count)
                    io.observe(JournalWritePoint(sequence: sequence, stage: .payloadChunk(offset: chunkStart)))
                    try io.writeAll(
                        segment.fd, payload.subdata(in: chunkStart..<chunkEnd), operation: "write payload")
                    chunkStart = chunkEnd
                }
                io.observe(JournalWritePoint(sequence: sequence, stage: .digest))
                try io.writeAll(segment.fd, digest, operation: "write digest")

                segment.size += length
                segment.recordCount += 1
                if segment.firstSequence == nil { segment.firstSequence = sequence }
                active = segment
                nextSequence += 1
                lastAppended = sequence
                io.observe(JournalWritePoint(sequence: sequence, stage: .appended))
                return AppendReceipt(
                    sequence: sequence, recordID: draft.recordID,
                    location: JournalLocation(segment: segment.number, offset: offset, length: length),
                    digest: digest.map { String(format: "%02x", $0) }.joined())
            } catch {
                state = .failed
                throw error
            }
        }
    }

    /// Flushes appended records to stable storage. Returns the highest synchronized sequence.
    @discardableResult
    public func synchronize() throws -> UInt64? {
        try mutex.withLock {
            try requireOpen()
            do {
                if let active {
                    try io.synchronize(active.fd, full: options.durability == .fullSync, operation: "sync segment")
                }
            } catch {
                state = .failed
                throw error
            }
            synchronizedThrough = lastAppended
            if let lastAppended { io.observe(JournalWritePoint(sequence: lastAppended, stage: .synchronized)) }
            return synchronizedThrough
        }
    }

    /// Synchronizes, removes an empty active segment, and releases the lock. The active segment
    /// stays unsealed so the next session keeps appending to it.
    public func close() throws {
        try mutex.withLock {
            guard state != .closed else { return }
            defer {
                if let active { Darwin.close(active.fd) }
                active = nil
                Darwin.close(lockFD)
                lockFD = -1
                state = .closed
            }
            guard state == .open, let current = active else { return }
            try io.synchronize(current.fd, full: options.durability == .fullSync, operation: "sync on close")
            synchronizedThrough = lastAppended
            if current.size == 0 {
                try FileManager.default.removeItem(at: layout.segmentURL(current.number))
                try io.synchronizeDirectory(layout.segments, operation: "sync directory")
            }
        }
    }

    private func requireOpen() throws {
        switch state {
        case .open: return
        case .failed: throw JournalError.writerFailed
        case .closed: throw JournalError.closed
        }
    }

    private func createSegment() throws {
        let number = lastSegmentNumber + 1
        let url = layout.segmentURL(number)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0o600)
        guard fd >= 0 else { throw JournalError.io(operation: "create segment", errno: errno) }
        do {
            try io.synchronizeDirectory(layout.segments, operation: "sync directory")
        } catch {
            Darwin.close(fd)
            throw error
        }
        lastSegmentNumber = number
        active = ActiveSegment(number: number, fd: fd, size: 0, firstSequence: nil, recordCount: 0)
    }

    private func sealActive() throws {
        guard let current = active, let first = current.firstSequence, let last = lastAppended else { return }
        let full = options.durability == .fullSync
        try io.synchronize(current.fd, full: full, operation: "sync before seal")
        synchronizedThrough = last
        let data = try Data(contentsOf: layout.segmentURL(current.number))
        guard data.count == current.size else {
            throw JournalError.corruptSealedSegment(segment: current.number, reason: "size changed before sealing")
        }
        try JournalRecovery.seal(
            layout, io: io, number: current.number, data: data, first: first, last: last,
            count: current.recordCount, fullSync: full,
            beforeRename: { io.observe(JournalWritePoint(sequence: last, stage: .sealTemporaryWritten)) })
        io.observe(JournalWritePoint(sequence: last, stage: .sealRenamed))
        Darwin.close(current.fd)
        active = nil
    }
}
