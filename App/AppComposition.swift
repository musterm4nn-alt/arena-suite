import ApplicationActions
import ArchiveIndex
import ArenaAdapter
import Foundation

/// Composition root: the only app file that knows concrete implementations (plan v3 §5, §16).
enum AppComposition {
    struct Services {
        let accounts: AccountService
        let sync: HistorySyncService
        /// nil when the index could not be opened; `archiveUnavailable` says why.
        let archive: ArchiveService?
        let archiveUnavailable: String?
    }

    /// `~/Library/Application Support/Arena Suite/Archive`, or `--archive-root <path>` for development.
    static var archiveRoot: URL {
        #if DEBUG
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--archive-root"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Arena Suite/Archive", isDirectory: true)
    }

    static func makeServices() -> Services {
        let sessions = ArenaAccountSessions()
        let registry = AccountRegistryStore(url: archiveRoot.appendingPathComponent("accounts/registry.json"))
        let accounts = AccountService(registry: registry, sessions: sessions)
        let journals = JournalStore(archiveRoot: archiveRoot)
        let sync = HistorySyncService(accounts: accounts, journals: journals, engine: ArenaHistorySync(sessions: sessions))
        do {
            let index = try ArchiveIndex(url: archiveRoot.appendingPathComponent("index/archive.sqlite"))
            let archive = ArchiveService(
                index: index, journals: journals, decoder: ArenaArchiveDecoder(),
                accounts: { ((try? registry.load()) ?? []).map(\.id) })
            return Services(accounts: accounts, sync: sync, archive: archive, archiveUnavailable: nil)
        } catch {
            // Accounts and sync keep working; the journal is untouched. Removing index/ rebuilds it.
            return Services(
                accounts: accounts, sync: sync, archive: nil,
                archiveUnavailable: "The archive index could not be opened (\(error)). Your journal is untouched; quit and remove the index folder to rebuild it.")
        }
    }
}
