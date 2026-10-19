import ApplicationActions
import ArchiveIndex
import CaptureJournal
import Foundation
import SuiteDomain
import Testing

@testable import ArenaAdapter

// Insights end to end: detail responses journaled, decoded by ArenaArchiveDecoder, projected, then
// summarized with the adapter's vote vocabulary (Docs/insights-2026-10-19.md, N-016).

private func battle(_ id: String, updatedAt: String, a: String, b: String, value: String, names: [String: String]) -> Data {
    let revealed = names.sorted { $0.key < $1.key }.map { #"{"id":"\#($0.key)","displayName":"\#($0.value)"}"# }
    return Data(#"""
    {"id":"\#(id)","title":"t","mode":"battle","updatedAt":"\#(updatedAt)","lastMessageIds":["\#(id)a","\#(id)b"],
     "messages":[
      {"id":"\#(id)u","role":"user","status":"success","content":"q","parentMessageIds":[]},
      {"id":"\#(id)a","role":"assistant","status":"success","participantPosition":"a","modelId":"\#(a)","parentMessageIds":["\#(id)u"],"content":"x"},
      {"id":"\#(id)b","role":"assistant","status":"success","participantPosition":"b","modelId":"\#(b)","parentMessageIds":["\#(id)u"],"content":"y"}
     ],
     "revealedModels":[\#(revealed.joined(separator: ","))],
     "pairwiseFeedbacks":[{"id":"\#(id)f","messageAId":"\#(id)a","messageBId":"\#(id)b","modelAId":"\#(a)","modelBId":"\#(b)","value":"\#(value)"}]}
    """#.utf8)
}

@Test func theAdaptersVocabularyIsExactlyTheObservedValues() {
    let vocabulary = ArenaArchiveDecoder.voteVocabulary
    #expect(vocabulary.outcomes == ["model_a": .preferA, "model_b": .preferB, "tie": .tie, "both_bad": .bothBad])
    #expect(vocabulary.outcome("a") == nil && vocabulary.outcome("MODEL_A") == nil && vocabulary.outcome(nil) == nil)
    #expect(vocabulary.evidence.contains("N-016"))
}

@Test func insightsSummarizeDecodedBattles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("insights-\(UUID().uuidString)")
    let account = AccountID()
    let journals = JournalStore(archiveRoot: root)
    let writer = try await journals.writer(for: account)
    let bodies = [
        battle("c1", updatedAt: "2026-08-03 10:00:00.000000+00", a: "m-x", b: "m-y", value: "model_a", names: ["m-x": "X", "m-y": "Y"]),
        battle("c2", updatedAt: "2026-09-14 10:00:00.000000+00", a: "m-y", b: "m-z", value: "model_b", names: ["m-y": "Y", "m-z": "Z"]),
        battle("c3", updatedAt: "2026-09-20 10:00:00.000000+00", a: "m-x", b: "m-z", value: "tie", names: ["m-x": "X 2", "m-z": "Z"]),
    ]
    for (n, body) in bodies.enumerated() {
        _ = try writer.append(
            JournalDraft(
                kind: "exchange", payload: body, accountID: account.rawValue,
                metadata: [
                    "role": .string("detail"), "status": .integer(200), "transfer_end": .string("complete"),
                    "entry_id": .string("c\(n + 1)"), "entry_type": .string("evaluation"),
                ]))
    }
    try writer.synchronize()
    let index = try ArchiveIndex(url: root.appendingPathComponent("index/archive.sqlite"))
    let archive = ArchiveService(index: index, journals: journals, decoder: ArenaArchiveDecoder(), accounts: { [account] })
    _ = try await archive.project(account)

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let result = try InsightsService(archive: archive, vocabulary: ArenaArchiveDecoder.voteVocabulary).insights(calendar: utc)

    #expect(result.decoderVersion == ArenaArchiveDecoder().version)
    #expect(result.conversations == 3 && result.prompts == 3 && result.responses == 6)
    #expect(result.modes == [.init("battle", 3)])
    #expect(result.activity.map { "\($0.year)-\($0.month):\($0.count)" } == ["2026-8:1", "2026-9:2"])
    #expect(result.votes.total == 3 && result.votes.outcomes == [.preferA: 1, .preferB: 1, .tie: 1, .bothBad: 0])
    #expect(result.exclusions.isEmpty && result.attributedVotes == 3)
    let records = Dictionary(uniqueKeysWithValues: result.models.map { ($0.modelID, $0) })
    let x = try #require(records["m-x"]), y = try #require(records["m-y"]), z = try #require(records["m-z"])
    #expect(x.displayName == "X 2", "the latest revealed name")
    #expect((x.votes, x.preferred, x.notPreferred, x.ties) == (2, 1, 0, 1))
    #expect(y.displayName == "Y" && (y.votes, y.preferred, y.notPreferred, y.ties) == (2, 0, 2, 0))
    #expect(z.displayName == "Z" && (z.votes, z.preferred, z.notPreferred, z.ties) == (2, 1, 0, 1))
    #expect(result.models.map(\.votes).reduce(0, +) == 2 * result.attributedVotes)
    #expect(result.models.allSatisfy { $0.votes == $0.preferred + $0.notPreferred + $0.ties + $0.bothBad })
}

/// Insights on a real archive. Read-only on the journals; the index lives in a temporary folder that
/// is removed afterwards. Prints counts only, never names, model IDs, titles or text.
/// `ARENA_SUITE_REAL_ARCHIVE=<archive> swift test --package-path Packages/ArenaProtocol --filter realArchiveInsights`
@Test(.enabled(if: ProcessInfo.processInfo.environment["ARENA_SUITE_REAL_ARCHIVE"] != nil))
func realArchiveInsightsAttributeEveryInterpretedVote() async throws {
    let archiveRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARENA_SUITE_REAL_ARCHIVE"]!)
    let journals = JournalStore(archiveRoot: archiveRoot)
    let accounts = journals.accountsOnDisk()
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("real-insights-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temp) }
    let archive = ArchiveService(
        index: try ArchiveIndex(url: temp.appendingPathComponent("index/archive.sqlite")), journals: journals,
        decoder: ArenaArchiveDecoder(), accounts: { accounts })
    for account in accounts { _ = try await archive.project(account) }

    let result = try InsightsService(archive: archive, vocabulary: ArenaArchiveDecoder.voteVocabulary).insights()
    let outcomes = VoteOutcome.allCases.map { "\($0.rawValue) \(result.votes.outcomes[$0] ?? 0)" }
    print("insights: accounts \(result.accounts.count), conversations \(result.conversations), with snapshot \(result.withSnapshot)")
    print("  prompts \(result.prompts), responses \(result.responses), modes \(result.modes.count), months \(result.activity.count), undated \(result.undated)")
    print("  votes \(result.votes.total): \(outcomes.joined(separator: ", ")); unrecognized values \(result.votes.unrecognized.count), without value \(result.votes.withoutValue)")
    print("  attributed \(result.attributedVotes), exclusions \(result.exclusions.map { "\($0.key.rawValue) \($0.value)" }.sorted()), models \(result.models.count)")
    #expect(result.votes.unrecognized.isEmpty && result.votes.withoutValue == 0, "every recorded value is in the vocabulary (N-016)")
    #expect(result.exclusions.isEmpty, "every vote's claims agree with its messages (N-015)")
    #expect(result.models.allSatisfy { $0.votes == $0.preferred + $0.notPreferred + $0.ties + $0.bothBad })
    #expect(result.models.map(\.votes).reduce(0, +) == 2 * result.attributedVotes)
    // Feedback on a single response is not decoded; any keys inside it are reported as unknown.
    var pointwise = 0
    for account in accounts {
        pointwise += try archive.unknownFields(account: account).filter { $0.path.hasPrefix("$.pointwiseFeedbacks") }.count
    }
    print("  unknown paths under pointwiseFeedbacks: \(pointwise)")
    #expect(pointwise == 0, "no single-response feedback recorded, so the page's pairwise votes are all the votes")

    // History filters (Docs/history-filters-2026-10-19.md) over the same index.
    let list = try archive.conversations(account: nil)
    let facets = try archive.historyFacets(account: nil)
    let now = Date()
    let options = HistoryFilterOptions.build(list, facets: facets, now: now, calendar: .current)
    print("  filters: modes \(options.modes.count), with a vote \(options.withVote), without \(options.withoutVote), no transcript \(options.withoutTranscript), models \(options.models.count), years \(options.years.count), undated \(options.undated)")
    #expect(list.count == result.conversations)
    #expect(options.withoutTranscript == result.conversations - result.withSnapshot, "list-only conversations are neither with nor without a vote")
    #expect(options.withVote + options.withoutVote == result.withSnapshot, "every conversation with a transcript has readable facets")
    #expect(HistoryFilter(votes: .with).apply(list, facets: facets, now: now, calendar: .current).count == options.withVote)
    #expect(HistoryFilter(votes: .without).apply(list, facets: facets, now: now, calendar: .current).count == options.withoutVote)
    #expect(Set(result.models.map(\.modelID)).isSubset(of: Set(options.models.map(\.id))), "every model with a record can be filtered to")
}
