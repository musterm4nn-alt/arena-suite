import ApplicationActions
import ArchiveIndex
import Foundation
import Observation
import SuiteDomain

/// Presentation state for browsing the archive. Reads only the rebuildable index; raw evidence is
/// read from the journal on demand. Works offline.
@MainActor @Observable
final class ArchiveModel {
    struct ConversationKey: Hashable {
        let account: AccountID
        let remoteID: String
    }

    /// One user prompt and the responses to it, grouped by lane (never merged).
    struct Turn: Identifiable {
        let id: String
        let prompt: DetailMessage?
        let lanes: [(lane: String, messages: [DetailMessage])]
        let votes: [ArchivedFeedback]
    }

    private(set) var conversations: [ConversationSummary] = []
    private(set) var hits: [SearchHit] = []
    private(set) var detail: ConversationDetail?
    private(set) var turns: [Turn] = []
    private(set) var evidence: RawEvidence?
    private(set) var projecting = false
    private(set) var problems: (warnings: Int, unknownPaths: Int) = (0, 0)
    var message: String?

    var accountFilter: AccountID? { didSet { Task { await reload() } } }
    var searchText = "" { didSet { Task { await runSearch() } } }
    var includeReasoningAndTools = false { didSet { Task { await runSearch() } } }
    private(set) var selection: ConversationKey?
    /// nil = latest snapshot.
    private(set) var snapshotSequence: UInt64?
    var highlightedMessage: String?
    private(set) var inspectedMessage: DetailMessage?

    private let archive: ArchiveService

    init(archive: ArchiveService) { self.archive = archive }

    /// Brings every account's index up to date from its journal, then refreshes the list.
    func projectAll(_ accounts: [AccountID]) async {
        projecting = true
        defer { projecting = false }
        do {
            for account in accounts { _ = try await archive.project(account) }
        } catch {
            message = "The archive index could not be updated. The journal is unaffected."
        }
        await reload()
    }

    func reload() async {
        do {
            conversations = try archive.conversations(account: accountFilter)
            problems = (try archive.warnings(account: accountFilter).count, try archive.unknownFields(account: accountFilter).count)
        } catch {
            message = "The archive index could not be read."
        }
        await runSearch()
    }

    private func runSearch() async {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            hits = []
            return
        }
        hits = (try? archive.search(text, account: accountFilter, includeReasoningAndTools: includeReasoningAndTools, limit: 200)) ?? []
    }

    func open(_ hit: SearchHit) {
        highlightedMessage = hit.messageID
        select(ConversationKey(account: hit.account, remoteID: hit.conversationID))
    }

    func select(_ key: ConversationKey?) {
        guard key != selection else { return }
        selection = key
        snapshotSequence = nil
        loadDetail()
    }

    func selectSnapshot(_ sequence: UInt64?) {
        guard sequence != snapshotSequence else { return }
        snapshotSequence = sequence
        loadDetail()
    }

    func inspect(_ message: DetailMessage?) {
        inspectedMessage = message
        Task { await loadEvidence() }
    }

    private func loadDetail() {
        inspectedMessage = nil
        evidence = nil
        guard let selection else {
            detail = nil
            turns = []
            return
        }
        detail = try? archive.conversation(account: selection.account, remoteID: selection.remoteID, snapshot: snapshotSequence)
        turns = detail.map(Self.turns(for:)) ?? []
    }

    private func loadEvidence() async {
        guard let selection, inspectedMessage != nil, let sequence = snapshotSequence ?? detail?.summary.latestSnapshotSequence else {
            evidence = nil
            return
        }
        do {
            evidence = try await archive.rawEvidence(account: selection.account, snapshotSequence: sequence)
        } catch {
            evidence = nil
            message = "The raw record could not be read or failed its digest check."
        }
    }

    /// Display names from `revealedModels`, keyed by model ID (claims keep their source).
    var revealedNames: [String: String] {
        Dictionary(
            (detail?.claims ?? []).filter { $0.source == "detail_revealed" }.compactMap { claim in
                claim.displayName.map { (claim.modelID, $0) }
            }, uniquingKeysWith: { first, _ in first })
    }

    static func turns(for detail: ConversationDetail) -> [Turn] {
        var turns: [Turn] = []
        var prompt: DetailMessage?
        var lanes: [String: [DetailMessage]] = [:]
        var laneOrder: [String] = []
        func flush() {
            guard prompt != nil || !lanes.isEmpty else { return }
            let ids = Set(lanes.values.flatMap { $0.map(\.remoteID) })
            let votes = detail.feedback.filter { ids.contains($0.messageA ?? "") || ids.contains($0.messageB ?? "") }
            turns.append(
                Turn(
                    id: prompt?.remoteID ?? laneOrder.first.flatMap { lanes[$0]?.first?.remoteID } ?? UUID().uuidString,
                    prompt: prompt, lanes: laneOrder.map { ($0, lanes[$0] ?? []) }, votes: votes))
            prompt = nil
            lanes = [:]
            laneOrder = []
        }
        for message in detail.messages {
            if message.role == "user" {
                flush()
                prompt = message
            } else {
                let lane = message.lane ?? "—"
                if lanes[lane] == nil { laneOrder.append(lane) }
                lanes[lane, default: []].append(message)
            }
        }
        flush()
        return turns
    }
}
