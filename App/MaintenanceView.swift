import AppKit
import ApplicationActions
import Foundation
import Observation
import SuiteDomain
import SwiftUI

/// Verify, back up, restore and diagnostics (plan v3 §13, Phase 7). Every action is user-started and
/// runs one at a time; backup and restore wait until no sync is running.
@MainActor @Observable
final class MaintenanceModel {
    private(set) var working: String?
    private(set) var lines: [String] = []
    private(set) var failed = false
    private(set) var lastVerification: VerificationReport?
    private(set) var revealURL: URL?

    private let services: AppComposition.Maintenance
    private let accounts: AccountsModel
    private let archive: ArchiveModel
    private let rebuildIndex: () async throws -> Void

    init(services: AppComposition.Maintenance, accounts: AccountsModel, archive: ArchiveModel,
         rebuildIndex: @escaping () async throws -> Void) {
        self.services = services
        self.accounts = accounts
        self.archive = archive
        self.rebuildIndex = rebuildIndex
    }

    var busy: Bool { working != nil || accounts.isSyncing || archive.projecting }
    var hasAccounts: Bool { !accounts.accounts.isEmpty }
    /// No accounts and no kept journals: the only state a restore may target.
    var canRestore: Bool { !hasAccounts && services.backups.canRestore }

    func verify() async {
        await run("Verifying the archive…", exclusive: true) {
            let report = await services.verification.run()
            lastVerification = report
            var out = [report.isClean ? "Archive verified: no problems found." : "Problems found. Nothing was changed."]
            for (n, journal) in report.journals.enumerated() {
                out.append("Journal \(n + 1): \(journal.segments) segment(s), \(journal.records) record(s)"
                    + (journal.isClean ? ", ok" : ""))
                out += journal.issues.map { "  • \($0)" }
            }
            if let index = report.index {
                out.append(index.matches
                    ? "Index: identical to a fresh replay of the journals."
                    : "Index: differs from a fresh replay of the journals. Use “Rebuild Index” to fix it.")
            }
            if let problem = report.indexProblem { out.append("Index: \(problem)") }
            if report.journals.contains(where: { !$0.isClean }) {
                out.append("A damaged journal can be replaced from a backup (see the release notes).")
            }
            return (out, !report.isClean)
        }
    }

    func rebuild() async {
        await run("Rebuilding the index from the journals…", exclusive: true) {
            try await rebuildIndex()
            archive.reload()
            return (["Index rebuilt from the journals."], false)
        }
    }

    func backUp() async {
        guard !accounts.isSyncing else { return note("Wait for the running sync to finish, then back up.") }
        guard let folder = Self.chooseFolder(prompt: "Back Up Here") else { return }
        await run("Writing the backup…", exclusive: true) {
            let url = try await services.backups.create(in: folder)
            let check = try await services.backups.check(url)
            revealURL = url
            return ([
                "Backup written and checked: \(check.accounts) journal(s), \(check.records) record(s).",
                url.lastPathComponent,
                "It holds your journals and account list, not passwords or sessions.",
            ], false)
        }
    }

    func checkBackup() async {
        guard let folder = Self.chooseFolder(prompt: "Check Backup", message: "Choose an “Arena Suite Backup” folder") else { return }
        await run("Checking the backup…") {
            let check = try await services.backups.check(folder)
            return (["Backup is intact: \(check.accounts) journal(s), \(check.records) record(s), created \(check.manifest.createdAt)."], false)
        }
    }

    /// Only offered while there are no accounts (a new Mac or a fresh install).
    func restore() async {
        guard canRestore else { return note("Restore only works into an empty archive (no accounts and no kept journals).") }
        guard let folder = Self.chooseFolder(prompt: "Restore", message: "Choose an “Arena Suite Backup” folder") else { return }
        await run("Restoring…", exclusive: true) {
            let check = try await services.backups.restore(from: folder)
            try await rebuildIndex()
            await accounts.reloadAccounts()
            archive.reload()
            return ([
                "Restored \(check.accounts) journal(s), \(check.records) record(s); the index was rebuilt from them.",
                "Accounts whose sessions are not in this Mac's Keychain need “Sign In Again”.",
            ], false)
        }
    }

    func saveDiagnostics() async {
        guard let folder = Self.chooseFolder(prompt: "Save Here") else { return }
        await run("Collecting diagnostics…") {
            let states = accounts.accounts.map { ($0.id, $0.state) }
            let data = services.diagnostics.report(accounts: states, verification: lastVerification)
            let url = try services.diagnostics.write(data, to: folder)
            revealURL = url
            return ([
                "Diagnostics saved: \(url.lastPathComponent)",
                "Counts, versions and journal health only: no messages, titles, IDs, names or emails.",
            ], false)
        }
    }

    private func note(_ text: String) {
        lines = [text]
        failed = true
    }

    /// `exclusive`: the journals must not change meanwhile, so no sync may start or be running.
    private func run(_ label: String, exclusive: Bool = false, _ work: () async throws -> ([String], Bool)) async {
        guard working == nil else { return }
        if exclusive {
            do { try await services.sync.beginMaintenance() } catch {
                return note("A sync is running. Try again when it has finished.")
            }
        }
        working = label
        revealURL = nil
        defer { working = nil }
        do {
            (lines, failed) = try await work()
        } catch {
            lines = [Self.describe(error)]
            failed = true
        }
        if exclusive { await services.sync.endMaintenance() }
    }

    static func describe(_ error: any Error) -> String {
        switch error as? BackupError {
        case .notABackup: "That folder is not an Arena Suite backup."
        case .unsupportedFormat(let format): "This backup format (\(format)) is not supported by this version."
        case .fileMismatch(let what): "The backup does not match its manifest (\(what)). Do not rely on it."
        case .journalDamaged(_, let issue): "A journal could not be copied or verified (\(issue))."
        case .replayMismatch: "The backup's journals do not replay to the recorded index digest."
        case .targetNotEmpty: "Restore only works into an empty archive (no accounts and no kept journals)."
        case .archiveChanged: "Accounts changed while the backup ran. Nothing was written; try again."
        case .cancelled: "Cancelled. Nothing was written."
        case .io(let what): "A file operation failed (\(what)). Nothing partial was left behind."
        case .none: "The action failed (\((error as NSError).domain) \((error as NSError).code))."
        }
    }

    static func chooseFolder(prompt: String, message: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        if let message { panel.message = message }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct MaintenanceView: View {
    @Bindable var model: MaintenanceModel
    let accounts: AccountsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Maintenance").font(Theme.heading)
            Text("Everything here reads your archive locally. Nothing is sent to Arena.")
                .font(Theme.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                row("Verify Archive", "Check every journal record and compare the index with a fresh replay.") {
                    await model.verify()
                }
                row("Rebuild Index", "Recreate the search index from the journals.") { await model.rebuild() }
                row("Back Up…", "Copy journals and account list into a new folder, then check the copy.") {
                    await model.backUp()
                }
                row("Check Backup…", "Confirm a backup folder is complete and unchanged.") { await model.checkBackup() }
                if model.canRestore {
                    row("Restore from Backup…", "Only while there are no accounts, e.g. on a new Mac.") {
                        await model.restore()
                    }
                }
                row("Save Diagnostics…", "A content-free report for troubleshooting.") { await model.saveDiagnostics() }
            }
            if accounts.isSyncing {
                Text("A sync is running. These actions are available when it finishes.").font(Theme.caption).foregroundStyle(.orange)
            }
            Divider()
            if let working = model.working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(working).font(Theme.text)
                }
            } else if !model.lines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(Theme.text).foregroundStyle(model.failed ? .orange : .primary)
                            .textSelection(.enabled)
                    }
                    if let url = model.revealURL {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                            Text("Reveal in Finder").font(Theme.text)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 640, height: 460, alignment: .topLeading)
    }

    private func row(_ title: String, _ detail: String, action: @escaping () async -> Void) -> some View {
        GridRow {
            Button { Task { await action() } } label: { Text(title).font(Theme.text).frame(minWidth: 170, alignment: .leading) }
                .disabled(model.busy)
            Text(detail).font(Theme.caption).foregroundStyle(.secondary)
        }
    }
}
