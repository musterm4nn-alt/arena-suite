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
        let maintenance: Maintenance
        /// Where the embedded site window may go (ADR 0006).
        let website: WebSitePolicy
    }

    /// Verify job, backups and diagnostics (plan v3 §13, Phase 7), and datasets (§14).
    struct Maintenance {
        let verification: VerificationService
        let backups: BackupService
        let diagnostics: DiagnosticsService
        /// nil when the index could not be opened.
        let datasets: DatasetService?
        /// Holds new syncs off while journals are being read as a whole.
        let sync: HistorySyncService
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
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
        let archive: ArchiveService?
        let unavailable: String?
        do {
            let index = try ArchiveIndex(url: archiveRoot.appendingPathComponent("index/archive.sqlite"))
            archive = ArchiveService(
                index: index, journals: journals, decoder: ArenaArchiveDecoder(),
                // With every journal on disk (the service adds those): an unreadable list fails the
                // rebuild instead of replaying nothing.
                accounts: { try registry.load().map(\.id) })
            unavailable = nil
        } catch {
            // Accounts and sync keep working; the journal is untouched. Removing index/ rebuilds it.
            archive = nil
            unavailable = "The archive index could not be opened (\(error)). Your journal is untouched; quit and remove the index folder to rebuild it."
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let maintenance = Maintenance(
            verification: VerificationService(
                archive: archive, journals: journals,
                accounts: { Array(Set(try registry.load().map(\.id)).union(try journals.journalAccounts()))
                    .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString } },
                scratch: FileManager.default.temporaryDirectory.appendingPathComponent("arena-suite-verify", isDirectory: true)),
            backups: BackupService(archiveRoot: archiveRoot, decoder: ArenaArchiveDecoder(), appVersion: appVersion),
            diagnostics: DiagnosticsService(
                archive: archive, journals: journals,
                environment: .init(
                    appVersion: appVersion, osVersion: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")),
            datasets: archive.map(DatasetService.init(archive:)),
            sync: sync)
        return Services(
            accounts: accounts, sync: sync, archive: archive, archiveUnavailable: unavailable, maintenance: maintenance,
            website: ArenaWebsite.policy)
    }
}
