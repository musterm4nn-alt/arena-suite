import ArchiveIndex
import Foundation
import SuiteDomain
import Testing

@testable import ApplicationActions

// Unit tests for the dataset builder's pure parts (plan v3 §14, v2 §12/§17): strict recipes, text
// keys, near-duplicates, label-term leakage, lineage, split hashing, and the audit's own checks.

// MARK: - Recipe

@Test func defaultRecipeIsCanonicalAndRoundTrips() throws {
    let recipe = DatasetRecipe()
    let object = try recipe.jsonObject()
    #expect(object["schema"] as? String == "arena-suite.dataset-recipe/1")
    #expect((object["labels"] as? [String: Any])?["accepted_tiers"] as? [String] == ["revealed_message_claim"])
    #expect((object["features"] as? [String: Any])?["allowlist"] as? [String] == ["response_text"])
    #expect((object["selection"] as? [String: Any])?["origins"] as? [String] == ["history_import"])
    #expect(try DatasetRecipe.parse(recipe.fileData()) == recipe.validated())
    #expect(try DatasetRecipe.parse(recipe.canonicalData()).sha256() == recipe.sha256())
    // A minimal recipe takes every default.
    #expect(try DatasetRecipe.parse(Data(#"{"schema":"arena-suite.dataset-recipe/1"}"#.utf8)).sha256() == recipe.sha256())
}

@Test func recipeHashIgnoresListOrderAndDuplicates() throws {
    let a = DatasetRecipe(statuses: ["success", "stopped"], acceptedTiers: [.requestedSelection, .revealedMessageClaim],
                          features: [.reasoningText, .responseText])
    let b = DatasetRecipe(statuses: ["stopped", "success", "stopped"], acceptedTiers: [.revealedMessageClaim, .requestedSelection],
                          features: [.responseText, .reasoningText])
    #expect(try a.sha256() == b.sha256())
    #expect(try a.sha256() != DatasetRecipe().sha256())
    #expect(try DatasetRecipe(seed: "other").sha256() != DatasetRecipe().sha256())
}

@Test(arguments: [
    (#"{"schema":"arena-suite.dataset-recipe/2"}"#, DatasetRecipeError.unsupportedSchema("arena-suite.dataset-recipe/2")),
    (#"{"schema":"arena-suite.dataset-recipe/1","labels":{"accepted_teirs":[]}}"#, DatasetRecipeError.unknownKey("$.labels.accepted_teirs")),
    (#"{"schema":"arena-suite.dataset-recipe/1","extra":1}"#, DatasetRecipeError.unknownKey("$.extra")),
    (#"{"schema":"arena-suite.dataset-recipe/1","split":{"percent":{"train":80.5}}}"#, DatasetRecipeError.wrongType("$.split.percent.train", expected: "integer")),
    (#"{"schema":"arena-suite.dataset-recipe/1","split":{"percent":{"train":true}}}"#, DatasetRecipeError.wrongType("$.split.percent.train", expected: "integer")),
    (#"{"schema":"arena-suite.dataset-recipe/1","split":{"percent":{"train":"80"}}}"#, DatasetRecipeError.wrongType("$.split.percent.train", expected: "integer")),
    (#"{"schema":"arena-suite.dataset-recipe/1","split":{"percent":{"train":18446744073709551696}}}"#, DatasetRecipeError.wrongType("$.split.percent.train", expected: "integer")),
    (#"{"schema":"arena-suite.dataset-recipe/1","quality":{"exclude_cross_lane_ancestry":1}}"#, DatasetRecipeError.wrongType("$.quality.exclude_cross_lane_ancestry", expected: "true or false")),
    (#"{"schema":"arena-suite.dataset-recipe/1","grouping":{"algorithm":"connected-groups/2"}}"#, DatasetRecipeError.invalidValue("$.grouping.algorithm", "connected-groups/1 in this version")),
    (#"{"schema":"arena-suite.dataset-recipe/1","selection":{"snapshot_policy":"all"}}"#, DatasetRecipeError.invalidValue("$.selection.snapshot_policy", "latest in this version")),
    (#"{"schema":"arena-suite.dataset-recipe/1","responses":{"statuses":null}}"#, DatasetRecipeError.wrongType("$.responses.statuses", expected: "list of strings")),
])
func recipeParsingIsStrict(_ json: String, _ expected: DatasetRecipeError) {
    #expect(throws: expected) { _ = try DatasetRecipe.parse(Data(json.utf8)) }
}

@Test func recipeValuesAreValidated() throws {
    func invalid(_ json: String) -> Bool {
        do {
            _ = try DatasetRecipe.parse(Data(json.utf8))
            return false
        } catch DatasetRecipeError.invalidValue { return true } catch { return false }
    }
    let prefix = #"{"schema":"arena-suite.dataset-recipe/1","#
    #expect(invalid(prefix + #""split":{"percent":{"train":80,"validation":10,"test":20}}}"#), "must sum to 100")
    #expect(invalid(prefix + #""split":{"percent":{"train":0,"validation":50,"test":50}}}"#), "train must be above 0")
    #expect(invalid(prefix + #""split":{"holdout":{"account":"00000000-0000-0000-0000-00000000000A"}}}"#), "holdout needs test 0")
    #expect(invalid(prefix + #""split":{"percent":{"train":90,"validation":10,"test":0},"holdout":{"updated_after":"yesterday"}}}"#))
    #expect(invalid(prefix + #""split":{"percent":{"train":90,"validation":10,"test":0},"holdout":{"updated_after":"2026-09-01T00:00:00.5Z"}}}"#), "whole seconds only")
    #expect(invalid(prefix + #""split":{"percent":{"train":90,"validation":10,"test":0},"holdout":{}}}"#))
    #expect(invalid(prefix + #""features":{"allowlist":["prompt_text"]}}"#), "response_text is required")
    #expect(invalid(prefix + #""features":{"allowlist":["response_text","model_name"]}}"#))
    #expect(invalid(prefix + #""labels":{"accepted_tiers":["verified_identity"]}}"#))
    #expect(invalid(prefix + #""labels":{"accepted_tiers":[]}}"#))
    #expect(invalid(prefix + #""labels":{"mode_classes":{"battle":"revealed"}}}"#))
    #expect(invalid(prefix + #""selection":{"accounts":[]}}"#))
    #expect(invalid(prefix + #""selection":{"accounts":["not-a-uuid"]}}"#))
    #expect(invalid(prefix + #""grouping":{"near_duplicates":{"threshold_percent":20}}}"#))
    #expect(invalid(prefix + #""name":""}"#))

    let holdout = try DatasetRecipe.parse(Data(
        (prefix + #""split":{"percent":{"train":90,"validation":10,"test":0},"holdout":{"updated_after":"2026-09-01T02:00:00+02:00"}}}"#).utf8))
    #expect(holdout.holdout == .updatedAfter(text: "2026-09-01T02:00:00+02:00", microseconds: 1_788_220_800_000_000))
    // The instant is derived from the text, never taken on trust.
    let forged = DatasetRecipe(trainPercent: 90, validationPercent: 10, testPercent: 0, holdout: .updatedAfter(text: "2026-09-01T00:00:00Z", microseconds: 0))
    #expect(try forged.validated().holdout == .updatedAfter(text: "2026-09-01T00:00:00Z", microseconds: 1_788_220_800_000_000))
}

// MARK: - Text keys and near-duplicates

@Test func normalizationOnlyAffectsGroupingKeys() {
    #expect(DatasetText.normalized("  What IS\tthe\n\ncapital？ ") == "what is the capital?")
    #expect(DatasetText.normalized("ﬁ Ｐａｒｉｓ") == "fi paris")
    #expect(DatasetText.normalized(" \n ").isEmpty)
    #expect(DatasetText.joined(["a", "b"]) == "a\n\nb")
}

@Test func nearDuplicatesAreVerifiedPairsAndDeterministic() {
    let texts = [
        "what is the capital of france?", "what is the capital of france??", "recommend a board game for four players",
        "what is the capital of spain?", "", "hi", "hi!",
    ].map(DatasetText.normalized)
    let pairs = NearDuplicates.pairs(texts, thresholdPercent: 80)
    #expect(pairs.map { "\($0.0)-\($0.1)" } == ["0-1"], "only the one-character edit pairs at 80%")
    #expect(NearDuplicates.pairs(texts, thresholdPercent: 80).map { "\($0.0)-\($0.1)" } == pairs.map { "\($0.0)-\($0.1)" })
    // LSH only proposes; every reported pair is verified by exact Jaccard, at any threshold.
    let loose = NearDuplicates.pairs(texts, thresholdPercent: 50)
    #expect(loose.contains { $0 == (0, 1) })
    for (a, b) in loose {
        #expect(NearDuplicates.similar(NearDuplicates.shingles(texts[a]), NearDuplicates.shingles(texts[b]), thresholdPercent: 50))
    }
    #expect(!NearDuplicates.similar(NearDuplicates.shingles(texts[0]), NearDuplicates.shingles(texts[3]), thresholdPercent: 80))
    #expect(NearDuplicates.similar(NearDuplicates.shingles(texts[0]), NearDuplicates.shingles(texts[3]), thresholdPercent: 50))
    #expect(NearDuplicates.shingles("").isEmpty && NearDuplicates.shingles("abc").count == 1)
    #expect(!NearDuplicates.similar([], [], thresholdPercent: 50))
    // Reordering the input finds the same text pairs.
    let reversed = Array(texts.reversed())
    let again = NearDuplicates.pairs(reversed, thresholdPercent: 80).map { Set([reversed[$0.0], reversed[$0.1]]) }
    #expect(again == [Set([texts[0], texts[1]])])
}

@Test func unionFindJoinsConnectedMembersOnly() {
    var sets = UnionFind(count: 6)
    let joined = [sets.union(0, 1), sets.union(1, 2), sets.union(0, 2), sets.union(4, 5)]
    #expect(joined == [true, true, false, true])
    let roots = (0..<6).map { sets.find($0) }
    #expect(roots[2] == roots[0] && roots[3] != roots[0] && roots[4] == roots[5] && roots[3] != roots[4])
}

// MARK: - Leakage terms

private let claims = [
    ModelClaim(subject: .conversation, subjectID: "c", role: nil, modelID: "m-alpha", displayName: "Alpha Chat", organization: "AlphaLab", source: "detail_revealed"),
    ModelClaim(subject: .conversation, subjectID: "c", role: nil, modelID: "m-beta", displayName: "Beta", organization: "BetaWorks", provider: "betacloud", source: "detail_revealed"),
    ModelClaim(subject: .conversation, subjectID: "c", role: nil, modelID: "m-gamma", displayName: "Go", organization: "AlphaLab", source: "detail_revealed"),
]

@Test func labelTermsAreScannedRecursivelyAndClassified() {
    let terms = LabelTerms(claims: claims, minimumLength: 3)
    // m-alpha, alpha chat, alphalab (shared by two models), m-beta, beta, betaworks, betacloud, m-gamma;
    // "go" is under the minimum length.
    #expect(terms.count == 8)
    #expect(terms.findings(in: ["response_text": "I am alpha CHAT."], label: "m-alpha") == [.ownLabel])
    #expect(terms.findings(in: ["response_text": "Built by AlphaLab"], label: "m-alpha") == [.ownOrganization])
    #expect(terms.findings(in: ["response_text": "Built by AlphaLab"], label: "m-beta") == [.otherModel])
    #expect(terms.findings(in: ["response_text": "Served from BETACLOUD."], label: "m-beta") == [.ownOrganization])
    #expect(terms.findings(in: ["response_text": "Let's go."], label: "m-gamma").isEmpty, "terms under 3 characters are ignored")
    // v2 §17: a denylisted ID inside a nested feature object is found.
    let nested: [String: Any] = ["response_text": "fine", "extra": ["deep": [["note": "see m-alpha"]]]]
    #expect(terms.findings(in: nested, label: "m-alpha") == [.ownLabel])
    #expect(terms.findings(in: nested, label: "m-beta") == [.otherModel])
    #expect(terms.findings(in: ["response_text": NSNull()], label: "m-alpha").isEmpty)
}

@Test func labelTermMatchingIsWordBounded() {
    #expect(LabelTerms.contains("i am alpha chat.", "alpha chat"))
    #expect(!LabelTerms.contains("alpha chatty", "alpha chat"))
    #expect(!LabelTerms.contains("betaworksx", "betaworks"))
    #expect(LabelTerms.contains("(betaworks)", "betaworks"))
    #expect(LabelTerms.contains("m-alpha-2 is newer", "m-alpha"), "hyphen is a boundary: over-flagging is the safe side")
    #expect(LabelTerms.contains("x m-alpha", "m-alpha") && LabelTerms.contains("m-alpha", "m-alpha"))
    #expect(!LabelTerms.contains("caf\u{E9}", "caf"), "a letter after the match continues the word")
    // Scanned text is normalized first, so a decomposed accent composes and is not a boundary.
    #expect(!LabelTerms.contains(DatasetText.normalized("cafe\u{301} menu"), "cafe"))
    let terms = LabelTerms(claims: claims, minimumLength: 3)
    #expect(terms.findings(in: ["response_text": "I am \u{FF21}\u{FF2C}\u{FF30}\u{FF28}\u{FF21}\u{3000}Chat"], label: "m-alpha") == [.ownLabel],
            "fullwidth letters and an ideographic space are the same name")
    #expect(terms.findings(in: ["response_text": "alpha\n   chat here"], label: "m-alpha") == [.ownLabel])
    #expect(LabelTerms.contains("alphalabalphalab alphalab", "alphalab"), "later occurrences are checked")
}

@Test func structuralCheckRejectsNonTextAndUnlistedFeatures() {
    let allow: Set = ["response_text"]
    #expect(LabelTerms.structuralViolations(["response_text": "x"], allowlist: allow).isEmpty)
    #expect(LabelTerms.structuralViolations(["response_text": NSNull()], allowlist: allow).isEmpty)
    #expect(LabelTerms.structuralViolations(["response_text": ["x"]], allowlist: allow).count == 1)
    #expect(LabelTerms.structuralViolations(["model_id": "m"], allowlist: allow).count == 1)
}

// MARK: - Lineage

private func node(_ id: String, _ role: String, lane: String? = "a", parents: [String]) -> DetailMessage {
    DetailMessage(remoteID: id, role: role, status: "success", lane: lane, parentIDs: parents, modelRemoteID: nil, createdAt: nil, blocks: [], attachments: [])
}

@Test func lineageFindsMissingParentsAndLoopsWithoutHanging() {
    func run(_ messages: [DetailMessage], _ id: String) -> (Int, Bool, Bool) {
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.remoteID, $0) })
        let result = DatasetService.lineage(of: byID[id]!, in: byID)
        return (result.ancestors.count, result.unresolved, result.cyclic)
    }
    // A diamond (two paths to one ancestor) is not a loop.
    let diamond = [node("u", "user", parents: []), node("x", "user", parents: ["u"]), node("y", "user", parents: ["u"]),
                   node("r", "assistant", parents: ["x", "y"])]
    #expect(run(diamond, "r") == (3, false, false))
    #expect(run([node("r", "assistant", parents: ["gone"])], "r") == (0, true, false))
    #expect(run([node("r", "assistant", parents: ["r"])], "r").2)
    #expect(run([node("p", "user", parents: ["q"]), node("q", "user", parents: ["p"]), node("r", "assistant", parents: ["p"])], "r").2)
    #expect(run([node("p", "user", parents: ["r"]), node("r", "assistant", parents: ["p"])], "r").2)
}

// MARK: - Splits

@Test func groupHashSplitsFollowThePercentagesAndTheSeed() {
    var counts = [0, 0, 0]
    for index in 0..<10_000 {
        let bucket = DatasetService.bucket(seed: "arena-suite", group: "g-\(index)")
        #expect((0..<100).contains(bucket))
        counts[bucket < 80 ? 0 : bucket < 90 ? 1 : 2] += 1
    }
    #expect(abs(counts[0] - 8_000) < 300 && abs(counts[1] - 1_000) < 200 && abs(counts[2] - 1_000) < 200, "\(counts)")
    #expect(DatasetService.bucket(seed: "arena-suite", group: "g-1") == DatasetService.bucket(seed: "arena-suite", group: "g-1"))
    let moved = (0..<200).filter {
        DatasetService.bucket(seed: "a", group: "g-\($0)") != DatasetService.bucket(seed: "b", group: "g-\($0)")
    }
    #expect(moved.count > 150, "a different seed reshuffles groups")
    // Framing keeps concatenations apart.
    #expect(DatasetService.digestID("s-", "d", ["ab", "c"]) != DatasetService.digestID("s-", "d", ["a", "bc"]))
}

// MARK: - Audit checks

private func candidate(
    _ id: String, conversation: String, split: DatasetService.Split, group: String, response: String,
    extraFeatures: [String: Any] = [:]
) -> DatasetService.Candidate {
    var label = DatasetService.LabelEvidence()
    label.modelID = "m"
    label.tier = .revealedMessageClaim
    var candidate = DatasetService.Candidate(
        sampleID: id, account: AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!),
        conversationID: conversation, conversationKind: "evaluation", mode: "battle", modality: nil, updatedOrder: nil,
        message: node(id, "assistant", parents: []), snapshotSequence: 1, record: .available(digest: "d", origin: "history_import"),
        promptID: nil, label: label, features: extraFeatures.merging(["response_text": response]) { $1 },
        responseKey: DatasetText.normalized(response), promptKey: nil, reasons: [], warnings: [])
    candidate.split = split
    candidate.groupID = group
    return candidate
}

@Test func auditIndependentlyDetectsCrossSplitLeaks() throws {
    let source = DatasetSource(decoderVersion: "v", contentDigest: "d", accounts: [], conversations: [], claims: [], feedback: [])
    func audit(_ candidates: [DatasetService.Candidate], pairs: [(String, String)] = []) throws -> DatasetAudit {
        var grouping = DatasetService.Grouping()
        grouping.responsePairs = pairs
        return try DatasetService.audit(
            candidates, grouping: grouping, counts: .init(), recipe: DatasetRecipe(), recipeSHA256: "r", source: source,
            terms: LabelTerms(claims: [], minimumLength: 3))
    }
    let clean = try audit([
        candidate("s1", conversation: "c1", split: .train, group: "g1", response: "one"),
        candidate("s2", conversation: "c2", split: .test, group: "g2", response: "two"),
    ])
    #expect(clean.isClean)
    // Even if grouping were wrong, the audit sees one conversation, one text and one group in two splits.
    let leaky = try audit([
        candidate("s1", conversation: "c1", split: .train, group: "g1", response: "same text"),
        candidate("s2", conversation: "c1", split: .test, group: "g1", response: "Same  TEXT"),
    ])
    #expect(!leaky.isClean)
    #expect(leaky.violations["conversations_across_splits"] == 1 && leaky.violations["groups_across_splits"] == 1)
    #expect(leaky.violations["duplicate_responses_across_splits"] == 1)
    // A near-duplicate pair is found by the exact recount even when grouping's LSH proposed no pair.
    let fox = "the quick brown fox jumps over the lazy dog near the river bank today"
    let near = try audit(
        [candidate("s1", conversation: "c1", split: .train, group: "g1", response: fox),
         candidate("s2", conversation: "c2", split: .test, group: "g2", response: fox + "!")],
        pairs: [])
    #expect(near.violations["near_duplicate_response_pairs_across_splits"] == 1)
    let report = try #require(try JSONSerialization.jsonObject(with: near.report) as? [String: Any])
    #expect(((report["grouping"] as? [String: Any])?["near_duplicate_recount"] as? [String: String])?["responses"] == "exhaustive_exact_jaccard")
    // Texts below the threshold are not counted, whatever LSH proposed.
    let far = try audit(
        [candidate("s1", conversation: "c1", split: .train, group: "g1", response: "alpha"),
         candidate("s2", conversation: "c2", split: .test, group: "g2", response: "alphas")],
        pairs: [("alpha", "alphas")])
    #expect(far.violations["near_duplicate_response_pairs_across_splits"] == 0)
    let structural = candidate("s3", conversation: "c3", split: .train, group: "g3", response: "x", extraFeatures: ["model_id": "m"])
    #expect(try audit([structural]).violations["structural_feature_violations"] == 1)
}

@Test func sourceRecordEnvelopeIsClassifiedByWhatWasObserved() {
    let account = AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
    func classify(_ text: String) -> String {
        switch DatasetService.classify(envelope: Data(text.utf8), digest: "d", account: account) {
        case .available(_, let origin): "available \(origin)"
        case .unavailable: "unavailable"
        case .accountMismatch: "mismatch"
        }
    }
    #expect(classify(#"{"account_id":"00000000-0000-0000-0000-00000000000A","kind":"exchange"}"#) == "available history_import")
    #expect(classify(#"{"account_id":"00000000-0000-0000-0000-00000000000A","kind":"other"}"#) == "available unknown")
    #expect(classify(#"{"account_id":"00000000-0000-0000-0000-00000000000B","kind":"exchange"}"#) == "mismatch")
    // Unreadable or missing account: unavailable evidence, never "another account".
    #expect(classify(#"{"kind":"exchange"}"#) == "unavailable")
    #expect(classify(#"{"account_id":"not-a-uuid"}"#) == "unavailable")
    #expect(classify("not json") == "unavailable")
}

// MARK: - Source view

@Test func datasetSourceMatchesTheIndexQueries() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ds-\(UUID().uuidString)/index.sqlite")
    let index = try ArchiveIndex(url: url)
    let account = AccountID()
    let messages = [
        ArchivedMessage(remoteID: "u", role: "user", status: "success", lane: "a", parentIDs: [], modelRemoteID: nil, createdAt: "t",
                        updatedAt: nil, failureReason: nil, blocks: [ArchivedBlock(kind: .text, text: "hi", pointer: "$.m[0]")], attachments: []),
        ArchivedMessage(remoteID: "r", role: "assistant", status: "success", lane: "a", parentIDs: ["u", "x"], modelRemoteID: "m1",
                        createdAt: nil, updatedAt: nil, failureReason: nil,
                        blocks: [ArchivedBlock(kind: .text, text: "one", pointer: "$.m[1]"), ArchivedBlock(kind: .reasoning, text: "two", pointer: "$.m[1].r")],
                        attachments: [ArchivedAttachment(name: "a.png", contentType: "image/png", hasURL: true)]),
    ]
    let snapshot = ConversationSnapshot(
        facts: ConversationFacts(remoteID: "c1", kind: "evaluation", mode: "battle", updatedAt: "2026", updatedOrder: 42),
        messages: messages, lastMessageIDs: [], claims: [ModelClaim(subject: .message, subjectID: "r", role: "a", modelID: "m1", source: "message_model_id")],
        feedback: [ArchivedFeedback(remoteID: "f", value: "a", messageA: "r", messageB: nil)])
    try index.apply(
        account: account,
        records: [(RecordRef(account: account, sequence: 3, segment: 1, offset: 10, length: 20),
                   DecodedRecord(events: [.snapshot(snapshot), .warning(code: "w", detail: "d")], unknownFields: ["$.messages[].x": 1]))],
        through: 3, decoderVersion: "test/1")

    let source = try index.datasetSource()
    #expect(try source.decoderVersion == "test/1" && source.contentDigest == index.contentDigest())
    #expect(source.accounts == [DatasetSourceAccount(account: account, checkpoint: 3,
                                                     unknownFields: [UnknownFieldRange(path: "$.messages[].x", count: 1, firstSequence: 3, lastSequence: 3)])])
    let conversation = try #require(source.conversations.first)
    #expect(try conversation.messages == index.conversation(account: account, remoteID: "c1")?.messages)
    #expect(conversation.updatedOrder == 42)
    #expect(conversation.snapshotLocation == RecordRef(account: account, sequence: 3, segment: 1, offset: 10, length: 20))
    #expect(conversation.snapshotWarnings.map(\.code) == ["w"])
    #expect(source.claims.map(\.claim.modelID) == ["m1"] && source.claims.first?.sequence == 3)
    #expect(source.feedback.first?.conversationID == "c1" && source.feedback.first?.feedback.messageA == "r")
    #expect(try index.datasetSource(accounts: [AccountID()]).conversations.isEmpty, "the account filter limits conversations")
    #expect(try index.datasetSource(accounts: [AccountID()]).claims.count == 1, "claims always cover every account")
}
