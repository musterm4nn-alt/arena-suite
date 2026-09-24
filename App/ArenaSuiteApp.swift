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

    init() {
        Theme.registerFonts()
        let services = AppComposition.makeServices()
        let archive = ArchiveModel(archive: services.archive, unavailableReason: services.archiveUnavailable)
        let accounts = AccountsModel(services: services, archiveRoot: AppComposition.archiveRoot)
        accounts.onSyncFinished = { [archive] _ in await archive.projectAll(accounts.accounts.map(\.id)) }
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
            MainView(accounts: accounts, archive: archive, maintenance: maintenance)
                .frame(minWidth: 1200, minHeight: 600)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
