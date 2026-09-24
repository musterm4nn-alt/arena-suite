import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct ArenaSuiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var accounts = AccountsModel(
        services: AppComposition.makeServices(), archiveRoot: AppComposition.archiveRoot)

    var body: some Scene {
        WindowGroup("Arena Suite") {
            AccountsView(model: accounts)
        }
    }
}
