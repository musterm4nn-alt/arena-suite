import ArchiveIndex
import Foundation
import SuiteDomain

/// A summary of the user's own archive for the Insights page (Docs/insights-2026-10-19.md). It is
/// built from the latest snapshot of each conversation. Model records count claims, never verified
/// identity, and come only from the user's own votes; they are not Arena's ranking.
public struct ArchiveInsights: Sendable, Equatable {
    /// A label and how often it occurred.
    public struct Tally: Sendable, Equatable {
        public let label: String
        public let count: Int

        public init(_ label: String, _ count: Int) {
            self.label = label
            self.count = count
        }
    }

    public struct Month: Sendable, Equatable, Hashable {
        public let year: Int
        public let month: Int
        public let count: Int

        public init(year: Int, month: Int, count: Int) {
            self.year = year
            self.month = month
            self.count = count
        }
    }

    public struct Votes: Sendable, Equatable {
        /// Every vote in the latest snapshots.
        public let total: Int
        /// Interpreted values, in `VoteOutcome.allCases` order (zero counts included).
        public let outcomes: [VoteOutcome: Int]
        /// Values outside the vocabulary, as recorded, most frequent first. Never interpreted.
        public let unrecognized: [Tally]
        /// Votes without a value.
        public let withoutValue: Int
    }

    /// One model's record in the user's votes. `modelID` is a claim, not a verified identity.
    public struct ModelRecord: Sendable, Equatable {
        public let modelID: String
        /// The name Arena revealed for this model ID (latest record wins); nil if never revealed.
        public let displayName: String?
        public let votes: Int
        /// Votes where this model's response was preferred.
        public let preferred: Int
        /// Votes where the other response was preferred.
        public let notPreferred: Int
        public let ties: Int
        public let bothBad: Int

        /// Share of the decisive votes (one side preferred) in which this model was preferred.
        public var preferenceShare: Double? {
            let decisive = preferred + notPreferred
            return decisive == 0 ? nil : Double(preferred) / Double(decisive)
        }
    }

    public enum Exclusion: String, Sendable, Equatable, CaseIterable {
        /// The value is missing or not in the vocabulary.
        case valueNotInterpreted = "value_not_interpreted"
        /// No claimed model was found for a side (no vote claim, and the voted message is missing
        /// from the snapshot or claims no model).
        case noModelClaim = "no_model_claim"
        /// A side's claims name different models.
        case conflictingClaims = "conflicting_claims"
        /// Both sides claim the same model.
        case sameModelOnBothSides = "same_model_on_both_sides"
    }

    public let decoderVersion: String?
    /// Where the vote vocabulary comes from (`VoteVocabulary.evidence`).
    public let vocabularyEvidence: String
    public let conversations: Int
    /// Conversations with at least one detail snapshot (the rest are known from the list only).
    public let withSnapshot: Int
    /// Messages of the latest snapshots by role: your prompts ("user") and responses ("assistant").
    public let prompts: Int
    public let responses: Int
    /// Conversations by recorded mode ("not stated" when absent), most frequent first.
    public let modes: [Tally]
    /// Conversations by recorded kind (entry type), most frequent first.
    public let kinds: [Tally]
    public let accounts: [AccountID: Int]
    /// Conversations by the month of their last update, every month from the first to the last.
    public let activity: [Month]
    /// Conversations without a parsable update time.
    public let undated: Int
    public let votes: Votes
    /// Most votes first, then the higher preference share, then the name.
    public let models: [ModelRecord]
    /// Votes left out of the model records, by reason.
    public let exclusions: [Exclusion: Int]

    public var isEmpty: Bool { conversations == 0 }

    /// Votes that went into the model records.
    public var attributedVotes: Int { votes.total - exclusions.values.reduce(0, +) }

    public static func build(source: InsightsSource, vocabulary: VoteVocabulary, calendar: Calendar) -> ArchiveInsights {
        let conversations = source.conversations

        func tallies(_ labels: [String]) -> [Tally] {
            Dictionary(labels.map { ($0, 1) }, uniquingKeysWith: +)
                .map { Tally($0.key, $0.value) }
                .sorted { ($0.count, $1.label) > ($1.count, $0.label) }
        }

        // Activity by the month of the last update.
        var months: [DateComponents: Int] = [:]
        var undated = 0
        for conversation in conversations {
            guard let micros = conversation.updatedOrder else {
                undated += 1
                continue
            }
            let date = Date(timeIntervalSince1970: TimeInterval(micros / 1_000_000))
            let parts = calendar.dateComponents([.year, .month], from: date)
            months[DateComponents(year: parts.year, month: parts.month), default: 0] += 1
        }
        var activity: [Month] = []
        let keys = months.keys.compactMap { key in key.year.flatMap { year in key.month.map { (year, $0) } } }
        if let first = keys.min(by: { $0 < $1 }), let last = keys.max(by: { $0 < $1 }) {
            var (year, month) = first
            while (year, month) <= last {
                activity.append(Month(year: year, month: month, count: months[DateComponents(year: year, month: month)] ?? 0))
                (year, month) = month == 12 ? (year + 1, 1) : (year, month + 1)
            }
        }

        // Votes and their attribution.
        var outcomes = Dictionary(uniqueKeysWithValues: VoteOutcome.allCases.map { ($0, 0) })
        var unrecognized: [String] = []
        var withoutValue = 0
        var exclusions: [Exclusion: Int] = [:]
        struct Record { var votes = 0, preferred = 0, notPreferred = 0, ties = 0, bothBad = 0 }
        var records: [String: Record] = [:]

        struct SnapshotKey: Hashable { let account: AccountID; let sequence: UInt64 }
        struct MessageKey: Hashable { let account: AccountID; let sequence: UInt64; let message: String }
        var messageModels: [MessageKey: String] = [:]
        for message in source.messages {
            if let model = message.modelRemoteID {
                messageModels[MessageKey(account: message.account, sequence: message.sequence, message: message.remoteID)] = model
            }
        }
        struct SideKey: Hashable { let account: AccountID; let sequence: UInt64; let vote: String; let side: String }
        var voteClaims: [SideKey: Set<String>] = [:]
        for item in source.claims {
            let claim = item.claim
            if claim.subject == .feedback, claim.source == "pairwise_feedback", let side = claim.role {
                voteClaims[SideKey(account: item.account, sequence: item.sequence, vote: claim.subjectID, side: side), default: []]
                    .insert(claim.modelID)
            }
        }
        // Revealed names, from any snapshot: the latest record's name per model ID. Model IDs are
        // Arena's own, so under all accounts a name revealed in one account labels the same ID in
        // another.
        var names: [String: (sequence: UInt64, account: String, name: String)] = [:]
        for item in source.namedClaims {
            let claim = item.claim
            if claim.source == "detail_revealed", let name = claim.displayName {
                let candidate = (sequence: item.sequence, account: item.account.rawValue.uuidString, name: name)
                if let current = names[claim.modelID],
                    (current.sequence, current.account, current.name) >= (candidate.sequence, candidate.account, candidate.name)
                {
                    continue
                }
                names[claim.modelID] = candidate
            }
        }

        for item in source.votes {
            let vote = item.feedback
            guard let outcome = vocabulary.outcome(vote.value) else {
                if let value = vote.value { unrecognized.append(value) } else { withoutValue += 1 }
                exclusions[.valueNotInterpreted, default: 0] += 1
                continue
            }
            outcomes[outcome, default: 0] += 1
            enum Side { case model(String), excluded(Exclusion) }
            func model(_ side: String, message: String?) -> Side {
                var claimed = voteClaims[SideKey(account: item.account, sequence: item.sequence, vote: vote.remoteID, side: side)] ?? []
                if let message, let own = messageModels[MessageKey(account: item.account, sequence: item.sequence, message: message)] {
                    claimed.insert(own)
                }
                switch claimed.count {
                case 0: return .excluded(.noModelClaim)
                case 1: return .model(claimed.first!)
                default: return .excluded(.conflictingClaims)
                }
            }
            let a = model("a", message: vote.messageA), b = model("b", message: vote.messageB)
            let modelA: String, modelB: String
            switch (a, b) {
            case (.model(let x), .model(let y)):
                (modelA, modelB) = (x, y)
            default:
                // One reason per vote; a conflict outweighs a missing claim.
                let reasons = [a, b].compactMap { side -> Exclusion? in
                    if case .excluded(let reason) = side { return reason }
                    return nil
                }
                exclusions[reasons.contains(.conflictingClaims) ? .conflictingClaims : .noModelClaim, default: 0] += 1
                continue
            }
            guard modelA != modelB else {
                exclusions[.sameModelOnBothSides, default: 0] += 1
                continue
            }
            records[modelA, default: Record()].votes += 1
            records[modelB, default: Record()].votes += 1
            switch outcome {
            case .preferA:
                records[modelA]!.preferred += 1
                records[modelB]!.notPreferred += 1
            case .preferB:
                records[modelB]!.preferred += 1
                records[modelA]!.notPreferred += 1
            case .tie:
                records[modelA]!.ties += 1
                records[modelB]!.ties += 1
            case .bothBad:
                records[modelA]!.bothBad += 1
                records[modelB]!.bothBad += 1
            }
        }

        let models = records.map { id, r in
            ModelRecord(
                modelID: id, displayName: names[id]?.name, votes: r.votes, preferred: r.preferred,
                notPreferred: r.notPreferred, ties: r.ties, bothBad: r.bothBad)
        }.sorted { lhs, rhs in
            if lhs.votes != rhs.votes { return lhs.votes > rhs.votes }
            let l = lhs.preferenceShare ?? -1, r = rhs.preferenceShare ?? -1
            if l != r { return l > r }
            return (lhs.displayName ?? lhs.modelID, lhs.modelID) < (rhs.displayName ?? rhs.modelID, rhs.modelID)
        }

        return ArchiveInsights(
            decoderVersion: source.decoderVersion, vocabularyEvidence: vocabulary.evidence,
            conversations: conversations.count,
            withSnapshot: conversations.filter { $0.latestSnapshotSequence != nil }.count,
            prompts: source.messages.filter { $0.role == "user" }.count,
            responses: source.messages.filter { $0.role == "assistant" }.count,
            modes: tallies(conversations.map { $0.mode ?? "not stated" }),
            kinds: tallies(conversations.map(\.kind)),
            accounts: Dictionary(conversations.map { ($0.account, 1) }, uniquingKeysWith: +),
            activity: activity, undated: undated,
            votes: Votes(
                total: source.votes.count, outcomes: outcomes, unrecognized: tallies(unrecognized),
                withoutValue: withoutValue),
            models: models, exclusions: exclusions)
    }
}

/// Reads the index and builds `ArchiveInsights`. Read-only.
public struct InsightsService: Sendable {
    private let archive: ArchiveService
    private let vocabulary: VoteVocabulary

    public init(archive: ArchiveService, vocabulary: VoteVocabulary) {
        self.archive = archive
        self.vocabulary = vocabulary
    }

    /// `accounts` nil = every account.
    public func insights(accounts: Set<AccountID>? = nil, calendar: Calendar = .current) throws -> ArchiveInsights {
        ArchiveInsights.build(source: try archive.insightsSource(accounts: accounts), vocabulary: vocabulary, calendar: calendar)
    }
}
