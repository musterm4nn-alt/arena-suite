import ApplicationActions
import ArchiveIndex
import Foundation
import SuiteDomain
import Testing

// History filters (Docs/history-filters-2026-10-19.md): the facet read and the pure filter.

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private func micros(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970) * 1_000_000 }

/// A conversation's snapshot: a prompt and two responses with their own model claims, and
/// optionally a vote that claims the same models.
private func snapshot(
    _ id: String, mode: String? = "battle", updated: Date? = nil, models: (String, String)? = ("alpha", "beta"),
    voted: Bool = true, revealed: [String: String] = [:]
) -> ArchiveEvent {
    func message(_ suffix: String, role: String, model: String?) -> ArchivedMessage {
        ArchivedMessage(
            remoteID: "\(id)-\(suffix)", role: role, status: "success", lane: role == "user" ? nil : suffix, parentIDs: [],
            modelRemoteID: model, createdAt: nil, updatedAt: nil, failureReason: nil, blocks: [], attachments: [])
    }
    var claims: [ModelClaim] = []
    if let (a, b) = models {
        claims += [
            ModelClaim(subject: .message, subjectID: "\(id)-a", role: "a", modelID: a, source: "message_model_id"),
            ModelClaim(subject: .message, subjectID: "\(id)-b", role: "b", modelID: b, source: "message_model_id"),
        ]
        if voted {
            claims += [
                ModelClaim(subject: .feedback, subjectID: "\(id)-v", role: "a", modelID: a, source: "pairwise_feedback"),
                ModelClaim(subject: .feedback, subjectID: "\(id)-v", role: "b", modelID: b, source: "pairwise_feedback"),
            ]
        }
    }
    for (model, name) in revealed.sorted(by: { $0.key < $1.key }) {
        claims.append(ModelClaim(subject: .conversation, subjectID: id, role: nil, modelID: model, displayName: name, source: "detail_revealed"))
    }
    return .snapshot(
        ConversationSnapshot(
            facts: ConversationFacts(remoteID: id, kind: "evaluation", mode: mode, updatedOrder: updated.map(micros)),
            messages: [message("p", role: "user", model: nil), message("a", role: "assistant", model: models?.0),
                       message("b", role: "assistant", model: models?.1)],
            lastMessageIDs: [], claims: claims,
            feedback: voted ? [ArchivedFeedback(remoteID: "\(id)-v", value: "model_a", messageA: "\(id)-a", messageB: "\(id)-b")] : []))
}

private func index(_ batches: [(AccountID, UInt64, [ArchiveEvent])]) throws -> ArchiveIndex {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("filters-\(UUID().uuidString)/index.sqlite")
    let index = try ArchiveIndex(url: url)
    for (account, sequence, events) in batches {
        try index.apply(
            account: account,
            records: [(RecordRef(account: account, sequence: sequence, segment: 1, offset: Int(sequence), length: 64),
                       DecodedRecord(events: events, unknownFields: [:]))],
            through: sequence, decoderVersion: "test/1")
    }
    return index
}

private func shown(_ filter: HistoryFilter, _ index: ArchiveIndex, account: AccountID? = nil, now: Date = date(2026, 10, 19)) throws -> [String] {
    let list = try index.conversations(account: account)
    let facets = HistoryFacets(source: try index.historyFacetSource(account: account))
    return filter.apply(list, facets: facets, now: now, calendar: utc).map(\.remoteID).sorted()
}

@Test func facetsReadTheLatestSnapshotsVotesAndClaimedModels() throws {
    let one = AccountID(), two = AccountID()
    let index = try index([
        (one, 1, [snapshot("c1", revealed: ["alpha": "Alpha"])]),
        (one, 2, [snapshot("c2")]),
        // c2's newer snapshot: other models, no vote. Only this one counts.
        (one, 3, [snapshot("c2", models: ("gamma", "beta"), voted: false)]),
        (one, 4, [.listed(ConversationFacts(remoteID: "c3", kind: "agentic"), claims: [])]),
        (two, 1, [snapshot("c4", models: ("delta", "alpha"))]),
    ])
    let facets = HistoryFacets(source: try index.historyFacetSource(account: nil))
    func facet(_ account: AccountID, _ id: String) -> HistoryFacets.Facet? { facets.conversations[.init(account: account, remoteID: id)] }
    #expect(facet(one, "c1") == .init(votes: 1, models: ["alpha", "beta"]))
    #expect(facet(one, "c2") == .init(votes: 0, models: ["gamma", "beta"]), "latest snapshot only")
    #expect(facet(one, "c3") == .init(votes: 0, models: []), "known from the list only")
    #expect(facet(two, "c4") == .init(votes: 1, models: ["delta", "alpha"]))
    #expect(facets.names == ["alpha": "Alpha"])

    let onlyTwo = HistoryFacets(source: try index.historyFacetSource(account: two))
    #expect(Set(onlyTwo.conversations.keys) == [.init(account: two, remoteID: "c4")] && onlyTwo.names.isEmpty)
}

@Test func eachDimensionNarrowsAloneAndTogether() throws {
    let account = AccountID()
    let index = try index([
        (account, 1, [snapshot("c1", mode: "battle")]),
        (account, 2, [snapshot("c2", mode: "side-by-side", models: ("gamma", "beta"))]),
        (account, 3, [snapshot("c3", mode: nil, voted: false)]),
        (account, 4, [snapshot("c4", mode: "direct", models: ("gamma", "delta"), voted: false)]),
        (account, 5, [.listed(ConversationFacts(remoteID: "c5", kind: "agentic", mode: "battle"), claims: [])]),
    ])
    #expect(try shown(HistoryFilter(), index) == ["c1", "c2", "c3", "c4", "c5"])
    #expect(try shown(HistoryFilter(modes: ["battle"]), index) == ["c1", "c5"])
    #expect(try shown(HistoryFilter(modes: [nil]), index) == ["c3"], "not stated")
    #expect(try shown(HistoryFilter(modes: ["side-by-side", nil]), index) == ["c2", "c3"], "any of the chosen modes")
    #expect(try shown(HistoryFilter(votes: .with), index) == ["c1", "c2"])
    #expect(try shown(HistoryFilter(votes: .without), index) == ["c3", "c4"])
    #expect(try !shown(HistoryFilter(votes: .with), index).contains("c5") && !shown(HistoryFilter(votes: .without), index).contains("c5"),
        "a conversation known only from the list has no transcript: whether it has a vote is unknown")
    #expect(try shown(HistoryFilter(model: "gamma"), index) == ["c2", "c4"])
    #expect(try shown(HistoryFilter(model: "nobody"), index).isEmpty)
    #expect(try shown(HistoryFilter(modes: ["battle", "direct"], votes: .without, model: "gamma"), index) == ["c4"])
}

@Test func aModelClaimedOnlyInAnEarlierSnapshotDoesNotMatch() throws {
    let account = AccountID()
    let index = try index([
        (account, 1, [snapshot("c1", models: ("alpha", "beta"))]),
        (account, 2, [snapshot("c1", models: ("gamma", "beta"))]),
    ])
    #expect(try shown(HistoryFilter(model: "alpha"), index).isEmpty)
    #expect(try shown(HistoryFilter(model: "gamma"), index) == ["c1"])
}

@Test func periodsFollowTheClockAndTheCalendar() throws {
    let account = AccountID()
    let now = date(2026, 10, 19, 12)
    let index = try index([
        (account, 1, [snapshot("exactly-7-days", updated: now.addingTimeInterval(-7 * 86_400))]),
        (account, 2, [snapshot("just-over-7-days", updated: now.addingTimeInterval(-7 * 86_400 - 1))]),
        (account, 3, [snapshot("12-months", updated: date(2025, 10, 19, 12))]),
        (account, 4, [snapshot("over-12-months", updated: date(2025, 10, 19, 11))]),
        (account, 5, [snapshot("new-year-utc", updated: date(2025, 12, 31, 20))]),
        (account, 6, [snapshot("undated", updated: nil)]),
    ])
    #expect(try shown(HistoryFilter(period: .lastDays(7)), index, now: now) == ["exactly-7-days"])
    #expect(try shown(HistoryFilter(period: .lastDays(30)), index, now: now) == ["exactly-7-days", "just-over-7-days"])
    #expect(try shown(HistoryFilter(period: .lastMonths(12)), index, now: now)
        == ["12-months", "exactly-7-days", "just-over-7-days", "new-year-utc"])
    #expect(try shown(HistoryFilter(period: .year(2025)), index, now: now) == ["12-months", "new-year-utc", "over-12-months"])
    #expect(try shown(HistoryFilter(period: .any), index, now: now).contains("undated"))

    // The year follows the calendar's time zone: 20:00 UTC on 31 December is already 2026 in Tokyo.
    var tokyo = utc
    tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    let list = try index.conversations(account: nil)
    let facets = HistoryFacets(source: try index.historyFacetSource(account: nil))
    let in2026 = HistoryFilter(period: .year(2026)).apply(list, facets: facets, now: now, calendar: tokyo).map(\.remoteID)
    #expect(in2026.contains("new-year-utc") && !in2026.contains("undated"))
}

@Test func optionsCountEachChoiceInTheList() throws {
    let account = AccountID()
    let now = date(2026, 10, 19)
    let index = try index([
        (account, 1, [snapshot("c1", mode: "battle", updated: date(2026, 10, 15), revealed: ["alpha": "Alpha"])]),
        (account, 2, [snapshot("c2", mode: "battle", updated: date(2025, 3, 1), models: ("gamma", "beta"))]),
        (account, 3, [snapshot("c3", mode: nil, updated: nil, voted: false)]),
        (account, 4, [.listed(ConversationFacts(remoteID: "c4", kind: "agentic", mode: "", updatedOrder: micros(date(2026, 9, 1))), claims: [])]),
    ])
    let list = try index.conversations(account: nil)
    let facets = HistoryFacets(source: try index.historyFacetSource(account: nil))
    let options = HistoryFilterOptions.build(list, facets: facets, now: now, calendar: utc)
    #expect(options.modes == [.init("battle", 2), .init(nil, 1), .init("", 1)], "count, then not stated, then the recorded value")
    #expect(options.withVote == 2 && options.withoutVote == 1 && options.withoutTranscript == 1)
    #expect(options.withVote + options.withoutVote + options.withoutTranscript == list.count)
    #expect(options.models == [
        .init(id: "beta", name: nil, count: 3), .init(id: "alpha", name: "Alpha", count: 2), .init(id: "gamma", name: nil, count: 1),
    ])
    #expect(options.years == [.init(2026, 2), .init(2025, 1)] && options.undated == 1)
    #expect(options.recent == [.init(.lastDays(7), 1), .init(.lastDays(30), 1), .init(.lastMonths(12), 2)])
    // Each count is what choosing it shows.
    for item in options.recent {
        #expect(HistoryFilter(period: item.value).apply(list, facets: facets, now: now, calendar: utc).count == item.count)
    }
    #expect(HistoryFilter(votes: .with).apply(list, facets: facets, now: now, calendar: utc).count == options.withVote)
    #expect(HistoryFilter(votes: .without).apply(list, facets: facets, now: now, calendar: utc).count == options.withoutVote)

    // Without facets the vote and model choices count nothing.
    let blind = HistoryFilterOptions.build(list, facets: nil, now: now, calendar: utc)
    #expect(blind.withVote == 0 && blind.withoutVote == 0 && blind.models.isEmpty && blind.withoutTranscript == 1)
    #expect(blind.modes == options.modes && blind.years == options.years && blind.recent == options.recent)
}

@Test func unreadableOrMissingFacetsAreNotGuessed() throws {
    let account = AccountID()
    let index = try index([
        (account, 1, [snapshot("c1")]),
        (account, 2, [snapshot("c2", voted: false)]),
    ])
    let list = try index.conversations(account: nil)
    let filters = [HistoryFilter(votes: .with), HistoryFilter(votes: .without), HistoryFilter(model: "alpha")]

    // Facets that could not be read: the vote and model dimensions are not applied (the app says so).
    for filter in filters {
        #expect(filter.needsFacets)
        #expect(filter.apply(list, facets: nil, now: date(2026, 10, 19), calendar: utc).count == list.count)
    }
    #expect(HistoryFilter(modes: ["direct"], votes: .with).apply(list, facets: nil, now: date(2026, 10, 19), calendar: utc).isEmpty,
        "the other dimensions still apply")
    #expect(!HistoryFilter(modes: ["battle"]).needsFacets && !HistoryFilter(period: .lastDays(7)).needsFacets)

    // Readable facets that lack a conversation (a sync landed between the two reads): it matches no
    // vote or model choice rather than counting as "without".
    let partial = HistoryFacets(conversations: [.init(account: account, remoteID: "c1"): .init(votes: 1, models: ["alpha"])], names: [:])
    for filter in filters {
        #expect(!filter.apply(list, facets: partial, now: date(2026, 10, 19), calendar: utc).map(\.remoteID).contains("c2"))
    }
    #expect(HistoryFilter().apply(list, facets: partial, now: date(2026, 10, 19), calendar: utc).count == 2)
}

@Test func modeLabelsAndOrderAreStable() {
    #expect(HistoryFilter.label(mode: nil) == "not stated")
    #expect(HistoryFilter.label(mode: "") != "" && HistoryFilter.label(mode: "") != HistoryFilter.label(mode: nil))
    #expect(HistoryFilter.label(mode: "battle") == "battle")
    #expect(HistoryFilter.label(mode: "not stated") != HistoryFilter.label(mode: nil), "a recorded value never reads as a missing one")
    let items: [(mode: String?, count: Int)] = [("b", 1), ("", 1), (nil, 1), ("a", 2)]
    for permutation in [items, items.reversed(), [items[2], items[0], items[3], items[1]]] {
        #expect(permutation.sorted(by: HistoryFilter.modeOrder).map(\.mode) == ["a", nil, "", "b"])
    }
}

@Test func searchSummaryNamesWhatItCounted() {
    #expect(SearchSummary.lines(read: 0, visible: 0, limit: 1_000, shown: 200).isEmpty)
    #expect(SearchSummary.lines(read: 1, visible: 1, limit: 1_000, shown: 200) == ["1 match"])
    #expect(SearchSummary.lines(read: 120, visible: 23, limit: 1_000, shown: 200) == ["23 matches", "97 more hidden by the history filters"])
    #expect(SearchSummary.lines(read: 5, visible: 0, limit: 1_000, shown: 200) == ["5 matches hidden by the history filters"])
    #expect(SearchSummary.lines(read: 1, visible: 0, limit: 1_000, shown: 200) == ["1 match hidden by the history filters"])
    let capped = SearchSummary.lines(read: 1_000, visible: 600, limit: 1_000, shown: 200)
    #expect(capped.first == "First 200 of 600 matches")
    #expect(capped.last?.contains("stopped at 1,000") == true, "a capped search says its counts cover only what it read")
    #expect(!capped.joined().contains("+"))
}

/// Votes are matched to a conversation by sequence alone (`feedback` has no conversation column).
/// That is sound only while a record holds at most one snapshot: the index refuses a second one.
@Test func aRecordHoldsAtMostOneSnapshotSoVotesMatchBySequence() throws {
    let account = AccountID()
    #expect(throws: (any Error).self) { _ = try index([(account, 1, [snapshot("c1"), snapshot("c2", voted: false)])]) }
}

/// With other filters on, each menu count is what choosing that option shows.
@Test func menuCountsAreWhatChoosingShowsUnderTheOtherFilters() throws {
    let account = AccountID()
    let now = date(2026, 10, 19)
    let index = try index([
        (account, 1, [snapshot("c1", mode: "battle", updated: date(2026, 10, 15))]),
        (account, 2, [snapshot("c2", mode: "battle", updated: date(2025, 3, 1), models: ("gamma", "beta"), voted: false)]),
        (account, 3, [snapshot("c3", mode: "direct", updated: date(2026, 9, 1), models: ("gamma", "alpha"))]),
        (account, 4, [snapshot("c4", mode: nil, updated: nil, voted: false)]),
        (account, 5, [.listed(ConversationFacts(remoteID: "c5", kind: "agentic", mode: "battle", updatedOrder: micros(date(2026, 10, 1))), claims: [])]),
    ])
    let list = try index.conversations(account: nil)
    let facets = HistoryFacets(source: try index.historyFacetSource(account: nil))
    func count(_ filter: HistoryFilter) -> Int { filter.apply(list, facets: facets, now: now, calendar: utc).count }

    let active = [
        HistoryFilter(modes: ["battle"]), HistoryFilter(votes: .with), HistoryFilter(model: "gamma"),
        HistoryFilter(period: .year(2026)), HistoryFilter(modes: ["battle", nil], votes: .without, period: .lastMonths(12)),
    ]
    for filter in active {
        let options = HistoryFilterOptions.build(list, facets: facets, filter: filter, now: now, calendar: utc)
        for mode in options.modes {
            var choice = filter
            choice.modes = [mode.value]
            #expect(count(choice) == mode.count, "mode \(String(describing: mode.value)) under \(filter)")
        }
        for (votes, expected) in [(HistoryFilter.Votes.with, options.withVote), (.without, options.withoutVote)] {
            var choice = filter
            choice.votes = votes
            #expect(count(choice) == expected, "\(votes) under \(filter)")
        }
        for model in options.models {
            var choice = filter
            choice.model = model.id
            #expect(count(choice) == model.count, "model \(model.id) under \(filter)")
        }
        for period in options.recent + options.years.map({ .init(.year($0.value), $0.count) }) {
            var choice = filter
            choice.period = period.value
            #expect(count(choice) == period.count, "\(period.value) under \(filter)")
        }
        var anyTime = filter
        anyTime.period = .any
        let undated = anyTime.apply(list, facets: facets, now: now, calendar: utc).filter { $0.updatedOrder == nil }.count
        #expect(options.undated == undated)
    }
}
