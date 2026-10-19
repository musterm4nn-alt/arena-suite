import ApplicationActions
import Foundation
import Observation
import SuiteDomain
import SwiftUI

/// The Insights page's state: one summary of the index, read off the main actor
/// (Docs/insights-2026-10-19.md). It only reads; nothing is sent to Arena or written.
@MainActor @Observable
final class InsightsModel {
    /// What a summary is built for: the archive's reload revision and the account choice.
    struct Key: Hashable, Sendable {
        let revision: Int
        let account: AccountID?
    }

    private(set) var insights: ArchiveInsights?
    private(set) var loading = false
    private(set) var failure: String?
    private var loadedKey: Key?
    private var generation = 0

    private let service: InsightsService?

    /// `service` is nil when the archive index could not be opened.
    init(service: InsightsService?) {
        self.service = service
    }

    var isAvailable: Bool { service != nil }

    /// Reads the index for `key` unless the summary shown is already for it. Only the newest call's
    /// result is applied, so a slow read never replaces a newer one.
    func load(_ key: Key) async {
        guard let service, key != loadedKey else { return }
        generation += 1
        let mine = generation
        loading = true
        let accounts = key.account.map { Set([$0]) }
        let result = await Task.detached(priority: .userInitiated) {
            Result { try service.insights(accounts: accounts, calendar: .current) }
        }.value
        guard mine == generation else { return }
        loading = false
        switch result {
        case .success(let insights):
            self.insights = insights
            failure = nil
            loadedKey = key
        case .failure(let error):
            failure = "The archive index could not be read (\(error.localizedDescription)). Rebuild Index under Maintenance recreates it from the journals."
        }
    }
}

/// A summary of the user's own archive: totals, activity by month, modes, how they voted, and each
/// model's record in those votes. Models are the archive's claims, never verified identity, and the
/// records are the user's votes, not Arena's ranking. The page says so.
struct InsightsView: View {
    let model: InsightsModel
    @Bindable var archive: ArchiveModel
    @Bindable var accounts: AccountsModel
    @Binding var destination: MainDestination
    @State private var showAllModels = false

    /// Models listed before "Show all".
    private static let modelsShown = 15

    private var key: InsightsModel.Key { .init(revision: archive.revision, account: archive.accountFilter) }
    private var scope: SidebarScope { SidebarScope(accounts: accounts, archive: archive) }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar {
                Text("Insights")
                Text("· \(scope.name)").foregroundStyle(.secondary).lineLimit(1)
            } trailing: {
                if model.loading { ProgressView().controlSize(.mini).padding(.trailing, 6) }
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .task(id: key) { await model.load(key) }
    }

    @ViewBuilder private var content: some View {
        if !model.isAvailable {
            Text(archive.message ?? "The archive index is unavailable.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(40)
        } else if let insights = model.insights {
            if insights.isEmpty {
                emptyState
            } else {
                ScrollView {
                    page(insights)
                        .padding(28)
                        .frame(maxWidth: 860, alignment: .topLeading)
                        .frame(maxWidth: .infinity)
                }
                // Otherwise scrolled content draws into the header bar in the window's top band.
                .clipped()
            }
        } else if let failure = model.failure {
            Text(failure).foregroundStyle(.orange).multilineTextAlignment(.center).padding(40)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: Empty

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 32)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Insights").font(Theme.heading)
            Text(scope.chosen == nil ? "Nothing archived yet." : "Nothing archived for \(scope.name) yet.")
                .foregroundStyle(.secondary)
            Text("Once your history is archived, this page shows your activity by month, your modes and your votes.")
                .font(Theme.caption).foregroundStyle(.tertiary)
            if !scope.syncable.isEmpty {
                Button(scope.syncing.isEmpty ? "Sync History" : "Syncing…") { scope.startSync() }
                    .buttonStyle(.arenaPill)
                    .disabled(!scope.syncing.isEmpty)
                    .padding(.top, 4)
            } else {
                Button("Show the First Step") { destination = .archive }
                    .buttonStyle(.arenaPill)
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }

    // MARK: Page

    private func page(_ insights: ArchiveInsights) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            if let failure = model.failure {
                Text(failure).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            totals(insights)
            if !insights.activity.isEmpty || insights.undated > 0 { activity(insights) }
            HStack(alignment: .top, spacing: 36) {
                section("Modes") { bars(insights.modes.map { Bar($0.label, $0.count) }) }
                section("Kinds") { bars(insights.kinds.map { Bar($0.label, $0.count) }) }
            }
            if insights.accounts.count > 1 { accountsSection(insights) }
            votes(insights)
            if insights.votes.total > 0 { models(insights) }
            footnote(insights)
        }
    }

    private func totals(_ insights: ArchiveInsights) -> some View {
        HStack(spacing: 12) {
            tile(insights.conversations, "conversations",
                 help: "\(insights.withSnapshot.formatted()) with a recorded transcript; the rest are known from the history list only.")
            tile(insights.prompts, "prompts", help: "Your messages in the latest snapshot of each conversation.")
            tile(insights.responses, "responses", help: "Model responses in the latest snapshot of each conversation.")
            tile(insights.votes.total, "votes",
                 help: "Votes between two responses in the latest snapshot of each conversation. Feedback on a single response is not decoded; it stays in the journal.")
        }
    }

    private func tile(_ value: Int, _ label: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value.formatted()).font(Theme.heading).lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(Theme.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .help(help)
        .accessibilityElement(children: .combine)
    }

    // MARK: Activity

    private func activity(_ insights: ArchiveInsights) -> some View {
        let months = insights.activity
        let busiest = months.max { ($0.count, $1.year, $1.month) < ($1.count, $0.year, $0.month) }
        var detail = "Conversations by the month of their last update, as Arena reports it."
        if let busiest, busiest.count > 0 { detail += " Busiest: \(Self.label(busiest)), \(busiest.count.formatted())." }
        if insights.undated > 0 { detail += " \(insights.undated.formatted()) without a date." }
        return section("Activity", detail: detail) {
            if !months.isEmpty { ActivityChart(months: months) }
        }
    }

    static func label(_ month: ArchiveInsights.Month) -> String {
        let symbols = Calendar.current.shortMonthSymbols
        let name = symbols.indices.contains(month.month - 1) ? symbols[month.month - 1] : "\(month.month)"
        return "\(name) \(month.year)"
    }

    // MARK: Accounts

    private func accountsSection(_ insights: ArchiveInsights) -> some View {
        let rows = insights.accounts
            .map { id, count in
                Bar(accounts.accounts.first { $0.id == id }?.displayName ?? "An account no longer in the list", count)
            }
            .sorted { ($0.count, $1.label) > ($1.count, $0.label) }
        return section("Accounts") { bars(rows) }
    }

    // MARK: Votes

    private func votes(_ insights: ArchiveInsights) -> some View {
        let votes = insights.votes
        let count = { (outcome: VoteOutcome) in votes.outcomes[outcome] ?? 0 }
        var rows = [
            Bar("A is better", count(.preferA)), Bar("B is better", count(.preferB)),
            Bar("Tie", count(.tie)), Bar("Both are bad", count(.bothBad)),
        ]
        rows += votes.unrecognized.map {
            Bar("“\($0.label)”", $0.count, help: "Recorded as “\($0.label)”. This value is not known, so it is not interpreted.")
        }
        if votes.withoutValue > 0 { rows.append(Bar("No value", votes.withoutValue, help: "Votes recorded without a value.")) }
        return section(
            "Your votes",
            detail: votes.total == 0
                ? "No votes between two responses are recorded in the latest snapshots."
                : "\(votes.total.formatted()) votes between two responses. What each recorded value means is assumed from its name."
        ) {
            if votes.total > 0 { bars(rows) }
        }
    }

    private func models(_ insights: ArchiveInsights) -> some View {
        let all = insights.models
        let shown = showAllModels ? all : Array(all.prefix(Self.modelsShown))
        return section(
            "Models in your votes",
            detail: "Each model’s record in the votes you cast, by the model the archive claims for each side. Your votes, not Arena’s ranking."
        ) {
            VStack(spacing: 0) {
                ModelRow.header
                ForEach(shown, id: \.modelID) { ModelRow(record: $0) }
            }
            if all.count > Self.modelsShown {
                Button(showAllModels ? "Show Fewer" : "Show All \(all.count)") { showAllModels.toggle() }
                    .buttonStyle(.arenaPill)
                    .padding(.top, 6)
            }
            Text(Self.attribution(insights))
                .font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    /// How many votes went into the records, and why the rest did not.
    static func attribution(_ insights: ArchiveInsights) -> String {
        var text = "\(insights.attributedVotes.formatted()) of \(insights.votes.total.formatted()) votes are in these records."
        let reasons = ArchiveInsights.Exclusion.allCases.compactMap { reason -> String? in
            guard let n = insights.exclusions[reason], n > 0 else { return nil }
            return switch reason {
            case .valueNotInterpreted: "\(n.formatted()) whose value is missing or not interpreted"
            case .noModelClaim: "\(n.formatted()) with no claimed model found for a side"
            case .conflictingClaims: "\(n.formatted()) whose claims for a side disagree"
            case .sameModelOnBothSides: "\(n.formatted()) with the same model on both sides"
            }
        }
        if !reasons.isEmpty { text += " Left out: " + reasons.joined(separator: "; ") + "." }
        return text
    }

    private func footnote(_ insights: ArchiveInsights) -> some View {
        var lines = [
            "Scope: the latest snapshot of each conversation, \(scope.chosen == nil ? "all accounts" : scope.name). Months follow this Mac’s calendar and time zone.",
            "Models are what the archive records Arena claiming, not verified identity. Names are the ones Arena revealed; a model never revealed is shown by its ID.",
            "Votes are those between two responses; feedback on a single response is not decoded and stays in the journal as raw evidence. Vote meanings: \(insights.vocabularyEvidence).",
        ]
        if let version = insights.decoderVersion { lines.append("Index decoder: \(version).") }
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.self) { Text($0) }
        }
        .font(Theme.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    // MARK: Building blocks

    private func section(_ title: String, detail: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).accessibilityAddTraits(.isHeader)
                if let detail {
                    Text(detail).font(Theme.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    struct Bar: Identifiable {
        let label: String
        let count: Int
        var help: String?
        var id: String { label }

        init(_ label: String, _ count: Int, help: String? = nil) {
            self.label = label
            self.count = count
            self.help = help
        }
    }

    /// Horizontal bars scaled to the largest count.
    private func bars(_ rows: [Bar]) -> some View {
        let peak = max(1, rows.map(\.count).max() ?? 1)
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Text(row.label).lineLimit(1).truncationMode(.middle).frame(width: 120, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.sunken)
                            if row.count > 0 {
                                Capsule().fill(Theme.primaryText.opacity(0.78))
                                    .frame(width: max(4, geometry.size.width * CGFloat(row.count) / CGFloat(peak)))
                            }
                        }
                    }
                    .frame(height: 7)
                    Text(row.count.formatted()).frame(minWidth: 44, alignment: .trailing)
                }
                .help(row.help ?? "\(row.label): \(row.count.formatted())")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.label): \(row.count)")
            }
        }
    }
}

/// Conversations per month as columns, first and last month labelled; each column has a tooltip.
private struct ActivityChart: View {
    let months: [ArchiveInsights.Month]
    private let height: CGFloat = 120

    var body: some View {
        let peak = max(1, months.map(\.count).max() ?? 1)
        GeometryReader { geometry in
            let n = CGFloat(months.count)
            let spacing: CGFloat = months.count > 60 ? 1 : 3
            let width = min(64, max(2, (geometry.size.width - spacing * (n - 1)) / n))
            let chartWidth = width * n + spacing * (n - 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(months, id: \.self) { month in
                        // The whole column answers the pointer, not only the bar.
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: min(2, width / 2))
                                .fill(month.count == 0 ? Theme.border : Theme.primaryText.opacity(0.78))
                                .frame(height: month.count == 0 ? 1 : max(3, height * CGFloat(month.count) / CGFloat(peak)))
                        }
                        .frame(width: width, height: height)
                        .contentShape(Rectangle())
                        .help("\(InsightsView.label(month)): \(month.count.formatted()) conversations")
                    }
                }
                .frame(height: height, alignment: .bottom)
                HStack {
                    Text(InsightsView.label(months[0]))
                    Spacer(minLength: 8)
                    if months.count > 1 { Text(InsightsView.label(months[months.count - 1])) }
                }
                .font(Theme.caption)
                .foregroundStyle(.secondary)
                .frame(width: max(chartWidth, 160))
            }
        }
        .frame(height: height + 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Conversations per month")
        .accessibilityValue(months.map { "\(InsightsView.label($0)): \($0.count)" }.joined(separator: ", "))
    }
}

/// One model's line in the records table.
private struct ModelRow: View {
    let record: ArchiveInsights.ModelRecord

    struct Column {
        let title: String
        let width: CGFloat
        let help: String
    }

    static let columns = [
        Column(title: "Votes", width: 56, help: "Your votes with this model on one side"),
        Column(title: "Preferred", width: 82, help: "Votes where this model’s response was the better one"),
        Column(title: "Not preferred", width: 104, help: "Votes where the other response was the better one"),
        Column(title: "Ties", width: 48, help: "Votes marked as a tie"),
        Column(title: "Both bad", width: 72, help: "Votes marked as both bad"),
        Column(title: "Share", width: 112, help: "Share of the decisive votes (one side better) in which this model was preferred"),
    ]

    static var header: some View {
        HStack(spacing: 0) {
            Text("Model").frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns, id: \.title) { column in
                Text(column.title).frame(width: column.width, alignment: .trailing).help(column.help)
            }
        }
        .font(Theme.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }

    var body: some View {
        let values = [record.votes, record.preferred, record.notPreferred, record.ties, record.bothBad]
        HStack(spacing: 0) {
            Text(record.displayName ?? record.modelID)
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(record.displayName == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(record.displayName == nil
                    ? "Never revealed; shown by its claimed model ID."
                    : "Claimed model ID: \(record.modelID)")
            ForEach(Array(values.enumerated()), id: \.offset) { n, value in
                Text(value.formatted())
                    .foregroundStyle(value == 0 ? .tertiary : .primary)
                    .frame(width: Self.columns[n].width, alignment: .trailing)
            }
            share.frame(width: Self.columns[5].width, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Theme.border.opacity(0.6).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(record.displayName ?? record.modelID)
        .accessibilityValue(
            "\(record.votes) votes, preferred \(record.preferred), not preferred \(record.notPreferred), ties \(record.ties), both bad \(record.bothBad)")
    }

    @ViewBuilder private var share: some View {
        if let share = record.preferenceShare {
            HStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.sunken)
                    Capsule().fill(Theme.primaryText.opacity(0.78)).frame(width: max(share > 0 ? 3 : 0, 48 * share))
                }
                .frame(width: 48, height: 6)
                Text(share.formatted(.percent.precision(.fractionLength(0)))).frame(width: 40, alignment: .trailing)
            }
        } else {
            Text("—").foregroundStyle(.tertiary).help("No decisive votes")
        }
    }
}
