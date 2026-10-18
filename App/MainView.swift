import AppKit
import ApplicationActions
import ArchiveIndex
import SuiteDomain
import SwiftUI

/// What the window shows beside the sidebar.
enum MainDestination: Hashable {
    /// Conversation list with search · transcript, with the raw-evidence inspector.
    case archive
    /// The site in this account's web profile (ADR 0006).
    case site(AccountID)
    /// Accounts: add, sign in, verify, sync, remove.
    case accounts
    /// Verify, back up, restore, diagnostics and datasets.
    case maintenance

    var isSite: Bool { if case .site = self { true } else { false } }
}

/// The one app window, laid out like the site: a sidebar (site entry, search, sync, the history by
/// date and the account switcher) beside the archive or the site. It has no title bar or toolbar;
/// each pane draws its own header bar in the window's top band. Launch always shows the archive;
/// the site loads only when the user opens it.
struct MainView: View {
    @Bindable var accounts: AccountsModel
    @Bindable var archive: ArchiveModel
    let maintenance: MaintenanceModel
    let profiles: ArenaWebProfiles
    @State private var destination = MainDestination.archive
    /// The sidebar as an icon rail (like the site's collapsed sidebar). The archive remembers the
    /// user's choice; opening the site always starts with the rail, to give the page the room.
    @AppStorage("sidebarRailInArchive") private var archiveRail = false
    @State private var siteRail = true
    @State private var searching = false
    @State private var showingInspector = false

    // Laid out here rather than with NavigationSplitView: its sidebar cannot switch reliably
    // between full width and a rail (it restores a saved width and grows the window when shown).
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Theme.border.frame(width: 1)
            Group {
                switch destination {
                case .archive:
                    ArchivePane(archive: archive, accounts: accounts, siteName: profiles.siteName, showingInspector: $showingInspector)
                case .site(let account):
                    ArenaWebPane(accountID: account, accounts: accounts, profiles: profiles, open: openSite).id(account)
                case .accounts:
                    AccountsView(model: accounts)
                case .maintenance:
                    MaintenanceView(model: maintenance, accounts: accounts)
                }
            }
            // With the rail, the window buttons reach past the sidebar into the header bar.
            .environment(\.headerLeadingInset, rail ? max(0, Theme.windowButtonsWidth - Theme.railWidth - 1) : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .ignoresSafeArea()
        .arenaPalette()
        .departureMono()
        .onChange(of: accounts.accounts.map(\.id)) { _, ids in
            if case .site(let account) = destination, !ids.contains(account) { destination = .archive }
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
                searching = true
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
            // `--preview-site-closed` (or `--preview-site-header`) shows the first account's site pane
            // without opening its session: nothing is loaded.
            if arguments.contains("--preview-site-closed") || arguments.contains("--preview-site-header"),
                let first = accounts.accounts.first
            {
                destination = .site(first.id)
            }
            if arguments.contains("--preview-accounts") { destination = .accounts }
            if arguments.contains("--preview-maintenance") {
                destination = .maintenance
                await maintenance.verify()
            }
            if arguments.contains("--validate-dataset") {
                destination = .maintenance
                await maintenance.validateDataset()
            }
            #endif
        }
    }

    private var rail: Bool { destination.isSite ? siteRail : archiveRail }

    private func setRail(_ value: Bool) {
        if destination.isSite { siteRail = value } else { archiveRail = value }
    }

    /// The user's click on an account's site entry: shows the site with the sidebar as a rail.
    private func openSite(_ account: AccountID) {
        profiles.open(account)
        siteRail = true
        destination = .site(account)
    }

    /// Full sidebar or rail; its own button (or Control-Command-S) switches between them.
    @ViewBuilder private var sidebar: some View {
        if rail {
            SidebarRail(
                accounts: accounts, archive: archive, profiles: profiles, destination: $destination,
                searching: $searching, openSite: openSite
            ) { setRail(false) }
        } else {
            SidebarView(
                accounts: accounts, archive: archive, profiles: profiles, destination: $destination,
                searching: $searching, openSite: openSite
            ) { setRail(true) }
            .frame(width: Theme.sidebarWidth)
        }
    }
}
