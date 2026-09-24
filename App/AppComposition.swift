import ApplicationActions
import ArenaAdapter
import Foundation

/// Composition root: the only app file that knows concrete implementations (plan v3 §5, §16).
enum AppComposition {
    /// `~/Library/Application Support/Arena Suite/Archive`, or `--archive-root <path>` for development.
    static var archiveRoot: URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--archive-root"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Arena Suite/Archive", isDirectory: true)
    }

    static func makeAccountService() -> AccountService {
        AccountService(
            registry: AccountRegistryStore(url: archiveRoot.appendingPathComponent("accounts/registry.json")),
            sessions: ArenaAccountSessions())
    }
}
