import CaptureJournal
import Foundation
import SuiteDomain

/// Plan v3 §2 and §9. Defaults follow the traffic policy; spacing may only be raised.
public struct SyncOptions: Sendable, Equatable {
    /// Minimum delay between history requests of one account.
    public var requestSpacing: Duration
    /// List every page even when the newest pages show nothing changed.
    public var fullPass: Bool
    /// Longest `Retry-After` the job waits for (once) before stopping with `partial`.
    public var maximumRetryWait: Duration
    /// Safety bound on pages per job.
    public var maximumPages: Int

    public init(
        requestSpacing: Duration = .seconds(1), fullPass: Bool = false, maximumRetryWait: Duration = .seconds(120),
        maximumPages: Int = 1_000
    ) {
        self.requestSpacing = max(requestSpacing, .seconds(1))
        self.fullPass = fullPass
        self.maximumRetryWait = maximumRetryWait
        self.maximumPages = maximumPages
    }

    /// Tests only: no spacing floor.
    public static func testing(fullPass: Bool = false, maximumRetryWait: Duration = .seconds(120)) -> SyncOptions {
        var options = SyncOptions(fullPass: fullPass, maximumRetryWait: maximumRetryWait)
        options.requestSpacing = .zero
        return options
    }
}

public enum SyncOutcome: String, Codable, Sendable {
    /// Listing reached `hasMore == false` (or caught up) and every needed detail was fetched.
    case completed
    /// Stopped early for a recorded reason (rate limit, pagination anomaly, transport); resumable.
    case partial
    /// A 403, challenge or non-JSON page. Nothing retried.
    case blocked
    /// The session was rejected (401) or no verified session exists.
    case needsSignIn
    /// The account was signed in again during the job; the job stopped rather than switch credentials.
    case sessionReplaced
    case cancelled
    /// The journal could not be written. Nothing unsaved is reported as archived.
    case storageFailed
}

/// Summary written as the `job.finished` record and shown in the UI. Counts only; no titles or IDs.
public struct SyncManifest: Sendable, Codable, Equatable {
    public var jobID: UUID
    public var accountID: AccountID
    public var resumedJobID: UUID?
    public var outcome: SyncOutcome
    public var reason: String?
    public var pagesListed = 0
    public var entriesListed = 0
    public var entryTypes: [String: Int] = [:]
    public var detailsFetched = 0
    public var detailsUnchanged = 0
    public var detailsFailed = 0
    public var listOnlyEntries = 0
    /// "Complete" always names its scope: listing ended on `hasMore == false`, or caught up early.
    public var listingEnd: String?
    public var warnings: [String] = []

    public init(jobID: UUID, accountID: AccountID, outcome: SyncOutcome) {
        self.jobID = jobID
        self.accountID = accountID
        self.outcome = outcome
    }
}

public struct SyncProgress: Sendable, Equatable {
    public enum Stage: String, Sendable { case verifying, listing, details, finishing }
    public let stage: Stage
    public let pages: Int
    public let entries: Int
    public let detailsDone: Int
    public let detailsNeeded: Int

    public init(stage: Stage, pages: Int, entries: Int, detailsDone: Int, detailsNeeded: Int) {
        self.stage = stage
        self.pages = pages
        self.entries = entries
        self.detailsDone = detailsDone
        self.detailsNeeded = detailsNeeded
    }
}

/// Implemented by the Arena adapter: runs one read-only sync job for one account, recording every
/// response in `journal` before interpreting it.
public protocol HistorySyncing: Sendable {
    func sync(
        account: AccountContext, principal: PrincipalIdentity, journal: JournalWriter, journalRoot: URL,
        options: SyncOptions, progress: @escaping @Sendable (SyncProgress) -> Void
    ) async -> SyncManifest
}

/// One journal per account under `Archive/accounts/<uuid>/journal`, opened once and kept open.
public actor JournalStore {
    private let accountsRoot: URL
    private var writers: [AccountID: JournalWriter] = [:]

    public init(archiveRoot: URL) { accountsRoot = archiveRoot.appendingPathComponent("accounts", isDirectory: true) }

    public func root(for account: AccountID) -> URL {
        accountsRoot.appendingPathComponent(account.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent("journal", isDirectory: true)
    }

    public func writer(for account: AccountID) throws -> JournalWriter {
        if let writer = writers[account] { return writer }
        let writer = try JournalWriter.open(at: root(for: account))
        writers[account] = writer
        return writer
    }

    public func close(_ account: AccountID) {
        try? writers.removeValue(forKey: account)?.close()
    }
}

/// Runs sync jobs: at most one per account, accounts independent (plan v3 §5 invariant 5).
public actor HistorySyncService {
    private let accounts: AccountService
    private let journals: JournalStore
    private let engine: any HistorySyncing
    private var running: [AccountID: Task<SyncManifest, Never>] = [:]
    private var lastManifest: [AccountID: SyncManifest] = [:]
    private var progress: [AccountID: SyncProgress] = [:]

    public init(accounts: AccountService, journals: JournalStore, engine: any HistorySyncing) {
        self.accounts = accounts
        self.journals = journals
        self.engine = engine
    }

    public func isRunning(_ account: AccountID) -> Bool { running[account] != nil }
    public func manifest(_ account: AccountID) -> SyncManifest? { lastManifest[account] }
    public func currentProgress(_ account: AccountID) -> SyncProgress? { progress[account] }

    /// Starts a job and returns its manifest when it ends. Refuses a second job for the same account.
    public func sync(_ account: AccountID, options: SyncOptions = SyncOptions()) async throws -> SyncManifest {
        guard running[account] == nil else { throw AccountError.busy }
        let context = try await accounts.context(for: account)  // only signed-in accounts
        let principal = try await accounts.principal(for: account)
        let writer = try await journals.writer(for: account)
        let root = await journals.root(for: account)
        let engine = self.engine
        let service = self  // held only for the job's duration
        let task = Task {
            await engine.sync(
                account: context, principal: principal, journal: writer, journalRoot: root, options: options
            ) { update in
                Task { await service.record(update, for: account) }
            }
        }
        running[account] = task
        let manifest = await task.value
        running[account] = nil
        progress[account] = nil
        lastManifest[account] = manifest
        return manifest
    }

    public func cancel(_ account: AccountID) { running[account]?.cancel() }

    private func record(_ update: SyncProgress, for account: AccountID) {
        if running[account] != nil { progress[account] = update }
    }
}
