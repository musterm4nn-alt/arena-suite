import AppKit
import ApplicationActions
import ArchiveIndex
import SuiteDomain
import SwiftUI

/// The archive beside the sidebar: a header bar with the conversation's title and actions, the
/// transcript as a centered reading column, and the evidence panel at the trailing edge.
struct ArchivePane: View {
    @Bindable var archive: ArchiveModel
    let accounts: AccountsModel
    let siteName: String
    @Binding var showingInspector: Bool
    @Binding var destination: MainDestination
    @State private var confirmExactRaw = false
    @State private var showingExport = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) { exportNotice }
            }
            if showingInspector, archive.detail != nil {
                Theme.border.frame(width: 1)
                EvidenceInspector(archive: archive) { showingInspector = false }
                    .frame(width: 340)
                    .environment(\.headerLeadingInset, 0)
            }
        }
        .background(Theme.background)
        .navigationTitle(archive.detail?.summary.title ?? "Arena Suite")
        #if DEBUG
        // `--preview-export-popover` (with `--preview-conversation`) opens the export popover.
        .task(id: archive.detail?.snapshotSequence) {
            if archive.detail != nil, CommandLine.arguments.contains("--preview-export-popover") { showingExport = true }
        }
        #endif
        .confirmationDialog("Export the whole conversation's raw bodies exactly?", isPresented: $confirmExactRaw) {
            Button("Export Exact Raw JSON to Downloads") {
                Task { await archive.export(.rawJSON, scope: .wholeConversation, exactRawBodies: true, to: nil) }
            }
        } message: {
            Text("Raw JSON is the recorded response, so it holds the whole conversation of the snapshot shown. Exact bodies include Arena's per-message metadata: bot and reCAPTCHA scores, browser-fingerprint ratios, coarse location and a hashed IP about you. The default export masks them.")
        }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        if let detail = archive.detail {
            HeaderBar {
                Text(detail.summary.title ?? "Untitled").lineLimit(1).layoutPriority(1)
                Text(meta(detail.summary)).foregroundStyle(.secondary).lineLimit(1)
            } trailing: {
                if detail.snapshotSequences.count > 1 { snapshotMenu(detail) }
                refreshButton(detail)
                exportMenu(detail)
                Button { showingInspector.toggle() } label: {
                    Label(showingInspector ? "Hide Evidence" : "Show Evidence", systemImage: "sidebar.right")
                }
                .buttonStyle(.arenaIcon(width: 28, height: 24, selected: showingInspector))
                .keyboardShortcut("0", modifiers: [.option, .command])
                .help("Show the raw journal record behind this transcript (⌥⌘0)")
            }
        } else {
            HeaderBar {
                Text("Archive").foregroundStyle(.secondary)
            } trailing: {
                EmptyView()
            }
        }
    }

    private func meta(_ summary: ConversationSummary) -> String {
        let account = accounts.accounts.first { $0.id == summary.account }?.displayName
        var parts = [summary.mode, summary.modality].compactMap { $0 }
        if let account, accounts.accounts.count > 1 { parts.append(account) }
        if let updated = HistoryGroup.display(summary) { parts.append(updated) }
        return parts.joined(separator: " · ")
    }

    private func snapshotMenu(_ detail: ConversationDetail) -> some View {
        Menu {
            Picker("Snapshot", selection: Binding(get: { archive.snapshotSequence }, set: { archive.selectSnapshot($0) })) {
                Text("Latest").tag(UInt64?.none)
                ForEach(detail.snapshotSequences, id: \.self) { Text("Record \($0)").tag(UInt64?.some($0)) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                Text(archive.snapshotSequence.map { "Record \($0)" } ?? "Latest")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.arenaPill)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Each sync that found changes kept a separate snapshot")
    }

    /// Fetches the conversation shown again from Arena (Docs/sync-refresh-2026-10-20.md). Its account
    /// and conversation come from this transcript, never from the selection.
    @ViewBuilder private func refreshButton(_ detail: ConversationDetail) -> some View {
        let account = detail.summary.account
        if accounts.refreshing[account] == detail.summary.remoteID {
            ProgressView().controlSize(.small).frame(width: 28, height: 24).help("Fetching this conversation from Arena…")
        } else {
            let reason = refreshUnavailable(detail)
            Button {
                Task { await accounts.refreshConversation(account: account, conversation: detail.summary.remoteID) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.arenaIcon(width: 28, height: 24))
            .disabled(reason != nil)
            .help(reason ?? "Fetch this conversation again from Arena, for example after voting")
        }
    }

    private func refreshUnavailable(_ detail: ConversationDetail) -> String? {
        let account = detail.summary.account
        if detail.summary.latestSnapshotSequence == nil { return "Only listed on Arena; there is no transcript to fetch again" }
        if !accounts.canRefresh(kind: detail.summary.kind, latestSnapshot: detail.summary.latestSnapshotSequence) {
            return "This kind of conversation can't be fetched again"
        }
        if accounts.accounts.first(where: { $0.id == account })?.state != .signedIn {
            return "Sign in to this conversation's account to fetch it again"
        }
        if accounts.syncing[account] != nil || accounts.refreshing[account] != nil { return "This account is syncing" }
        return nil
    }

    private func exportMenu(_ detail: ConversationDetail) -> some View {
        Button { showingExport.toggle() } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.arenaIcon(width: 28, height: 24, selected: showingExport))
        .keyboardShortcut("e", modifiers: [.shift, .command])
        .disabled(!archive.canExport)
        .help("Export or copy this snapshot (⇧⌘E)")
        .popover(isPresented: $showingExport, arrowEdge: .bottom) {
            ExportPopover(archive: archive) {
                showingExport = false
                confirmExactRaw = true
            } close: {
                showingExport = false
            }
        }
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let detail = archive.detail, let layout = archive.layout {
            TranscriptView(archive: archive, detail: detail, layout: layout) { showingInspector = true }
        } else if archive.selection != nil {
            ProgressView().controlSize(.small)
        } else {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("Arena Suite").font(Theme.heading)
                firstStep
            }
            .multilineTextAlignment(.center)
            .padding(40)
        }
    }

    /// The home screen's next step: add an account, sign it in, archive it, then browse.
    @ViewBuilder private var firstStep: some View {
        let needsSignIn = accounts.accounts.first { $0.state == .needsSignIn || $0.state == .quarantined }
        let needsCheck = accounts.accounts.first { $0.state == .blocked || $0.state == .unreachable }
        let scope = SidebarScope(accounts: accounts, archive: archive)
        if accounts.loading && accounts.accounts.isEmpty {
            Text("Checking saved sessions…").foregroundStyle(.secondary)
        } else if accounts.accounts.isEmpty {
            Text("Add your Arena account to archive its history on this Mac.").foregroundStyle(.secondary)
            Button("Add Account…") {
                accounts.pendingAdd = true
                destination = .accounts
            }
            .buttonStyle(.arenaPill)
        } else if archive.conversations.isEmpty, !scope.syncable.isEmpty {
            Text("Nothing archived yet. Sync History copies your Arena history into the local archive.")
                .foregroundStyle(.secondary)
            Button(scope.syncing.isEmpty ? "Sync History" : "Syncing…") { scope.startSync() }
                .buttonStyle(.arenaPill)
                .disabled(!scope.syncing.isEmpty)
        } else if archive.conversations.isEmpty, let account = needsSignIn {
            Text("“\(account.displayName)” needs to sign in again before its history can be archived.")
                .foregroundStyle(.secondary)
            Button("Sign In…") {
                accounts.pendingSignIn = account.id
                destination = .accounts
            }
            .buttonStyle(.arenaPill)
        } else if archive.conversations.isEmpty, let account = needsCheck {
            Text(account.state == .blocked
                ? "Arena refused “\(account.displayName)”. Verify checks the session again; nothing is retried until then."
                : "Arena could not be reached for “\(account.displayName)”. Verify checks the session again.")
                .foregroundStyle(.secondary)
            Button(accounts.working.contains(account.id) ? "Verifying…" : "Verify") {
                Task { await accounts.verify(account.id) }
            }
            .buttonStyle(.arenaPill)
            .disabled(accounts.working.contains(account.id))
        } else {
            Text("\(archive.conversations.count) conversations archived").foregroundStyle(.secondary)
            if archive.filter.isActive {
                Text("\(archive.visibleConversations.count) shown by the history filters.")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Choose one in the sidebar, search with ⌘F, or open \(siteName) there.")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var exportNotice: some View {
        if let outcome = archive.exportOutcome {
            HStack(spacing: 10) {
                switch outcome {
                case .copied(let text):
                    Image(systemName: "doc.on.clipboard")
                    Text(text).lineLimit(1).truncationMode(.middle)
                case .refused(let reason):
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(reason).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                case .saved(let result):
                    Image(systemName: "checkmark.circle")
                    Text("Exported \(result.url.lastPathComponent) · \(result.byteCount) bytes · SHA-256 \(result.sha256.prefix(12))…")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                        .buttonStyle(.arenaPill)
                }
                Button { archive.dismissExport() } label: { Label("Dismiss", systemImage: "xmark") }
                    .buttonStyle(.arenaIcon(width: 20, height: 20))
            }
            .font(Theme.caption)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .padding(16)
        }
    }
}

// MARK: - Export

/// What and how to export, like arena-exporter's popup: a scope, a format, then copy or save. The
/// choices are remembered between launches. Exact raw bodies stay behind their own confirmation.
private struct ExportPopover: View {
    @Bindable var archive: ArchiveModel
    let confirmExactRaw: () -> Void
    let close: () -> Void
    @AppStorage("exportScope") private var scopeChoice = ExportScope.wholeConversation.rawValue
    @AppStorage("exportFormat") private var formatChoice = ExportFormat.markdown.rawValue

    private var scope: ExportScope { ExportScope(rawValue: scopeChoice) ?? .wholeConversation }
    private var format: ExportFormat { ExportFormat(rawValue: formatChoice) ?? .markdown }
    /// Raw JSON is one recorded response: it has no last answer.
    private var available: Bool { scope == .wholeConversation || format.supportsLastAnswer }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Scope", selection: $scopeChoice) {
                ForEach(ExportScope.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.radioGroup)
            Picker("Format", selection: $formatChoice) {
                ForEach(ExportFormat.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Text(hint)
                .font(Theme.caption)
                .foregroundStyle(available ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Copy", action: copy).help("Copy the export to the clipboard; no file is written")
                Button("Save to Downloads") { save(to: nil) }
                Button("Save to Folder…") {
                    close()
                    if let folder = ArchivePane.chooseFolder() { save(to: folder) }
                }
            }
            .buttonStyle(.arenaPill)
            .disabled(!available || !archive.canExport)
            Divider()
            // Raw JSON always holds the whole conversation, whatever scope is chosen above.
            Button("Whole conversation as Raw JSON with exact bodies (includes Arena telemetry)…", action: confirmExactRaw)
                .buttonStyle(.plain)
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(!archive.canExport)
        }
        .padding(14)
        .frame(width: 370, alignment: .leading)
        .departureMono()
        .arenaPalette()
    }

    private var hint: String {
        guard available else { return "Raw JSON is one recorded response, so it always holds the whole conversation." }
        let what: String = switch format {
        case .markdown: "A readable transcript. Lossy: no raw bytes, timing or telemetry."
        case .normalizedJSON: "Messages, model claims and feedback, with provenance. Telemetry masked."
        case .jsonl: "The records of Normalized JSON, one per line, for streaming tools."
        case .rawJSON: "The recorded response, base64-encoded, with Arena's telemetry masked."
        }
        return scope == .lastAnswer ? "The messages Arena lists as last, and the prompts they reply to. " + what : what
    }

    private func copy() {
        let (format, scope) = (format, scope)
        close()
        Task {
            await archive.copy(format, scope: scope) { text in
                let pasteboard = NSPasteboard.general
                let previous = pasteboard.string(forType: .string)
                pasteboard.clearContents()
                if pasteboard.setString(text, forType: .string) { return .written }
                // A failed copy puts back the text the clipboard held (other kinds of content are not kept).
                guard let previous else { return .refused(previousTextRestored: false) }
                pasteboard.clearContents()
                return .refused(previousTextRestored: pasteboard.setString(previous, forType: .string))
            }
        }
    }

    private func save(to folder: URL?) {
        let (format, scope) = (format, scope)
        close()
        Task { await archive.export(format, scope: scope, exactRawBodies: false, to: folder) }
    }
}

// MARK: - Transcript

private struct TranscriptView: View {
    @Bindable var archive: ArchiveModel
    let detail: ConversationDetail
    let layout: TranscriptLayout
    let showInspector: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    intro
                    ForEach(layout.turns) { turn in
                        TurnView(
                            turn: turn, names: archive.revealedNames, agent: detail.summary.kind == "agentic",
                            highlighted: archive.highlightedMessage,
                            notes: archive.canWriteNotes ? archive.voteNotes : nil,
                            notesUnavailable: archive.canWriteNotes ? archive.notesUnavailable : "Notes are unavailable: the archive index could not be opened.",
                            savingNotes: archive.savingNotes
                        ) {
                            archive.inspect($0)
                            showInspector()
                        } inspectVote: { vote in
                            archive.inspect(.init(title: "Vote \(vote.remoteID)", pointers: ["$.pairwiseFeedbacks[] (id \(vote.remoteID))"]))
                            showInspector()
                        } setNote: { choice, vote in
                            archive.setNote(choice, beside: vote, in: detail)
                        }
                    }
                    if !layout.unmatchedVotes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Votes not tied to a single turn").foregroundStyle(.secondary)
                            ForEach(layout.unmatchedVotes, id: \.remoteID) { vote in
                                Text("Vote: \(vote.value ?? "unknown") (messages \(vote.messageA ?? "?"), \(vote.messageB ?? "?"))")
                                    .font(Theme.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 64)
                .frame(maxWidth: 1080)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
                .environment(\.attachmentReader, AttachmentReader(revision: archive.revision) { [archive, account = detail.summary.account] in
                    await archive.attachmentData(account: account, sha256: $0)
                })
            }
            // Runs when the transcript first appears too: a search hit that opens a conversation
            // requests the scroll in the same update that delivers the transcript.
            .task(id: archive.scrollRequest) {
                guard let target = archive.highlightedMessage else { return }
                try? await Task.sleep(for: .milliseconds(50))
                withAnimation { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    /// Model claims (each with its source) and what the snapshot holds, above the first turn.
    @ViewBuilder private var intro: some View {
        let claims = detail.claims.filter { $0.subject == .conversation }
        // Only the latest snapshot: sync and Refresh fetch the conversation's next one.
        let unfinished = !detail.isFrozen && detail.messages.contains { $0.status.map(archive.unfinishedStatuses.contains) ?? false }
        if !claims.isEmpty || detail.messages.isEmpty || unfinished {
            VStack(alignment: .leading, spacing: 8) {
                if unfinished {
                    Label {
                        Text("Recorded while a response was still being generated. Sync History fetches this conversation again a few times; Refresh fetches it now.")
                    } icon: {
                        Image(systemName: "hourglass")
                    }
                    .foregroundStyle(.secondary)
                }
                if !claims.isEmpty {
                    HStack(spacing: 6) {
                        Text("Model claims").fontWeight(.bold)
                        Text("from Arena, each with its source; not verified identities").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button {
                            archive.inspect(.init(title: "Model claims", pointers: ["$.revealedModels[]", "history list: $.entries[].modelAId / modelBId"]))
                            showInspector()
                        } label: {
                            Label("Show evidence for model claims", systemImage: "doc.text.magnifyingglass")
                        }
                        .buttonStyle(.arenaIcon(width: 24, height: 22))
                    }
                    ForEach(Array(claims.enumerated()), id: \.offset) { _, claim in
                        HStack(spacing: 8) {
                            if let lane = claim.role { LaneBadge(lane: lane) }
                            Text(claim.displayName ?? claim.modelID)
                            Text([claim.source, claim.recordSequence.map { "record \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if detail.messages.isEmpty {
                    Text(detail.summary.latestSnapshotSequence == nil
                        ? (detail.summary.kind == "agentic"
                            ? "Not fetched yet. Sync History fetches this Agent conversation's transcript."
                            : "Only listed on Arena; no transcript is available for this conversation type yet.")
                        : "No messages in this snapshot.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sunken.opacity(0.6)))
        }
    }
}

/// A lane's letter in a small circle, like the site's answer headers.
private struct LaneBadge: View {
    let lane: String?

    var body: some View {
        Text(lane?.uppercased() ?? "?")
            .font(Theme.caption)
            .frame(width: 20, height: 20)
            .overlay(Circle().strokeBorder(Theme.border))
            .accessibilityLabel(lane.map { "Lane \($0.uppercased())" } ?? "Lane not exposed")
    }
}

private struct TurnView: View {
    let turn: TranscriptLayout.Turn
    let names: [String: String]
    /// An Agent conversation: its replies are the agent's, with no lanes.
    let agent: Bool
    let highlighted: String?
    /// Your local notes in this conversation; nil when they cannot be read or written.
    let notes: [VoteNote]?
    /// Why `notes` is nil.
    let notesUnavailable: String?
    let savingNotes: Set<String>
    let inspect: (DetailMessage) -> Void
    let inspectVote: (ArchivedFeedback) -> Void
    let setNote: (VoteOutcome?, ArchivedFeedback) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let prompt = turn.prompt {
                PromptBubble(message: prompt, highlighted: highlighted == prompt.remoteID, inspect: inspect)
            }
            HStack(alignment: .top, spacing: 14) {
                ForEach(Array(turn.lanes.enumerated()), id: \.offset) { _, lane in
                    VStack(alignment: .leading, spacing: 10) {
                        if lane.hasAlternatives {
                            Text("\(lane.messages.count) responses in this lane (regenerations or branches), in server order")
                                .font(Theme.caption).foregroundStyle(.secondary)
                        }
                        ForEach(lane.messages, id: \.message.remoteID) { entry in
                            MessageCard(
                                message: entry.message, lane: lane.lane, showsLane: !agent || lane.lane != nil,
                                title: laneTitle(lane.lane, entry.message),
                                note: entry.otherParents.isEmpty ? nil : "Replies to \(entry.otherParents.joined(separator: ", "))",
                                highlighted: highlighted == entry.message.remoteID, inspect: inspect)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            ForEach(turn.otherRoles, id: \.remoteID) { message in
                MessageCard(
                    message: message, lane: nil, title: "Role: \(message.role ?? "not stated")", note: nil,
                    highlighted: highlighted == message.remoteID, inspect: inspect)
            }
            ForEach(turn.votes, id: \.remoteID) { vote in
                let note = notes?.first { $0.messageA == vote.messageA && $0.messageB == vote.messageB }
                let letters = laneLetters(vote)
                HStack(spacing: 6) {
                    Text("Your vote: \(vote.value ?? "unknown")").foregroundStyle(.secondary)
                    if let choice = note?.choice {
                        Text("· Your local note: \(Self.title(choice, letters))")
                            .help("Kept only in this archive. It is never sent to Arena.")
                    }
                    Button { inspectVote(vote) } label: {
                        Label("Show evidence for this vote", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.arenaIcon(width: 22, height: 20))
                    if vote.messageA != nil, vote.messageB != nil, vote.messageA != vote.messageB {
                        noteMenu(vote, current: note?.choice, letters: letters)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.sunken.opacity(0.6)))
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// A menu of your note's choices. Nothing is pre-selected, and nothing here is sent anywhere.
    private func noteMenu(_ vote: ArchivedFeedback, current: VoteOutcome?, letters: (a: String, b: String)) -> some View {
        Menu {
            // Checks the current note; choosing it again records nothing new.
            Picker(
                "Your note",
                selection: Binding(get: { current }, set: { choice in if let choice, choice != current { setNote(choice, vote) } })
            ) {
                ForEach(VoteOutcome.allCases, id: \.self) { outcome in
                    Text(Self.title(outcome, letters)).tag(VoteOutcome?.some(outcome))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if current != nil {
                Divider()
                Button("Remove Note") { setNote(nil, vote) }
            }
            Divider()
            Text("A note is kept only in this archive. It is never sent to Arena.")
        } label: {
            Label(current == nil ? "Add a note" : "Change your note", systemImage: current == nil ? "square.and.pencil" : "pencil")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(.arenaIcon(width: 22, height: 20))
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(notes == nil || savingNotes.contains(vote.remoteID))
        .help(notes == nil
            ? notesUnavailable ?? "Notes are unavailable."
            : "Your own note beside this vote, kept only in this archive. It is never sent to Arena.")
        .accessibilityLabel(current == nil ? "Add a local note to this vote" : "Change your local note on this vote")
    }

    /// The letters the transcript shows for the vote's two messages (their lanes); the vote's own A
    /// and B when a lane is not exposed or both would read the same.
    private func laneLetters(_ vote: ArchivedFeedback) -> (a: String, b: String) {
        func lane(_ id: String?) -> String? {
            turn.lanes.first { $0.messages.contains { $0.message.remoteID == id } }?.lane?.uppercased()
        }
        guard let a = lane(vote.messageA), let b = lane(vote.messageB), a != b else { return ("A", "B") }
        return (a, b)
    }

    private static func title(_ outcome: VoteOutcome, _ letters: (a: String, b: String)) -> String {
        switch outcome {
        case .preferA: "\(letters.a) is better"
        case .preferB: "\(letters.b) is better"
        case .tie: "Tie"
        case .bothBad: "Both are bad"
        }
    }

    private func laneTitle(_ lane: String?, _ message: DetailMessage) -> String {
        if let model = message.modelRemoteID.map({ names[$0] ?? $0 }) { return model }
        if agent, lane == nil { return "Agent" }
        return lane.map { "Assistant \($0.uppercased())" } ?? "Response (lane not exposed)"
    }
}

/// Your prompt: a filled bubble at the trailing side, as on the site.
private struct PromptBubble: View {
    let message: DetailMessage
    let highlighted: Bool
    let inspect: (DetailMessage) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 120)
            Button { inspect(message) } label: { Label("Show raw evidence", systemImage: "doc.text.magnifyingglass") }
                .buttonStyle(.arenaIcon(width: 24, height: 22))
                .opacity(hovering ? 1 : 0)
                // Takes no clicks while invisible; VoiceOver, which cannot hover, still reaches it.
                .allowsHitTesting(hovering)
                .help("Show raw evidence for this prompt")
            VStack(alignment: .leading, spacing: 8) {
                if let status = message.status, status != "success" { Text("[\(status)]").foregroundStyle(.orange) }
                MessageBody(message: message)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                let shape = RoundedRectangle(cornerRadius: 14)
                ZStack {
                    shape.fill(Theme.raised)
                    if highlighted { shape.fill(Color.yellow.opacity(0.14)) }
                    if highlighted { shape.strokeBorder(Color.yellow.opacity(0.5)) }
                }
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(highlighted ? "Your prompt, search match" : "Your prompt")
        .id(message.remoteID)
    }
}

/// A response: an outlined card with a header row, as on the site.
private struct MessageCard: View {
    let message: DetailMessage
    let lane: String?
    /// Off for an Agent's replies, which have no lanes to mark.
    var showsLane = true
    let title: String
    let note: String?
    let highlighted: Bool
    let inspect: (DetailMessage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if showsLane { LaneBadge(lane: lane) }
                Text(title).fontWeight(.bold).lineLimit(1)
                if let status = message.status, status != "success" { Text("[\(status)]").foregroundStyle(.orange) }
                if highlighted { Text("match").font(Theme.caption).foregroundStyle(.yellow) }
                Spacer(minLength: 0)
                Button { inspect(message) } label: { Label("Show raw evidence", systemImage: "doc.text.magnifyingglass") }
                    .buttonStyle(.arenaIcon(width: 24, height: 22))
                    .help("Show raw evidence for this message")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 38)
            Theme.border.frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                if let note { Text(note).font(Theme.caption).foregroundStyle(.secondary) }
                MessageBody(message: message)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            let shape = RoundedRectangle(cornerRadius: 12)
            ZStack {
                shape.fill(Theme.background)
                if highlighted { shape.fill(Color.yellow.opacity(0.08)) }
                shape.strokeBorder(highlighted ? Color.yellow.opacity(0.5) : Theme.border)
            }
        }
        .id(message.remoteID)
    }
}

private struct MessageBody: View {
    let message: DetailMessage

    var body: some View {
        ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
            BlockView(block: block)
        }
        ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
            AttachmentView(attachment: attachment)
        }
    }
}

/// Reads a stored attachment file of the open conversation's account (from the archive, never
/// from the network).
struct AttachmentReader {
    /// The archive's reload count: files are read again after a sync, Refresh or restore.
    let revision: Int
    let read: @MainActor (String) async -> Result<Data, AttachmentFileError>
}

private struct AttachmentReaderKey: EnvironmentKey {
    static let defaultValue: AttachmentReader? = nil
}

extension EnvironmentValues {
    var attachmentReader: AttachmentReader? {
        get { self[AttachmentReaderKey.self] }
        set { self[AttachmentReaderKey.self] = newValue }
    }
}

/// One attachment (Docs/attachments-2026-10-20.md): a stored image shown inline, another stored
/// file as a row, each with Save Copy…; otherwise why the archive has no file for it.
private struct AttachmentView: View {
    let attachment: ArchivedAttachment
    @Environment(\.attachmentReader) private var reader
    @State private var loaded: Result<Data, AttachmentFileError>?
    @State private var image: NSImage?
    @State private var saveProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, 480), maxHeight: min(image.size.height, 360), alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(attachment.name ?? "Attached image")
            }
            HStack(spacing: 8) {
                Label(attachment.name ?? "unnamed", systemImage: image == nil ? "paperclip" : "photo")
                    .lineLimit(1)
                Text(state).foregroundStyle(stateIsProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                if case .success(let data) = loaded {
                    Button("Save Copy…") { save(data) }.buttonStyle(.arenaPill)
                }
            }
            .font(Theme.caption)
            .foregroundStyle(.secondary)
            if let saveProblem { Text(saveProblem).font(Theme.caption).foregroundStyle(.orange) }
        }
        .task(id: "\(storedName ?? "") \(reader?.revision ?? -1)") { await load() }
    }

    /// The object name when the archive holds this attachment's file.
    private var storedName: String? {
        guard let download = attachment.file?.download, download.outcome == .stored else { return nil }
        return download.sha256
    }

    private var contentType: String? { attachment.file?.download.contentType ?? attachment.contentType }

    private func load() async {
        loaded = nil
        image = nil
        guard let storedName else { return }
        guard let reader else { return loaded = .failure(.unreadable) }
        let result = await reader.read(storedName)
        loaded = result
        guard case .success(let data) = result else { return }
        if let preview = await Task.detached(operation: { Self.preview(data) }).value {
            image = NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height))
        }
    }

    /// Types shown inline, decided by the bytes, never by the stated type. SVG, PDF and anything
    /// else stay files.
    nonisolated static let rasterTypes: Set<String> = [
        "public.png", "public.jpeg", "com.compuserve.gif", "org.webmproject.webp", "public.heic", "public.heif",
        "public.tiff", "com.microsoft.bmp",
    ]

    /// A raster image scaled to at most 1 600 pixels on its longer side; nil for anything else and
    /// for an image over 100 megapixels.
    nonisolated static func preview(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source) as String?, rasterTypes.contains(type),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 100_000_000 / height
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_600, kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private var stateIsProblem: Bool {
        if case .failure = loaded { return true }
        return false
    }

    private var state: String {
        let type = contentType.map { " · \($0)" } ?? ""
        switch loaded {
        case .success(let data):
            return ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file) + type
        case .failure(.missing):
            return "The file is missing from the archive. Verify Archive lists every missing file; Refresh downloads it again."
        case .failure(.damaged):
            return "The file in the archive is damaged (its bytes changed). Refresh downloads it again."
        case .failure(.unreadable):
            return "The file could not be read from the archive."
        case nil: break
        }
        if storedName != nil { return "Reading…" }
        if let download = attachment.file?.download {
            let status = download.status.map { "HTTP \($0)" }
            switch download.outcome {
            case .denied: return "Not downloaded: the file host refused it (\(status ?? "no status")). Refresh tries again."
            case .unavailable: return "Not downloaded (\(status ?? "no complete response")). Refresh tries again."
            case .notStored:
                return "Downloaded, but the file could not be written to the archive (its bytes are kept in the journal). Refresh tries again."
            case .stored: break
            }
        }
        guard attachment.hasURL else { return "No link was recorded for this file." + type }
        guard attachment.objectKey != nil else { return "Not downloaded: the link is not one this app downloads from." + type }
        if let expires = attachment.linkExpiresAt.flatMap({ try? Date($0, strategy: .iso8601) }), expires <= Date() {
            return "Not downloaded; its link has expired. Refresh gets a new link and downloads it." + type
        }
        return "Not downloaded yet. Refresh downloads it." + type
    }

    private func save(_ data: Data) {
        saveProblem = nil
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.fileName(attachment.name)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) } catch {
                saveProblem = "The copy could not be saved (\((error as NSError).domain) \((error as NSError).code))."
            }
        }
    }

    /// The attachment's name as a single file name (it comes from Arena): no path separators,
    /// control or format characters (such as bidirectional overrides), no leading dot, and at most
    /// 240 bytes.
    static func fileName(_ name: String?) -> String {
        let cleaned = String((name ?? "").map { character -> Character in
            let hidden = character.unicodeScalars.contains {
                [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
            }
            return character == "/" || character == ":" || character.isNewline || hidden ? "-" : character
        })
        var trimmed = String(cleaned.trimmingCharacters(in: .whitespaces).drop { $0 == "." })
        while trimmed.utf8.count > 240 { trimmed.removeLast() }
        return trimmed.isEmpty ? "attachment" : trimmed
    }
}

private struct BlockView: View {
    let block: DetailBlock

    var body: some View {
        switch block.kind {
        case .text:
            Text(Self.markdown(block.text ?? "")).fixedSize(horizontal: false, vertical: true)
        case .reasoning:
            Expandable(title: "Reasoning", symbol: "brain") { Text(block.text ?? "").foregroundStyle(.secondary) }
        case .toolCall:
            Expandable(title: "Tool call · \(block.toolName ?? "unknown")", symbol: "wrench.and.screwdriver") { payload }
        case .toolResult:
            Expandable(title: "Tool result · \(block.toolName ?? block.toolCallID ?? "")", symbol: "tray.and.arrow.down") { payload }
        case .sources:
            Expandable(title: "Sources", symbol: "link") { payload }
        case .opaque:
            Expandable(title: "Unrecognized block (kept as-is)", symbol: "questionmark.square.dashed") { payload }
        }
    }

    /// Inline Markdown only (emphasis, code, links as text); whitespace preserved; nothing is loaded.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private var payload: some View {
        Text(block.payload ?? "").font(Theme.caption).foregroundStyle(.secondary).lineLimit(40)
    }
}

/// A collapsed section (reasoning, tool calls): a chevron row that opens an indented body.
private struct Expandable<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Image(systemName: symbol).imageScale(.small)
                    Text(title).lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                content
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Theme.border.frame(width: 2) }
            }
        }
    }
}

// MARK: - Evidence

private struct EvidenceInspector: View {
    @Bindable var archive: ArchiveModel
    let close: () -> Void
    @State private var showBody = false
    @State private var hex = false
    private static let textLimit = 262_144
    private static let hexLimit = 65_536

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar {
                Text("Evidence")
            } trailing: {
                Button(action: close) { Label("Hide Evidence", systemImage: "xmark") }
                    .buttonStyle(.arenaIcon(width: 24, height: 22))
                    .help("Hide Evidence (⌥⌘0)")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Showing") {
                        if let target = archive.inspected {
                            Text(target.title).textSelection(.enabled)
                            ForEach(target.pointers, id: \.self) { Text($0).font(Theme.caption).foregroundStyle(.secondary) }
                        } else {
                            Text("Choose an evidence button on a message, vote or claim.").foregroundStyle(.secondary)
                        }
                        if archive.inspected != nil && archive.evidenceUnavailable {
                            Text("The raw record for this snapshot is unavailable.").foregroundStyle(.orange)
                        }
                    }
                    if let evidence = archive.evidence {
                        section("Journal record") {
                            Text("Record \(evidence.location.sequence) · segment \(evidence.location.segment) · offset \(evidence.location.offset) · \(evidence.location.length) bytes")
                            Text("SHA-256 \(evidence.digest)").font(Theme.caption).textSelection(.enabled)
                            Text("Digest verified on read · current decoder \(evidence.decoderVersion)").font(Theme.caption).foregroundStyle(.secondary)
                        }
                        section("Envelope") {
                            Text("Reformatted for display; the digest covers the stored bytes.").font(Theme.caption).foregroundStyle(.secondary)
                            Text(Self.pretty(evidence.envelope)).font(Theme.caption).textSelection(.enabled)
                        }
                        section("Raw body") {
                            Toggle(isOn: $showBody) { Text("Show raw body (\(evidence.payload.count) bytes)") }
                                .toggleStyle(.checkbox)
                            if showBody {
                                Text("The raw body includes Arena's per-message metadata (anti-abuse telemetry about you). It is shown here only on request and never indexed or exported by default.")
                                    .font(Theme.caption).foregroundStyle(.orange)
                                Toggle(isOn: $hex) { Text("Hex") }.toggleStyle(.checkbox)
                                let limit = hex ? Self.hexLimit : Self.textLimit
                                if evidence.payload.count > limit {
                                    Text("Showing the first \(limit) of \(evidence.payload.count) bytes.").font(Theme.caption).foregroundStyle(.orange)
                                }
                                Text(hex ? Self.hex(evidence.payload.prefix(limit)) : String(decoding: evidence.payload.prefix(limit), as: UTF8.self))
                                    .font(Theme.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.background)
        .onChange(of: archive.inspected) { showBody = false }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.caption).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    static func pretty(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: pretty, as: UTF8.self)
    }

    static func hex(_ data: Data) -> String {
        stride(from: 0, to: data.count, by: 16).map { start in
            let row = data[data.startIndex + start..<data.startIndex + min(start + 16, data.count)]
            return String(format: "%08x  ", start) + row.map { String(format: "%02x", $0) }.joined(separator: " ")
        }.joined(separator: "\n")
    }
}
