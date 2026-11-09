import ApplicationActions
import SuiteDomain
import SwiftUI

/// Export on the site pane (ADR 0006, amendment 2026-11-04): the conversation the shown page's
/// address names, exported from the archive. Nothing is read from the page. On the user's click the
/// conversation is brought up to date with the account's own Arena Suite sign-in first, by Refresh
/// when it is archived and by Sync History when it isn't yet; then the archive's export choices are
/// shown for it.
struct PageExportButton: View {
    let account: AccountSummary
    /// The page address's path segments, last first (`WebSitePolicy.pageSegments`).
    let candidates: [String]
    let archive: ArchiveModel
    let accounts: AccountsModel
    @State private var showing = false
    @State private var confirmExactRaw = false
    @State private var step = Step.finding

    enum Step: Equatable {
        case finding, refreshing, syncing
        /// Shown; the note says why it may not hold the latest turns.
        case ready(title: String, note: String?)
        case failed(String)
    }

    var body: some View {
        Button {
            showing = true
            Task { await prepare() }
        } label: {
            Label { Text("Export Conversation") } icon: { Theme.shareIcon() }
        }
        .buttonStyle(.arenaIcon(width: 28, height: 24, selected: showing))
        .keyboardShortcut("e", modifiers: [.shift, .command])
        .disabled(candidates.isEmpty)
        .help(candidates.isEmpty ? "Open a conversation on the site to export it" : "Export or copy this conversation from the archive (⇧⌘E)")
        .popover(isPresented: $showing, arrowEdge: .bottom) { content }
        .exactRawConfirmation(isPresented: $confirmExactRaw, archive: archive)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .ready(let title, let note):
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.heading).lineLimit(2)
                    if let note { Text(note).font(Theme.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }
                .padding([.horizontal, .top], 14)
                ExportPopover(archive: archive) {
                    showing = false
                    confirmExactRaw = true
                } close: {
                    showing = false
                }
            }
            .frame(width: 370, alignment: .leading)
        case .failed(let reason):
            Text(reason).fixedSize(horizontal: false, vertical: true).padding(14).frame(width: 340, alignment: .leading)
        default:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step == .finding ? "Finding this conversation in the archive…"
                    : step == .refreshing ? "Fetching its latest turns…" : "Syncing History to archive it…")
            }
            .padding(14)
        }
    }

    private func prepare() async {
        step = .finding
        let id = account.id
        let signedIn = account.state == .signedIn
        let busy = accounts.syncing[id] != nil || accounts.refreshing[id] != nil
        var note: String?
        var found = await archive.locate(account: id, among: candidates)
        if let summary = found {
            if !accounts.canRefresh(kind: summary.kind, latestSnapshot: summary.latestSnapshotSequence) {
                // Kinds that are never fetched again: the archive's snapshot is all there is.
            } else if !signedIn {
                note = "This account isn't signed in to Arena Suite, so the archive's latest snapshot is exported. Turns since then are missing."
            } else if busy {
                note = "This account is syncing, so the archive's latest snapshot is exported."
            } else {
                step = .refreshing
                let earlier = accounts.syncErrors[id]
                await accounts.refreshConversation(account: id, conversation: summary.remoteID)
                if let problem = accounts.syncErrors[id], problem != earlier { note = problem + " The archive's latest snapshot is exported." }
                found = await archive.locate(account: id, among: [summary.remoteID]) ?? summary
            }
        } else {
            guard signedIn else {
                return step = .failed("This conversation isn't archived yet, and this account isn't signed in to Arena Suite. Sign it in under Manage Accounts, then try again.")
            }
            guard !busy else { return step = .failed("This account is syncing. Try again when it finishes.") }
            step = .syncing
            await accounts.syncHistory(id)
            found = await archive.locate(account: id, among: candidates)
            guard found != nil else {
                return step = .failed(
                    accounts.syncErrors[id]
                        ?? "This page isn't a conversation in this account's Arena history. The page may be signed in to another Arena account than \(account.displayName).")
            }
        }
        guard let summary = found, summary.latestSnapshotSequence != nil else {
            return step = .failed("Arena lists this conversation, but the archive holds no transcript of it, so there is nothing to export.")
        }
        archive.show(.init(account: summary.account, remoteID: summary.remoteID))
        step = .ready(title: summary.title ?? "Untitled", note: note)
    }
}
