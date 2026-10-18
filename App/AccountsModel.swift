import ApplicationActions
import Foundation
import Observation
import SuiteDomain

/// Presentation state for the Accounts window. All work goes through `AccountService`.
@MainActor @Observable
final class AccountsModel {
    private(set) var accounts: [AccountSummary] = []
    private(set) var working: Set<AccountID> = []
    private(set) var loading = true
    private(set) var syncing: [AccountID: SyncProgress] = [:]
    private(set) var lastSync: [AccountID: SyncManifest] = [:]
    /// Why each account's last sync failed, kept per account: with several syncs running, one
    /// account's success must not erase another's failure.
    private(set) var syncErrors: [AccountID: String] = [:]
    var message: String?

    private let service: AccountService
    private let sync: HistorySyncService
    private let statusURL: URL

    init(services: AppComposition.Services, archiveRoot: URL) {
        service = services.accounts
        sync = services.sync
        statusURL = archiveRoot.appendingPathComponent("diagnostics/accounts-status.json")
    }

    /// User-initiated read-only history sync (plan v3 §2). One job per account.
    func syncHistory(_ id: AccountID) async {
        guard syncing[id] == nil else { return }
        syncing[id] = SyncProgress(stage: .verifying, pages: 0, entries: 0, detailsDone: 0, detailsNeeded: 0)
        let poll = Task { @MainActor [sync] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                if let progress = await sync.currentProgress(id) { self.syncing[id] = progress }
            }
        }
        do {
            let manifest = try await sync.sync(id)
            lastSync[id] = manifest
            syncErrors[id] = nil
        } catch {
            syncErrors[id] = Self.describe(error)
        }
        poll.cancel()
        syncing[id] = nil
        await refresh()
        await onSyncFinished?(id)
    }

    func cancelSync(_ id: AccountID) async { await sync.cancel(id) }

    /// Clears the shown errors (the sidebar's Dismiss). Manifests and the status file keep the outcome.
    func dismissErrors() {
        message = nil
        syncErrors = [:]
    }

    var isSyncing: Bool { !syncing.isEmpty }

    /// After a restore: reads the restored account list and restores saved sessions.
    func reloadAccounts() async {
        do {
            try await service.load()
            await service.restoreAll()
            message = nil
        } catch {
            message = "The account list could not be read. Nothing was changed."
        }
        await refresh()
    }

    /// Called after each finished sync (the app updates the archive index).
    var onSyncFinished: ((AccountID) async -> Void)?
    private var started = false

    func start() async {
        guard !started else { return }
        started = true
        do {
            try await service.load()
            accounts = await service.accounts()
            await service.restoreAll()
        } catch {
            message = "The account list could not be read. Nothing was changed."
        }
        await refresh()
        loading = false
        // Development: `--sync-on-launch` runs the same user-initiated sync for each signed-in
        // account in turn (used for live Phase 3 verification). Never on by default.
        #if DEBUG
        if CommandLine.arguments.contains("--sync-on-launch") {
            for account in accounts where account.state == .signedIn { await syncHistory(account.id) }
        }
        #endif
    }

    func add(name: String, email: String, password: String) async -> Bool {
        do {
            _ = try await service.addAccount(email: email, password: password, displayName: name)
            message = nil
            await refresh()
            return true
        } catch {
            message = Self.describe(error)
            return false
        }
    }

    func signInAgain(_ id: AccountID, email: String, password: String) async -> Bool {
        await run(id) { try await $0.signInAgain(id, email: email, password: password) }
    }

    func verify(_ id: AccountID) async { _ = await run(id) { try await $0.verify(id) } }

    func remove(_ id: AccountID) async {
        if await run(id, { try await $0.remove(id) }) {
            syncErrors[id] = nil
            await onAccountRemoved?(id)
        }
    }

    /// Called after an account was removed (the app deletes its web profile, ADR 0006).
    var onAccountRemoved: ((AccountID) async -> Void)?

    private func run<T: Sendable>(_ id: AccountID, _ work: (AccountService) async throws -> T) async -> Bool {
        working.insert(id)
        defer { working.remove(id) }
        do {
            _ = try await work(service)
            message = nil
            await refresh()
            return true
        } catch {
            message = Self.describe(error)
            await refresh()
            return false
        }
    }

    private func refresh() async {
        accounts = await service.accounts()
        writeStatus()
    }

    /// Value-free status for diagnostics: local account IDs and states only.
    private func writeStatus() {
        struct Status: Encodable {
            struct Entry: Encodable {
                let id: String
                let state: String
                let credentialGeneration: UInt64
                let lastSync: SyncManifest?
            }
            let schema = "accounts-status/1"
            let updatedAt: String
            let accounts: [Entry]
        }
        let status = Status(
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            accounts: accounts.map {
                .init(
                    id: $0.id.rawValue.uuidString, state: $0.state.rawValue,
                    credentialGeneration: $0.credentialGeneration, lastSync: lastSync[$0.id])
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try PrivateFile.write(try encoder.encode(status), to: statusURL)
        } catch {
            message = "The diagnostics status file could not be written."
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error as? AccountError {
        case .duplicateAccount: "That Arena account is already in the list."
        case .principalChanged: "That sign-in belongs to a different Arena account than this entry."
        case .signIn(.rejected(let status)): "Arena rejected the sign-in (HTTP \(status)). Check email and password."
        case .signIn(.identityUnverified): "Signed in, but Arena did not confirm the account identity. Nothing was saved."
        case .signIn(.unreachable): "Arena could not be reached. Nothing was saved."
        case .signIn(.sessionStorageFailed): "The session could not be saved to the Keychain. Nothing was added."
        case .registryUnavailable: "The account list could not be saved."
        case .busy: "This account is busy. Try again in a moment."
        case .notSignedIn, .unknownAccount, .none: "The action could not be completed."
        }
    }
}
