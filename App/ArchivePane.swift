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
        .confirmationDialog("Export raw bodies exactly?", isPresented: $confirmExactRaw) {
            Button("Export Exact Raw JSON to Downloads") { Task { await archive.export(.rawJSON, exactRawBodies: true, to: nil) } }
        } message: {
            Text("Exact bodies include Arena's per-message metadata: bot and reCAPTCHA scores, browser-fingerprint ratios, coarse location and a hashed IP about you. The default export masks them.")
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

    private func exportMenu(_ detail: ConversationDetail) -> some View {
        Menu {
            Section("Export to Downloads") {
                ForEach(ExportFormat.allCases, id: \.rawValue) { format in
                    Button(format.label) { Task { await archive.export(format, exactRawBodies: false, to: nil) } }
                }
            }
            Menu("Export to Folder") {
                ForEach(ExportFormat.allCases, id: \.rawValue) { format in
                    Button("\(format.label)…") {
                        if let folder = Self.chooseFolder() { Task { await archive.export(format, exactRawBodies: false, to: folder) } }
                    }
                }
            }
            Divider()
            Button("Raw JSON with Exact Bodies (includes Arena telemetry)…") { confirmExactRaw = true }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(.arenaIcon)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(archive.exporting || detail.summary.latestSnapshotSequence == nil)
        .help("Export this snapshot")
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
            Text("Choose one in the sidebar, search with ⌘F, or open \(siteName) there.")
                .font(Theme.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var exportNotice: some View {
        if let result = archive.lastExport {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                Text("Exported \(result.url.lastPathComponent) · \(result.byteCount) bytes · SHA-256 \(result.sha256.prefix(12))…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                    .buttonStyle(.arenaPill)
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
                        TurnView(turn: turn, names: archive.revealedNames, highlighted: archive.highlightedMessage) {
                            archive.inspect($0)
                            showInspector()
                        } inspectVote: { vote in
                            archive.inspect(.init(title: "Vote \(vote.remoteID)", pointers: ["$.pairwiseFeedbacks[] (id \(vote.remoteID))"]))
                            showInspector()
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
        if !claims.isEmpty || detail.messages.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
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
                        ? "Only listed on Arena; no transcript is available for this conversation type yet."
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
    let highlighted: String?
    let inspect: (DetailMessage) -> Void
    let inspectVote: (ArchivedFeedback) -> Void

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
                                message: entry.message, lane: lane.lane, title: laneTitle(lane.lane, entry.message),
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
                HStack(spacing: 6) {
                    Text("Your vote: \(vote.value ?? "unknown")").foregroundStyle(.secondary)
                    Button { inspectVote(vote) } label: {
                        Label("Show evidence for this vote", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.arenaIcon(width: 22, height: 20))
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.sunken.opacity(0.6)))
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func laneTitle(_ lane: String?, _ message: DetailMessage) -> String {
        if let model = message.modelRemoteID.map({ names[$0] ?? $0 }) { return model }
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
    let title: String
    let note: String?
    let highlighted: Bool
    let inspect: (DetailMessage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                LaneBadge(lane: lane)
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
            Label("\(attachment.name ?? "unnamed") \(attachment.contentType.map { "(\($0))" } ?? "")", systemImage: "paperclip")
                .font(Theme.caption).foregroundStyle(.secondary)
        }
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
