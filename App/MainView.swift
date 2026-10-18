import AppKit
import ApplicationActions
import ArchiveIndex
import SuiteDomain
import SwiftUI

/// Sidebar (accounts) · conversation list with search · transcript, with the raw-evidence inspector.
struct MainView: View {
    @Bindable var accounts: AccountsModel
    @Bindable var archive: ArchiveModel
    let maintenance: MaintenanceModel
    let profiles: ArenaWebProfiles
    @State private var showingAccounts = false
    @State private var showingMaintenance = false
    @State private var showingInspector = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                accounts: accounts, archive: archive, siteName: profiles.siteName, showingAccounts: $showingAccounts,
                showingMaintenance: $showingMaintenance)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } content: {
            ConversationListView(archive: archive)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            TranscriptView(archive: archive, showingInspector: $showingInspector)
                .frame(minWidth: 440)
                .inspector(isPresented: $showingInspector) {
                    EvidenceInspector(archive: archive).inspectorColumnWidth(min: 260, ideal: 320, max: 520)
                }
        }
        .departureMono()
        .sheet(isPresented: $showingAccounts) {
            AccountsView(model: accounts)
                .departureMono()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingAccounts = false } } }
        }
        .sheet(isPresented: $showingMaintenance) {
            MaintenanceView(model: maintenance, accounts: accounts)
                .departureMono()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingMaintenance = false }.disabled(maintenance.working != nil)
                    }
                }
        }
        .task {
            await accounts.start()
            await archive.projectAll(accounts.accounts.map(\.id))
            // Finishes web profile deletions for removed accounts that could not complete earlier.
            await profiles.lifecycle.retryPending()
            #if DEBUG
            // Development: `--preview-conversation "<title prefix>"` opens that conversation and the
            // evidence inspector, for screenshots of this window only.
            let arguments = CommandLine.arguments
            for _ in 0..<100 where archive.conversations.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
            if let index = arguments.firstIndex(of: "--preview-search"), arguments.indices.contains(index + 1) {
                archive.searchText = arguments[index + 1]
            }
            if let index = arguments.firstIndex(of: "--preview-conversation"), arguments.indices.contains(index + 1),
                let match = archive.conversations.first(where: { ($0.title ?? "").hasPrefix(arguments[index + 1]) })
            {
                archive.select(.init(account: match.account, remoteID: match.remoteID))
                for _ in 0..<100 where archive.detail == nil { try? await Task.sleep(for: .milliseconds(50)) }
                if let message = archive.detail?.messages.dropFirst().first { archive.inspect(message) }
                showingInspector = !arguments.contains("--preview-export")
                if arguments.contains("--preview-export") {
                    // Writes to a temporary folder, never to Downloads.
                    await archive.export(.markdown, exactRawBodies: false, to: FileManager.default.temporaryDirectory.appendingPathComponent("arena-preview-exports"))
                }
            }
            if arguments.contains("--preview-maintenance") {
                showingMaintenance = true
                await maintenance.verify()
            }
            if arguments.contains("--validate-dataset") {
                showingMaintenance = true
                await maintenance.validateDataset()
            }
            #endif
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Bindable var accounts: AccountsModel
    @Bindable var archive: ArchiveModel
    let siteName: String
    @Environment(\.openWindow) private var openWindow
    @Binding var showingAccounts: Bool
    @Binding var showingMaintenance: Bool

    var body: some View {
        List {
            Section {
                row(title: "All accounts", subtitle: "\(archive.conversations.count) conversations", account: nil)
            } header: { Text("Archive").font(Theme.caption) }
            Section {
                ForEach(accounts.accounts) { account in
                    VStack(alignment: .leading, spacing: 2) {
                        row(title: account.displayName, subtitle: AccountsView.label(account.state), account: account.id)
                        if let progress = accounts.syncing[account.id] {
                            Text(AccountsView.describe(progress)).font(Theme.caption).foregroundStyle(.secondary)
                        } else if let manifest = accounts.lastSync[account.id] {
                            Text(AccountsView.describe(manifest)).font(Theme.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        HStack {
                            if accounts.syncing[account.id] != nil {
                                Button("Stop") { Task { await accounts.cancelSync(account.id) } }
                            } else if account.state == .signedIn {
                                Button("Sync History") { Task { await accounts.syncHistory(account.id) } }
                                    .accessibilityHint("Reads your Arena history for this account into the local archive")
                            }
                            Button("Open \(siteName)") { openWindow(id: ArenaWebWindow.id, value: account.id) }
                                .help("Use \(siteName) in a window with this account's own web profile")
                        }
                        .buttonStyle(.link)
                        .font(Theme.text)
                    }
                    .padding(.vertical, 2)
                }
            } header: { Text("Accounts").font(Theme.caption) }
            if archive.problems.warnings > 0 || archive.problems.unknownPaths > 0 {
                Section {
                    Text("\(archive.problems.warnings) decoder warning(s), \(archive.problems.unknownPaths) unknown field path(s). Raw evidence is kept.")
                        .font(Theme.caption).foregroundStyle(.orange)
                } header: { Text("Attention").font(Theme.caption) }
            }
        }
        .font(Theme.text)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if archive.projecting { Text("Updating index…").font(Theme.caption).foregroundStyle(.secondary) }
                if let message = archive.message ?? accounts.message {
                    Text(message).font(Theme.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Button { showingAccounts = true } label: { Text("Manage Accounts…").font(Theme.text) }
                Button { showingMaintenance = true } label: { Text("Maintenance…").font(Theme.text) }
            }
            .padding(10)
        }
    }

    private func row(title: String, subtitle: String, account: AccountID?) -> some View {
        Button {
            archive.accountFilter = account
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.text).fontWeight(archive.accountFilter == account ? .bold : .regular)
                Text(subtitle).font(Theme.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(archive.accountFilter == account ? .isSelected : [])
    }
}

// MARK: - Conversation list

private struct ConversationListView: View {
    @Bindable var archive: ArchiveModel

    var body: some View {
        Group {
            if !archive.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                List(archive.hits, id: \.self) { hit in
                    Button { archive.open(hit) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title ?? "Untitled").font(Theme.text).lineLimit(1)
                            Text(hit.snippet).font(Theme.caption).foregroundStyle(.secondary).lineLimit(3)
                            Text(hit.kind).font(Theme.caption).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .font(Theme.text)
                .overlay { if archive.hits.isEmpty { ContentUnavailableView.search(text: archive.searchText) } }
            } else {
                List(selection: Binding(get: { archive.selection }, set: { archive.select($0) })) {
                    ForEach(archive.conversations, id: \.self) { conversation in
                        ConversationRow(conversation: conversation)
                            .font(Theme.text)
                            .tag(ArchiveModel.ConversationKey(account: conversation.account, remoteID: conversation.remoteID))
                    }
                }
                .overlay {
                    if archive.conversations.isEmpty {
                        ContentUnavailableView(
                            "No archived conversations", systemImage: "tray",
                            description: Text("Sign in under Manage Accounts, then Sync History."))
                    }
                }
            }
        }
        .searchable(text: $archive.searchText, placement: .sidebar, prompt: "Search archive")
        .toolbar {
            Toggle(isOn: $archive.includeReasoningAndTools) { Text("Reasoning & tools").font(Theme.text) }
                .help("Also search reasoning, tool calls and tool results")
        }
    }
}

extension SearchHit: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(account.rawValue)
        hasher.combine(conversationID)
        hasher.combine(messageID)
        hasher.combine(kind)
    }
}

extension ConversationSummary: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(account.rawValue)
        hasher.combine(remoteID)
    }
}

private struct ConversationRow: View {
    let conversation: ConversationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title ?? "Untitled").font(Theme.text).lineLimit(2)
            HStack(spacing: 6) {
                Text([conversation.mode, conversation.modality].compactMap { $0 }.joined(separator: " · "))
                if conversation.latestSnapshotSequence == nil { Text("list only") }
                if conversation.snapshotCount > 1 { Text("\(conversation.snapshotCount) snapshots") }
                if conversation.isAbsent { Text("not on Arena").foregroundStyle(.orange) }
            }
            .font(Theme.caption)
            .foregroundStyle(.secondary)
            if let updated = conversation.updatedAt {
                Text(updated.prefix(16)).font(Theme.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Transcript

private struct TranscriptView: View {
    @Bindable var archive: ArchiveModel
    @Binding var showingInspector: Bool
    @AppStorage("exportFormat") private var exportFormat = ExportFormat.markdown.rawValue
    @State private var confirmExactRaw = false

    var body: some View {
        if let detail = archive.detail, let layout = archive.layout {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        header(detail)
                        if detail.messages.isEmpty {
                            Text(detail.summary.latestSnapshotSequence == nil
                                ? "Only listed on Arena; no transcript is available for this conversation type yet."
                                : "No messages in this snapshot.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(layout.turns) { turn in
                            TurnView(turn: turn, names: archive.revealedNames, highlighted: archive.highlightedMessage) {
                                archive.inspect($0)
                                showingInspector = true
                            } inspectVote: { vote in
                                archive.inspect(.init(title: "Vote \(vote.remoteID)", pointers: ["$.pairwiseFeedbacks[] (id \(vote.remoteID))"]))
                                showingInspector = true
                            }
                        }
                        if !layout.unmatchedVotes.isEmpty {
                            Text("Votes not tied to a single turn:").foregroundStyle(.secondary)
                            ForEach(layout.unmatchedVotes, id: \.remoteID) { vote in
                                Text("Vote: \(vote.value ?? "unknown") (messages \(vote.messageA ?? "?"), \(vote.messageB ?? "?"))")
                                    .font(Theme.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(22)
                    .textSelection(.enabled)
                }
                .onChange(of: archive.scrollRequest) {
                    if let target = archive.highlightedMessage {
                        withAnimation { proxy.scrollTo(target, anchor: .center) }
                    }
                }
            }
            .toolbar {
                if detail.snapshotSequences.count > 1 {
                    Picker(
                        "Snapshot",
                        selection: Binding(get: { archive.snapshotSequence }, set: { archive.selectSnapshot($0) })
                    ) {
                        Text("Latest").tag(UInt64?.none)
                        ForEach(detail.snapshotSequences, id: \.self) { Text("Record \($0)").tag(UInt64?.some($0)) }
                    }
                    .help("Each sync that found changes kept a separate snapshot")
                }
                Picker("Format", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                .help("Export format (remembered)")
                Menu {
                    Button("Export to Downloads") { Task { await archive.export(format, exactRawBodies: false, to: nil) } }
                    Button("Export to Folder…") {
                        if let folder = Self.chooseFolder() { Task { await archive.export(format, exactRawBodies: false, to: folder) } }
                    }
                    if format == .rawJSON {
                        Divider()
                        Button("Raw JSON with Exact Bodies (includes Arena telemetry)…") { confirmExactRaw = true }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                } primaryAction: {
                    Task { await archive.export(format, exactRawBodies: false, to: nil) }
                }
                .disabled(archive.exporting || detail.summary.latestSnapshotSequence == nil)
                .help("Export this snapshot as \(format.label) to Downloads")
                Button { showingInspector.toggle() } label: { Label("Evidence", systemImage: "doc.text.magnifyingglass") }
                    .help("Show the raw journal record behind this transcript")
            }
            .safeAreaInset(edge: .bottom) {
                if let result = archive.lastExport {
                    HStack {
                        Text("Exported \(result.url.lastPathComponent) · \(result.byteCount) bytes · SHA-256 \(result.sha256.prefix(12))…")
                            .font(Theme.caption).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { NSWorkspace.shared.activateFileViewerSelecting([result.url]) } label: { Text("Reveal in Finder").font(Theme.caption) }
                    }
                    .padding(8)
                    .background(.bar)
                }
            }
            .confirmationDialog(
                "Export raw bodies exactly?", isPresented: $confirmExactRaw
            ) {
                Button("Export Exact Raw JSON to Downloads") { Task { await archive.export(.rawJSON, exactRawBodies: true, to: nil) } }
            } message: {
                Text("Exact bodies include Arena's per-message metadata: bot and reCAPTCHA scores, browser-fingerprint ratios, coarse location and a hashed IP about you. The default export masks them.")
            }
        } else if archive.selection != nil {
            ProgressView()
        } else {
            ContentUnavailableView("Select a conversation", systemImage: "text.bubble")
        }
    }

    private var format: ExportFormat { ExportFormat(rawValue: exportFormat) ?? .markdown }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        return panel.runModal() == .OK ? panel.url : nil
    }

    @ViewBuilder private func header(_ detail: ConversationDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.summary.title ?? "Untitled").font(Theme.heading)
            Text([detail.summary.kind, detail.summary.mode, detail.summary.modality].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            let conversationClaims = detail.claims.filter { $0.subject == .conversation }
            if !conversationClaims.isEmpty {
                HStack {
                    Text("Model claims (each with its source; not verified identity):").foregroundStyle(.secondary)
                    Button {
                        archive.inspect(.init(title: "Model claims", pointers: ["$.revealedModels[]", "history list: $.entries[].modelAId / modelBId"]))
                        showingInspector = true
                    } label: { Image(systemName: "doc.text.magnifyingglass") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Show evidence for model claims")
                }
                ForEach(Array(conversationClaims.enumerated()), id: \.offset) { _, claim in
                    Text("  \(claim.role.map { "lane \($0.uppercased()): " } ?? "")\(claim.displayName ?? claim.modelID) — \(claim.source)")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TurnView: View {
    let turn: TranscriptLayout.Turn
    let names: [String: String]
    let highlighted: String?
    let inspect: (DetailMessage) -> Void
    let inspectVote: (ArchivedFeedback) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let prompt = turn.prompt { MessageView(message: prompt, title: "You", note: nil, highlighted: highlighted, inspect: inspect) }
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(turn.lanes.enumerated()), id: \.offset) { _, lane in
                    VStack(alignment: .leading, spacing: 8) {
                        if lane.hasAlternatives {
                            Text("\(lane.messages.count) responses in this lane (regenerations or branches), in server order")
                                .font(Theme.caption).foregroundStyle(.secondary)
                        }
                        ForEach(lane.messages, id: \.message.remoteID) { entry in
                            MessageView(
                                message: entry.message, title: laneTitle(lane.lane, entry.message),
                                note: entry.otherParents.isEmpty ? nil : "Replies to \(entry.otherParents.joined(separator: ", "))",
                                highlighted: highlighted, inspect: inspect)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            ForEach(turn.otherRoles, id: \.remoteID) { message in
                MessageView(message: message, title: "Role: \(message.role ?? "not stated")", note: nil, highlighted: highlighted, inspect: inspect)
            }
            ForEach(turn.votes, id: \.remoteID) { vote in
                HStack {
                    Text("Your vote: \(vote.value ?? "unknown")").font(Theme.caption).foregroundStyle(.secondary)
                    Button { inspectVote(vote) } label: { Image(systemName: "doc.text.magnifyingglass") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Show evidence for this vote")
                }
            }
        }
    }

    private func laneTitle(_ lane: String?, _ message: DetailMessage) -> String {
        let model = message.modelRemoteID.map { names[$0] ?? $0 }
        return (lane.map { "Lane \($0.uppercased())" } ?? "Response (lane not exposed)") + (model.map { " · \($0)" } ?? "")
    }
}

private struct MessageView: View {
    let message: DetailMessage
    let title: String
    let note: String?
    let highlighted: String?
    let inspect: (DetailMessage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).fontWeight(.bold)
                if let status = message.status, status != "success" { Text("[\(status)]").foregroundStyle(.orange) }
                Spacer()
                Button { inspect(message) } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show raw evidence for this message")
                    .accessibilityLabel("Show raw evidence")
            }
            if let note { Text(note).font(Theme.caption).foregroundStyle(.secondary) }
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                Text("Attachment: \(attachment.name ?? "unnamed") \(attachment.contentType.map { "(\($0))" } ?? "")")
                    .font(Theme.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 4).fill(message.remoteID == highlighted ? Color.yellow.opacity(0.15) : Color.secondary.opacity(0.07)))
        .overlay(alignment: .leading) {
            if message.remoteID == highlighted { Text("▶").font(Theme.caption).offset(x: -14).accessibilityLabel("Search match") }
        }
        .id(message.remoteID)
    }
}

private struct BlockView: View {
    let block: DetailBlock

    var body: some View {
        switch block.kind {
        case .text:
            Text(Self.markdown(block.text ?? ""))
        case .reasoning:
            DisclosureGroup("Reasoning") { Text(block.text ?? "").foregroundStyle(.secondary) }
        case .toolCall:
            DisclosureGroup("Tool call · \(block.toolName ?? "unknown")") { payload }
        case .toolResult:
            DisclosureGroup("Tool result · \(block.toolName ?? block.toolCallID ?? "")") { payload }
        case .sources:
            DisclosureGroup("Sources") { payload }
        case .opaque:
            DisclosureGroup("Unrecognized block (kept as-is)") { payload }
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

// MARK: - Evidence inspector

private struct EvidenceInspector: View {
    @Bindable var archive: ArchiveModel
    @State private var showBody = false
    @State private var hex = false
    private static let textLimit = 262_144
    private static let hexLimit = 65_536

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Evidence").font(Theme.heading)
                if let target = archive.inspected {
                    Text(target.title).textSelection(.enabled)
                    ForEach(target.pointers, id: \.self) { Text($0).font(Theme.caption).foregroundStyle(.secondary) }
                } else {
                    Text("Choose an evidence button on a message, vote or claim.").foregroundStyle(.secondary)
                }
                if archive.inspected != nil && archive.evidenceUnavailable {
                    Text("The raw record for this snapshot is unavailable.").foregroundStyle(.orange)
                }
                if let evidence = archive.evidence {
                    Divider()
                    Text("Journal record \(evidence.location.sequence) · segment \(evidence.location.segment) · offset \(evidence.location.offset) · \(evidence.location.length) bytes")
                    Text("SHA-256 \(evidence.digest)").font(Theme.caption).textSelection(.enabled)
                    Text("Digest verified on read · current decoder \(evidence.decoderVersion)").font(Theme.caption).foregroundStyle(.secondary)
                    Text("Envelope").fontWeight(.bold)
                    Text("Reformatted for display; the digest covers the stored bytes.").font(Theme.caption).foregroundStyle(.secondary)
                    Text(Self.pretty(evidence.envelope)).font(Theme.caption).textSelection(.enabled)
                    Toggle(isOn: $showBody) { Text("Show raw body (\(evidence.payload.count) bytes)").font(Theme.text) }
                    if showBody {
                        Text("The raw body includes Arena's per-message metadata (anti-abuse telemetry about you). It is shown here only on request and never indexed or exported by default.")
                            .font(Theme.caption).foregroundStyle(.orange)
                        Toggle(isOn: $hex) { Text("Hex").font(Theme.text) }
                        let limit = hex ? Self.hexLimit : Self.textLimit
                        if evidence.payload.count > limit {
                            Text("Showing the first \(limit) of \(evidence.payload.count) bytes.").font(Theme.caption).foregroundStyle(.orange)
                        }
                        Text(hex ? Self.hex(evidence.payload.prefix(limit)) : String(decoding: evidence.payload.prefix(limit), as: UTF8.self))
                            .font(Theme.caption).textSelection(.enabled)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .departureMono()
        .onChange(of: archive.inspected) { showBody = false }
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
