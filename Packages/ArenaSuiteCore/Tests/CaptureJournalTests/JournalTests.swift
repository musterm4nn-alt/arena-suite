import Darwin
import Foundation
import Testing

@_spi(JournalTesting) @testable import CaptureJournal

// MARK: - Helpers

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let fast = JournalOptions(durability: .fsync)

private func draft(_ index: Int, payload: Data? = nil, kind: String = "exchange") -> JournalDraft {
    JournalDraft(
        kind: kind, payload: payload ?? Data("payload-\(index)".utf8),
        timestamp: JournalTimestamp(wallMilliseconds: 1_790_222_400_000 + Int64(index), monotonicTicks: UInt64(index)),
        metadata: ["index": .integer(Int64(index))])
}

private func segmentURL(_ root: URL, _ number: Int) -> URL {
    JournalLayout(root: root).segmentURL(number)
}

private func flipByte(in url: URL, at offset: Int) throws {
    var data = try Data(contentsOf: url)
    data[offset] ^= 0xFF
    try data.write(to: url)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

private final class ByteBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int?
    func arm(_ bytes: Int) { lock.withLock { remaining = bytes } }
    /// Returns how many bytes may be written now, or nil when the budget is exhausted.
    func take(_ wanted: Int) -> Int? {
        lock.withLock {
            guard let left = remaining else { return wanted }
            guard left > 0 else { return nil }
            let granted = min(left, wanted)
            remaining = left - granted
            return granted
        }
    }
}

// MARK: - Round trips

@Test func recordsRoundTripAcrossRotationAndReopen() throws {
    let root = try temporaryRoot()
    let options = JournalOptions(maximumSegmentBytes: 400, durability: .fsync)
    var payloads: [Data] = [Data(), Data([0, 255, 13, 10]), Data(repeating: 0x41, count: 900)]
    payloads += (0..<7).map { Data("record \($0) \u{00E9}".utf8) }

    var writer = try JournalWriter.open(at: root, options: options)
    for (index, payload) in payloads.prefix(5).enumerated() { _ = try writer.append(draft(index, payload: payload)) }
    try writer.close()
    writer = try JournalWriter.open(at: root, options: options)
    #expect(writer.recoveryReport.lastSequence == 5)
    for (index, payload) in payloads.enumerated().dropFirst(5) { _ = try writer.append(draft(index, payload: payload)) }
    try writer.close()

    let records = try JournalReader(root: root).readAll()
    #expect(records.map(\.envelope.sequence) == Array(1...UInt64(payloads.count)))
    #expect(records.map(\.payload) == payloads)
    #expect(records[3].envelope.metadata["index"] == .integer(3))
    let segments = try JournalLayout(root: root).segmentNumbers()
    #expect(segments.count > 2)
    for number in segments.dropLast() {
        #expect(FileManager.default.fileExists(atPath: JournalLayout(root: root).manifestURL(number).path))
    }
    let report = try JournalVerifier.verify(root: root)
    #expect(report.isClean)
    #expect(report.recordsChecked == payloads.count)
}

@Test func readAtLocationReturnsTheAppendedRecord() throws {
    let root = try temporaryRoot()
    let writer = try JournalWriter.open(at: root, options: fast)
    _ = try writer.append(draft(1))
    let receipt = try writer.append(draft(2, payload: Data([1, 2, 3])))
    let record = try JournalReader(root: root).read(at: receipt.location)
    #expect(record.envelope.sequence == 2)
    #expect(record.payload == Data([1, 2, 3]))
    #expect(record.digest.map { String(format: "%02x", $0) }.joined() == receipt.digest)
    let wrong = JournalLocation(segment: 1, offset: receipt.location.offset + 1, length: receipt.location.length)
    #expect(throws: JournalError.recordNotFound) { try JournalReader(root: root).read(at: wrong) }
}

@Test func slicedPayloadIsStoredExactly() throws {
    let root = try temporaryRoot()
    let writer = try JournalWriter.open(at: root, options: JournalOptions(durability: .fsync, payloadWriteChunk: 3))
    let source = Data((0..<50).map { UInt8($0) })
    let slice = source[10..<37]
    _ = try writer.append(draft(1, payload: slice))
    #expect(try JournalReader(root: root).readAll().first?.payload == Data(slice))
}

@Test func emptyActiveSegmentIsRemovedOnClose() throws {
    let root = try temporaryRoot()
    let writer = try JournalWriter.open(at: root, options: fast)
    try writer.close()
    #expect(try JournalLayout(root: root).segmentNumbers().isEmpty)
}

@Test func secondWriterIsRefusedWhileLocked() throws {
    let root = try temporaryRoot()
    let writer = try JournalWriter.open(at: root, options: fast)
    #expect(throws: JournalError.alreadyOpen) { _ = try JournalWriter.open(at: root, options: fast) }
    try writer.close()
    _ = try JournalWriter.open(at: root, options: fast)
}

// MARK: - Envelope format

@Test func envelopeEncodingIsCanonical() throws {
    let envelope = JournalEnvelope(
        recordID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, sequence: 42, kind: "exchange",
        accountID: nil, jobID: nil,
        timestamp: JournalTimestamp(wallMilliseconds: 1500, monotonicTicks: 18_446_744_073_709_551_615),
        payloadRepresentation: nil, transformations: [], metadata: ["b": .bool(true), "a": .null])
    let text = String(decoding: try JournalEnvelope.makeEncoder().encode(envelope), as: UTF8.self)
    #expect(
        text
            == #"{"format":1,"kind":"exchange","metadata":{"a":null,"b":true},"monotonic_ticks":"18446744073709551615","observed_at":"1970-01-01T00:00:01.500Z","record_id":"00000000-0000-4000-8000-000000000001","sequence":"42","transformations":[]}"#
    )
    #expect(try JSONDecoder().decode(JournalEnvelope.self, from: Data(text.utf8)) == envelope)
}

@Test(arguments: [Int64(0), 1, 999, 1_790_222_400_123, 253_402_300_799_999])
func timestampsRoundTripExactly(_ milliseconds: Int64) {
    let text = JournalTimestamp(wallMilliseconds: milliseconds).iso8601
    #expect(JournalTimestamp.parseWallMilliseconds(text) == milliseconds)
}

@Test func goldenFixtureMatchesFormat() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let golden = root.appendingPathComponent("Fixtures/Journal/golden-v1.asj")

    let journal = try temporaryRoot()
    let writer = try JournalWriter.open(at: journal, options: fast)
    let account = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let job = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let base = JournalTimestamp(wallMilliseconds: 1_790_222_400_000, monotonicTicks: 9_007_199_254_740_993)
    _ = try writer.append(
        JournalDraft(
            kind: JournalKind.jobStarted, recordID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            accountID: account, jobID: job, timestamp: base, metadata: ["job_kind": .string("history_sync")]))
    _ = try writer.append(
        JournalDraft(
            kind: "exchange", payload: Data(#"{"entries":[],"partial":false}"#.utf8),
            recordID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, accountID: account, jobID: job,
            timestamp: JournalTimestamp(wallMilliseconds: 1_790_222_400_250, monotonicTicks: 9_007_199_254_741_000),
            payloadRepresentation: "foundation_decoded_entity", transformations: ["credential_omitted"],
            metadata: [
                "method": .string("GET"), "route": .string("/example"), "status": .integer(200),
                "request_header_names": .array([.string("Accept")]),
            ]))
    _ = try writer.append(
        JournalDraft(
            kind: JournalKind.jobFinished, payload: Data([0x00, 0xFF, 0x0D, 0x0A]),
            recordID: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, accountID: account, jobID: job,
            timestamp: JournalTimestamp(wallMilliseconds: 1_790_222_401_000),
            metadata: ["outcome": .string("completed")]))
    try writer.close()
    let produced = try Data(contentsOf: segmentURL(journal, 1))

    if ProcessInfo.processInfo.environment["ARENA_SUITE_UPDATE_GOLDEN"] == "1" {
        try FileManager.default.createDirectory(
            at: golden.deletingLastPathComponent(), withIntermediateDirectories: true)
        try produced.write(to: golden)
    }
    #expect(try Data(contentsOf: golden) == produced, "Format drift: journal bytes differ from the golden fixture")
}

// MARK: - Recovery

@Test func tornTailAtEveryByteIsQuarantinedExactly() throws {
    let source = try temporaryRoot()
    let writer = try JournalWriter.open(at: source, options: fast)
    _ = try writer.append(draft(1))
    _ = try writer.append(draft(2))
    let last = try writer.append(draft(3, payload: Data(repeating: 7, count: 40)))
    try writer.close()
    let original = try Data(contentsOf: segmentURL(source, 1))
    let start = last.location.offset

    for cut in start...(start + last.location.length - 1) {
        let root = try temporaryRoot()
        try FileManager.default.removeItem(at: root)
        try FileManager.default.copyItem(at: source, to: root)
        try original.prefix(cut).write(to: segmentURL(root, 1))

        let reopened = try JournalWriter.open(at: root, options: fast)
        let report = reopened.recoveryReport
        try reopened.close()
        let records = try JournalReader(root: root).readAll()

        if cut == start {
            #expect(report.quarantined.isEmpty)
            #expect(records.map(\.envelope.sequence) == [1, 2])
            continue
        }
        #expect(report.quarantined.count == 1)
        let range = try #require(report.quarantined.first)
        #expect(range.offset == start && range.length == cut - start)
        let saved = try Data(contentsOf: JournalLayout(root: root).quarantine.appendingPathComponent(range.file))
        #expect(saved == original.subdata(in: start..<cut))
        #expect(records.map(\.envelope.sequence) == [1, 2, 3])
        #expect(records[2].envelope.kind == JournalKind.journalRecovered)
        #expect(try JournalVerifier.verify(root: root).isClean)
    }
}

@Test func corruptedLastRecordIsQuarantinedNotReadmitted() throws {
    let root = try temporaryRoot()
    let writer = try JournalWriter.open(at: root, options: fast)
    _ = try writer.append(draft(1))
    let second = try writer.append(draft(2))
    _ = try writer.append(draft(3))
    try writer.close()
    try flipByte(in: segmentURL(root, 1), at: second.location.offset + second.location.length - 40)

    #expect(try !JournalVerifier.verify(root: root).isClean)
    let reopened = try JournalWriter.open(at: root, options: fast)
    let range = try #require(reopened.recoveryReport.quarantined.first)
    #expect(range.offset == second.location.offset && range.reason == "digest mismatch")
    try reopened.close()
    // Record 3 was valid-looking but after the damage; it is preserved in quarantine, not re-admitted.
    let records = try JournalReader(root: root).readAll()
    #expect(records.map(\.envelope.sequence) == [1, 2])
    #expect(records[1].envelope.kind == JournalKind.journalRecovered)
}

@Test func quarantineIsIdempotentAcrossInterruptedRecovery() throws {
    let root = try temporaryRoot()
    let writer = try JournalWriter.open(at: root, options: fast)
    _ = try writer.append(draft(1))
    let second = try writer.append(draft(2))
    try writer.close()
    let original = try Data(contentsOf: segmentURL(root, 1))
    let cut = second.location.offset + 10
    try original.prefix(cut).write(to: segmentURL(root, 1))
    // Simulate a crash after the quarantine copy but before truncation.
    let layout = JournalLayout(root: root)
    try FileManager.default.createDirectory(at: layout.quarantine, withIntermediateDirectories: true)
    let name = "000001-" + String(format: "%010d", second.location.offset) + ".tail"
    try original.subdata(in: second.location.offset..<cut).write(to: layout.quarantine.appendingPathComponent(name))

    let reopened = try JournalWriter.open(at: root, options: fast)
    #expect(reopened.recoveryReport.quarantined.first?.file == name)
    #expect(try FileManager.default.contentsOfDirectory(atPath: layout.quarantine.path) == [name])
}

@Test func corruptionInSealedSegmentBlocksOpenAndChangesNothing() throws {
    let root = try temporaryRoot()
    let options = JournalOptions(maximumSegmentBytes: 300, durability: .fsync)
    let writer = try JournalWriter.open(at: root, options: options)
    for index in 1...6 { _ = try writer.append(draft(index)) }
    try writer.close()
    try flipByte(in: segmentURL(root, 1), at: 30)
    let before = try Data(contentsOf: segmentURL(root, 1))

    #expect(throws: JournalError.self) { _ = try JournalWriter.open(at: root, options: options) }
    do {
        _ = try JournalWriter.open(at: root, options: options)
    } catch let JournalError.corruptSealedSegment(segment, _) {
        #expect(segment == 1)
    }
    #expect(try Data(contentsOf: segmentURL(root, 1)) == before)
    #expect(try !JournalVerifier.verify(root: root).isClean)
}

@Test func unknownFormatMagicIsRefusedNotQuarantined() throws {
    let root = try temporaryRoot()
    let writer = try JournalWriter.open(at: root, options: fast)
    _ = try writer.append(draft(1))
    try writer.close()
    let handle = try FileHandle(forWritingTo: segmentURL(root, 1))
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("ASJ2".utf8) + Data(repeating: 0, count: 40))
    try handle.close()
    let before = try Data(contentsOf: segmentURL(root, 1))
    #expect(throws: JournalError.self) { _ = try JournalWriter.open(at: root, options: fast) }
    #expect(try Data(contentsOf: segmentURL(root, 1)) == before)
}

@Test func unsealedNonFinalSegmentIsSealedDuringRecovery() throws {
    let root = try temporaryRoot()
    let options = JournalOptions(maximumSegmentBytes: 300, durability: .fsync)
    let writer = try JournalWriter.open(at: root, options: options)
    for index in 1...6 { _ = try writer.append(draft(index)) }
    try writer.close()
    let layout = JournalLayout(root: root)
    try FileManager.default.removeItem(at: layout.manifestURL(1))

    let reopened = try JournalWriter.open(at: root, options: options)
    #expect(reopened.recoveryReport.sealedDuringRecovery == [1])
    try reopened.close()
    #expect(try JournalVerifier.verify(root: root).isClean)
}

@Test func segmentGapBlocksOpen() throws {
    let root = try temporaryRoot()
    let options = JournalOptions(maximumSegmentBytes: 300, durability: .fsync)
    let writer = try JournalWriter.open(at: root, options: options)
    for index in 1...6 { _ = try writer.append(draft(index)) }
    try writer.close()
    let layout = JournalLayout(root: root)
    let last = try #require(try layout.segmentNumbers().last)
    try FileManager.default.moveItem(at: layout.segmentURL(last), to: layout.segmentURL(last + 1))
    #expect(throws: JournalError.segmentGap(expected: last, found: last + 1)) {
        _ = try JournalWriter.open(at: root, options: options)
    }
}

@Test func leftoverTemporaryManifestIsRemovedAndReported() throws {
    let root = try temporaryRoot()
    let writer = try JournalWriter.open(at: root, options: fast)
    _ = try writer.append(draft(1))
    try writer.close()
    let temporary = JournalLayout(root: root).temporaryManifestURL(1)
    try Data("partial".utf8).write(to: temporary)
    #expect(try !JournalVerifier.verify(root: root).isClean)

    let reopened = try JournalWriter.open(at: root, options: fast)
    #expect(reopened.recoveryReport.removedTemporaryFiles == [temporary.lastPathComponent])
    #expect(!FileManager.default.fileExists(atPath: temporary.path))
}

@Test func unterminatedJobsAreReported() throws {
    let root = try temporaryRoot()
    let first = UUID()
    let second = UUID()
    let writer = try JournalWriter.open(at: root, options: fast)
    _ = try writer.append(JournalDraft(kind: JournalKind.jobStarted, jobID: first))
    _ = try writer.append(JournalDraft(kind: JournalKind.jobStarted, jobID: second))
    _ = try writer.append(JournalDraft(kind: JournalKind.jobFinished, jobID: first))
    try writer.close()
    #expect(try JournalWriter.open(at: root, options: fast).recoveryReport.unterminatedJobIDs == [second])
}

// MARK: - Fault injection

@Test func interruptedAndPartialWritesAreCompleted() throws {
    let root = try temporaryRoot()
    let calls = Counter()
    let io = JournalIO(
        write: { fd, pointer, count in
            if calls.next() % 2 == 0 {
                errno = EINTR
                return -1
            }
            return Darwin.write(fd, pointer, min(count, 3))
        },
        sync: JournalIO.system.sync, observe: { _ in })
    let writer = try JournalWriter.open(at: root, options: fast, io: io)
    _ = try writer.append(draft(1, payload: Data(repeating: 9, count: 100)))
    _ = try writer.append(draft(2))
    try writer.close()
    let records = try JournalReader(root: root).readAll()
    #expect(records.map(\.payload) == [Data(repeating: 9, count: 100), Data("payload-2".utf8)])
}

@Test(arguments: [ENOSPC, EIO])
func writeFailureStopsWriterAndReopenRecoversPrefix(_ code: Int32) throws {
    let root = try temporaryRoot()
    let budget = ByteBudget()
    let io = JournalIO(
        write: { fd, pointer, count in
            guard let allowed = budget.take(count) else {
                errno = code
                return -1
            }
            return Darwin.write(fd, pointer, allowed)
        },
        sync: JournalIO.system.sync, observe: { _ in })
    let writer = try JournalWriter.open(at: root, options: fast, io: io)
    _ = try writer.append(draft(1))
    _ = try writer.append(draft(2))
    budget.arm(25)  // header plus part of the envelope of record 3
    #expect(throws: JournalError.io(operation: "write envelope", errno: code)) { _ = try writer.append(draft(3)) }
    #expect(throws: JournalError.writerFailed) { _ = try writer.append(draft(4)) }
    #expect(throws: JournalError.writerFailed) { try writer.synchronize() }
    try writer.close()

    let reopened = try JournalWriter.open(at: root, options: fast)
    #expect(reopened.recoveryReport.quarantined.first?.length == 25)
    try reopened.close()
    let records = try JournalReader(root: root).readAll()
    #expect(records.prefix(2).map(\.payload) == [Data("payload-1".utf8), Data("payload-2".utf8)])
    #expect(records.last?.envelope.kind == JournalKind.journalRecovered)
}

@Test func syncFailureStopsWriter() throws {
    let root = try temporaryRoot()
    let failing = ByteBudget()  // reused as an on/off switch: armed(0) means "fail"
    let io = JournalIO(
        write: JournalIO.system.write,
        sync: { fd, full in
            guard failing.take(1) != nil else {
                errno = EIO
                return -1
            }
            return JournalIO.system.sync(fd, full)
        }, observe: { _ in })
    let writer = try JournalWriter.open(at: root, options: fast, io: io)
    _ = try writer.append(draft(1))
    failing.arm(0)
    #expect(throws: JournalError.io(operation: "sync segment", errno: EIO)) { try writer.synchronize() }
    #expect(writer.synchronizedSequence == nil)
    #expect(throws: JournalError.writerFailed) { _ = try writer.append(draft(2)) }
}

@Test func oversizedRecordsAreRejectedBeforeAnyWrite() throws {
    let root = try temporaryRoot()
    let writer = try JournalWriter.open(at: root, options: fast)
    _ = try writer.append(draft(1))
    #expect(throws: JournalError.payloadTooLarge(RecordCodec.maximumPayloadBytes + 1)) {
        _ = try writer.append(draft(2, payload: Data(count: RecordCodec.maximumPayloadBytes + 1)))
    }
    var huge = draft(3)
    huge.metadata["blob"] = .string(String(repeating: "x", count: RecordCodec.maximumEnvelopeBytes))
    #expect(throws: JournalError.self) { _ = try writer.append(huge) }
    let receipt = try writer.append(draft(4))
    #expect(receipt.sequence == 2)
    try writer.close()
    #expect(try JournalVerifier.verify(root: root).isClean)
}
