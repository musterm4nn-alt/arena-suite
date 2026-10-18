import CaptureJournal
import Foundation
import SuiteDomain

/// One account's journal as the verifier found it. Issue texts name segments and offsets only.
public struct JournalCheck: Sendable, Equatable {
    public let account: AccountID
    public let segments: Int
    public let records: Int
    public let lastSequence: UInt64?
    public let issues: [String]
    public var isClean: Bool { issues.isEmpty }
}

public struct VerificationReport: Sendable, Equatable {
    public let journals: [JournalCheck]
    /// nil if the index is unavailable or the replay failed (`indexProblem` says why).
    public let index: IndexCheck?
    public let indexProblem: String?
    /// Set when the list of accounts could not be read: then only the journals found on disk were
    /// checked, and the report is not clean.
    public var inventoryProblem: String? = nil
    public var isClean: Bool {
        inventoryProblem == nil && journals.allSatisfy(\.isClean) && index?.matches == true && indexProblem == nil
    }
}

/// The verify job (plan v3 §13, Phase 7). Read-only: checks every account's journal (record
/// digests, sequence continuity, seal manifests, leftover temp files) and replays the journals into a
/// scratch index to confirm the live index is exactly what they produce. Repairs nothing; a
/// mismatched index is fixed by rebuilding it, a damaged journal by restoring from a backup.
public struct VerificationService: Sendable {
    private let archive: ArchiveService?
    private let journals: JournalStore
    private let accounts: @Sendable () throws -> [AccountID]
    private let scratch: URL

    public init(
        archive: ArchiveService?, journals: JournalStore, accounts: @escaping @Sendable () throws -> [AccountID],
        scratch: URL
    ) {
        self.archive = archive
        self.journals = journals
        self.accounts = accounts
        self.scratch = scratch
    }

    public func run() async -> VerificationReport {
        var checks: [JournalCheck] = []
        let inventory: [AccountID]
        var inventoryProblem: String?
        do {
            inventory = try accounts()
        } catch {
            // Never a silently shorter list: check what is on disk and say the list was incomplete.
            inventoryProblem = "The list of accounts could not be read (\(Self.describe(error)))."
            inventory = journals.accountsOnDisk()
        }
        for account in inventory {
            checks.append(Self.checkJournal(account: account, root: journals.root(for: account)))
        }
        guard let archive else {
            return VerificationReport(
                journals: checks, index: nil, indexProblem: "The archive index is unavailable.",
                inventoryProblem: inventoryProblem)
        }
        do {
            // A fresh folder per run, so concurrent runs never share a scratch index.
            let run = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { rmdir(scratch.path) }  // only if empty; other runs may still be using it
            let check = try await archive.checkAgainstJournal(scratch: run)
            return VerificationReport(journals: checks, index: check, indexProblem: nil, inventoryProblem: inventoryProblem)
        } catch {
            return VerificationReport(
                journals: checks, index: nil, indexProblem: "The journal could not be replayed (\(Self.describe(error))).",
                inventoryProblem: inventoryProblem)
        }
    }

    static func checkJournal(account: AccountID, root: URL) -> JournalCheck {
        // An account that never synced has no journal yet.
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("segments").path) else {
            return JournalCheck(account: account, segments: 0, records: 0, lastSequence: nil, issues: [])
        }
        do {
            let report = try JournalVerifier.verify(root: root)
            return JournalCheck(
                account: account, segments: report.segmentsChecked, records: report.recordsChecked,
                lastSequence: report.lastSequence,
                issues: report.issues.map { issue in
                    [issue.segment.map { "segment \($0)" }, issue.offset.map { "offset \($0)" }, issue.detail]
                        .compactMap { $0 }.joined(separator: ", ")
                })
        } catch {
            return JournalCheck(
                account: account, segments: 0, records: 0, lastSequence: nil,
                issues: ["journal could not be read (\(describe(error)))"])
        }
    }

    /// Error descriptions without paths (they contain the home folder name).
    static func describe(_ error: any Error) -> String {
        if let error = error as? JournalError { return "\(error)" }
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)"
    }
}
