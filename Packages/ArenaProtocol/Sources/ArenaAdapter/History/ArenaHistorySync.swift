import ApplicationActions
import CaptureJournal
import Foundation
import FoundationTransport
import SuiteDomain

/// Read-only history sync (plan v3 §9). Every response is appended to the account journal before
/// it is interpreted; resume and incremental decisions are derived from the journal alone.
public struct ArenaHistorySync: HistorySyncing {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    /// Conversation kinds whose detail route is observed (N-007, N-008): the only ones fetched in
    /// detail, so the only ones Refresh can fetch again. Arena vocabulary, passed to the app.
    public static let refreshableKinds: Set<String> = ["evaluation"]

    private let sessions: ArenaAccountSessions
    private let downloads: any HTTPTransporting
    private let sleep: Sleeper
    private let now: @Sendable () -> Date

    /// `downloads` fetches attachment files (Docs/attachments-2026-10-20.md): a transport without
    /// cookies or credentials, never an account's session. `now` decides whether a link's signed
    /// lifetime has passed.
    public init(
        sessions: ArenaAccountSessions, downloads: any HTTPTransporting = AccountHTTPSession(cookies: false),
        sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.sessions = sessions
        self.downloads = downloads
        self.sleep = sleep
        self.now = now
    }

    public func sync(
        account: AccountContext, principal: PrincipalIdentity, journal: JournalWriter, journalRoot: URL,
        objects: ObjectStore, options: SyncOptions, progress: @escaping @Sendable (SyncProgress) -> Void
    ) async -> SyncManifest {
        let job = SyncJob(
            account: account.accountID, principal: principal, sessions: sessions, journal: journal,
            journalRoot: journalRoot, files: FileDownloads(objects: objects, transport: downloads, now: now),
            options: options, sleep: sleep, progress: progress)
        return await job.run()
    }

    public func refresh(
        account: AccountContext, principal: PrincipalIdentity, journal: JournalWriter, journalRoot: URL,
        objects: ObjectStore, conversationID: String, options: SyncOptions
    ) async -> SyncManifest {
        let job = SyncJob(
            account: account.accountID, principal: principal, sessions: sessions, journal: journal,
            journalRoot: journalRoot, files: FileDownloads(objects: objects, transport: downloads, now: now),
            options: options, sleep: sleep, progress: { _ in }, mode: .refresh(conversationID))
        return await job.run()
    }
}

/// Where a job's attachment files come from and go to.
struct FileDownloads {
    let objects: ObjectStore
    let transport: any HTTPTransporting
    let now: @Sendable () -> Date
}

/// Journal-derived state: what has already been archived for this account.
struct ArchivedState {
    /// Conversation ID → `updatedAt` from the list entry when its valid detail snapshot was fetched.
    var snapshots: [String: String?] = [:]
    /// Entry ID → last `updatedAt` seen in any recorded list page.
    var listed: [String: String?] = [:]
    /// Conversation ID → `updatedAt` when its detail request was answered 404 (observed absence).
    var absent: [String: String?] = [:]
    /// Entry ID → its type in the last recorded list page that listed it.
    var types: [String: String] = [:]
    /// Conversation ID → unfinished snapshots in a row for one `updatedAt`, while its latest valid
    /// snapshot is unfinished (Docs/sync-refresh-2026-10-20.md). Only for a snapshot recorded with
    /// an `updatedAt`: without one, a change can't be detected and the always-fetch rule applies.
    var unfinished: [String: UnfinishedRun] = [:]
    /// Refresh jobs that never recorded `job.finished`; closed as `interrupted`, never resumed.
    var abandonedRefreshes: [UUID] = []
    /// Object key → the file a recorded download stored for it (Docs/attachments-2026-10-20.md).
    var storedFiles: [String: ObjectStore.Stored] = [:]

    struct UnfinishedRun: Equatable {
        let updatedAt: String
        let count: Int
    }

    /// Unfinished snapshots in a row (for one `updatedAt`) after which sync stops fetching a
    /// conversation again for being unfinished: the first fetch and up to two more.
    static let unfinishedLimit = 3
    /// The most recent history job that never recorded `job.finished` (e.g. the app was killed).
    var interrupted: Interrupted?
    /// Older unfinished jobs, closed as `interrupted` without resuming.
    var abandoned: [UUID] = []

    struct Interrupted {
        let jobID: UUID
        var entries: [ListEntry] = []
        var pages = 0
        var lastCursor: String?
        var lastHasMore: Bool?
        /// Pages that did not prove themselves complete (`ListPage.incompleteness`).
        var incompletePages: [String] = []
    }

    static func scan(_ root: URL) throws -> ArchivedState {
        var state = ArchivedState()
        var open: [UUID: Interrupted] = [:]
        var order: [UUID] = []
        var refreshes: [UUID] = []
        try JournalReader(root: root).forEach { record in
            let envelope = record.envelope
            let role = envelope.metadata["role"].flatMap { if case .string(let value) = $0 { value } else { nil } }
            switch envelope.kind {
            case JournalKind.jobStarted where envelope.metadata["job_kind"] == .string("history_sync"):
                if let job = envelope.jobID {
                    open[job] = Interrupted(jobID: job)
                    order.append(job)
                }
            case JournalKind.jobStarted where envelope.metadata["job_kind"] == .string(SyncJob.refreshKind):
                if let job = envelope.jobID { refreshes.append(job) }
            case JournalKind.jobFinished:
                if let job = envelope.jobID {
                    open[job] = nil
                    order.removeAll { $0 == job }
                    refreshes.removeAll { $0 == job }
                }
            case "exchange" where role == "list":
                guard record.envelope.metadata["status"] == .integer(200),
                    record.envelope.metadata["transfer_end"] == .string("complete"),
                    let page = ListPage.decode(record.payload)
                else { return }
                for entry in page.entries {
                    state.listed[entry.id] = entry.updatedAt
                    state.types[entry.id] = entry.type
                }
                if let job = envelope.jobID, var interrupted = open[job] {
                    interrupted.entries.append(contentsOf: page.entries)
                    interrupted.pages += 1
                    interrupted.lastCursor = page.cursor
                    interrupted.lastHasMore = page.hasMore
                    if let gap = page.incompleteness { interrupted.incompletePages.append("page \(interrupted.pages): \(gap)") }
                    open[job] = interrupted
                }
            case "exchange" where role == "detail" && envelope.metadata["status"] == .integer(404):
                guard case .string(let id) = envelope.metadata["entry_id"] else { return }
                if case .string(let updated) = envelope.metadata["source_updated_at"] {
                    state.absent[id] = updated
                } else {
                    state.absent[id] = String?.none
                }
                // Absent now: fetching it again for being unfinished would only repeat the 404.
                state.unfinished[id] = nil
            case SyncJob.downloadKind where envelope.metadata["outcome"] == .string(AttachmentOutcome.stored.rawValue):
                guard case .string(let key) = envelope.metadata["object_key"],
                    case .string(let digest) = envelope.metadata[ObjectStore.digestKey],
                    case .integer(let size) = envelope.metadata[ObjectStore.sizeKey], size >= 0
                else { return }
                state.storedFiles[key] = ObjectStore.Stored(sha256: digest, size: Int(size))
            case "exchange" where role == "detail":
                guard case .string(let id) = envelope.metadata["entry_id"],
                    envelope.metadata["status"] == .integer(200),
                    envelope.metadata["transfer_end"] == .string("complete"),
                    let unfinished = DetailCheck.unfinished(record.payload, id: id)
                else { return }
                state.absent[id] = nil
                let updated: String?
                if case .string(let value) = envelope.metadata["source_updated_at"] { updated = value } else { updated = nil }
                state.snapshots[id] = updated
                if unfinished, let updated {
                    let previous = state.unfinished[id]
                    let count = previous.map { $0.updatedAt == updated ? $0.count + 1 : 1 } ?? 1
                    state.unfinished[id] = UnfinishedRun(updatedAt: updated, count: count)
                } else {
                    state.unfinished[id] = nil
                }
            default:
                break
            }
        }
        if let latest = order.last { state.interrupted = open[latest] }
        state.abandoned = order.dropLast().filter { open[$0] != nil }
        state.abandonedRefreshes = refreshes
        return state
    }

    func isUnchanged(_ entry: ListEntry) -> Bool {
        guard let updated = entry.updatedAt, listed[entry.id] == updated else { return false }
        return entry.type != "evaluation" || snapshots[entry.id] == updated || absent[entry.id] == updated
    }

    func needsDetail(_ entry: ListEntry) -> Bool {
        guard entry.type == "evaluation" else { return false }
        // Without `updatedAt` a change is undetectable, so such conversations are always refetched.
        guard let updated = entry.updatedAt else { return true }
        if snapshots[entry.id] == updated { return refetchesUnfinished(entry) }
        // A 404 for this same version is remembered; a changed `updatedAt` retries it.
        return absent[entry.id] != updated
    }

    /// The latest snapshot of this unchanged entry was taken while a response was still being
    /// generated (N-020: the list doesn't change when it finishes), and it was fetched fewer than
    /// `unfinishedLimit` times in a row for this `updatedAt`.
    func refetchesUnfinished(_ entry: ListEntry) -> Bool {
        isUnfinished(entry) && (unfinished[entry.id]?.count ?? 0) < Self.unfinishedLimit
    }

    /// The latest snapshot of this unchanged `evaluation` entry is unfinished.
    func isUnfinished(_ entry: ListEntry) -> Bool {
        guard entry.type == "evaluation", let updated = entry.updatedAt, snapshots[entry.id] == updated,
            let run = unfinished[entry.id]
        else { return false }
        return run.updatedAt == updated
    }

    /// Unfinished conversations still under the limit, whether or not a listing reaches them (an
    /// incremental listing stops before older entries). Sorted, so jobs are deterministic.
    var unfinishedToRevisit: [String] { unfinishedConversations { $0 < Self.unfinishedLimit } }

    /// Unfinished conversations that reached the limit: sync leaves them until their `updatedAt`
    /// changes or the user refreshes one.
    var unfinishedAtLimit: [String] { unfinishedConversations { $0 >= Self.unfinishedLimit } }

    private func unfinishedConversations(_ count: (Int) -> Bool) -> [String] {
        unfinished.filter { id, run in
            count(run.count) && types[id] == "evaluation" && snapshots[id] == run.updatedAt
        }.keys.sorted()
    }
}

final class SyncJob {
    /// A history sync, or a refresh of one conversation's detail (Docs/sync-refresh-2026-10-20.md).
    enum Mode: Equatable {
        case history
        case refresh(String)
    }

    static let refreshKind = "conversation_refresh"
    /// One attachment file request and its response (Docs/attachments-2026-10-20.md).
    static let downloadKind = "attachment.download"

    private let mode: Mode
    private var jobKind: String { mode == .history ? "history_sync" : Self.refreshKind }
    private let account: AccountID
    private let principal: PrincipalIdentity
    private let sessions: ArenaAccountSessions
    private let journal: JournalWriter
    private let journalRoot: URL
    private let files: FileDownloads
    private let options: SyncOptions
    private let sleep: ArenaHistorySync.Sleeper
    private let report: @Sendable (SyncProgress) -> Void
    private let jobID = UUID()
    private var manifest: SyncManifest
    private var session: ArenaAccountSession?
    private var requestsSent = 0
    /// Why the listing is not proven complete (partial pages, failed sources, no `hasMore`). Any
    /// entry keeps the outcome from being `completed`, even if every detail was fetched.
    private var listingGaps: [String] = []
    /// What this job listed (entry ID → `updatedAt`), for `unfinishedLeft`.
    private var listedByJob: [String: String?] = [:]
    /// Sequence of the record `record` appended last.
    private var lastSequence: UInt64?
    /// Object key → stored file, from the journal and from this job.
    private var storedFiles: [String: ObjectStore.Stored] = [:]
    private var objectsOpened = false
    /// Why downloads stopped for the rest of this job (403, 429, …), and what was left unrequested.
    private var downloadsStopped: String?
    private var downloadsLeft = 0
    private lazy var recorder = ExchangeRecorder(journal: journal, account: account, jobID: jobID)

    init(
        account: AccountID, principal: PrincipalIdentity, sessions: ArenaAccountSessions, journal: JournalWriter,
        journalRoot: URL, files: FileDownloads, options: SyncOptions, sleep: @escaping ArenaHistorySync.Sleeper,
        progress: @escaping @Sendable (SyncProgress) -> Void, mode: Mode = .history
    ) {
        self.mode = mode
        self.account = account
        self.principal = principal
        self.sessions = sessions
        self.journal = journal
        self.journalRoot = journalRoot
        self.files = files
        self.options = options
        self.sleep = sleep
        self.report = progress
        manifest = SyncManifest(jobID: jobID, accountID: account, outcome: .partial)
    }

    private enum Stop: Error {
        case outcome(SyncOutcome, String)
    }

    func run() async -> SyncManifest {
        report(SyncProgress(stage: .verifying, pages: 0, entries: 0, detailsDone: 0, detailsNeeded: 0))
        let state: ArchivedState
        do { state = try ArchivedState.scan(journalRoot) } catch {
            return finishWithoutJournal(.storageFailed, "journal could not be read")
        }
        storedFiles = state.storedFiles
        // Only a conversation listed as `evaluation` has an observed detail route; nothing is sent
        // or written for anything else.
        if case .refresh(let id) = mode, state.types[id].map(ArenaHistorySync.refreshableKinds.contains) != true {
            return finishWithoutJournal(.partial, "refused: not listed as a conversation in this account")
        }
        do {
            for job in state.abandonedRefreshes { try closeInterrupted(job, kind: Self.refreshKind, resumedBy: nil) }
            // A refresh leaves an interrupted history job for the next sync to resume.
            if mode == .history {
                for job in state.abandoned { try closeInterrupted(job, kind: jobKind, resumedBy: nil) }
                if let interrupted = state.interrupted {
                    manifest.resumedJobID = interrupted.jobID
                    try closeInterrupted(interrupted.jobID, kind: jobKind, resumedBy: jobID)
                }
            }
            var started: [String: JournalValue] = ["job_kind": .string(jobKind)]
            if mode == .history {
                started["full_pass"] = .bool(options.fullPass)
                started["page_limit"] = .integer(Int64(HistoryRoutes.pageLimit))
            }
            if let resumed = manifest.resumedJobID { started["resumes"] = .string(resumed.uuidString) }
            // Counted now in case the job can't start, and again when it ends.
            if mode == .history { manifest.unfinishedLeft = unfinishedLeft(state) }
            try append(JournalDraft(kind: JournalKind.jobStarted, accountID: account.rawValue, jobID: jobID, metadata: started))
            try journal.synchronize()
        } catch {
            return finishWithoutJournal(.storageFailed, "journal could not be written")
        }

        do {
            try await verifyIdentity()
            switch mode {
            case .history:
                let entries = try await list(state: state)
                try await fetchDetails(entries, state: state)
            case .refresh(let id):
                try await refreshDetail(id, state: state)
            }
            noteDownloadsLeft()
            var reasons: [String] = []
            if manifest.detailsFailed > 0 { reasons.append("\(manifest.detailsFailed) detail request(s) failed; resumable") }
            if !listingGaps.isEmpty { reasons.append("listing not proven complete (\(listingGaps.joined(separator: "; ")))") }
            manifest.outcome = reasons.isEmpty ? .completed : .partial
            manifest.reason = reasons.isEmpty ? nil : reasons.joined(separator: "; ")
        } catch Stop.outcome(let outcome, let reason) {
            noteDownloadsLeft()
            manifest.outcome = outcome
            manifest.reason = reason
            // The account's state follows: a rejected session needs a new sign-in, a refusal stops
            // further jobs until the user checks again (plan v3 §2: stop on 403/challenge).
            switch outcome {
            case .needsSignIn: manifest.sessionState = manifest.sessionState ?? .needsSignIn
            case .blocked: manifest.sessionState = manifest.sessionState ?? .blocked
            default: break
            }
        } catch {
            noteDownloadsLeft()
            manifest.outcome = .storageFailed
            manifest.reason = "journal could not be written"
        }
        if mode == .history { manifest.unfinishedLeft = unfinishedLeft(state) }
        return finish()
    }

    /// Unfinished conversations at the limit that this job left alone because of it, however the
    /// job ended. One this job listed with another `updatedAt` isn't held by the limit: this job
    /// fetches it (the ordinary rule), or the next one does if this one stopped first.
    private func unfinishedLeft(_ state: ArchivedState) -> Int {
        state.unfinishedAtLimit.filter { id in
            guard let listed = listedByJob[id] else { return true }
            return listed == state.unfinished[id]?.updatedAt
        }.count
    }

    /// Identity first: nothing else is sent before the principal is verified again for this job.
    /// The `/api/me` response is journaled (role `identity`) before it is interpreted.
    private func verifyIdentity() async throws {
        let recorder = self.recorder
        let failure = RecordFailure()
        let request = ArenaRoutes.identity()
        let (check, session) = await sessions.verifyRecording(account: account, expected: principal) { exchange in
            do {
                try recorder.record(exchange, request: request, role: "identity", route: "/api/me", extra: [:])
            } catch {
                failure.set()
                throw error
            }
        }
        requestsSent += 1
        if failure.isSet { throw Stop.outcome(.storageFailed, "journal could not be written") }
        switch check {
        case .verified: break
        case .rejected(let status): throw Stop.outcome(.needsSignIn, "identity HTTP \(status.map(String.init) ?? "rejected")")
        case .noSavedSession: throw Stop.outcome(.needsSignIn, "no verified session")
        case .mismatch:
            manifest.sessionState = .quarantined
            throw Stop.outcome(.needsSignIn, "identity mismatch; session discarded")
        case .blocked(let status): throw Stop.outcome(.blocked, "identity HTTP \(status.map(String.init) ?? "blocked")")
        case .unreachable: throw Stop.outcome(.partial, "identity check unreachable")
        }
        guard let session else { throw Stop.outcome(.needsSignIn, "no verified session") }
        self.session = session
        try append(
            JournalDraft(
                kind: "session.verified", accountID: account.rawValue, jobID: jobID,
                metadata: ["namespace": .string(principal.namespace)]))
    }

    // MARK: Listing

    private func list(state: ArchivedState) async throws -> [ListEntry] {
        var entries: [ListEntry] = []
        var seen = Set<String>()
        func add(_ page: [ListEntry]) {
            for entry in page where seen.insert(entry.id).inserted {
                entries.append(entry)
                listedByJob[entry.id] = entry.updatedAt
            }
        }
        var cursor: String?
        if let interrupted = state.interrupted {
            add(interrupted.entries)
            manifest.pagesListed = interrupted.pages
            listingGaps += interrupted.incompletePages.map { "\($0) (resumed)" }
            if interrupted.pages > 0 {
                guard interrupted.lastHasMore == true else {
                    if interrupted.lastHasMore == nil {
                        manifest.listingEnd = "hasMore absent (resumed)"
                        listingGaps.append("pagination.hasMore absent (resumed)")
                    } else {
                        manifest.listingEnd = "hasMore=false (resumed)"
                    }
                    tally(entries)
                    return entries
                }
                cursor = interrupted.lastCursor
                guard cursor != nil else { throw Stop.outcome(.partial, "resumed page had hasMore without cursor") }
            }
        }
        var cursors = Set<String>()
        var bodies = Set<Data>()
        while true {
            guard manifest.pagesListed < options.maximumPages else {
                throw Stop.outcome(.partial, "page limit \(options.maximumPages) reached")
            }
            guard let request = HistoryRoutes.list(cursor: cursor) else {
                throw Stop.outcome(.partial, "cursor not usable as an opaque query value")
            }
            let exchange = try await fetch(request, role: "list", route: HistoryRoutes.listTemplate, extra: [:])
            guard let page = ListPage.decode(exchange.body) else {
                throw Stop.outcome(Self.looksLikeChallenge(exchange) ? .blocked : .partial, "list page not recognized")
            }
            manifest.pagesListed += 1
            if page.skippedEntries > 0 {
                manifest.warnings.append("page \(manifest.pagesListed): \(page.skippedEntries) entry(ies) without a usable id skipped (raw bytes kept)")
            }
            if let gap = page.incompleteness {
                manifest.warnings.append("page \(manifest.pagesListed): \(gap)")
                listingGaps.append("page \(manifest.pagesListed): \(gap)")
            }
            guard bodies.insert(exchange.body).inserted else { throw Stop.outcome(.partial, "repeated page") }
            // Catching up early needs a page that proves itself complete: entries missing from a
            // partial page could be the changed ones.
            let unchangedPage =
                !options.fullPass && page.incompleteness == nil && !page.entries.isEmpty
                && page.entries.allSatisfy(state.isUnchanged) && Self.isNewestFirst(page.entries)
            add(page.entries)
            report(SyncProgress(stage: .listing, pages: manifest.pagesListed, entries: entries.count, detailsDone: 0, detailsNeeded: 0))
            if unchangedPage {
                manifest.listingEnd = "caught up: page \(manifest.pagesListed) unchanged and newest-first"
                break
            }
            guard page.hasMore == true else {
                manifest.listingEnd = page.hasMore == false ? "hasMore=false" : "hasMore absent"
                if page.hasMore == nil {
                    // Not an observed end of the history: later pages may exist.
                    manifest.warnings.append("pagination.hasMore absent")
                    listingGaps.append("pagination.hasMore absent on page \(manifest.pagesListed)")
                }
                break
            }
            guard let next = page.cursor else { throw Stop.outcome(.partial, "hasMore=true without cursor") }
            guard cursors.insert(next).inserted else { throw Stop.outcome(.partial, "repeated cursor") }
            cursor = next
        }
        tally(entries)
        return entries
    }

    private func tally(_ entries: [ListEntry]) {
        manifest.entriesListed = entries.count
        manifest.entryTypes = entries.reduce(into: [:]) { $0[$1.type, default: 0] += 1 }
        manifest.listOnlyEntries = entries.filter { $0.type != "evaluation" }.count
    }

    /// Early stop is only safe if the page is visibly ordered by `updatedAt`, newest first.
    /// Compares parsed instants, never strings: mixed precision or offsets must not fake an order.
    /// Any missing or unparseable stamp disables the early stop.
    static func isNewestFirst(_ entries: [ListEntry]) -> Bool {
        let instants = entries.compactMap { $0.updatedAt.flatMap(SourceInstant.init) }
        return instants.count == entries.count && zip(instants, instants.dropFirst()).allSatisfy { $0 >= $1 }
    }

    // MARK: Details

    private func fetchDetails(_ entries: [ListEntry], state: ArchivedState) async throws {
        let needed = entries.filter(state.needsDetail)
        // Unfinished conversations this listing didn't reach are fetched by ID, as a refresh would.
        let listedIDs = Set(entries.map(\.id))
        let unlisted = state.unfinishedToRevisit.filter { !listedIDs.contains($0) }
        manifest.detailsUnchanged = entries.filter { $0.type == "evaluation" }.count - needed.count
        let total = needed.count + unlisted.count
        let unstamped = needed.filter { $0.updatedAt == nil }.count
        if unstamped > 0 {
            manifest.warnings.append("\(unstamped) conversation(s) without updatedAt refetched (change not detectable)")
        }
        for (index, entry) in needed.enumerated() {
            report(SyncProgress(stage: .details, pages: manifest.pagesListed, entries: entries.count, detailsDone: index, detailsNeeded: total))
            guard let request = HistoryRoutes.detail(id: entry.id) else {
                manifest.detailsFailed += 1
                manifest.warnings.append("detail skipped: ID not path-safe")
                continue
            }
            var extra: [String: JournalValue] = ["entry_id": .string(entry.id), "entry_type": .string(entry.type)]
            if let updated = entry.updatedAt { extra["source_updated_at"] = .string(updated) }
            let refetch = state.refetchesUnfinished(entry)
            if try await fetchDetail(request, id: entry.id, extra: extra), refetch { manifest.detailsRefetchedUnfinished += 1 }
        }
        for (index, id) in unlisted.enumerated() {
            report(SyncProgress(stage: .details, pages: manifest.pagesListed, entries: entries.count, detailsDone: needed.count + index, detailsNeeded: total))
            if try await refreshDetail(id, state: state) { manifest.detailsRefetchedUnfinished += 1 }
        }
        report(SyncProgress(stage: .finishing, pages: manifest.pagesListed, entries: entries.count, detailsDone: total, detailsNeeded: total))
    }

    /// One conversation's detail by ID (a refresh, or an unfinished one the listing didn't reach).
    /// This job didn't see it listed, so the record names the type and `updatedAt` last listed for
    /// it in the journal and says where those values came from. True when a valid detail arrived.
    @discardableResult
    private func refreshDetail(_ id: String, state: ArchivedState) async throws -> Bool {
        guard let request = HistoryRoutes.detail(id: id) else {
            manifest.detailsFailed += 1
            manifest.warnings.append("detail skipped: ID not path-safe")
            return false
        }
        var extra: [String: JournalValue] = ["entry_id": .string(id)]
        if let type = state.types[id] {
            extra["entry_type"] = .string(type)
            extra["entry_type_origin"] = .string("last_listed")
        }
        if case .some(.some(let updated)) = state.listed[id] {
            extra["source_updated_at"] = .string(updated)
            extra["source_updated_at_origin"] = .string("last_listed")
        }
        return try await fetchDetail(request, id: id, extra: extra)
    }

    /// True when a valid detail arrived (counted in `detailsFetched`). Its attachments' files are
    /// downloaded before anything else is requested: their links are fresh only now (N-019).
    private func fetchDetail(_ request: URLRequest, id: String, extra: [String: JournalValue]) async throws -> Bool {
        let exchange = try await fetch(request, role: "detail", route: HistoryRoutes.detailTemplate, extra: extra, allowNotFound: true)
        if exchange.status == 404 {
            manifest.detailsAbsent += 1  // plan §9.5: an observation of absence; local evidence kept
        } else if exchange.status == 200 && DetailCheck.isValid(exchange.body, id: id), let detail = lastSequence {
            manifest.detailsFetched += 1
            try await downloadAttachments(exchange.body, conversation: id, detail: detail)
            return true
        } else if exchange.status == 200 && Self.looksLikeChallenge(exchange) {
            throw Stop.outcome(.blocked, "detail response not recognized")
        } else {
            manifest.detailsFailed += 1
            manifest.warnings.append("detail HTTP \(exchange.status.map(String.init) ?? "none") or unrecognized body")
        }
        return false
    }

    // MARK: Attachment files (Docs/attachments-2026-10-20.md)

    /// One request per attachment of this detail, in order, under the job's spacing. A stored body
    /// goes to the object store, then a record names it; any other response is recorded with its
    /// body. Never changes the job's outcome; storage failures stop the job (after recording the
    /// body in the journal, if it still takes it).
    private func downloadAttachments(_ body: Data, conversation: String, detail: UInt64) async throws {
        for attachment in AttachmentLink.located(in: body) {
            guard let link = attachment.link, !link.isEmpty else { continue }  // no link: nothing to fetch
            guard let parsed = AttachmentLink.parse(link) else {
                manifest.attachmentsNotRecognized += 1
                continue
            }
            if let stored = storedFiles[parsed.objectKey], files.objects.state(stored.sha256, size: stored.size) == .present {
                manifest.attachmentsAlreadyStored += 1
                continue
            }
            if let expires = parsed.expiresAt, expires <= files.now() {
                manifest.attachmentsExpired += 1
                continue
            }
            guard downloadsStopped == nil else {
                downloadsLeft += 1
                continue
            }
            try await download(parsed, attachment: attachment, conversation: conversation, detail: detail)
        }
    }

    private func download(
        _ link: AttachmentLink.Parsed, attachment: AttachmentLink.Located, conversation: String, detail: UInt64
    ) async throws {
        if requestsSent > 0 {
            do { try await sleep(options.requestSpacing) } catch { throw Stop.outcome(.cancelled, "cancelled") }
        }
        try checkContinue()
        // The spacing may have outlived the link.
        if let expires = link.expiresAt, expires <= files.now() {
            manifest.attachmentsExpired += 1
            return
        }
        var request = URLRequest(url: link.url)
        request.httpMethod = "GET"
        requestsSent += 1
        let exchange: HTTPExchange
        do { exchange = try await files.transport.perform(request) } catch {
            if Task.isCancelled { throw Stop.outcome(.cancelled, "cancelled") }
            manifest.attachmentsFailed += 1
            manifest.warnings.append("attachment request failed before a response")
            return
        }
        let outcome: AttachmentOutcome
        var stored: ObjectStore.Stored?
        switch (exchange.status ?? 0, exchange.transferEnd) {
        case (200, .complete):
            do {
                if !objectsOpened {
                    try files.objects.open()
                    objectsOpened = true
                }
                stored = try files.objects.put(exchange.body)
                outcome = .stored
            } catch {
                outcome = .notStored  // the body goes into the record instead; the job stops below
            }
        case (401, _), (403, _):
            outcome = .denied
            downloadsStopped = "HTTP \(exchange.status ?? 0)"
        case (429, _), (503, _):
            outcome = .unavailable
            downloadsStopped = "HTTP \(exchange.status ?? 0)"
        default:
            outcome = .unavailable
        }
        var extra: [String: JournalValue] = [
            "entry_id": .string(conversation), "detail_sequence": .string(String(detail)),
            "message_id": .string(attachment.messageID), "attachment_ordinal": .integer(Int64(attachment.ordinal)),
            "object_key": .string(link.objectKey), "outcome": .string(outcome.rawValue),
        ]
        if let stored {
            extra[ObjectStore.digestKey] = .string(stored.sha256)
            extra[ObjectStore.sizeKey] = .integer(Int64(stored.size))
        }
        try recorder.recordDownload(exchange, request: request, stored: stored != nil, extra: extra)
        if let stored {
            storedFiles[link.objectKey] = stored
            manifest.attachmentsStored += 1
        } else {
            manifest.attachmentsFailed += 1
            if outcome == .notStored { throw Stop.outcome(.storageFailed, "attachment file could not be stored") }
            if exchange.transferEnd != .complete, Task.isCancelled { throw Stop.outcome(.cancelled, "cancelled") }
        }
    }

    /// Names the attachments left unrequested after downloads stopped.
    private func noteDownloadsLeft() {
        guard let stopped = downloadsStopped else { return }
        var warning = "attachment downloads stopped after \(stopped)"
        if downloadsLeft > 0 { warning += "; \(downloadsLeft) attachment(s) not requested" }
        if !manifest.warnings.contains(warning) { manifest.warnings.append(warning) }
    }

    // MARK: Requests

    /// One request under the traffic policy. The response is journaled before anything reads it.
    private func fetch(
        _ request: URLRequest, role: String, route: String, extra: [String: JournalValue], allowNotFound: Bool = false
    ) async throws -> HTTPExchange {
        var retried = false
        while true {
            if requestsSent > 0 {
                do { try await sleep(options.requestSpacing) } catch { throw Stop.outcome(.cancelled, "cancelled") }
            }
            try checkContinue()
            guard let session, await sessions.isCurrent(session, for: account) else {
                throw Stop.outcome(.sessionReplaced, "account signed in again during the job")
            }
            requestsSent += 1
            let exchange: HTTPExchange
            do {
                exchange = try await session.performVerified(request)
            } catch SessionGateError.notVerified {
                throw Stop.outcome(.needsSignIn, "session not verified")
            } catch {
                throw Stop.outcome(Task.isCancelled ? .cancelled : .partial, "transport failure")
            }
            try record(exchange, request: request, role: role, route: route, extra: extra)
            guard exchange.transferEnd == .complete else {
                throw Stop.outcome(Task.isCancelled ? .cancelled : .partial, "transfer \(exchange.transferEnd.rawValue)")
            }
            switch exchange.status ?? 0 {
            case 200: return exchange
            case 404 where allowNotFound: return exchange
            case 401: throw Stop.outcome(.needsSignIn, "HTTP 401")
            case 403: throw Stop.outcome(.blocked, "HTTP 403")
            case 429, 503:
                let wait = Self.retryAfter(exchange)
                guard !retried, let wait, wait <= options.maximumRetryWait else {
                    throw Stop.outcome(.partial, "rate limited (HTTP \(exchange.status ?? 0))")
                }
                retried = true
                do { try await sleep(wait) } catch { throw Stop.outcome(.cancelled, "cancelled") }
            default:
                throw Stop.outcome(.partial, "HTTP \(exchange.status.map(String.init) ?? "none")")
            }
        }
    }

    private func checkContinue() throws {
        if Task.isCancelled { throw Stop.outcome(.cancelled, "cancelled") }
    }

    static func retryAfter(_ exchange: HTTPExchange) -> Duration? {
        guard let value = exchange.headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value,
            let seconds = Int(value.trimmingCharacters(in: .whitespaces)), seconds >= 0
        else { return nil }
        return .seconds(seconds)
    }

    static func looksLikeChallenge(_ exchange: HTTPExchange) -> Bool { ArenaRoutes.looksLikeChallenge(exchange) }

    // MARK: Journal

    private func record(
        _ exchange: HTTPExchange, request: URLRequest, role: String, route: String, extra: [String: JournalValue]
    ) throws {
        lastSequence = try recorder.record(exchange, request: request, role: role, route: route, extra: extra)
    }

    private func append(_ draft: JournalDraft) throws {
        _ = try journal.append(draft)
    }

    private func closeInterrupted(_ job: UUID, kind: String, resumedBy: UUID?) throws {
        var metadata: [String: JournalValue] = ["job_kind": .string(kind), "outcome": .string("interrupted")]
        if let resumedBy { metadata["resumed_by"] = .string(resumedBy.uuidString) }
        try append(JournalDraft(kind: JournalKind.jobFinished, accountID: account.rawValue, jobID: job, metadata: metadata))
    }

    private func finish() -> SyncManifest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = (try? encoder.encode(manifest)) ?? Data()
        do {
            try append(
                JournalDraft(
                    kind: JournalKind.jobFinished, payload: payload, accountID: account.rawValue, jobID: jobID,
                    metadata: ["job_kind": .string(jobKind), "outcome": .string(manifest.outcome.rawValue)]))
            try journal.synchronize()
        } catch {
            manifest.outcome = .storageFailed
            manifest.reason = "job.finished could not be written"
        }
        return manifest
    }

    /// For stops before `job.started` was written: nothing was requested beyond identity.
    private func finishWithoutJournal(_ outcome: SyncOutcome, _ reason: String) -> SyncManifest {
        manifest.outcome = outcome
        manifest.reason = reason
        return manifest
    }
}

/// Appends one `exchange` record (and syncs) before anything interprets the response.
/// Sendable so it can run inside the session actor for identity checks.
struct ExchangeRecorder: Sendable {
    let journal: JournalWriter
    let account: AccountID
    let jobID: UUID

    /// The appended record's sequence.
    @discardableResult
    func record(
        _ exchange: HTTPExchange, request: URLRequest, role: String, route: String, extra: [String: JournalValue]
    ) throws -> UInt64 {
        var metadata = Self.metadata(exchange, request: request, extra: extra)
        metadata["role"] = .string(role)
        metadata["route"] = .string(route)
        metadata["path"] = .string(request.url?.path ?? "")
        metadata["query"] = request.url?.query.map(JournalValue.string) ?? .null
        return try append(
            kind: "exchange", exchange, payload: exchange.body, representation: "foundation_decoded_entity",
            transformations: ["credential_omitted"], metadata: metadata)
    }

    /// An attachment file request (`attachment.download`). A stored body is in the object store and
    /// named by `extra` (`object_sha256`, `object_size`); the payload is then empty. The link's
    /// signed query is not repeated: the detail record holds it.
    func recordDownload(_ exchange: HTTPExchange, request: URLRequest, stored: Bool, extra: [String: JournalValue]) throws {
        try append(
            kind: SyncJob.downloadKind, exchange, payload: stored ? Data() : exchange.body,
            representation: stored ? ObjectStore.representation : "foundation_decoded_entity",
            transformations: ["credential_omitted", "signed_query_omitted"],
            metadata: Self.metadata(exchange, request: request, extra: extra, omittingSignedQueries: true))
    }

    /// `omittingSignedQueries`: a redirect's `Location` (never followed) may carry a newly signed
    /// link; its query is replaced by `[omitted]`.
    private static func metadata(
        _ exchange: HTTPExchange, request: URLRequest, extra: [String: JournalValue], omittingSignedQueries: Bool = false
    ) -> [String: JournalValue] {
        var headers: [String: JournalValue] = [:]
        for (name, value) in exchange.headers {
            // Session material is never archived (plan v3 §5 invariant 7).
            if name.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                headers[name] = .string("[omitted]")
            } else if omittingSignedQueries, ["location", "content-location"].contains(name.lowercased()),
                let query = value.firstIndex(of: "?")
            {
                headers[name] = .string(value[..<query] + "?[omitted]")
            } else {
                headers[name] = .string(value)
            }
        }
        var metadata = extra
        metadata["method"] = .string(request.httpMethod ?? "GET")
        metadata["status"] = exchange.status.map { .integer(Int64($0)) } ?? .null
        metadata["transfer_end"] = .string(exchange.transferEnd.rawValue)
        metadata["observed_bytes"] = .integer(Int64(exchange.observedByteCount))
        metadata["response_headers"] = .object(headers)
        metadata["request_header_names"] = .array((request.allHTTPHeaderFields ?? [:]).keys.sorted().map(JournalValue.string))
        metadata["end_ticks"] = .string(String(exchange.endTicks))
        return metadata
    }

    @discardableResult
    private func append(
        kind: String, _ exchange: HTTPExchange, payload: Data, representation: String, transformations: [String],
        metadata: [String: JournalValue]
    ) throws -> UInt64 {
        let now = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        let receipt = try journal.append(
            JournalDraft(
                kind: kind, payload: payload, accountID: account.rawValue, jobID: jobID,
                timestamp: JournalTimestamp(wallMilliseconds: now, monotonicTicks: exchange.startTicks),
                payloadRepresentation: representation, transformations: transformations, metadata: metadata))
        try journal.synchronize()
        return receipt.sequence
    }
}

final class RecordFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    func set() { lock.withLock { failed = true } }
    var isSet: Bool { lock.withLock { failed } }
}

/// An exact instant parsed from a server timestamp, compared as integers (no floating point).
/// Accepts the observed PostgreSQL text form (N-012: `2026-09-24 10:00:00.123456+00`, 4–6 fraction
/// digits, hour-only offset) and ISO 8601 (`T`, `Z` or `±hh:mm`). Anything else is nil.
struct SourceInstant: Comparable, Sendable {
    let seconds: Int64
    let nanoseconds: Int64

    init?(_ text: String) {
        let pattern = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}(?::?\d{2})?)$/
        guard let match = text.wholeMatch(of: pattern),
            let year = Int(match.1), let month = Int(match.2), let day = Int(match.3),
            let hour = Int(match.4), let minute = Int(match.5), let second = Int(match.6),
            (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        (components.year, components.month, components.day) = (year, month, day)
        (components.hour, components.minute, components.second) = (hour, minute, second)
        guard let date = components.date else { return nil }
        var offsetSeconds = 0
        let zone = String(match.8)
        if zone != "Z" {
            let sign = zone.hasPrefix("-") ? -1 : 1
            let digits = zone.dropFirst().filter(\.isNumber)
            guard let hours = Int(digits.prefix(2)), hours <= 23 else { return nil }
            let minutes = digits.count > 2 ? Int(digits.dropFirst(2)) ?? 0 : 0
            offsetSeconds = sign * (hours * 3600 + minutes * 60)
        }
        seconds = Int64(date.timeIntervalSince1970) - Int64(offsetSeconds)
        let fraction = match.7.map(String.init) ?? ""
        nanoseconds = Int64(fraction.padding(toLength: 9, withPad: "0", startingAt: 0)) ?? 0
    }

    static func < (lhs: SourceInstant, rhs: SourceInstant) -> Bool {
        (lhs.seconds, lhs.nanoseconds) < (rhs.seconds, rhs.nanoseconds)
    }

    /// The instant as integer microseconds since 1970, for the index's sortable `updated_order`.
    var microseconds: Int64 { seconds * 1_000_000 + nanoseconds / 1_000 }
}
