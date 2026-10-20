import AppKit
import ApplicationActions
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct ArenaSuiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var accounts: AccountsModel
    @State private var archive: ArchiveModel
    @State private var maintenance: MaintenanceModel
    @State private var insights: InsightsModel
    @State private var profiles: ArenaWebProfiles

    init() {
        Theme.registerFonts()
        let services = AppComposition.makeServices()
        let archive = ArchiveModel(archive: services.archive, notes: services.notes, unavailableReason: services.archiveUnavailable)
        let accounts = AccountsModel(services: services, archiveRoot: AppComposition.archiveRoot)
        // One index update after the last of several concurrent syncs, not one per finished job.
        accounts.onSyncFinished = { [archive] _ in
            guard !accounts.isSyncing else { return }
            await archive.projectAll(accounts.accounts.map(\.id))
        }
        let profiles = ArenaWebProfiles(policy: services.website)
        accounts.onAccountRemoved = { [profiles] id in await profiles.accountRemoved(id) }
        _profiles = State(initialValue: profiles)
        _accounts = State(initialValue: accounts)
        _archive = State(initialValue: archive)
        _insights = State(initialValue: InsightsModel(service: services.insights))
        let index = services.archive
        _maintenance = State(
            initialValue: MaintenanceModel(
                services: services.maintenance, accounts: accounts, archive: archive,
                rebuildIndex: {
                    guard let index else { throw BackupError.io("the archive index is unavailable") }
                    try await index.rebuild()
                }))
    }

    var body: some Scene {
        WindowGroup("Arena Suite") {
            MainView(accounts: accounts, archive: archive, maintenance: maintenance, insights: insights, profiles: profiles)
                .frame(minWidth: 1040, minHeight: 600)
        }
        // No title bar or toolbar: the panes draw their own header bars (Theme.barHeight).
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
