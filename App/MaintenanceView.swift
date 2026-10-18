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

    // MARK: Datasets (plan v3 §14)

    /// Reads a frozen view of the index; nothing is written.
    func validateDataset() async {
        guard let datasets = services.datasets else { return note("The archive index is unavailable.") }
        await run("Checking the default dataset recipe…") {
            let recipe = DatasetRecipe()
            let audit = try await datasets.validate(recipe: recipe)
            return (Self.datasetSummary(audit, recipe: recipe), !audit.isClean)
        }
    }

    /// The first candidates and what the default recipe decides for each; shows no text.
    func previewDataset() async {
        guard let datasets = services.datasets else { return note("The archive index is unavailable.") }
        await run("Previewing the default dataset recipe…") {
            let preview = try await datasets.preview(recipe: DatasetRecipe(), limit: 12)
            var out = ["First \(preview.entries.count) of \(preview.audit.candidates) candidate responses:"]
            for entry in preview.entries {
                out.append("\(entry.sampleID.prefix(10))  " + (entry.included
                    ? "included · \(entry.tier ?? "") · \(entry.split ?? "")"
                    : "excluded · " + entry.reasons.joined(separator: ", ")))
            }
            return (out, false)
        }
    }

    /// `fromRecipe`: ask for a recipe file (e.g. an earlier dataset's `recipe.json`) first.
    func buildDataset(fromRecipe: Bool) async {
        guard let datasets = services.datasets else { return note("The archive index is unavailable.") }
        var recipe = DatasetRecipe()
        if fromRecipe {
            guard let file = Self.chooseFile(prompt: "Use Recipe", message: "Choose a dataset recipe, e.g. a dataset’s recipe.json")
            else { return }
            do {
                recipe = try DatasetRecipe.parse(try Data(contentsOf: file))
            } catch {
                return note(Self.describe(error))
            }
        }
        guard let folder = Self.chooseFolder(prompt: "Build Here") else { return }
        await run("Building the dataset…") {
            let result = try await datasets.build(recipe: recipe, in: folder, appVersion: AppComposition.appVersion)
            revealURL = result.url
            return (["Dataset written: \(result.url.lastPathComponent)"] + Self.datasetSummary(result.audit, recipe: recipe), false)
        }
    }

    static func datasetSummary(_ audit: DatasetAudit, recipe: DatasetRecipe) -> [String] {
        var out = [
            "Recipe “\(recipe.name)” (\(audit.recipeSHA256.prefix(12))): \(audit.candidates) candidate responses, \(audit.included) included, \(audit.excluded) excluded."
        ]
        if !audit.tiers.isEmpty {
            out.append("Included by label evidence: "
                + audit.tiers.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
                + ". Labels are Arena’s claims, not verified identities.")
        }
        out.append("Splits: " + ["train", "validation", "test"].map { "\($0) \(audit.splits[$0] ?? 0)" }.joined(separator: ", ")
            + " · \(audit.groups) group(s), \(audit.labels) label(s).")
        let reasons = audit.exclusionReasons.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5)
        if !reasons.isEmpty {
            out.append("Most common exclusions: " + reasons.map { "\($0.key.replacingOccurrences(of: "_", with: " ")) \($0.value)" }
                .joined(separator: ", ") + ".")
        }
        out.append(audit.isClean
            ? "Split checks passed: no group, conversation, prompt family or duplicate crosses splits."
            : "Split checks failed (" + audit.violations.filter { $0.value > 0 }.keys.sorted().joined(separator: ", ") + "). Nothing would be written.")
        return out + audit.notes
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
        switch error {
        case let error as DatasetRecipeError:
            switch error {
            case .notJSONObject: return "That file is not a dataset recipe (not a JSON object)."
            case .unsupportedSchema(let schema): return "This recipe version (\(schema)) is not supported by this version."
            case .unknownKey(let path): return "The recipe has an unknown key at \(path). Nothing was built."
            case .wrongType(let path, let expected): return "The recipe value at \(path) must be \(expected). Nothing was built."
            case .invalidValue(let path, let reason): return "The recipe value at \(path) is invalid: \(reason). Nothing was built."
            }
        case let error as DatasetError:
            switch error {
            case .auditFailed(let checks): return "The dataset failed its split checks (\(checks.joined(separator: ", "))). Nothing was written."
            case .cancelled: return "Cancelled. Nothing was written."
            case .io(let what): return "A file operation failed (\(what)). Nothing partial was left behind."
            }
        default: break
        }
        return switch error as? BackupError {
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

    static func chooseFile(prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
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
        VStack(spacing: 0) {
            HeaderBar {
                Text("Maintenance")
            } trailing: {
                EmptyView()
            }
            page
                .padding(28)
                .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
                .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("Maintenance")
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Everything here reads your archive locally. Nothing is sent to Arena.").foregroundStyle(.secondary)
            section("Archive") {
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
            section("Datasets") {
                Text("Training and attribution samples built from the archive. Labels are Arena’s claims with an evidence tier, never verified identities; related samples stay in one split.")
                    .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)
                row("Validate Dataset", "Audit the default recipe: labels, exclusions, splits and leak checks.") {
                    await model.validateDataset()
                }
                row("Preview Dataset", "List the first candidates and why each is included or excluded.") {
                    await model.previewDataset()
                }
                row("Build Dataset…", "Write the default dataset to a new folder.") { await model.buildDataset(fromRecipe: false) }
                row("Build from Recipe…", "Rebuild or customize from a recipe.json.") { await model.buildDataset(fromRecipe: true) }
            }
            if accounts.isSyncing {
                Text("A sync is running. These actions are available when it finishes.").foregroundStyle(.orange)
            }
            output
        }
    }

    /// The running action, or the last result, in a sunken panel that fills the rest of the sheet.
    private var output: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let working = model.working {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(working)
                    }
                } else if model.lines.isEmpty {
                    Text("Results appear here.").foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        Text(line).foregroundStyle(model.failed ? .orange : .primary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if let url = model.revealURL {
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(.arenaPill)
                            .padding(.top, 6)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.caption).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func row(_ title: String, _ detail: String, action: @escaping () async -> Void) -> some View {
        HStack(spacing: 14) {
            Button { Task { await action() } } label: { Text(title).frame(width: 150, alignment: .leading) }
                .buttonStyle(.arenaPill)
                .disabled(model.busy)
            Text(detail).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
