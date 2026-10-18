import CaptureJournal
import Foundation
import SuiteDomain

/// A content-free diagnostics report (plan v3 §13, Phase 7) for looking into problems without
/// sharing the archive. It holds versions, counts, journal health, warning codes and unknown field
/// paths. It never holds message text, titles, conversation or message IDs, account names, emails,
/// principal claims, routes with IDs, file paths, or response bodies. Accounts appear as ordinals.
public struct DiagnosticsService: Sendable {
    public struct Environment: Sendable {
        public let appVersion: String
        public let osVersion: String
        public init(appVersion: String, osVersion: String) {
            self.appVersion = appVersion
            self.osVersion = osVersion
        }
    }

    private let archive: ArchiveService?
    private let journals: JournalStore
    private let environment: Environment

    public init(archive: ArchiveService?, journals: JournalStore, environment: Environment) {
        self.archive = archive
        self.journals = journals
        self.environment = environment
    }

    public static let format = "arena-suite-diagnostics/1"

    /// `accounts`: local accounts in display order with their current state.
    public func report(accounts: [(AccountID, AccountAuthState)], verification: VerificationReport?, now: Date = Date())
        -> Data
    {
        var root: [String: Any] = [
            "format": Self.format,
            "generated_at": ISO8601DateFormatter().string(from: now),
            "app_version": environment.appVersion,
            "os_version": environment.osVersion,
        ]
        // Ordinals instead of IDs; removed accounts whose journals are kept are listed after the rest.
        var ordered = accounts.map(\.0)
        for account in journals.accountsOnDisk() where !ordered.contains(account) { ordered.append(account) }
        let ordinal = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1, "account-\($0 + 1)") })
        let states = Dictionary(accounts, uniquingKeysWith: { first, _ in first })

        root["accounts"] = ordered.map { account -> [String: Any] in
            var entry: [String: Any] = [
                "account": ordinal[account]!,
                "state": states[account]?.rawValue ?? "removed",
            ]
            entry["journal"] = Self.journalSummary(root: journals.root(for: account))
            return entry
        }
        if let archive {
            var index: [String: Any] = ["decoder_version": archive.decoderVersion]
            index["projection_version"] = (try? archive.projectionVersion()) ?? NSNull()
            index["counts"] = (try? archive.counts()) ?? [:]
            let warnings = (try? archive.warnings(account: nil)) ?? []
            index["warning_codes"] = Dictionary(warnings.map { (Self.token($0.code), 1) }, uniquingKeysWith: +)
            // Unknown JSON key paths are schema names (e.g. `$.messages[].newField`), not content.
            index["unknown_field_paths"] = Dictionary(
                ((try? archive.unknownFields(account: nil)) ?? []).map { (Self.keyPath($0.path), $0.count) },
                uniquingKeysWith: +)
            root["index"] = index
        } else {
            root["index"] = ["available": false]
        }
        if let verification {
            var verify: [String: Any] = ["clean": verification.isClean]
            verify["journals"] = verification.journals.map { check -> [String: Any] in
                [
                    "account": ordinal[check.account] ?? "account-?", "segments": check.segments,
                    "records": check.records, "issues": check.issues,
                ]
            }
            if let index = verification.index { verify["index_matches_journal"] = index.matches }
            if let problem = verification.indexProblem { verify["index_problem"] = problem }
            if let problem = verification.inventoryProblem { verify["inventory_problem"] = problem }
            root["verification"] = verify
        }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Writes the report to `directory` as a new owner-only file and returns its URL.
    public func write(_ data: Data, to directory: URL, now: Date = Date()) throws -> URL {
        let name = "Arena Suite Diagnostics \(BackupService.stamp(now))"
        for attempt in 1...100 {
            let url = directory.appendingPathComponent(attempt == 1 ? "\(name).json" : "\(name) \(attempt).json")
            do {
                try PrivateFile.write(data, to: url, exclusive: true)
                return url
            } catch PrivateFile.Failure.io(_, EEXIST) {
                continue  // never overwrite; try the next name
            }
        }
        throw BackupError.io("no free diagnostics file name")
    }

    /// Record kinds, HTTP statuses, transfer end states and job outcomes, by count. Values are taken
    /// only from envelope fields with fixed vocabularies and filtered to plain tokens.
    static func journalSummary(root: URL) -> [String: Any] {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("segments").path) else {
            return ["present": false]
        }
        var kinds: [String: Int] = [:]
        var statuses: [String: Int] = [:]
        var transfers: [String: Int] = [:]
        var outcomes: [String: Int] = [:]
        var bytes = 0
        do {
            let summary = try JournalReader(root: root).forEach { record in
                kinds[token(record.envelope.kind), default: 0] += 1
                bytes += record.location.length
                if case .integer(let status)? = record.envelope.metadata["status"] {
                    statuses[String(status), default: 0] += 1
                }
                if case .string(let end)? = record.envelope.metadata["transfer_end"] {
                    transfers[token(end), default: 0] += 1
                }
                if record.envelope.kind == JournalKind.jobFinished, case .string(let outcome)? = record.envelope.metadata["outcome"] {
                    outcomes[token(outcome), default: 0] += 1
                }
            }
            return [
                "present": true, "records": summary.recordCount, "record_bytes": bytes,
                "incomplete_tail": summary.incompleteTail != nil, "kinds": kinds, "http_statuses": statuses,
                "transfer_end": transfers, "job_outcomes": outcomes,
            ]
        } catch {
            return ["present": true, "readable": false, "error": VerificationService.describe(error)]
        }
    }

    /// Plain lowercase tokens pass; anything else is replaced so free text can never leak.
    public static func token(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_.-")
        return value.count <= 48 && !value.isEmpty && value.allSatisfy(allowed.contains) ? value : "(other)"
    }

    /// JSON key paths as the decoder reports them; anything that does not look like one is replaced.
    public static func keyPath(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.$[]-")
        return value.count <= 200 && value.hasPrefix("$") && value.allSatisfy(allowed.contains) ? value : "(other)"
    }
}
