import ApplicationActions
import CaptureJournal
import Foundation
import FoundationTransport
import SuiteDomain

/// Read-only history sync (plan v3 §9). Every response is appended to the account journal before
/// it is interpreted; resume and incremental decisions are derived from the journal alone.
public struct ArenaHistorySync: HistorySyncing {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void
    private let sessions: ArenaAccountSessions
    private let sleep: Sleeper

    public init(sessions: ArenaAccountSessions, sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }) {
        self.sessions = sessions
        self.sleep = sleep
    }

    public func sync(
        account: AccountContext, principal: PrincipalIdentity, journal: JournalWriter, journalRoot: URL,
        options: SyncOptions, progress: @escaping @Sendable (SyncProgress) -> Void
    ) async -> SyncManifest {
        let job = SyncJob(
            account: account.accountID, principal: principal, sessions: sessions, journal: journal,
            journalRoot: journalRoot, options: options, sleep: sleep, progress: progress)
        return await job.run()
    }
}

/// Journal-derived state: what has already been archived for this account.
struct ArchivedState {
    /// Conversation ID → `updatedAt` from the list entry when its valid detail snapshot was fetched.
    var snapshots: [String: String?] = [:]
    /// Entry ID → last `updatedAt` seen in any recorded list page.
    var listed: [String: String?] = [:]
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
    }

    static func scan(_ root: URL) throws -> ArchivedState {
        var state = ArchivedState()
        var open: [UUID: Interrupted] = [:]
        var order: [UUID] = []
        try JournalReader(root: root).forEach { record in
            let envelope = record.envelope
            let role = envelope.metadata["role"].flatMap { if case .string(let value) = $0 { value } else { nil } }
            switch envelope.kind {
            case JournalKind.jobStarted where envelope.metadata["job_kind"] == .string("history_sync"):
                if let job = envelope.jobID {
                    open[job] = Interrupted(jobID: job)
                    order.append(job)
                }
            case JournalKind.jobFinished:
                if let job = envelope.jobID {
                    open[job] = nil
                    order.removeAll { $0 == job }
                }
            case "exchange" where role == "list":
                guard record.envelope.metadata["status"] == .integer(200),
                    record.envelope.metadata["transfer_end"] == .string("complete"),
                    let page = ListPage.decode(record.payload)
                else { return }
                for entry in page.entries { state.listed[entry.id] = entry.updatedAt }
                if let job = envelope.jobID, var interrupted = open[job] {
                    interrupted.entries.append(contentsOf: page.entries)
                    interrupted.pages += 1
                    interrupted.lastCursor = page.cursor
                    interrupted.lastHasMore = page.hasMore
                    open[job] = interrupted
                }
            case "exchange" where role == "detail":
                guard case .string(let id) = envelope.metadata["entry_id"],
                    envelope.metadata["status"] == .integer(200),
                    envelope.metadata["transfer_end"] == .string("complete"),
                    DetailCheck.isValid(record.payload, id: id)
                else { return }
                if case .string(let updated) = envelope.metadata["source_updated_at"] {
                    state.snapshots[id] = updated
                } else {
                    state.snapshots[id] = String?.none
                }
            default:
                break
            }
        }
        if let latest = order.last { state.interrupted = open[latest] }
        state.abandoned = order.dropLast().filter { open[$0] != nil }
        return state
    }

    func isUnchanged(_ entry: ListEntry) -> Bool {
        guard let updated = entry.updatedAt, listed[entry.id] == updated else { return false }
        return entry.type != "evaluation" || snapshots[entry.id] == updated
    }

    func needsDetail(_ entry: ListEntry) -> Bool {
        guard entry.type == "evaluation" else { return false }
        // Refetch only when the server's `updatedAt` differs from the one archived with the snapshot.
        // (Without `updatedAt` a change is undetectable; a full refresh is a separate, explicit job.)
        guard let archived = snapshots[entry.id] else { return true }
        return archived != entry.updatedAt
    }
}

final class SyncJob {
    private let account: AccountID
    private let principal: PrincipalIdentity
    private let sessions: ArenaAccountSessions
    private let journal: JournalWriter
    private let journalRoot: URL
    private let options: SyncOptions
    private let sleep: ArenaHistorySync.Sleeper
    private let report: @Sendable (SyncProgress) -> Void
    private let jobID = UUID()
    private var manifest: SyncManifest
    private var session: ArenaAccountSession?
    private var requestsSent = 0

    init(
        account: AccountID, principal: PrincipalIdentity, sessions: ArenaAccountSessions, journal: JournalWriter,
        journalRoot: URL, options: SyncOptions, sleep: @escaping ArenaHistorySync.Sleeper,
        progress: @escaping @Sendable (SyncProgress) -> Void
    ) {
        self.account = account
        self.principal = principal
        self.sessions = sessions
        self.journal = journal
        self.journalRoot = journalRoot
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
        // Identity first: nothing else is sent before the principal is verified again for this job.
        switch await sessions.verify(account: account, expected: principal) {
        case .verified: break
        case .rejected, .noSavedSession: return finishWithoutJournal(.needsSignIn, "session rejected or absent")
        case .mismatch: return finishWithoutJournal(.needsSignIn, "identity mismatch; session discarded")
        case .unreachable: return finishWithoutJournal(.partial, "identity check unreachable")
        }
        guard let session = await sessions.session(for: account) else {
            return finishWithoutJournal(.needsSignIn, "no verified session")
        }
        self.session = session

        let state: ArchivedState
        do { state = try ArchivedState.scan(journalRoot) } catch {
            return finishWithoutJournal(.storageFailed, "journal could not be read")
        }
        do {
            for job in state.abandoned { try closeInterrupted(job, resumedBy: nil) }
            if let interrupted = state.interrupted {
                manifest.resumedJobID = interrupted.jobID
                try closeInterrupted(interrupted.jobID, resumedBy: jobID)
            }
            var started: [String: JournalValue] = [
                "job_kind": .string("history_sync"), "full_pass": .bool(options.fullPass),
                "page_limit": .integer(Int64(HistoryRoutes.pageLimit)),
            ]
            if let resumed = manifest.resumedJobID { started["resumes"] = .string(resumed.uuidString) }
            try append(JournalDraft(kind: JournalKind.jobStarted, accountID: account.rawValue, jobID: jobID, metadata: started))
            try append(
                JournalDraft(
                    kind: "session.verified", accountID: account.rawValue, jobID: jobID,
                    metadata: ["namespace": .string(principal.namespace)]))
            try journal.synchronize()
        } catch {
            return finishWithoutJournal(.storageFailed, "journal could not be written")
        }

        do {
            let entries = try await list(state: state)
            try await fetchDetails(entries, state: state)
            manifest.outcome = .completed
        } catch Stop.outcome(let outcome, let reason) {
            manifest.outcome = outcome
            manifest.reason = reason
        } catch {
            manifest.outcome = .storageFailed
            manifest.reason = "journal could not be written"
        }
        return finish()
    }

    // MARK: Listing

    private func list(state: ArchivedState) async throws -> [ListEntry] {
        var entries: [ListEntry] = []
        var seen = Set<String>()
        func add(_ page: [ListEntry]) {
            for entry in page where seen.insert(entry.id).inserted { entries.append(entry) }
        }
        var cursor: String?
        if let interrupted = state.interrupted {
            add(interrupted.entries)
            manifest.pagesListed = interrupted.pages
            if interrupted.pages > 0 {
                guard interrupted.lastHasMore == true else {
                    manifest.listingEnd = "hasMore=false (resumed)"
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
            if page.partial == true || page.failedSources > 0 {
                manifest.warnings.append("page \(manifest.pagesListed): partial=\(page.partial ?? false), failedSources=\(page.failedSources)")
            }
            guard bodies.insert(exchange.body).inserted else { throw Stop.outcome(.partial, "repeated page") }
            let unchangedPage =
                !options.fullPass && !page.entries.isEmpty && page.entries.allSatisfy(state.isUnchanged)
                && Self.isNewestFirst(page.entries)
            add(page.entries)
            report(SyncProgress(stage: .listing, pages: manifest.pagesListed, entries: entries.count, detailsDone: 0, detailsNeeded: 0))
            if unchangedPage {
                manifest.listingEnd = "caught up: page \(manifest.pagesListed) unchanged and newest-first"
                break
            }
            guard page.hasMore == true else {
                manifest.listingEnd = page.hasMore == false ? "hasMore=false" : "hasMore absent"
                if page.hasMore == nil { manifest.warnings.append("pagination.hasMore absent") }
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
    static func isNewestFirst(_ entries: [ListEntry]) -> Bool {
        let stamps = entries.compactMap(\.updatedAt)
        return stamps.count == entries.count && zip(stamps, stamps.dropFirst()).allSatisfy { $0 >= $1 }
    }

    // MARK: Details

    private func fetchDetails(_ entries: [ListEntry], state: ArchivedState) async throws {
        let needed = entries.filter(state.needsDetail)
        manifest.detailsUnchanged = entries.filter { $0.type == "evaluation" }.count - needed.count
        for (index, entry) in needed.enumerated() {
            report(SyncProgress(stage: .details, pages: manifest.pagesListed, entries: entries.count, detailsDone: index, detailsNeeded: needed.count))
            guard let request = HistoryRoutes.detail(id: entry.id) else {
                manifest.detailsFailed += 1
                manifest.warnings.append("detail skipped: ID not path-safe")
                continue
            }
            var extra: [String: JournalValue] = ["entry_id": .string(entry.id), "entry_type": .string(entry.type)]
            if let updated = entry.updatedAt { extra["source_updated_at"] = .string(updated) }
            let exchange = try await fetch(request, role: "detail", route: HistoryRoutes.detailTemplate, extra: extra, allowNotFound: true)
            if exchange.status == 200 && DetailCheck.isValid(exchange.body, id: entry.id) {
                manifest.detailsFetched += 1
            } else if exchange.status == 200 && Self.looksLikeChallenge(exchange) {
                throw Stop.outcome(.blocked, "detail response not recognized")
            } else {
                manifest.detailsFailed += 1
                manifest.warnings.append("detail HTTP \(exchange.status.map(String.init) ?? "none") or unrecognized body")
            }
        }
        report(SyncProgress(stage: .finishing, pages: manifest.pagesListed, entries: entries.count, detailsDone: needed.count, detailsNeeded: needed.count))
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

    static func looksLikeChallenge(_ exchange: HTTPExchange) -> Bool {
        let type = exchange.contentType?.lowercased() ?? ""
        return type.contains("html") || exchange.body.prefix(64).contains(UInt8(ascii: "<"))
    }

    // MARK: Journal

    private func record(
        _ exchange: HTTPExchange, request: URLRequest, role: String, route: String, extra: [String: JournalValue]
    ) throws {
        var headers: [String: JournalValue] = [:]
        for (name, value) in exchange.headers {
            // Session material is never archived (plan v3 §5 invariant 7).
            headers[name] = name.caseInsensitiveCompare("Set-Cookie") == .orderedSame ? .string("[omitted]") : .string(value)
        }
        var metadata = extra
        metadata["role"] = .string(role)
        metadata["method"] = .string(request.httpMethod ?? "GET")
        metadata["route"] = .string(route)
        metadata["path"] = .string(request.url?.path ?? "")
        metadata["query"] = request.url?.query.map(JournalValue.string) ?? .null
        metadata["status"] = exchange.status.map { .integer(Int64($0)) } ?? .null
        metadata["transfer_end"] = .string(exchange.transferEnd.rawValue)
        metadata["observed_bytes"] = .integer(Int64(exchange.observedByteCount))
        metadata["response_headers"] = .object(headers)
        metadata["request_header_names"] = .array((request.allHTTPHeaderFields ?? [:]).keys.sorted().map(JournalValue.string))
        metadata["end_ticks"] = .string(String(exchange.endTicks))
        let now = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        try append(
            JournalDraft(
                kind: "exchange", payload: exchange.body, accountID: account.rawValue, jobID: jobID,
                timestamp: JournalTimestamp(wallMilliseconds: now, monotonicTicks: exchange.startTicks),
                payloadRepresentation: "foundation_decoded_entity", transformations: ["credential_omitted"],
                metadata: metadata))
        try journal.synchronize()
    }

    private func append(_ draft: JournalDraft) throws {
        _ = try journal.append(draft)
    }

    private func closeInterrupted(_ job: UUID, resumedBy: UUID?) throws {
        var metadata: [String: JournalValue] = ["job_kind": .string("history_sync"), "outcome": .string("interrupted")]
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
                    metadata: ["job_kind": .string("history_sync"), "outcome": .string(manifest.outcome.rawValue)]))
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
