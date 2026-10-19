import ApplicationActions
import ArchiveIndex
import Foundation
import SuiteDomain
import Testing

// Insights (Docs/insights-2026-10-19.md): the one-transaction index read and the pure aggregation.

private let vocabulary = VoteVocabulary(
    outcomes: ["model_a": .preferA, "model_b": .preferB, "tie": .tie, "both_bad": .bothBad], evidence: "test")

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// Microseconds since 1970 for a UTC date.
private func micros(_ year: Int, _ month: Int, _ day: Int = 15) -> Int64 {
    let date = utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    return Int64(date.timeIntervalSince1970) * 1_000_000
}

private func tempIndexURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("insights-\(UUID().uuidString)/index.sqlite")
}

/// One battle's latest snapshot: two responses with their own model claims and one vote.
private struct Battle {
    var id: String
    var mode: String? = "battle"
    var updated: Int64? = nil
    var modelA: String? = "alpha"
    var modelB: String? = "beta"
    /// The vote's own claims; nil = the same as the messages'.
    var voteA: String? = nil
    var voteB: String? = nil
    var value: String? = "model_a"
    var revealed: [String: String] = [:]
    /// The message the vote names for side A; nil = this battle's own response A.
    var voteMessageA: String? = nil

    func events() -> [ArchiveEvent] {
        let prompt = ArchivedMessage(
            remoteID: "\(id)-p", role: "user", status: nil, lane: nil, parentIDs: [], modelRemoteID: nil, createdAt: nil,
            updatedAt: nil, failureReason: nil, blocks: [], attachments: [])
        func response(_ lane: String, _ model: String?) -> ArchivedMessage {
            ArchivedMessage(
                remoteID: "\(id)-\(lane)", role: "assistant", status: "success", lane: lane, parentIDs: ["\(id)-p"],
                modelRemoteID: model, createdAt: nil, updatedAt: nil, failureReason: nil, blocks: [], attachments: [])
        }
        var claims: [ModelClaim] = []
        for (lane, model) in [("a", modelA), ("b", modelB)] {
            if let model {
                claims.append(ModelClaim(subject: .message, subjectID: "\(id)-\(lane)", role: lane, modelID: model, source: "message_model_id"))
            }
        }
        for (lane, model) in [("a", voteA ?? modelA), ("b", voteB ?? modelB)] {
            if let model {
                claims.append(ModelClaim(subject: .feedback, subjectID: "\(id)-v", role: lane, modelID: model, source: "pairwise_feedback"))
            }
        }
        for (model, name) in revealed.sorted(by: { $0.key < $1.key }) {
            claims.append(
                ModelClaim(subject: .conversation, subjectID: id, role: nil, modelID: model, displayName: name, source: "detail_revealed"))
        }
        let vote = ArchivedFeedback(remoteID: "\(id)-v", value: value, messageA: voteMessageA ?? "\(id)-a", messageB: "\(id)-b")
        return [
            .snapshot(
                ConversationSnapshot(
                    facts: ConversationFacts(remoteID: id, kind: "evaluation", mode: mode, updatedOrder: updated),
                    messages: [prompt, response("a", modelA), response("b", modelB)], lastMessageIDs: [], claims: claims,
                    feedback: [vote]))
        ]
    }
}

private func index(_ batches: [(AccountID, UInt64, [ArchiveEvent])]) throws -> ArchiveIndex {
    let index = try ArchiveIndex(url: tempIndexURL())
    for (account, sequence, events) in batches {
        try index.apply(
            account: account,
            records: [(RecordRef(account: account, sequence: sequence, segment: 1, offset: Int(sequence), length: 64),
                       DecodedRecord(events: events, unknownFields: [:]))],
            through: sequence, decoderVersion: "test/1")
    }
    return index
}

private func insights(_ index: ArchiveIndex, accounts: Set<AccountID>? = nil) throws -> ArchiveInsights {
    ArchiveInsights.build(source: try index.insightsSource(accounts: accounts), vocabulary: vocabulary, calendar: utc)
}

@Test func countsModesKindsAccountsAndMessagesOfTheLatestSnapshots() throws {
    let one = AccountID(), two = AccountID()
    let index = try index([
        (one, 1, Battle(id: "c1").events()),
        (one, 2, Battle(id: "c2", mode: "side-by-side").events()),
        (two, 1, Battle(id: "c3").events()),
        (two, 2, [.listed(ConversationFacts(remoteID: "c4", kind: "agentic"), claims: [])]),
    ])
    let result = try insights(index)
    #expect(result.conversations == 4 && result.withSnapshot == 3)
    #expect(result.prompts == 3 && result.responses == 6)
    #expect(result.modes == [.init("battle", 2), .init(nil, 1), .init("side-by-side", 1)], "not stated stays nil")
    #expect(result.kinds == [.init("evaluation", 3), .init("agentic", 1)])
    #expect(result.accounts == [one: 2, two: 2])
    #expect(result.decoderVersion == "test/1" && result.vocabularyEvidence == "test")

    let onlyTwo = try insights(index, accounts: [two])
    #expect(onlyTwo.conversations == 2 && onlyTwo.accounts == [two: 2] && onlyTwo.votes.total == 1)
}

@Test func activityFillsEveryMonthAndCountsUndatedConversations() throws {
    let account = AccountID()
    let index = try index([
        (account, 1, Battle(id: "c1", updated: micros(2025, 11)).events()),
        (account, 2, Battle(id: "c2", updated: micros(2026, 2, 1)).events()),
        (account, 3, Battle(id: "c3", updated: micros(2026, 2, 28)).events()),
        (account, 4, Battle(id: "c4", updated: nil).events()),
    ])
    let result = try insights(index)
    #expect(result.activity.map { "\($0.year)-\($0.month):\($0.count)" } == ["2025-11:1", "2025-12:0", "2026-1:0", "2026-2:2"])
    #expect(result.undated == 1)

    // Month boundaries follow the calendar's time zone.
    var tokyo = utc
    tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let lateJanuaryUTC = utc.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 20))!
    let shifted = try ArchiveIndex(url: tempIndexURL())
    try shifted.apply(
        account: account,
        records: [(RecordRef(account: account, sequence: 1, segment: 1, offset: 1, length: 64),
                   DecodedRecord(events: Battle(id: "c1", updated: Int64(lateJanuaryUTC.timeIntervalSince1970) * 1_000_000).events(), unknownFields: [:]))],
        through: 1, decoderVersion: "test/1")
    let source = try shifted.insightsSource()
    #expect(ArchiveInsights.build(source: source, vocabulary: vocabulary, calendar: utc).activity.map(\.month) == [1])
    #expect(ArchiveInsights.build(source: source, vocabulary: vocabulary, calendar: tokyo).activity.map(\.month) == [2])
}

@Test func votesAreInterpretedOnlyThroughTheVocabulary() throws {
    let account = AccountID()
    let index = try index([
        (account, 1, Battle(id: "c1", value: "model_a").events()),
        (account, 2, Battle(id: "c2", value: "model_b").events()),
        (account, 3, Battle(id: "c3", value: "tie").events()),
        (account, 4, Battle(id: "c4", value: "both_bad").events()),
        (account, 5, Battle(id: "c5", value: "model_c").events()),
        (account, 6, Battle(id: "c6", value: nil).events()),
    ])
    let votes = try insights(index).votes
    #expect(votes.total == 6)
    #expect(votes.outcomes == [.preferA: 1, .preferB: 1, .tie: 1, .bothBad: 1])
    #expect(votes.unrecognized == [.init("model_c", 1)], "kept as recorded, never interpreted")
    #expect(votes.withoutValue == 1)
}

@Test func modelRecordsCountOnlyUnambiguousVotesAndNameEveryExclusion() throws {
    let account = AccountID()
    let index = try index([
        (account, 1, Battle(id: "c1", value: "model_a").events()),          // alpha preferred over beta
        (account, 2, Battle(id: "c2", value: "model_b").events()),          // beta preferred over alpha
        (account, 3, Battle(id: "c3", modelA: "gamma", value: "model_a").events()),  // gamma over beta
        (account, 4, Battle(id: "c4", value: "tie").events()),
        (account, 5, Battle(id: "c5", value: "both_bad").events()),
        (account, 6, Battle(id: "c6", voteA: "delta", value: "model_a").events()),   // vote and message disagree
        (account, 7, Battle(id: "c7", modelA: nil, value: "model_a").events()),      // side A has no claim
        (account, 8, Battle(id: "c8", modelB: "alpha", value: "model_a").events()),  // alpha on both sides
        (account, 9, Battle(id: "c9", value: "model_c").events()),                   // value not interpreted
    ])
    let result = try insights(index)
    #expect(result.exclusions == [.conflictingClaims: 1, .noModelClaim: 1, .sameModelOnBothSides: 1, .valueNotInterpreted: 1])
    #expect(result.attributedVotes == 5)
    let records = Dictionary(uniqueKeysWithValues: result.models.map { ($0.modelID, $0) })
    #expect(Set(records.keys) == ["alpha", "beta", "gamma"], "an excluded vote adds nothing, not even its claimed models")
    let alpha = try #require(records["alpha"]), beta = try #require(records["beta"]), gamma = try #require(records["gamma"])
    #expect((alpha.votes, alpha.preferred, alpha.notPreferred, alpha.ties, alpha.bothBad) == (4, 1, 1, 1, 1))
    #expect((beta.votes, beta.preferred, beta.notPreferred, beta.ties, beta.bothBad) == (5, 1, 2, 1, 1))
    #expect((gamma.votes, gamma.preferred, gamma.notPreferred) == (1, 1, 0))
    #expect(alpha.preferenceShare == 0.5 && gamma.preferenceShare == 1)
    #expect(result.models.map(\.modelID) == ["beta", "alpha", "gamma"], "most votes first")
    expectConsistentRecords(result)
}

/// Every attributed vote adds one to each of its two models, and each vote has exactly one outcome.
private func expectConsistentRecords(_ result: ArchiveInsights) {
    #expect(result.models.map(\.votes).reduce(0, +) == 2 * result.attributedVotes)
    #expect(result.models.allSatisfy { $0.votes == $0.preferred + $0.notPreferred + $0.ties + $0.bothBad })
}

@Test func aModelWithoutDecisiveVotesHasNoShareAndEmptyValuesAreNotInterpreted() throws {
    let account = AccountID()
    let index = try index([
        (account, 1, Battle(id: "c1", modelA: "epsilon", modelB: "zeta", value: "tie").events()),
        (account, 2, Battle(id: "c2", modelA: "epsilon", modelB: "zeta", value: "both_bad").events()),
        (account, 3, Battle(id: "c3", value: "").events()),
    ])
    let result = try insights(index)
    #expect(result.models.map(\.modelID).sorted() == ["epsilon", "zeta"])
    #expect(result.models.allSatisfy { $0.preferenceShare == nil && $0.votes == 2 })
    #expect(result.votes.unrecognized == [.init("", 1)] && result.votes.withoutValue == 0, "present but empty: kept as recorded")
    #expect(result.exclusions == [.valueNotInterpreted: 1])
    expectConsistentRecords(result)
}

@Test func aVoteNamingAMessageOutsideTheSnapshotHasNoModelForThatSide() throws {
    let account = AccountID()
    // The vote names a message the snapshot does not hold, and the vote itself claims no model for
    // that side: nothing names the model, so the vote is left out rather than guessed.
    let index = try index([(account, 1, Battle(id: "c1", modelA: nil, voteMessageA: "elsewhere").events())])
    let result = try insights(index)
    #expect(result.exclusions == [.noModelClaim: 1] && result.models.isEmpty)
}

@Test func rowsOfAnotherConversationInTheSameRecordAreNotCounted() throws {
    let account = AccountID()
    // One record holding c1's snapshot and, for c2, a listing whose claim names c1's vote: joined by
    // sequence alone, that claim would turn c1's vote into a conflict.
    var events = Battle(id: "c1").events()
    events.append(
        .listed(
            ConversationFacts(remoteID: "c2", kind: "evaluation"),
            claims: [ModelClaim(subject: .feedback, subjectID: "c1-v", role: "a", modelID: "intruder", source: "pairwise_feedback")]))
    let result = try insights(try index([(account, 1, events)]))
    #expect(result.conversations == 2 && result.exclusions.isEmpty && result.attributedVotes == 1)
    #expect(Set(result.models.map(\.modelID)) == ["alpha", "beta"])
}

@Test func aNameRevealedInAnEarlierSnapshotIsKept() throws {
    let account = AccountID()
    let index = try index([
        (account, 1, Battle(id: "c1", revealed: ["alpha": "Alpha"]).events()),
        // The newer snapshot of the same conversation no longer carries the reveal.
        (account, 2, Battle(id: "c1").events()),
    ])
    let result = try insights(index)
    #expect(result.votes.total == 1)
    #expect(Dictionary(uniqueKeysWithValues: result.models.map { ($0.modelID, $0.displayName) }) == ["alpha": "Alpha", "beta": nil])
}

@Test func theLatestRevealedNameIsShownAndOnlyLatestSnapshotsCount() throws {
    let account = AccountID()
    let index = try index([
        (account, 1, Battle(id: "c1", value: "model_b", revealed: ["alpha": "Alpha 1"]).events()),
        // A later snapshot of the same conversation replaces its vote (latest snapshot only).
        (account, 2, Battle(id: "c1", value: "model_a", revealed: ["alpha": "Alpha 1"]).events()),
        (account, 3, Battle(id: "c2", value: "model_a", revealed: ["alpha": "Alpha 2", "beta": "Beta"]).events()),
    ])
    let result = try insights(index)
    #expect(result.votes.total == 2 && result.votes.outcomes[.preferA] == 2 && result.votes.outcomes[.preferB] == 0)
    let names = Dictionary(uniqueKeysWithValues: result.models.map { ($0.modelID, $0.displayName) })
    #expect(names == ["alpha": "Alpha 2", "beta": "Beta"])
}

@Test func anEmptyArchiveHasEmptyInsights() throws {
    let result = try insights(try ArchiveIndex(url: tempIndexURL()))
    #expect(result.isEmpty && result.activity.isEmpty && result.models.isEmpty && result.votes.total == 0)
    #expect(result.decoderVersion == nil)
}
