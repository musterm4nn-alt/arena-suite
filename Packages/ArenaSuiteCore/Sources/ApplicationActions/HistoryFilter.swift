import ArchiveIndex
import Foundation
import SuiteDomain

/// What the history list and search show (Docs/history-filters-2026-10-19.md). The default shows
/// everything. Each dimension narrows the list; a conversation is shown when it matches all of them.
public struct HistoryFilter: Sendable, Equatable {
    public enum Votes: String, Sendable, CaseIterable {
        case any
        /// The latest snapshot holds at least one vote between two responses.
        case with
        /// The conversation has a snapshot, and its latest snapshot holds no vote. A conversation
        /// known only from the history list matches neither this nor `.with`: whether it has a vote
        /// is not in the archive.
        case without

        public var label: String {
            switch self {
            case .any: "Any"
            case .with: "With a vote"
            case .without: "No vote in its transcript"
            }
        }
    }

    public enum Period: Sendable, Hashable {
        case any
        /// Updated at most this many days (of 24 hours) before now, or later.
        case lastDays(Int)
        /// Updated at most this many calendar months before now, or later.
        case lastMonths(Int)
        /// Updated in this calendar year.
        case year(Int)

        public var label: String {
            switch self {
            case .any: "Any time"
            case .lastDays(let days): "Past \(days) days"
            case .lastMonths(let months): "Past \(months) months"
            case .year(let year): String(year)
            }
        }

        /// The relative periods the menu offers.
        public static let presets: [Period] = [.lastDays(7), .lastDays(30), .lastMonths(12)]
    }

    /// What the period filter measures, for the menu.
    public static let periodScope = "Last update as Arena reports it, in this Mac’s time zone (a day is 24 hours)"

    /// How a recorded mode is shown. Only display: the filter keeps the recorded value. A recorded
    /// value that would read like the placeholder for a missing one is quoted.
    public static func label(mode: String?) -> String {
        guard let mode else { return notStated }
        if mode.isEmpty { return "“” (empty)" }
        return mode == notStated ? "“\(mode)” (recorded)" : mode
    }

    private static let notStated = "not stated"

    /// Recorded modes to show; `nil` stands for "not stated". Empty = any mode.
    public var modes: Set<String?>
    public var votes: Votes
    /// A model ID the latest snapshot claims; nil = any. A claim, not verified identity.
    public var model: String?
    /// By the update time Arena reports, in the given calendar. Undated conversations match only `.any`.
    public var period: Period

    public init(modes: Set<String?> = [], votes: Votes = .any, model: String? = nil, period: Period = .any) {
        self.modes = modes
        self.votes = votes
        self.model = model
        self.period = period
    }

    public var isActive: Bool { !modes.isEmpty || votes != .any || model != nil || period != .any }

    /// The vote and model dimensions need the facets read from the index.
    public var needsFacets: Bool { votes != .any || model != nil }

    /// `facets` nil means they could not be read: the vote and model dimensions are then not applied
    /// (the app says so) rather than guessed. A conversation missing from readable facets (a sync
    /// landed between the two reads) matches no vote or model choice.
    public func matches(_ conversation: ConversationSummary, facets: HistoryFacets?, now: Date, calendar: Calendar) -> Bool {
        if !modes.isEmpty, !modes.contains(conversation.mode) { return false }
        if needsFacets, let facets {
            let facet = facets.facet(for: conversation)
            switch votes {
            case .any: break
            case .with:
                guard let facet, facet.votes > 0 else { return false }
            case .without:
                guard conversation.latestSnapshotSequence != nil, let facet, facet.votes == 0 else { return false }
            }
            if let model {
                guard let facet, facet.models.contains(model) else { return false }
            }
        }
        if period != .any {
            guard let micros = conversation.updatedOrder else { return false }
            let date = Date(timeIntervalSince1970: TimeInterval(micros) / 1_000_000)
            switch period {
            case .any: break
            case .lastDays(let days):
                if date < now.addingTimeInterval(-TimeInterval(days) * 86_400) { return false }
            case .lastMonths(let months):
                guard let start = calendar.date(byAdding: .month, value: -months, to: now), date >= start else { return false }
            case .year(let year):
                if calendar.component(.year, from: date) != year { return false }
            }
        }
        return true
    }

    /// The conversations this filter shows, in their original order.
    public func apply(_ conversations: [ConversationSummary], facets: HistoryFacets?, now: Date, calendar: Calendar) -> [ConversationSummary] {
        guard isActive else { return conversations }
        return conversations.filter { matches($0, facets: facets, now: now, calendar: calendar) }
    }

    /// Recorded modes, most frequent first, then "not stated" (nil), then by value.
    public static func modeOrder(_ lhs: (mode: String?, count: Int), _ rhs: (mode: String?, count: Int)) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        switch (lhs.mode, rhs.mode) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (let l?, let r?): return l < r
        }
    }
}

/// Per conversation, what the filters need from its latest snapshot, and the revealed model names.
public struct HistoryFacets: Sendable, Equatable {
    public struct Key: Hashable, Sendable {
        public let account: AccountID
        public let remoteID: String

        public init(account: AccountID, remoteID: String) {
            self.account = account
            self.remoteID = remoteID
        }
    }

    public struct Facet: Sendable, Equatable {
        /// Votes between two responses in the latest snapshot.
        public let votes: Int
        /// Model IDs claimed in the latest snapshot, from any source.
        public let models: Set<String>

        public init(votes: Int, models: Set<String>) {
            self.votes = votes
            self.models = models
        }
    }

    public let conversations: [Key: Facet]
    /// The name Arena revealed for each model ID (`detail_revealed`), latest record first.
    public let names: [String: String]

    public static let empty = HistoryFacets(conversations: [:], names: [:])

    public init(conversations: [Key: Facet], names: [String: String]) {
        self.conversations = conversations
        self.names = names
    }

    public init(source: HistoryFacetSource) {
        conversations = Dictionary(
            source.conversations.map { (Key(account: $0.account, remoteID: $0.remoteID), Facet(votes: $0.votes, models: Set($0.models))) },
            uniquingKeysWith: { first, _ in first })
        names = RevealedNames.latest(source.namedClaims)
    }

    public func facet(for conversation: ConversationSummary) -> Facet? {
        conversations[Key(account: conversation.account, remoteID: conversation.remoteID)]
    }
}

/// What the filter menu offers, with counts. Each dimension is counted under the other active
/// dimensions, so a count is what choosing that option shows (for a mode: choosing that mode alone).
public struct HistoryFilterOptions: Sendable, Equatable {
    public struct Count<Value: Hashable & Sendable>: Sendable, Equatable, Hashable {
        public let value: Value
        public let count: Int

        public init(_ value: Value, _ count: Int) {
            self.value = value
            self.count = count
        }
    }

    public struct Model: Sendable, Equatable, Hashable, Identifiable {
        public let id: String
        /// The revealed name, if Arena revealed one.
        public let name: String?
        public let count: Int

        public init(id: String, name: String?, count: Int) {
            self.id = id
            self.name = name
            self.count = count
        }
    }

    /// Most frequent first, then "not stated" (`nil`), then by value.
    public let modes: [Count<String?>]
    public let withVote: Int
    /// With a snapshot whose latest holds no vote.
    public let withoutVote: Int
    /// Known only from the history list: no transcript, so neither with nor without a vote.
    public let withoutTranscript: Int
    /// Most conversations first, then by name.
    public let models: [Model]
    /// Newest year first.
    public let years: [Count<Int>]
    /// The relative periods (`Period.presets`), in that order, counted at the time given to `build`.
    public let recent: [Count<HistoryFilter.Period>]
    /// Conversations without a parsable update time: they match only "any time".
    public let undated: Int

    public static let empty = HistoryFilterOptions(
        modes: [], withVote: 0, withoutVote: 0, withoutTranscript: 0, models: [], years: [], recent: [], undated: 0)

    public init(
        modes: [Count<String?>], withVote: Int, withoutVote: Int, withoutTranscript: Int, models: [Model], years: [Count<Int>],
        recent: [Count<HistoryFilter.Period>], undated: Int
    ) {
        self.modes = modes
        self.withVote = withVote
        self.withoutVote = withoutVote
        self.withoutTranscript = withoutTranscript
        self.models = models
        self.years = years
        self.recent = recent
        self.undated = undated
    }

    /// `filter` is the active filter (its other dimensions narrow each dimension's counts).
    /// `facets` nil (they could not be read): the vote and model choices count nothing.
    public static func build(
        _ conversations: [ConversationSummary], facets: HistoryFacets?, filter: HistoryFilter = HistoryFilter(), now: Date,
        calendar: Calendar
    ) -> HistoryFilterOptions {
        /// The list under every active dimension except the one `clear` resets.
        func under(_ clear: (inout HistoryFilter) -> Void) -> [ConversationSummary] {
            var others = filter
            clear(&others)
            return others.apply(conversations, facets: facets, now: now, calendar: calendar)
        }
        var modes: [String?: Int] = [:]
        for conversation in under({ $0.modes = [] }) { modes[conversation.mode, default: 0] += 1 }

        var withVote = 0, withoutVote = 0, withoutTranscript = 0
        for conversation in under({ $0.votes = .any }) {
            if conversation.latestSnapshotSequence == nil { withoutTranscript += 1 }
            if let facet = facets?.facet(for: conversation) {
                if facet.votes > 0 {
                    withVote += 1
                } else if conversation.latestSnapshotSequence != nil {
                    withoutVote += 1
                }
            }
        }

        var models: [String: Int] = [:]
        for conversation in under({ $0.model = nil }) {
            for model in facets?.facet(for: conversation)?.models ?? [] { models[model, default: 0] += 1 }
        }

        var years: [Int: Int] = [:]
        var undated = 0
        let anyTime = under { $0.period = .any }
        for conversation in anyTime {
            if let micros = conversation.updatedOrder {
                years[calendar.component(.year, from: Date(timeIntervalSince1970: TimeInterval(micros) / 1_000_000)), default: 0] += 1
            } else {
                undated += 1
            }
        }
        let recent = HistoryFilter.Period.presets.map { period in
            Count(period, HistoryFilter(period: period).apply(anyTime, facets: facets, now: now, calendar: calendar).count)
        }
        return HistoryFilterOptions(
            modes: modes.map { Count($0.key, $0.value) }.sorted { HistoryFilter.modeOrder(($0.value, $0.count), ($1.value, $1.count)) },
            withVote: withVote, withoutVote: withoutVote, withoutTranscript: withoutTranscript,
            models: models.map { Model(id: $0.key, name: facets?.names[$0.key], count: $0.value) }.sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return ($0.name ?? $0.id, $0.id) < ($1.name ?? $1.id, $1.id)
            },
            years: years.map { Count($0.key, $0.value) }.sorted { $0.value > $1.value },
            recent: recent, undated: undated)
    }
}

/// The name Arena revealed for each model ID (`detail_revealed` claims). Where several were revealed,
/// the latest record's wins (by sequence, then account, then name, so the choice is deterministic).
/// Model IDs are Arena's own, so a name revealed in one account labels the same ID in another.
enum RevealedNames {
    static func latest(_ claims: [SequencedClaim]) -> [String: String] {
        var names: [String: (sequence: UInt64, account: String, name: String)] = [:]
        for item in claims {
            guard item.claim.source == "detail_revealed", let name = item.claim.displayName else { continue }
            let candidate = (sequence: item.sequence, account: item.account.rawValue.uuidString, name: name)
            if let current = names[item.claim.modelID],
                (current.sequence, current.account, current.name) >= (candidate.sequence, candidate.account, candidate.name)
            {
                continue
            }
            names[item.claim.modelID] = candidate
        }
        return names.mapValues(\.name)
    }
}
