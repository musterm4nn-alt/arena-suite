import CaptureJournal
import Foundation
import SuiteDomain

/// Plan v3 §2 and §9. Defaults follow the traffic policy; spacing may only be raised.
public struct SyncOptions: Sendable, Equatable {
    /// Minimum delay between history requests of one account. Never below 1 s outside tests.
    public private(set) var requestSpacing: Duration
    /// List every page even when the newest pages show nothing changed.
    public var fullPass: Bool
    /// Longest `Retry-After` the job waits for (once) before stopping with `partial`.
    public var maximumRetryWait: Duration
    /// Safety bound on pages per job.
    public var maximumPages: Int

    public static let minimumSpacing: Duration = .seconds(1)

    public init(
        requestSpacing: Duration = .seconds(1), fullPass: Bool = false, maximumRetryWait: Duration = .seconds(120),
        maximumPages: Int = 1_000
    ) {
        self.requestSpacing = max(requestSpacing, Self.minimumSpacing)
        self.fullPass = fullPass
        self.maximumRetryWait = maximumRetryWait
        self.maximumPages = maximumPages
    }

    /// Spacing can only be raised above the policy minimum.
    public mutating func setRequestSpacing(_ spacing: Duration) {
        requestSpacing = max(spacing, Self.minimumSpacing)
    }

    /// Tests only: the single way to get zero spacing.
    public static func testing(fullPass: Bool = false, maximumRetryWait: Duration = .seconds(120)) -> SyncOptions {
        var options = SyncOptions(fullPass: fullPass, maximumRetryWait: maximumRetryWait)
        options.requestSpacing = .zero
        return options
    }
}

public enum SyncOutcome: String, Codable, Sendable {
    /// Listing reached `hasMore == false` (or caught up on a page that was itself complete), no page
    /// reported `partial` or failed sources, and every needed detail was fetched or observed absent
    /// (404). Scope: the pagination observed in this job.
    case completed
    /// Not proven complete: stopped early for a recorded reason (rate limit, pagination anomaly,
    /// transport), a detail failed, or the listing was partial, had failed sources or no `hasMore`.
    /// `reason` says which; a later sync tries again.
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
    /// Detail requests answered 404: recorded as absence, not retried until the entry changes.
    public var detailsAbsent = 0
    public var listOnlyEntries = 0
    /// "Complete" always names its scope: listing ended on `hasMore == false`, or caught up early.
    public var listingEnd: String?
    public var warnings: [String] = []
    /// What the job learned about the account's session when it can no longer be used: rejected
    /// (`needsSignIn`), another principal (`quarantined`) or refused (`blocked`). nil otherwise.
    public var sessionState: AccountAuthState?

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

    public nonisolated func root(for account: AccountID) -> URL {
        accountsRoot.appendingPathComponent(account.rawValue.uuidString, isDirectory: true)
            .appendingPathComponent("journal", isDirectory: true)
    }

    /// Accounts with a journal directory on disk, including removed accounts whose evidence is kept.
    /// Every account with a journal directory, for replay. Unlike `accountsOnDisk`, a folder that
    /// exists but cannot be listed is an error, never an empty inventory.
    public nonisolated func journalAccounts() throws -> [AccountID] {
        guard FileManager.default.fileExists(atPath: accountsRoot.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: accountsRoot.path)
        return names.compactMap { UUID(uuidString: $0) }
            .filter { FileManager.default.fileExists(atPath: root(for: AccountID(rawValue: $0)).path) }
            .sorted { $0.uuidString < $1.uuidString }
            .map { AccountID(rawValue: $0) }
    }

    public nonisolated func accountsOnDisk() -> [AccountID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: accountsRoot.path)) ?? []
        return names.compactMap { UUID(uuidString: $0) }
            .filter { FileManager.default.fileExists(atPath: root(for: AccountID(rawValue: $0)).path) }
            .sorted { $0.uuidString < $1.uuidString }
            .map { AccountID(rawValue: $0) }
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
    /// Written synchronously by the engine's progress callback, so updates keep their order.
    private let progress = ProgressBox()

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
        // Reserved before the first suspension, so neither a second job nor maintenance can slip in.
        guard running[account] == nil, !starting.contains(account), !maintaining else { throw AccountError.busy }
        starting.insert(account)
        defer { starting.remove(account) }
        let context = try await accounts.context(for: account)  // only signed-in accounts
        let principal = try await accounts.principal(for: account)
        let writer = try await journals.writer(for: account)
        let root = journals.root(for: account)
        let engine = self.engine
        let progress = self.progress
        let task = Task {
            await engine.sync(
                account: context, principal: principal, journal: writer, journalRoot: root, options: options
            ) { update in progress[account] = update }
        }
        running[account] = task
        let manifest = await task.value
        running[account] = nil
        progress[account] = nil
        lastManifest[account] = manifest
        if let state = manifest.sessionState {
            // Guarded by the job's credential generation: a newer sign-in is never downgraded.
            await accounts.noteSessionState(account, generation: context.credentialGeneration, state: state)
        }
        return manifest
    }

    public func cancel(_ account: AccountID) { running[account]?.cancel() }

    // MARK: Maintenance exclusion (plan v3 §13, Phase 7)

    private var maintaining = false
    private var starting: Set<AccountID> = []

    /// Verify, backup, restore and rebuild need journals that are not being appended to. Refuses
    /// while any sync runs; while held, new syncs are refused with `AccountError.busy`.
    public func beginMaintenance() throws {
        guard running.isEmpty, starting.isEmpty, localWrites == 0, !maintaining else { throw AccountError.busy }
        maintaining = true
    }

    public func endMaintenance() { maintaining = false }

    // MARK: Local records (plan v3 §7, `local.control`)

    private var localWrites = 0

    /// Appends one local record to `account`'s journal and flushes it to disk. Refused while
    /// maintenance runs; a write in progress holds maintenance off (reserved before the first
    /// suspension). A sync of the same account may run alongside: the shared writer serializes
    /// appends, and job tracking ignores records without a job ID. Refused for an account that is not
    /// in the app: a removed account's journal is kept as evidence, not extended.
    public func appendLocal(_ draft: JournalDraft, account: AccountID) async throws -> AppendReceipt {
        guard draft.kind == LocalControl.kind, draft.accountID == account.rawValue, draft.jobID == nil else {
            throw LocalWriteError.notALocalRecord
        }
        guard !maintaining else { throw AccountError.busy }
        localWrites += 1
        defer { localWrites -= 1 }
        guard await accounts.accounts().contains(where: { $0.id == account }) else { throw AccountError.unknownAccount }
        let writer = try await journals.writer(for: account)
        let receipt = try writer.append(draft)
        // Appended but maybe not on disk: the record may still be read after the next launch.
        do { try writer.synchronize() } catch { throw LocalWriteError.appendedButNotFlushed }
        return receipt
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AccountID: SyncProgress] = [:]
    subscript(account: AccountID) -> SyncProgress? {
        get { lock.withLock { values[account] } }
        set { lock.withLock { values[account] = newValue } }
    }
}

public enum LocalWriteError: Error, Equatable, Sendable {
    /// Only `local.control` records for the named account, outside any job, go through `appendLocal`.
    case notALocalRecord
    /// The record was appended, but flushing it to disk failed: it may or may not survive a restart.
    case appendedButNotFlushed
}
