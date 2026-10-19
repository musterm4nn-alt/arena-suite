import ApplicationActions
import ArchiveIndex
import SuiteDomain
import SwiftUI

/// What both sidebar forms act on. The account switcher at the bottom chooses the scope: one
/// account or all of them. The site entry, Sync History and the history list follow it.
@MainActor
struct SidebarScope {
    let accounts: AccountsModel
    let archive: ArchiveModel

    var chosen: AccountSummary? { archive.accountFilter.flatMap { id in accounts.accounts.first { $0.id == id } } }
    var members: [AccountSummary] { chosen.map { [$0] } ?? accounts.accounts }
    var name: String { chosen?.displayName ?? "All accounts" }
    var initial: String? { chosen.map { String($0.displayName.prefix(1)).uppercased() } }

    /// The account the site entry opens directly, or nil when the user has to pick one.
    var siteAccount: AccountID? { members.count == 1 ? members[0].id : nil }

    /// Every running sync, in scope or not: narrowing the scope must not hide a running job or its
    /// Stop. Starting stays scoped.
    var syncing: [AccountID] { accounts.accounts.map(\.id).filter { accounts.syncing[$0] != nil } }
    var syncable: [AccountID] { members.filter { $0.state == .signedIn }.map(\.id) }

    /// User-started sync of every signed-in account in scope: one job per account, as when each is
    /// started by hand (plan v3 §2 keeps one request in flight per account).
    func startSync() {
        for id in syncable where accounts.syncing[id] == nil { Task { await accounts.syncHistory(id) } }
    }

    func stopSync() {
        for id in syncing { Task { await accounts.cancelSync(id) } }
    }

    /// Why syncs failed, per account (kept until dismissed or that account syncs successfully).
    var errors: [ProgressLine] {
        accounts.accounts.compactMap { account in
            accounts.syncErrors[account.id].map { ProgressLine(id: account.id, name: account.displayName, text: $0) }
        }
    }

    /// The first message to show where there is room for one line (the rail).
    var firstMessage: String? {
        archive.message ?? accounts.message ?? errors.first.map { "\($0.name): \($0.text)" }
    }

    var syncHelp: String {
        let target = chosen == nil ? "every signed-in account" : "this account"
        let last = members.compactMap { account in
            accounts.lastSync[account.id].map { manifest in
                let time = accounts.lastSyncAt[account.id].map { " (\($0.formatted(date: .omitted, time: .shortened)))" } ?? ""
                return "\(account.displayName)\(time): \(AccountsView.describe(manifest))"
            }
        }
        return (["Archive the Arena history of \(target) into the local archive."] + last).joined(separator: "\n")
    }

    struct ProgressLine: Identifiable {
        let id: AccountID
        let name: String
        let text: String
    }

    /// Progress lines for every account that is syncing.
    var progress: [ProgressLine] {
        accounts.accounts.compactMap { account in
            accounts.syncing[account.id].map { ProgressLine(id: account.id, name: account.displayName, text: AccountsView.describe($0)) }
        }
    }

    var scopeBindings: (all: Binding<Bool>, account: (AccountID) -> Binding<Bool>) {
        let archive = archive
        return (
            Binding(get: { archive.accountFilter == nil }, set: { if $0 { archive.accountFilter = nil } }),
            { id in Binding(get: { archive.accountFilter == id }, set: { if $0 { archive.accountFilter = id } }) }
        )
    }
}

/// Switches the sidebar between full and rail (Control-Command-S, as for a sidebar).
struct SidebarToggle: View {
    let collapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(collapsed ? "Show Sidebar" : "Collapse Sidebar", systemImage: "sidebar.left")
        }
        .buttonStyle(.arenaIcon(width: 30, height: 26))
        .keyboardShortcut("s", modifiers: [.control, .command])
        .help(collapsed ? "Show Sidebar (⌃⌘S)" : "Collapse Sidebar (⌃⌘S)")
    }
}

// MARK: - Full sidebar

struct SidebarView: View {
    @Bindable var accounts: AccountsModel
    @Bindable var archive: ArchiveModel
    let profiles: ArenaWebProfiles
    @Binding var destination: MainDestination
    @Binding var searching: Bool
    let openSite: (AccountID) -> Void
    let collapse: () -> Void
    @FocusState private var searchFocused: Bool

    private var scope: SidebarScope { SidebarScope(accounts: accounts, archive: archive) }
    private var showsResults: Bool { searching && !archive.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            // The window buttons sit in this band, at its leading end.
            HStack {
                Spacer()
                SidebarToggle(collapsed: false, action: collapse)
            }
            .padding(.trailing, 8)
            .frame(height: Theme.barHeight)
            VStack(spacing: 1) {
                siteRow
                searchRow
                syncRow
                insightsRow
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            if searching {
                searchField.padding(.horizontal, 12).padding(.top, 8)
            }
            if showsResults {
                SearchResultsList(archive: archive) { hit in
                    archive.open(hit)
                    destination = .archive
                }
            } else {
                HistoryList(archive: archive, destination: $destination)
            }
            SidebarStatus(accounts: accounts, archive: archive, destination: $destination)
            Theme.border.frame(height: 1)
            AccountSwitcher(accounts: accounts, archive: archive, destination: $destination, compact: false)
            .padding(8)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.background)
        .font(Theme.text)
        .onAppear { if searching { searchFocused = true } }
        .onChange(of: searching) { _, now in if now { searchFocused = true } }
    }

    /// Shows the site in an account's web profile, opening its session on the first click.
    @ViewBuilder private var siteRow: some View {
        let selected = { if case .site = destination { true } else { false } }()
        let open = scope.members.contains { profiles.sessions[$0.id] != nil }
        let label = HStack(spacing: 10) {
            Image(systemName: "globe").frame(width: 18)
            Text(profiles.siteName)
            Spacer(minLength: 0)
            if open && !selected { Circle().fill(Theme.primaryText).frame(width: 5, height: 5).accessibilityLabel("open") }
        }
        if let account = scope.siteAccount {
            Button { openSite(account) } label: { label }
                .buttonStyle(.arenaRow(selected: selected))
                .help("Use \(profiles.siteName) here with \(scope.members[0].displayName)'s own web profile")
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            Menu {
                ForEach(scope.members) { account in
                    Button(account.displayName + (profiles.sessions[account.id] != nil ? " (open)" : "")) { openSite(account.id) }
                }
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.arenaRow(selected: selected))
            .menuIndicator(.hidden)
            .disabled(scope.members.isEmpty)
            .help(scope.members.isEmpty
                ? "Add an account under Manage Accounts first"
                : "Use \(profiles.siteName) here with one account's own web profile")
        }
    }

    private var searchRow: some View {
        Button {
            searching = true
            searchFocused = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").frame(width: 18)
                Text("Search")
                Spacer(minLength: 0)
                Text("⌘F").font(Theme.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.arenaRow)
        .keyboardShortcut("f", modifiers: .command)
        .help("Search the archive offline")
    }

    @ViewBuilder private var syncRow: some View {
        let syncing = !scope.syncing.isEmpty
        Button {
            if syncing { scope.stopSync() } else { scope.startSync() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: syncing ? "stop.circle" : "arrow.triangle.2.circlepath").frame(width: 18)
                Text(syncing ? "Stop Sync" : "Sync History")
                Spacer(minLength: 0)
                if syncing { ProgressView().controlSize(.mini) }
            }
        }
        .buttonStyle(.arenaRow)
        .disabled(!syncing && scope.syncable.isEmpty)
        .help(scope.syncable.isEmpty && !syncing ? "Sign an account in under Manage Accounts to archive it" : scope.syncHelp)
    }

    private var insightsRow: some View {
        Button { destination = .insights } label: {
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.xaxis").frame(width: 18)
                Text("Insights")
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.arenaRow(selected: destination == .insights))
        .help("Your archive at a glance: activity, modes and your votes")
        .accessibilityAddTraits(destination == .insights ? .isSelected : [])
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArenaField(symbol: "magnifyingglass") {
                TextField("Search archive", text: $archive.searchText)
                    .focused($searchFocused)
                    .onExitCommand(perform: closeSearch)
                Button(action: closeSearch) { Label("Close Search", systemImage: "xmark.circle.fill") }
                    .buttonStyle(.arenaIcon(width: 18, height: 18))
                    .help("Close search (Esc)")
            }
            Toggle(isOn: $archive.includeReasoningAndTools) {
                Text("Include reasoning & tools").font(Theme.caption)
            }
            .toggleStyle(.checkbox)
            .help("Also search reasoning, tool calls and tool results")
        }
    }

    private func closeSearch() {
        archive.searchText = ""
        searching = false
    }
}

// MARK: - Rail

/// The collapsed sidebar, like the site's: the same entries as icons, and the account switcher at
/// the bottom. Every icon has a tooltip and an accessibility label.
struct SidebarRail: View {
    @Bindable var accounts: AccountsModel
    @Bindable var archive: ArchiveModel
    let profiles: ArenaWebProfiles
    @Binding var destination: MainDestination
    @Binding var searching: Bool
    let openSite: (AccountID) -> Void
    let expand: () -> Void

    private var scope: SidebarScope { SidebarScope(accounts: accounts, archive: archive) }

    var body: some View {
        VStack(spacing: 6) {
            // The window buttons sit in this band; they are wider than the rail.
            Color.clear.frame(height: Theme.barHeight)
            SidebarToggle(collapsed: true, action: expand)
            siteIcon.padding(.top, 6)
            Button {
                searching = true
                expand()
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .buttonStyle(.arenaIcon(width: 36, height: 32))
            .keyboardShortcut("f", modifiers: .command)
            .help("Search the archive (⌘F)")
            syncIcon
            Button { destination = .insights } label: {
                Label("Insights", systemImage: "chart.bar.xaxis")
            }
            .buttonStyle(.arenaIcon(width: 36, height: 32, selected: destination == .insights))
            .help("Insights: activity, modes and your votes")
            .accessibilityAddTraits(destination == .insights ? .isSelected : [])
            Spacer()
            // The full sidebar's message line, which the rail has no room for.
            if let message = scope.firstMessage {
                Button(action: expand) { Label(message, systemImage: "exclamationmark.triangle") }
                    .buttonStyle(.arenaIcon(width: 36, height: 32))
                    .foregroundStyle(.red)
                    .help(message)
            }
            AccountSwitcher(accounts: accounts, archive: archive, destination: $destination, compact: true)
        }
        .padding(.bottom, 10)
        .frame(width: Theme.railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
    }

    @ViewBuilder private var siteIcon: some View {
        let selected = { if case .site = destination { true } else { false } }()
        let open = scope.members.contains { profiles.sessions[$0.id] != nil }
        let label = Label(profiles.siteName, systemImage: "globe")
            .overlay(alignment: .topTrailing) {
                if open && !selected { Circle().fill(Theme.primaryText).frame(width: 5, height: 5).offset(x: 6, y: -4) }
            }
        if let account = scope.siteAccount {
            Button { openSite(account) } label: { label }
                .buttonStyle(.arenaIcon(width: 36, height: 32, selected: selected))
                .help("\(profiles.siteName) · \(scope.members[0].displayName)" + (open && !selected ? " (open)" : ""))
                .accessibilityValue(open && !selected ? "open" : "")
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            Menu {
                ForEach(scope.members) { account in
                    Button(account.displayName + (profiles.sessions[account.id] != nil ? " (open)" : "")) { openSite(account.id) }
                }
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.arenaIcon(width: 36, height: 32, selected: selected))
            .menuIndicator(.hidden)
            .disabled(scope.members.isEmpty)
            .help("\(profiles.siteName): choose an account" + (open && !selected ? " (one is open)" : ""))
            .accessibilityValue(open && !selected ? "open" : "")
        }
    }

    @ViewBuilder private var syncIcon: some View {
        let syncing = !scope.syncing.isEmpty
        Button {
            if syncing { scope.stopSync() } else { scope.startSync() }
        } label: {
            Label(syncing ? "Stop Sync" : "Sync History", systemImage: syncing ? "stop.circle" : "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.arenaIcon(width: 36, height: 32))
        .disabled(!syncing && scope.syncable.isEmpty)
        .help(syncing ? (["Stop Sync"] + scope.progress.map { "\($0.name): \($0.text)" }).joined(separator: "\n") : scope.syncHelp)
    }
}

// MARK: - Account switcher

/// The bottom of the sidebar, like the site's account row: which accounts the archive shows, and
/// the Accounts and Maintenance pages.
private struct AccountSwitcher: View {
    @Bindable var accounts: AccountsModel
    @Bindable var archive: ArchiveModel
    @Binding var destination: MainDestination
    let compact: Bool

    private var scope: SidebarScope { SidebarScope(accounts: accounts, archive: archive) }

    var body: some View {
        // Two styles rather than one wrapped style: menus ignore a type-erased button style.
        if compact {
            menu.buttonStyle(.arenaIcon(width: 40, height: 36))
        } else {
            menu.buttonStyle(.arenaRow)
        }
    }

    private var menu: some View {
        let bindings = scope.scopeBindings
        return Menu {
            Toggle("All accounts", isOn: bindings.all)
            ForEach(accounts.accounts) { account in
                Toggle(isOn: bindings.account(account.id)) {
                    Text(account.displayName + (account.state == .signedIn ? "" : " — \(AccountsView.label(account.state))"))
                }
            }
            Divider()
            Button("Manage Accounts") { destination = .accounts }
            Button("Maintenance") { destination = .maintenance }
        } label: {
            if compact {
                AccountBadge(text: scope.initial, active: !scope.syncing.isEmpty)
            } else {
                HStack(spacing: 10) {
                    AccountBadge(text: scope.initial, size: 28, active: !scope.syncing.isEmpty)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(scope.name).lineLimit(1)
                        Text("\(archive.conversations.count) conversations").font(Theme.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small).foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .help("\(scope.name) · choose the accounts shown, or manage accounts")
        .accessibilityLabel("Accounts: \(scope.name)")
    }
}

// MARK: - Status

/// Sync progress, index updates, decoder attention and errors, above the account switcher.
private struct SidebarStatus: View {
    @Bindable var accounts: AccountsModel
    @Bindable var archive: ArchiveModel
    @Binding var destination: MainDestination

    var body: some View {
        let scope = SidebarScope(accounts: accounts, archive: archive)
        let progress = scope.progress
        let errors = scope.errors
        let message = archive.message ?? accounts.message
        let attention = archive.problems.warnings > 0 || archive.problems.unknownPaths > 0
        if archive.projecting || !progress.isEmpty || message != nil || !errors.isEmpty || attention {
            VStack(alignment: .leading, spacing: 6) {
                if archive.projecting {
                    Text("Updating index…").foregroundStyle(.secondary)
                }
                ForEach(progress) { line in
                    Text("\(line.name): \(line.text)").foregroundStyle(.secondary).lineLimit(2)
                }
                if attention {
                    Text("\(archive.problems.warnings) decoder warning(s), \(archive.problems.unknownPaths) unknown field path(s). Raw evidence is kept.")
                        .foregroundStyle(.orange)
                }
                if message != nil || !errors.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let message { Text(message).foregroundStyle(.red) }
                            ForEach(errors) { line in
                                Text("\(line.name): \(line.text)").foregroundStyle(.red)
                                recovery(line.id)
                            }
                        }
                        .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            archive.message = nil
                            accounts.dismissErrors()
                        } label: {
                            Label("Dismiss", systemImage: "xmark")
                        }
                        .buttonStyle(.arenaIcon(width: 18, height: 18))
                    }
                }
            }
            .font(Theme.caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The next step for an account whose last sync failed: sign in when the session is gone,
    /// check it again when Arena refused or could not be reached, otherwise sync again.
    @ViewBuilder private func recovery(_ id: AccountID) -> some View {
        if let account = accounts.accounts.first(where: { $0.id == id }), accounts.syncing[id] == nil,
            !accounts.working.contains(id)
        {
            switch account.state {
            case .needsSignIn, .quarantined:
                Button("Sign In…") {
                    accounts.pendingSignIn = id
                    destination = .accounts
                }
                .buttonStyle(.arenaPill)
            case .blocked, .unreachable:
                Button("Verify") { Task { await accounts.verify(id) } }.buttonStyle(.arenaPill)
            case .signedIn:
                Button("Sync Again") { Task { await accounts.syncHistory(id) } }.buttonStyle(.arenaPill)
            case .unverified:
                EmptyView()
            }
        }
    }
}

// MARK: - History

/// The archived conversations, newest first, grouped by date like the site's history.
private struct HistoryList: View {
    @Bindable var archive: ArchiveModel
    @Binding var destination: MainDestination
    @FocusState private var focused: Bool

    private static func key(_ conversation: ConversationSummary) -> ArchiveModel.ConversationKey {
        .init(account: conversation.account, remoteID: conversation.remoteID)
    }

    var body: some View {
        let groups = HistoryGroup.group(archive.conversations)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(groups) { group in
                        Text(group.title)
                            .font(Theme.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.conversations, id: \.self) { conversation in
                            row(conversation)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.automatic)
            // Drawn here rather than with List selection, which always uses the system accent.
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { step(1, proxy) }
            .onKeyPress(.upArrow) { step(-1, proxy) }
        }
        .overlay {
            if archive.conversations.isEmpty {
                VStack(spacing: 6) {
                    Text("No archived conversations")
                    Text("Add an account from the account menu below, then Sync History.")
                        .font(Theme.caption).foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .padding(20)
            }
        }
    }

    private func row(_ conversation: ConversationSummary) -> some View {
        let key = Self.key(conversation)
        let selected = destination == .archive && archive.selection == key
        return Button {
            archive.select(key)
            destination = .archive
            focused = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(conversation))
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(conversation.title ?? "Untitled")
                    .lineLimit(1)
                    .foregroundStyle(conversation.latestSnapshotSequence == nil ? .secondary : .primary)
                Spacer(minLength: 0)
                if conversation.isAbsent {
                    Image(systemName: "icloud.slash").imageScale(.small).foregroundStyle(.orange)
                }
            }
        }
        .buttonStyle(.arenaRow(selected: selected))
        .help(Self.details(conversation))
        .accessibilityLabel(Self.details(conversation).replacingOccurrences(of: "\n", with: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .id(key)
    }

    /// Up and down arrows move the selection, as in a list.
    private func step(_ offset: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let keys = archive.conversations.map(Self.key)
        guard !keys.isEmpty else { return .ignored }
        let current = archive.selection.flatMap { keys.firstIndex(of: $0) }
        let index = current.map { min(max($0 + offset, 0), keys.count - 1) } ?? (offset > 0 ? 0 : keys.count - 1)
        archive.select(keys[index])
        destination = .archive
        proxy.scrollTo(keys[index])
        return .handled
    }

    /// The site marks entries by modality; battles and direct chats share the chat symbol.
    static func symbol(_ conversation: ConversationSummary) -> String {
        switch conversation.modality?.lowercased() {
        case "webdev": "chevron.left.forwardslash.chevron.right"
        case "image": "photo"
        case "video": "film"
        case "search": "magnifyingglass"
        case "agentic": "gearshape.2"
        default: conversation.mode?.lowercased().contains("battle") == true ? "rectangle.split.2x1" : "bubble.left"
        }
    }

    static func details(_ conversation: ConversationSummary) -> String {
        var lines = [conversation.title ?? "Untitled"]
        let kind = [conversation.mode, conversation.modality].compactMap { $0 }.joined(separator: " · ")
        if !kind.isEmpty { lines.append(kind) }
        if let updated = HistoryGroup.display(conversation) { lines.append(updated) }
        if conversation.latestSnapshotSequence == nil { lines.append("List only: no transcript archived") }
        if conversation.snapshotCount > 1 { lines.append("\(conversation.snapshotCount) snapshots") }
        if conversation.isAbsent { lines.append("No longer on Arena") }
        return lines.joined(separator: "\n")
    }
}

/// One date section of the history.
struct HistoryGroup: Identifiable {
    let title: String
    var conversations: [ConversationSummary]
    var id: String { title }

    /// Groups in list order (newest first). Dates come from the instant the decoder parsed, the
    /// key the list is sorted by; a conversation without one goes last, under "Undated", rather
    /// than being parsed again here.
    @MainActor static func group(_ conversations: [ConversationSummary], now: Date = Date(), calendar: Calendar = .current) -> [HistoryGroup] {
        var groups: [HistoryGroup] = []
        var undated: [ConversationSummary] = []
        for conversation in conversations {
            guard let date = date(conversation) else {
                undated.append(conversation)
                continue
            }
            let title = section(date, now: now, calendar: calendar)
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].conversations.append(conversation)
            } else {
                groups.append(HistoryGroup(title: title, conversations: [conversation]))
            }
        }
        if !undated.isEmpty { groups.append(HistoryGroup(title: "Undated", conversations: undated)) }
        return groups
    }

    static func date(_ conversation: ConversationSummary) -> Date? {
        conversation.updatedOrder.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000_000) }
    }

    /// Relative sections for the past month, then months. A date after `now` (clock skew) gets its
    /// month, never "Today".
    @MainActor static func section(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2..<7: return "Previous 7 Days"
        case 7..<30: return "Previous 30 Days"
        default:
            monthFormatter.calendar = calendar
            monthFormatter.timeZone = calendar.timeZone
            return monthFormatter.string(from: date)
        }
    }

    /// One formatter for every month heading (the history is grouped on each redraw).
    @MainActor private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter
    }()

    /// Local date and time for display, or Arena's text when the decoder could not parse it.
    static func display(_ conversation: ConversationSummary) -> String? {
        date(conversation).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? conversation.updatedAt
    }
}

// MARK: - Search results

private struct SearchResultsList: View {
    @Bindable var archive: ArchiveModel
    let open: (SearchHit) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !archive.hits.isEmpty {
                    Text(archive.hits.count == 200 ? "First 200 matches" : "\(archive.hits.count) match(es)")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }
                ForEach(archive.hits, id: \.self) { hit in
                    Button { open(hit) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.title ?? "Untitled").lineLimit(1)
                            Text(hit.snippet).font(Theme.caption).foregroundStyle(.secondary).lineLimit(3)
                            Text(hit.kind).font(Theme.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.arenaRow)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .frame(maxHeight: .infinity)
        .overlay {
            if archive.hits.isEmpty {
                Text("No matches for “\(archive.searchText)”").foregroundStyle(.secondary).multilineTextAlignment(.center).padding(20)
            }
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
