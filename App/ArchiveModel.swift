import ApplicationActions
import ArchiveIndex
import Foundation
import Observation
import SuiteDomain

/// Presentation state for browsing the archive. Reads only the rebuildable index (off the main
/// actor); raw evidence is read from the journal on demand. Every async result is applied only if it
/// still belongs to the current selection or query, so stale results never replace fresh ones.
@MainActor @Observable
final class ArchiveModel {
    struct ConversationKey: Hashable, Sendable {
        let account: AccountID
        let remoteID: String
    }

    /// What the evidence inspector is showing: a label and the JSON paths inside the snapshot body.
    struct InspectTarget: Equatable {
        let title: String
        let pointers: [String]
    }

    /// Every conversation in the account scope; `visibleConversations` applies the filters.
    private(set) var conversations: [ConversationSummary] = []
    private(set) var visibleConversations: [ConversationSummary] = []
    private(set) var hits: [SearchHit] = []
    /// What the filter menu offers for the current scope, with counts.
    private(set) var filterOptions = HistoryFilterOptions.empty
    private(set) var detail: ConversationDetail?
    private(set) var layout: TranscriptLayout?
    /// Your local notes in the open conversation (Docs/vote-notes-2026-10-20.md); nil when they could
    /// not be read, so the note menus are off rather than showing "no note". `notesUnavailable` says why.
    private(set) var voteNotes: [VoteNote]? = []
    private(set) var notesUnavailable: String?
    /// The last note failure shown, cleared by the next note that is saved.
    private var noteFailure: String?
    /// Votes (remote IDs) whose note is being written.
    private(set) var savingNotes: Set<String> = []
    private(set) var evidence: RawEvidence?
    private(set) var evidenceUnavailable = false
    private(set) var projecting = false
    private(set) var problems: (warnings: Int, unknownPaths: Int) = (0, 0)
    /// A change of conversation or snapshot clears the export notice: it described the one shown.
    private(set) var selection: ConversationKey? {
        didSet { if selection != oldValue { exportOutcome = nil } }
    }
    /// nil = latest snapshot.
    private(set) var snapshotSequence: UInt64? {
        didSet { if snapshotSequence != oldValue { exportOutcome = nil } }
    }
    private(set) var inspected: InspectTarget?
    private(set) var highlightedMessage: String?
    /// Changes whenever the transcript should scroll to `highlightedMessage`.
    private(set) var scrollRequest = 0
    private(set) var exporting = false
    /// The outcome of the latest export or copy, for the notice. Each attempt replaces it, so a notice
    /// never describes an earlier attempt.
    enum ExportOutcome: Equatable {
        case saved(ExportResult)
        /// What was copied.
        case copied(String)
        /// Why nothing was saved or copied.
        case refused(String)
    }
    private(set) var exportOutcome: ExportOutcome?
    /// What a clipboard writer reports back to `copy`.
    enum ClipboardWrite {
        case written
        /// The clipboard refused the text; whether it holds its previous text again.
        case refused(previousTextRestored: Bool)
    }
    /// Changes on every reload (after a sync, rebuild, restore or a new account choice), so pages
    /// built from the index (Insights) know to read it again.
    private(set) var revision = 0
    var message: String?

    var accountFilter: AccountID? { didSet { if oldValue != accountFilter { reload() } } }
    /// Mode, vote, model and date filters for the history and search (Docs/history-filters-2026-10-19.md).
    /// Not saved: every launch starts unfiltered.
    var filter = HistoryFilter() {
        didSet {
            guard oldValue != filter else { return }
            applyFilter()
            // A conversation the filters now hide is not left open beside a list that lacks it.
            if let selection, !visibleKeys.contains(selection),
                conversations.contains(where: { $0.account == selection.account && $0.remoteID == selection.remoteID })
            {
                select(nil)
            }
        }
    }
    /// The vote and model facets could not be read: those filters are not applied, and the filter
    /// bar says so.
    var facetsUnavailable: Bool { facets == nil }
    var searchText = "" { didSet { if oldValue != searchText { scheduleSearch(debounce: true) } } }
    var includeReasoningAndTools = false { didSet { if oldValue != includeReasoningAndTools { scheduleSearch(debounce: false) } } }

    private let archive: ArchiveService?
    private let notes: VoteNoteService?
    /// nil = could not be read (see `facetsUnavailable`).
    private var facets: HistoryFacets? = .empty
    private var visibleKeys: Set<ConversationKey> = []
    private var listGeneration = 0
    private var detailGeneration = 0
    private var evidenceGeneration = 0
    private var searchTask: Task<Void, Never>?

    /// `archive` is nil when the index could not be opened; the app then shows `message`.
    /// Message statuses that mean the response was still being generated (from the adapter, N-020).
    let unfinishedStatuses: Set<String>

    init(
        archive: ArchiveService?, notes: VoteNoteService? = nil, unfinishedStatuses: Set<String> = [],
        unavailableReason: String? = nil
    ) {
        self.archive = archive
        self.notes = notes
        self.unfinishedStatuses = unfinishedStatuses
        message = unavailableReason
    }

    // MARK: Index maintenance

    /// Brings each account's index up to date from its journal. One failing account does not stop the others.
    func projectAll(_ accounts: [AccountID]) async {
        guard let archive else { return }
        projecting = true
        var failed = 0
        for account in accounts {
            do { _ = try await archive.project(account) } catch { failed += 1 }
        }
        projecting = false
        if failed > 0 { message = "\(failed) account index(es) could not be updated. The journals are unaffected." }
        reload()
    }

    // MARK: List and search

    /// Re-reads the list, the search and the open conversation (after a sync, rebuild or restore).
    func reload() {
        guard let archive else { return }
        revision += 1
        refreshDetail()
        listGeneration += 1
        let generation = listGeneration
        let filter = accountFilter
        Task {
            let result = await Task.detached {
                (try? archive.conversations(account: filter), try? archive.historyFacets(account: filter),
                    ((try? archive.warnings(account: filter).count) ?? 0, (try? archive.unknownFields(account: filter).count) ?? 0))
            }.value
            guard generation == listGeneration else { return }
            if let list = result.0 {
                conversations = list
            } else {
                message = "The archive index could not be read."
            }
            facets = result.1
            applyFilter()
            problems = result.2
        }
        scheduleSearch(debounce: false)
    }

    /// The most hits one search reads (the index's own cap); the filters apply to these, and the
    /// list shows the first `shownHits`.
    nonisolated static let searchLimit = 1_000
    nonisolated static let shownHits = 200

    /// Search hits within the conversations the filters show.
    var visibleHits: [SearchHit] {
        guard filter.isActive else { return hits }
        return hits.filter { visibleKeys.contains(ConversationKey(account: $0.account, remoteID: $0.conversationID)) }
    }

    /// Applies the filters to the loaded list and recounts the menu under them (the clock is read
    /// now, for the "past …" periods).
    private func applyFilter() {
        let now = Date()
        visibleConversations = filter.apply(conversations, facets: facets, now: now, calendar: .current)
        visibleKeys = Set(visibleConversations.map { ConversationKey(account: $0.account, remoteID: $0.remoteID) })
        filterOptions = HistoryFilterOptions.build(conversations, facets: facets, filter: filter, now: now, calendar: .current)
    }

    private func scheduleSearch(debounce: Bool) {
        searchTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard let archive, !text.isEmpty else {
            hits = []
            return
        }
        let filter = accountFilter
        let wide = includeReasoningAndTools
        searchTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            let found = await Task.detached {
                (try? archive.search(text, account: filter, includeReasoningAndTools: wide, limit: Self.searchLimit)) ?? []
            }.value
            // Apply only if the inputs are still the ones this query was for.
            guard !Task.isCancelled, text == searchText.trimmingCharacters(in: .whitespaces), filter == accountFilter,
                wide == includeReasoningAndTools
            else { return }
            hits = found
        }
    }

    // MARK: Selection

    func open(_ hit: SearchHit) {
        let key = ConversationKey(account: hit.account, remoteID: hit.conversationID)
        highlightedMessage = hit.messageID
        if key == selection {
            scrollRequest += 1  // same conversation: just scroll
        } else {
            select(key, keepHighlight: true)
        }
    }

    func select(_ key: ConversationKey?, keepHighlight: Bool = false) {
        guard key != selection else { return }
        if !keepHighlight { highlightedMessage = nil }
        selection = key
        snapshotSequence = nil
        loadDetail()
    }

    func selectSnapshot(_ sequence: UInt64?) {
        guard sequence != snapshotSequence else { return }
        highlightedMessage = nil
        snapshotSequence = sequence
        loadDetail()
    }

    private func loadDetail() {
        detailGeneration += 1
        let generation = detailGeneration
        inspected = nil
        evidence = nil
        evidenceUnavailable = false
        guard let archive, let key = selection else {
            detail = nil
            layout = nil
            voteNotes = []
            notesUnavailable = nil
            return
        }
        let snapshot = snapshotSequence
        Task {
            let (loaded, notes) = await Task.detached {
                (
                    try? archive.conversation(account: key.account, remoteID: key.remoteID, snapshot: snapshot),
                    Self.readNotes(archive, key)
                )
            }.value
            guard generation == detailGeneration else { return }
            detail = loaded
            layout = loaded.map(TranscriptLayout.init)
            (voteNotes, notesUnavailable) = notes
            if highlightedMessage != nil { scrollRequest += 1 }
        }
    }

    /// Reloads the open conversation in place, so Latest shows the newest snapshot; an explicitly
    /// chosen snapshot stays the same. The evidence panel and highlight are kept unless the displayed
    /// snapshot changed.
    private func refreshDetail() {
        guard let archive, let key = selection else { return }
        detailGeneration += 1
        let generation = detailGeneration
        let snapshot = snapshotSequence
        Task {
            let (loaded, notes) = await Task.detached {
                (
                    try? archive.conversation(account: key.account, remoteID: key.remoteID, snapshot: snapshot),
                    Self.readNotes(archive, key)
                )
            }.value
            guard generation == detailGeneration else { return }
            (voteNotes, notesUnavailable) = notes
            if loaded?.snapshotSequence != detail?.snapshotSequence {
                inspected = nil
                evidence = nil
                evidenceUnavailable = false
                highlightedMessage = nil
                exportOutcome = nil
            }
            detail = loaded
            layout = loaded.map(TranscriptLayout.init)
            // An evidence read still running was for the previous detail generation and is dropped.
            if let inspected, evidence == nil, !evidenceUnavailable { inspect(inspected) }
        }
    }

    // MARK: Vote notes (Docs/vote-notes-2026-10-20.md)

    /// The notes, or nil and why they could not be read.
    private nonisolated static func readNotes(_ archive: ArchiveService, _ key: ConversationKey) -> ([VoteNote]?, String?) {
        do {
            return (try archive.voteNotes(account: key.account, conversationID: key.remoteID), nil)
        } catch ArchiveIndex.QueryError.unreadableVoteNote {
            return (nil, "A note in this conversation has a value this version of the app cannot read. It is still in the archive.")
        } catch {
            return (nil, "Notes are unavailable: they could not be read from the archive index.")
        }
    }

    /// A stored attachment file's bytes, read off the main actor and checked against their SHA-256.
    func attachmentData(account: AccountID, sha256: String) async -> Result<Data, AttachmentFileError> {
        guard let archive else { return .failure(.unreadable) }
        return await Task.detached {
            do { return .success(try archive.attachmentData(account: account, sha256: sha256)) } catch {
                return .failure(error as? AttachmentFileError ?? .unreadable)
            }
        }.value
    }

    /// Whether notes can be written at all (the index opened).
    var canWriteNotes: Bool { notes != nil }

    /// Your note beside `vote` in the open conversation, if any.
    func note(beside vote: ArchivedFeedback) -> VoteNote? {
        voteNotes?.first { $0.messageA == vote.messageA && $0.messageB == vote.messageB }
    }

    /// Records your note (nil removes it) beside `vote` in `detail`, the transcript the vote was shown
    /// in. Its account, conversation and snapshot come from that transcript, never from the selection,
    /// which may already name another conversation still loading. The note stays in this archive;
    /// nothing is sent.
    func setNote(_ choice: VoteOutcome?, beside vote: ArchivedFeedback, in detail: ConversationDetail) {
        guard let notes, let snapshot = detail.snapshotSequence, !savingNotes.contains(vote.remoteID) else { return }
        let (account, conversation) = (detail.summary.account, detail.summary.remoteID)
        savingNotes.insert(vote.remoteID)
        Task {
            do {
                try await notes.set(choice, beside: vote, account: account, conversation: conversation, snapshot: snapshot)
                // Saved: an earlier note failure no longer applies (other messages are left alone).
                if let shown = noteFailure, message == shown { message = nil }
                noteFailure = nil
            } catch {
                let text = Self.describeNoteFailure(error)
                message = text
                noteFailure = text
            }
            savingNotes.remove(vote.remoteID)
            // Shows what the index now holds, whether or not the write went through.
            reload()
        }
    }

    private static func describeNoteFailure(_ error: Error) -> String {
        switch error {
        case AccountError.busy:
            "The note was not saved: a check, backup, restore or rebuild is running. Try again when it finishes."
        case AccountError.unknownAccount:
            "The note was not saved: this conversation's account is no longer in the app."
        case VoteNoteError.savedButNotIndexed:
            "The note is saved in the archive, but the index could not be updated; it shows after the next update."
        case VoteNoteError.voteWithoutTwoMessages:
            "This vote does not name two messages, so it cannot take a note."
        case VoteNoteError.voteNotInConversation:
            "The note was not saved: that vote is no longer in the archive's copy of the conversation."
        case LocalWriteError.appendedButNotFlushed:
            "The note was written but could not be flushed to disk, so it may not survive a restart. Quit and reopen the app before writing more; it is not shown until then."
        default:
            "The note could not be saved to the archive."
        }
    }

    // MARK: Evidence

    func inspect(_ message: DetailMessage) {
        inspect(InspectTarget(
            title: "Message \(message.remoteID)",
            pointers: message.blocks.map { "\($0.kind.rawValue): \($0.pointer)" }))
    }

    func inspect(_ target: InspectTarget) {
        evidenceGeneration += 1
        let generation = evidenceGeneration
        inspected = target
        evidence = nil
        evidenceUnavailable = false
        guard let archive, let key = selection, let sequence = detail?.snapshotSequence else {
            evidenceUnavailable = true
            return
        }
        let detailAtRequest = detailGeneration
        Task {
            do {
                let record = try await archive.rawEvidence(account: key.account, snapshotSequence: sequence)
                // Only for the conversation, snapshot and target this request was made for.
                guard generation == evidenceGeneration, detailAtRequest == detailGeneration else { return }
                evidence = record
                evidenceUnavailable = record == nil
            } catch {
                guard generation == evidenceGeneration else { return }
                evidenceUnavailable = true
                message = "The raw record could not be read or failed its digest check."
            }
        }
    }

    // MARK: Export

    /// Exports the displayed snapshot (never whatever is latest by the time the export runs).
    /// `directory` nil = Downloads. A written file's notice names the file, so it is shown even if
    /// another conversation is open by then; a refusal is shown only if the same snapshot still is.
    func export(_ format: ExportFormat, scope: ExportScope = .wholeConversation, exactRawBodies: Bool, to directory: URL?) async {
        guard let begun = beginExport() else { return }
        let (archive, key, displayed) = begun
        let destination = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        exporting = true
        defer { exporting = false }
        do {
            let result = try await ExportService(archive: archive).export(
                account: key.account, remoteID: key.remoteID, snapshot: displayed,
                options: ExportOptions(format: format, scope: scope, includeExactRawBodies: exactRawBodies), to: destination)
            exportOutcome = .saved(result)
        } catch {
            if stillShown(key, displayed) { exportOutcome = .refused(Self.describe(error, writing: true)) }
        }
    }

    /// Renders the displayed snapshot and hands the text to `write` (the clipboard); nothing is
    /// written to disk. Exact raw bodies are never offered here. The notice says what was copied
    /// only when `write` reports success. If the conversation or snapshot shown changed meanwhile,
    /// nothing is copied and no notice is shown: the notice describes the snapshot on screen.
    func copy(_ format: ExportFormat, scope: ExportScope, with write: (String) -> ClipboardWrite) async {
        guard let begun = beginExport() else { return }
        let (archive, key, displayed) = begun
        exporting = true
        defer { exporting = false }
        do {
            let rendered = try await ExportService(archive: archive).render(
                account: key.account, remoteID: key.remoteID, snapshot: displayed, options: ExportOptions(format: format, scope: scope))
            guard stillShown(key, displayed) else { return }
            let text = String(decoding: rendered.data, as: UTF8.self)
            if case .refused(let restored) = write(text) {
                exportOutcome = .refused(
                    "The clipboard did not accept the export, so nothing was copied. "
                        + (restored ? "It holds its previous text again." : "Its previous contents could not be kept."))
                return
            }
            let what = scope == .lastAnswer ? "the last answer" : "the conversation"
            exportOutcome = .copied("Copied \(what) as \(format.label) · \(text.utf8.count.formatted()) bytes")
        } catch {
            if stillShown(key, displayed) { exportOutcome = .refused(Self.describe(error, writing: false)) }
        }
    }

    // MARK: Bulk export (Docs/bulk-export-2026-10-21.md)

    enum BulkOutcome: Equatable {
        case saved(BulkExportService.Result)
        case refused(String)
    }

    /// (handled, total) while a bulk export runs.
    private(set) var bulkProgress: (done: Int, total: Int)?
    private(set) var bulkOutcome: BulkOutcome?
    private var bulkTask: Task<Void, Never>?

    /// What the sidebar lists: the conversations of the search results shown (in result order,
    /// within the filters), or the filtered history.
    func bulkTargets(searching: Bool) -> [BulkExportService.Target] {
        if searching {
            var seen = Set<ConversationKey>()
            return visibleHits.compactMap { hit in
                let key = ConversationKey(account: hit.account, remoteID: hit.conversationID)
                return seen.insert(key).inserted ? BulkExportService.Target(account: hit.account, remoteID: hit.conversationID) : nil
            }
        }
        return visibleConversations.map { BulkExportService.Target(account: $0.account, remoteID: $0.remoteID) }
    }

    /// Conversations among `targets` with no transcript to export (listed on Arena only).
    func listedOnly(_ targets: [BulkExportService.Target]) -> Int {
        let held = Dictionary(conversations.map { (ConversationKey(account: $0.account, remoteID: $0.remoteID), $0) }, uniquingKeysWith: { a, _ in a })
        return targets.filter { held[ConversationKey(account: $0.account, remoteID: $0.remoteID)]?.latestSnapshotSequence == nil }.count
    }

    /// `directory` nil = Downloads.
    func bulkExport(_ targets: [BulkExportService.Target], format: ExportFormat, scope: ExportScope, to directory: URL?) {
        guard let archive, bulkTask == nil else { return }
        bulkOutcome = nil
        bulkProgress = (0, targets.count)
        let destination = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        bulkTask = Task { [weak self] in
            let outcome: BulkOutcome
            do {
                let result = try await BulkExportService(archive: archive).export(
                    targets, options: ExportOptions(format: format, scope: scope), into: destination
                ) { done, total in
                    Task { @MainActor in self?.bulkProgress = (done, total) }
                }
                outcome = .saved(result)
            } catch ExportError.cancelled {
                outcome = .refused("Export stopped. Nothing was written.")
            } catch {
                outcome = .refused(Self.describe(error, writing: true))
            }
            self?.bulkOutcome = outcome
            self?.bulkProgress = nil
            self?.bulkTask = nil
        }
    }

    func stopBulkExport() { bulkTask?.cancel() }

    func dismissBulkOutcome() { bulkOutcome = nil }

    static func describe(_ reason: BulkExportService.SkipReason) -> String {
        switch reason {
        case .notInArchive: "no longer in the archive"
        case .noSnapshot: "listed on Arena only, no transcript"
        case .noLastAnswer: "no last answer recorded"
        case .lastMessageNotInSnapshot: "last answer not in the snapshot"
        case .lastMessagesUnreadable: "last-message list unreadable (rebuild the index)"
        case .rawRecordUnavailable: "raw record unreadable"
        }
    }

    /// Whether the detail on screen is the selection's, so there is a snapshot to export.
    var canExport: Bool { displayedSnapshot != nil && !exporting }

    /// Clears the previous outcome and returns what to export, or records why there is nothing.
    private func beginExport() -> (ArchiveService, ConversationKey, UInt64)? {
        exportOutcome = nil
        // The export controls are disabled while one runs, so a second attempt is simply ignored.
        guard let archive, !exporting else { return nil }
        guard let shown = displayedSnapshot else {
            exportOutcome = .refused("The conversation is still loading. Export it once it is shown.")
            return nil
        }
        return (archive, shown.key, shown.sequence)
    }

    private func stillShown(_ key: ConversationKey, _ sequence: UInt64) -> Bool {
        displayedSnapshot.map { $0.key == key && $0.sequence == sequence } ?? false
    }

    /// The open conversation and the snapshot shown, when the detail on screen is the selection's,
    /// and is the chosen snapshot (not the previous one while a chosen record loads).
    private var displayedSnapshot: (key: ConversationKey, sequence: UInt64)? {
        guard let key = selection, let detail, detail.summary.account == key.account, detail.summary.remoteID == key.remoteID,
            let displayed = detail.snapshotSequence, snapshotSequence == nil ? !detail.isFrozen : snapshotSequence == displayed
        else { return nil }
        return (key, displayed)
    }

    private static func describe(_ error: Error, writing: Bool) -> String {
        switch error as? ExportError {
        case .noLastAnswer?: "Arena's last-message list for this snapshot is empty or was not in its response, so there is no last answer to export."
        case .lastMessageNotInSnapshot?: "Arena lists a last message that this snapshot does not hold, so no last answer is exported rather than a guessed one."
        case .lastMessagesUnreadable?: "The index could not read this snapshot's last-message list. Rebuilding the index (Maintenance) restores it from the journal."
        case .scopeNotAvailable?: "Raw JSON is one recorded response, so it always holds the whole conversation."
        case .rawRecordUnavailable?: "The raw record behind this snapshot could not be read or failed its digest check."
        default: writing ? "The export could not be written (\(error)). Nothing was left behind." : "The export could not be made (\(error))."
        }
    }

    /// Hides the notice for the last export or copy (a written file stays where it was written).
    func dismissExport() {
        exportOutcome = nil
    }

    /// Display names from `revealedModels`, keyed by model ID (claims keep their source). Claims
    /// come in record order, so the latest name observed wins.
    var revealedNames: [String: String] {
        Dictionary(
            (detail?.claims ?? []).filter { $0.source == "detail_revealed" }.compactMap { claim in
                claim.displayName.map { (claim.modelID, $0) }
            }, uniquingKeysWith: { _, latest in latest })
    }
}
