import AppKit
import ApplicationActions
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct ArenaSuiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let engine = ArenaSuiteEngine()
    @State private var summary = "Checking Phase 0 status…"

    var body: some Scene {
        WindowGroup("Arena Suite — Phase 0") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Arena Suite").font(.title)
                Text(summary)
                Text("Offline foundation · no Arena connection configured")
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(minWidth: 460, minHeight: 180)
            .task { summary = await engine.feasibilitySummary() }
        }
    }
}
