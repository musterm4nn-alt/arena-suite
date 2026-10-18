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

    private(set) var conversations: [ConversationSummary] = []
    private(set) var hits: [SearchHit] = []
    private(set) var detail: ConversationDetail?
    private(set) var layout: TranscriptLayout?
    private(set) var evidence: RawEvidence?
    private(set) var evidenceUnavailable = false
    private(set) var projecting = false
    private(set) var problems: (warnings: Int, unknownPaths: Int) = (0, 0)
    private(set) var selection: ConversationKey?
    /// nil = latest snapshot.
    private(set) var snapshotSequence: UInt64?
    private(set) var inspected: InspectTarget?
    private(set) var highlightedMessage: String?
    /// Changes whenever the transcript should scroll to `highlightedMessage`.
    private(set) var scrollRequest = 0
    private(set) var exporting = false
    private(set) var lastExport: ExportResult?
    var message: String?

    var accountFilter: AccountID? { didSet { if oldValue != accountFilter { reload() } } }
    var searchText = "" { didSet { if oldValue != searchText { scheduleSearch(debounce: true) } } }
    var includeReasoningAndTools = false { didSet { if oldValue != includeReasoningAndTools { scheduleSearch(debounce: false) } } }

    private let archive: ArchiveService?
    private var listGeneration = 0
    private var detailGeneration = 0
    private var evidenceGeneration = 0
    private var searchTask: Task<Void, Never>?

    /// `archive` is nil when the index could not be opened; the app then shows `message`.
    init(archive: ArchiveService?, unavailableReason: String? = nil) {
        self.archive = archive
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
        refreshDetail()
        listGeneration += 1
        let generation = listGeneration
        let filter = accountFilter
        Task {
            let result = await Task.detached {
                (try? archive.conversations(account: filter),
                    ((try? archive.warnings(account: filter).count) ?? 0, (try? archive.unknownFields(account: filter).count) ?? 0))
            }.value
            guard generation == listGeneration else { return }
            if let list = result.0 {
                conversations = list
            } else {
                message = "The archive index could not be read."
            }
            problems = result.1
        }
        scheduleSearch(debounce: false)
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
                (try? archive.search(text, account: filter, includeReasoningAndTools: wide, limit: 200)) ?? []
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
            return
        }
        let snapshot = snapshotSequence
        Task {
            let loaded = await Task.detached {
                try? archive.conversation(account: key.account, remoteID: key.remoteID, snapshot: snapshot)
            }.value
            guard generation == detailGeneration else { return }
            detail = loaded
            layout = loaded.map(TranscriptLayout.init)
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
            let loaded = await Task.detached {
                try? archive.conversation(account: key.account, remoteID: key.remoteID, snapshot: snapshot)
            }.value
            guard generation == detailGeneration else { return }
            if loaded?.snapshotSequence != detail?.snapshotSequence {
                inspected = nil
                evidence = nil
                evidenceUnavailable = false
                highlightedMessage = nil
            }
            detail = loaded
            layout = loaded.map(TranscriptLayout.init)
            // An evidence read still running was for the previous detail generation and is dropped.
            if let inspected, evidence == nil, !evidenceUnavailable { inspect(inspected) }
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
    /// `directory` nil = Downloads.
    func export(_ format: ExportFormat, exactRawBodies: Bool, to directory: URL?) async {
        guard let archive, let key = selection, let detail, detail.summary.account == key.account,
            detail.summary.remoteID == key.remoteID, let displayed = detail.snapshotSequence
        else { return }
        let destination = directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        exporting = true
        defer { exporting = false }
        do {
            lastExport = try await ExportService(archive: archive).export(
                account: key.account, remoteID: key.remoteID, snapshot: displayed,
                options: ExportOptions(format: format, includeExactRawBodies: exactRawBodies), to: destination)
            message = nil
        } catch {
            lastExport = nil
            message = "The export could not be written (\(error)). Nothing was left behind."
        }
    }

    /// Hides the notice for the last export (the file stays where it was written).
    func dismissExport() { lastExport = nil }

    /// Display names from `revealedModels`, keyed by model ID (claims keep their source). Claims
    /// come in record order, so the latest name observed wins.
    var revealedNames: [String: String] {
        Dictionary(
            (detail?.claims ?? []).filter { $0.source == "detail_revealed" }.compactMap { claim in
                claim.displayName.map { (claim.modelID, $0) }
            }, uniquingKeysWith: { _, latest in latest })
    }
}
