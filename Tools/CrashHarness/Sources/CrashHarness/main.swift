// Phase 1 crash gate (plan v3 §7, §13).
//
// `CrashHarness` (driver) runs every scenario: it spawns itself as a child that appends
// records and SIGKILLs itself at one exact write boundary. The child reports each
// acknowledged append on stdout before continuing. The driver then reopens the journal
// (running recovery) and requires that every acknowledged record is present, byte-exact,
// with continuous sequences, and that the journal verifies clean afterwards.

import Darwin
import Foundation

@_spi(JournalTesting) import CaptureJournal

struct Scenario: Sendable {
    let name: String
    /// Sequence of the record during which the child dies.
    let victim: UInt64
    let stage: JournalWritePoint.Stage
    let rotate: Bool
    /// Whether bytes of the victim record reach the file before death (so a quarantine is expected).
    let expectsTail: Bool
}

let recordCount: UInt64 = 6
let victim: UInt64 = 4

let scenarios: [Scenario] = [
    Scenario(name: "before-header", victim: victim, stage: .header, rotate: false, expectsTail: false),
    Scenario(name: "before-envelope", victim: victim, stage: .envelope, rotate: false, expectsTail: true),
    Scenario(name: "before-payload", victim: victim, stage: .payloadChunk(offset: 0), rotate: false, expectsTail: true),
    Scenario(name: "mid-payload", victim: victim, stage: .payloadChunk(offset: 14), rotate: false, expectsTail: true),
    Scenario(name: "before-digest", victim: victim, stage: .digest, rotate: false, expectsTail: true),
    Scenario(name: "appended-not-acknowledged", victim: victim, stage: .appended, rotate: false, expectsTail: false),
    Scenario(name: "after-sync", victim: victim, stage: .synchronized, rotate: false, expectsTail: false),
    Scenario(name: "seal-temporary-written", victim: 2, stage: .sealTemporaryWritten, rotate: true, expectsTail: false),
    Scenario(name: "seal-renamed", victim: 2, stage: .sealRenamed, rotate: true, expectsTail: false),
]

func payload(_ sequence: UInt64) -> Data {
    Data((0..<48).map { UInt8(truncatingIfNeeded: Int(sequence) &* 31 &+ $0) })
}

func options(rotate: Bool) -> JournalOptions {
    JournalOptions(maximumSegmentBytes: rotate ? 700 : 64 << 20, durability: .fsync, payloadWriteChunk: 7)
}

// MARK: - Child

func runChild(root: URL, scenario: Scenario) -> Never {
    let io = JournalIO(
        write: JournalIO.system.write, sync: JournalIO.system.sync,
        observe: { point in
            // Seal points report the last sequence of the segment being sealed.
            if point.stage == scenario.stage && point.sequence == scenario.victim {
                kill(getpid(), SIGKILL)
            }
        })
    do {
        let writer = try JournalWriter.open(at: root, options: options(rotate: scenario.rotate), io: io)
        for sequence in 1...recordCount {
            let receipt = try writer.append(JournalDraft(kind: "crash.test", payload: payload(sequence)))
            FileHandle.standardOutput.write(Data("ACK \(receipt.sequence)\n".utf8))
            if receipt.sequence == scenario.victim && scenario.stage == .synchronized { try writer.synchronize() }
        }
        try writer.close()
    } catch {
        FileHandle.standardError.write(Data("child error: \(error)\n".utf8))
        exit(2)
    }
    FileHandle.standardError.write(Data("child finished without being killed\n".utf8))
    exit(3)
}

// MARK: - Driver

struct Failure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw Failure(description: message()) }
}

func runScenario(_ scenario: Scenario) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("crash-\(scenario.name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["child", root.path, scenario.name]
    let output = Pipe()
    child.standardOutput = output
    try child.run()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    child.waitUntilExit()
    try check(
        child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL,
        "child was not SIGKILLed (reason \(child.terminationReason.rawValue), status \(child.terminationStatus))")

    let acknowledged = String(decoding: stdout, as: UTF8.self).split(separator: "\n").compactMap {
        $0.hasPrefix("ACK ") ? UInt64($0.dropFirst(4)) : nil
    }

    let writer = try JournalWriter.open(at: root, options: options(rotate: scenario.rotate))
    let report = writer.recoveryReport
    let next = try writer.append(JournalDraft(kind: "crash.after-recovery"))
    try writer.close()

    let records = try JournalReader(root: root).readAll()
    let bySequence = Dictionary(uniqueKeysWithValues: records.map { ($0.envelope.sequence, $0) })
    for sequence in acknowledged {
        let record = try bySequence[sequence].map { $0 } ?? { throw Failure(description: "acknowledged record \(sequence) lost") }()
        try check(record.envelope.kind == "crash.test", "record \(sequence) has kind \(record.envelope.kind)")
        try check(record.payload == payload(sequence), "record \(sequence) payload differs")
    }
    try check(
        records.map(\.envelope.sequence) == Array(1...UInt64(records.count)), "sequences are not continuous from 1")
    try check(next.sequence == UInt64(records.count), "post-recovery append got sequence \(next.sequence)")
    try check(
        report.quarantined.isEmpty == !scenario.expectsTail,
        "expected tail quarantine: \(scenario.expectsTail), got \(report.quarantined)")
    let verification = try JournalVerifier.verify(root: root)
    try check(verification.isClean, "journal not clean after recovery: \(verification.issues)")

    let survivedVictim = bySequence[scenario.victim]?.envelope.kind == "crash.test"
    print(
        "  \(scenario.name): acked \(acknowledged.count), recovered \(records.filter { $0.envelope.kind == "crash.test" }.count) test records"
            + "\(survivedVictim ? " (victim record survived)" : ""), quarantined \(report.quarantined.map(\.length)) bytes, sealed during recovery \(report.sealedDuringRecovery)"
    )
}

let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == "child", let scenario = scenarios.first(where: { $0.name == arguments[3] }) {
    runChild(root: URL(fileURLWithPath: arguments[2]), scenario: scenario)
}

print("Journal crash gate: SIGKILL at each write boundary")
var failures = 0
for scenario in scenarios {
    do {
        try runScenario(scenario)
    } catch {
        failures += 1
        print("  \(scenario.name): FAILED — \(error)")
    }
}
if failures > 0 {
    print("Journal crash gate FAILED (\(failures) of \(scenarios.count) scenarios)")
    exit(1)
}
print("Journal crash gate passed (\(scenarios.count) scenarios): no acknowledged record lost")
