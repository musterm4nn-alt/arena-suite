import ApplicationActions
import ArchiveIndex
import ArenaAdapter
import Foundation

/// Composition root: the only app file that knows concrete implementations (plan v3 §5, §16).
enum AppComposition {
    struct Services {
        let accounts: AccountService
        let sync: HistorySyncService
        let archive: ArchiveService
    }

    /// `~/Library/Application Support/Arena Suite/Archive`, or `--archive-root <path>` for development.
    static var archiveRoot: URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--archive-root"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Arena Suite/Archive", isDirectory: true)
    }

    static func makeServices() -> Services {
        let sessions = ArenaAccountSessions()
        let accounts = AccountService(
            registry: AccountRegistryStore(url: archiveRoot.appendingPathComponent("accounts/registry.json")),
            sessions: sessions)
        let journals = JournalStore(archiveRoot: archiveRoot)
        let sync = HistorySyncService(accounts: accounts, journals: journals, engine: ArenaHistorySync(sessions: sessions))
        let registry = AccountRegistryStore(url: archiveRoot.appendingPathComponent("accounts/registry.json"))
        let index: ArchiveIndex
        do {
            index = try ArchiveIndex(url: archiveRoot.appendingPathComponent("index/archive.sqlite"))
        } catch {
            fatalError("The archive index could not be opened: \(error)")  // journal untouched; delete index/ to rebuild
        }
        let archive = ArchiveService(
            index: index, journals: journals, decoder: ArenaArchiveDecoder(),
            accounts: { ((try? registry.load()) ?? []).map(\.id) })
        return Services(accounts: accounts, sync: sync, archive: archive)
    }
}
