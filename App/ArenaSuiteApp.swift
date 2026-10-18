import AppKit
import ApplicationActions
import SuiteDomain
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
    @State private var profiles: ArenaWebProfiles

    init() {
        Theme.registerFonts()
        let services = AppComposition.makeServices()
        let archive = ArchiveModel(archive: services.archive, unavailableReason: services.archiveUnavailable)
        let accounts = AccountsModel(services: services, archiveRoot: AppComposition.archiveRoot)
        accounts.onSyncFinished = { [archive] _ in await archive.projectAll(accounts.accounts.map(\.id)) }
        let profiles = ArenaWebProfiles(policy: services.website)
        accounts.onAccountRemoved = { [profiles] id in await profiles.lifecycle.accountRemoved(id) }
        _profiles = State(initialValue: profiles)
        _accounts = State(initialValue: accounts)
        _archive = State(initialValue: archive)
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
            MainView(accounts: accounts, archive: archive, maintenance: maintenance, profiles: profiles)
                .frame(minWidth: 1200, minHeight: 600)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // The embedded site window, one per account (ADR 0006).
        WindowGroup(id: ArenaWebWindow.id, for: AccountID.self) { $account in
            ArenaWebWindow(accountID: account, accounts: accounts, profiles: profiles)
                .departureMono()
        }
        .defaultSize(width: 1280, height: 900)
    }
}
