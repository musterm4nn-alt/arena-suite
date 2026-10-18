import ApplicationActions
import ArchiveIndex
import CaptureJournal
import Foundation
import SuiteDomain
import Testing

@testable import ArenaAdapter

// §14 datasets end to end: Arena-shaped journal records → real decoder → index → DatasetService.
// Each conversation below exercises one labeling or hygiene rule (plan v3 §14, v2 §12, §17).

private let accountA = AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
private let accountB = AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
private let capitalPrompt = "What is the capital of France?"

private func message(
    _ id: String, _ role: String, lane: String = "a", model: String? = nil, parents: [String] = [], text: String? = nil,
    status: String = "success", reasoning: String? = nil, image: Bool = false
) -> [String: Any] {
    var message: [String: Any] = [
        "id": id, "role": role, "status": status, "participantPosition": lane, "parentMessageIds": parents,
        "content": text.map { [["type": "text", "text": $0]] } ?? [],
        // Arena's per-message telemetry: must never reach a dataset file.
        "metadata": ["botScore": 0.5, "hashedClientIp": "telemetry-marker"],
    ]
    if let model { message["modelId"] = model }
    if let reasoning { message["reasoning"] = reasoning }
    if image { message["experimental_attachments"] = [["name": "out.png", "contentType": "image/png", "url": "https://example.invalid/o"]] }
    return message
}

private func revealed(_ id: String, _ name: String, _ organization: String) -> [String: Any] {
    ["id": id, "displayName": name, "organization": organization]
}

private func vote(_ id: String, _ a: String, _ b: String, _ modelA: String, _ modelB: String) -> [String: Any] {
    ["id": id, "messageAId": a, "messageBId": b, "modelAId": modelA, "modelBId": modelB, "value": "a"]
}

private func detail(
    _ id: String, mode: String, _ messages: [[String: Any]], revealed: [[String: Any]] = [], votes: [[String: Any]] = [],
    updatedAt: String = "2026-09-20 10:00:00.000000+00"
) -> Data {
    try! JSONSerialization.data(
        withJSONObject: [
            "id": id, "title": "Title \(id)", "mode": mode, "updatedAt": updatedAt, "lastMessageIds": [],
            "messages": messages, "revealedModels": revealed, "pairwiseFeedbacks": votes,
        ], options: [.sortedKeys])
}

private func list(_ entries: [[String: Any]]) -> Data {
    try! JSONSerialization.data(
        withJSONObject: [
            "entries": entries, "pagination": ["hasMore": false, "cursor": NSNull(), "limit": 50], "partial": false,
            "failedSources": [],
        ], options: [.sortedKeys])
}

private var revealAlphaBeta: [[String: Any]] { [revealed("m-alpha", "Alpha Chat", "AlphaLab"), revealed("m-beta", "Beta Chat", "BetaWorks")] }

/// Two-lane battle turn helper: user prompt plus lane a/b responses with the given models.
private func battle(
    _ id: String, prompt: String, a: String, b: String, modelA: String? = "m-alpha", modelB: String? = "m-beta",
    reveal: Bool = true, updatedAt: String = "2026-09-20 10:00:00.000000+00"
) -> Data {
    detail(
        id, mode: "battle",
        [
            message("\(id)-u1", "user", text: prompt),
            message("\(id)-a1", "assistant", lane: "a", model: modelA, parents: ["\(id)-u1"], text: a),
            message("\(id)-b1", "assistant", lane: "b", model: modelB, parents: ["\(id)-u1"], text: b),
        ],
        revealed: reveal ? revealAlphaBeta : [],
        votes: reveal && modelA != nil && modelB != nil ? [vote("\(id)-f1", "\(id)-a1", "\(id)-b1", modelA!, modelB!)] : [],
        updatedAt: updatedAt)
}

private struct Record {
    let account: AccountID
    let role: String
    let body: Data
    let entryID: String?
}

private func scenario() -> [Record] {
    func detailRecord(_ account: AccountID, _ id: String, _ body: Data) -> Record { Record(account: account, role: "detail", body: body, entryID: id) }
    return [
        Record(
            account: accountA, role: "list",
            body: list([
                ["id": "sbs", "type": "evaluation", "mode": "side-by-side", "modality": "chat", "modelAId": "m-gamma", "modelBId": "m-delta"],
                ["id": "sbs-nomodel", "type": "evaluation", "mode": "side-by-side", "modality": "chat", "modelAId": "m-gamma", "modelBId": "m-delta"],
                ["id": "image", "type": "evaluation", "mode": "battle", "modality": "image"],
            ]), entryID: nil),
        detailRecord(accountA, "revealed", battle("revealed", prompt: capitalPrompt, a: "The capital of France is Paris.", b: "Paris.")),
        detailRecord(
            accountA, "unrevealed",
            battle("unrevealed", prompt: "Write a haiku about rain.", a: "Rain on the roof tiles", b: "Grey sky, falling drops",
                   modelA: nil, modelB: nil, reveal: false)),
        detailRecord(
            accountA, "sbs",
            detail("sbs", mode: "side-by-side", [
                message("sbs-u1", "user", text: "Explain recursion briefly."),
                message("sbs-a1", "assistant", lane: "a", model: "m-gamma", parents: ["sbs-u1"], text: "A function calling itself."),
                message("sbs-b1", "assistant", lane: "b", model: "m-delta", parents: ["sbs-u1"], text: "Defining a thing by itself."),
            ])),
        detailRecord(
            accountA, "sbs-nomodel",
            detail("sbs-nomodel", mode: "side-by-side", [
                message("sbsn-u1", "user", text: "Name a prime number."),
                message("sbsn-a1", "assistant", lane: "a", parents: ["sbsn-u1"], text: "Seven."),
            ])),
        detailRecord(
            accountA, "multi",
            detail("multi", mode: "battle", [
                message("multi-u1", "user", text: "Suggest a name for a cat."),
                message("multi-a1", "assistant", lane: "a", model: "m-alpha", parents: ["multi-u1"], text: "Whiskers."),
                message("multi-b1", "assistant", lane: "b", model: "m-beta", parents: ["multi-u1"], text: "Mittens."),
                // The user continued from lane a: lane b's second answer has lane a's text in its ancestry.
                message("multi-u2", "user", parents: ["multi-a1"], text: "Now one for a dog."),
                message("multi-a2", "assistant", lane: "a", model: "m-alpha", parents: ["multi-u2"], text: "Rex."),
                message("multi-b2", "assistant", lane: "b", model: "m-beta", parents: ["multi-u2"], text: "Buddy."),
            ], revealed: revealAlphaBeta, votes: [vote("multi-f1", "multi-a1", "multi-b1", "m-alpha", "m-beta")])),
        detailRecord(
            accountA, "image",
            detail("image", mode: "battle", [
                message("image-u1", "user", text: "Draw a lighthouse."),
                message("image-a1", "assistant", lane: "a", model: "m-alpha", parents: ["image-u1"], image: true),
                message("image-b1", "assistant", lane: "b", model: "m-beta", parents: ["image-u1"], image: true),
            ], revealed: revealAlphaBeta, votes: [vote("image-f1", "image-a1", "image-b1", "m-alpha", "m-beta")])),
        detailRecord(
            accountA, "selfid",
            battle("selfid", prompt: "Who made you?", a: "I am ALPHA CHAT, a helpful assistant.",
                   b: "Unlike AlphaLab models, I keep answers short.")),
        detailRecord(
            accountA, "conflict",
            detail("conflict", mode: "battle", [
                message("conflict-u1", "user", text: "Pick a colour."),
                message("conflict-a1", "assistant", lane: "a", model: "m-alpha", parents: ["conflict-u1"], text: "Blue."),
                message("conflict-b1", "assistant", lane: "b", model: "m-beta", parents: ["conflict-u1"], text: "Green."),
            ], revealed: revealAlphaBeta, votes: [vote("conflict-f1", "conflict-a1", "conflict-b1", "m-beta", "m-beta")])),
        detailRecord(
            accountA, "outside",
            battle("outside", prompt: "Pick a fruit.", a: "Apple.", b: "Pear.", modelA: "m-zeta")),
        detailRecord(
            accountA, "newmode",
            detail("newmode", mode: "arena-x", [
                message("newmode-u1", "user", text: "Say hi."),
                message("newmode-a1", "assistant", lane: "a", model: "m-alpha", parents: ["newmode-u1"], text: "Hi."),
            ])),
        detailRecord(
            accountA, "stopped",
            detail("stopped", mode: "battle", [
                message("stopped-u1", "user", text: "Count to three."),
                message("stopped-a1", "assistant", lane: "a", model: "m-alpha", parents: ["stopped-u1"], text: "One, two", status: "stopped"),
                message("stopped-b1", "assistant", lane: "b", model: "m-beta", parents: ["stopped-u1"], text: "1 2 3"),
            ], revealed: revealAlphaBeta, votes: [vote("stopped-f1", "stopped-a1", "stopped-b1", "m-alpha", "m-beta")])),
        // Same prompt as `revealed` in another conversation: one prompt family, one group.
        detailRecord(
            accountA, "again",
            battle("again", prompt: "  what is the CAPITAL of france? ", a: "It is Paris, of course.", b: "Paris, France.",
                   updatedAt: "2026-09-26 10:00:00.000000+00")),
        // Account B: a near-duplicate of the capital prompt, and the same conversation ID as `revealed`.
        detailRecord(
            accountB, "b-near",
            battle("b-near", prompt: "What is the capital of France??", a: "Paris is the answer.", b: "The answer is Paris.",
                   updatedAt: "2026-09-26 12:00:00.000000+00")),
        detailRecord(
            accountB, "revealed",
            battle("revealed", prompt: "Describe the sea.", a: "Vast and blue.", b: "Deep and salty.",
                   modelA: "m-beta", modelB: "m-alpha", updatedAt: "2026-09-26 12:00:00.000000+00")),
        detailRecord(
            accountB, "b-solo",
            detail("b-solo", mode: "battle", [
                message("b-solo-u1", "user", text: "Recommend a board game."),
                message("b-solo-a1", "assistant", lane: "a", model: "m-alpha", parents: ["b-solo-u1"], text: "Chess is timeless."),
                message("b-solo-b1", "assistant", lane: "b", model: "m-beta", parents: ["b-solo-u1"], text: "Try Catan."),
            ], revealed: [revealed("m-alpha", "Alpha Chat Two", "AlphaLab"), revealed("m-beta", "Beta Chat", "BetaWorks")],
               votes: [vote("b-solo-f1", "b-solo-a1", "b-solo-b1", "m-alpha", "m-beta")], updatedAt: "2026-09-27 08:00:00.000000+00")),
        // Anonymous battle whose messages carry a model ID but nothing was revealed or voted.
        detailRecord(
            accountA, "noreveal",
            battle("noreveal", prompt: "Name a long river.", a: "The Nile.", b: "The Amazon.", reveal: false)),
    ]
}

private struct DatasetHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dataset-\(UUID().uuidString)", isDirectory: true)
    let archive: ArchiveService
    let datasets: DatasetService
    var output: URL { root.appendingPathComponent("out", isDirectory: true) }

    init(_ records: [Record] = scenario()) async throws {
        let journals = JournalStore(archiveRoot: root)
        for record in records {
            let writer = try await journals.writer(for: record.account)
            var metadata: [String: JournalValue] = [
                "role": .string(record.role), "status": .integer(200), "transfer_end": .string("complete"),
            ]
            if let id = record.entryID { (metadata["entry_id"], metadata["entry_type"]) = (.string(id), .string("evaluation")) }
            _ = try writer.append(JournalDraft(kind: "exchange", payload: record.body, accountID: record.account.rawValue, metadata: metadata))
            try writer.synchronize()
        }
        archive = ArchiveService(
            index: try ArchiveIndex(url: root.appendingPathComponent("index/archive.sqlite")), journals: journals,
            decoder: ArenaArchiveDecoder(), accounts: { [accountA, accountB] })
        for account in [accountA, accountB] where records.contains(where: { $0.account == account }) {
            _ = try await archive.project(account)
        }
        datasets = DatasetService(archive: archive)
    }

    /// Every candidate's parsed line, keyed by "account/conversation/message".
    func decisions(_ recipe: DatasetRecipe = DatasetRecipe()) async throws -> [String: [String: Any]] {
        let preview = try await datasets.preview(recipe: recipe, limit: .max)
        var result: [String: [String: Any]] = [:]
        for entry in preview.entries {
            let line = try #require(try JSONSerialization.jsonObject(with: Data(entry.line.utf8)) as? [String: Any])
            let provenance = try #require(line["provenance"] as? [String: Any])
            let account = provenance["account_id"] as! String == accountA.rawValue.uuidString ? "A" : "B"
            result["\(account)/\(provenance["conversation_id"] as! String)/\(provenance["message_id"] as! String)"] = line
        }
        return result
    }
}

private func reasons(_ line: [String: Any]?) -> [String] { line?["reasons"] as? [String] ?? [] }
private func included(_ line: [String: Any]?) -> Bool { line?["schema"] as? String == "arena-suite.training/1" }
private func target(_ line: [String: Any]?) -> [String: Any] { line?["target"] as? [String: Any] ?? [:] }
private func groups(_ line: [String: Any]?) -> [String: Any] { line?["groups"] as? [String: Any] ?? [:] }
private func warnings(_ line: [String: Any]?) -> [String] { (line?["eligibility"] as? [String: Any])?["warnings"] as? [String] ?? [] }

@Test func defaultRecipeLabelsOnlyRevealedBattleResponses() async throws {
    let h = try await DatasetHarness()
    let d = try await h.decisions()

    for id in ["A/revealed/revealed-a1", "A/revealed/revealed-b1"] {
        #expect(included(d[id]), "\(id): \(reasons(d[id]))")
        let t = target(d[id])
        #expect(t["evidence_tier"] as? String == "revealed_message_claim")
        #expect(t["verified_identity"] as? Bool == false)
        #expect(t["label_sources"] as? [String] == ["message_model_id", "pairwise_feedback"])
        #expect(t["corroborated_by"] as? [String] == ["detail_revealed"])
    }
    #expect(target(d["A/revealed/revealed-a1"])["model_id"] as? String == "m-alpha")
    #expect(target(d["A/revealed/revealed-b1"])["model_id"] as? String == "m-beta")
    #expect(((d["A/revealed/revealed-a1"]?["features"]) as? [String: String]) == ["response_text": "The capital of France is Paris."])

    // Unrevealed battles carry no claim: nothing is inferred.
    #expect(reasons(d["A/unrevealed/unrevealed-a1"]) == ["no_message_scoped_claim"])
    // User-selected modes are requested selections, not reveals: excluded unless the recipe opts in.
    #expect(reasons(d["A/sbs/sbs-a1"]) == ["tier_not_accepted"])
    #expect(target(d["A/sbs/sbs-a1"]).isEmpty && (d["A/sbs/sbs-a1"]?["label"] as? [String: Any])?["evidence_tier"] as? String == "requested_selection")
    // A conversation-level list claim is never propagated to a message.
    #expect(reasons(d["A/sbs-nomodel/sbsn-a1"]) == ["no_message_scoped_claim"])
    // Context lineage: lane b's second answer descends from lane a's first.
    #expect(included(d["A/multi/multi-a1"]) && included(d["A/multi/multi-b1"]) && included(d["A/multi/multi-a2"]))
    #expect(reasons(d["A/multi/multi-b2"]) == ["cross_lane_ancestry"])
    // Image-only answers have no text feature.
    #expect(reasons(d["A/image/image-a1"]) == ["empty_response_text"])
    // Self-identification by display name (any case) is excluded; another model's organization is a warning.
    #expect(reasons(d["A/selfid/selfid-a1"]) == ["own_label_term"])
    #expect(included(d["A/selfid/selfid-b1"]) && warnings(d["A/selfid/selfid-b1"]).contains("other_model_term"))
    // Disagreements: the vote names another model; the message's model is outside the revealed set.
    #expect(reasons(d["A/conflict/conflict-a1"]) == ["conflicting_claims"])
    #expect(included(d["A/conflict/conflict-b1"]))
    #expect(reasons(d["A/outside/outside-a1"]) == ["conflicting_claims"])
    #expect(reasons(d["A/newmode/newmode-a1"]) == ["mode_unclassified"])
    #expect(reasons(d["A/stopped/stopped-a1"]) == ["status_not_accepted"])
    // A message claim with no revealed set is its own tier, not accepted by default.
    #expect(reasons(d["A/noreveal/noreveal-a1"]) == ["tier_not_accepted"])
    #expect((d["A/noreveal/noreveal-a1"]?["label"] as? [String: Any])?["evidence_tier"] as? String == "message_claim_without_reveal")
    // Same conversation and message IDs in two accounts: each is labeled from its own account's claims.
    #expect(included(d["B/revealed/revealed-a1"]) && included(d["B/revealed/revealed-b1"]))
    #expect(target(d["B/revealed/revealed-a1"])["model_id"] as? String == "m-beta")
    #expect(target(d["B/revealed/revealed-b1"])["model_id"] as? String == "m-alpha")
    // Only assistant messages are candidates.
    #expect(d.keys.allSatisfy { !$0.contains("-u") })
}

@Test func requestedSelectionsNeedAnExplicitOptIn() async throws {
    let h = try await DatasetHarness()
    let d = try await h.decisions(DatasetRecipe(acceptedTiers: [.revealedMessageClaim, .requestedSelection]))
    for id in ["A/sbs/sbs-a1", "A/sbs/sbs-b1"] {
        #expect(included(d[id]))
        #expect(target(d[id])["evidence_tier"] as? String == "requested_selection")
        #expect(target(d[id])["corroborated_by"] as? [String] == ["history_list"])
    }
    #expect(reasons(d["A/sbs-nomodel/sbsn-a1"]) == ["no_message_scoped_claim"])
}

@Test func messageClaimsWithoutRevealNeedAnExplicitOptIn() async throws {
    let h = try await DatasetHarness()
    let d = try await h.decisions(DatasetRecipe(acceptedTiers: [.revealedMessageClaim, .messageClaimWithoutReveal]))
    #expect(included(d["A/noreveal/noreveal-a1"]))
    #expect(target(d["A/noreveal/noreveal-a1"])["evidence_tier"] as? String == "message_claim_without_reveal")
    #expect(target(d["A/noreveal/noreveal-a1"])["label_sources"] as? [String] == ["message_model_id"])
    #expect(target(d["A/noreveal/noreveal-a1"])["corroborated_by"] as? [String] == [])
}

@Test func manifestLabelTableNamesOnlyTheSelectedAccounts() async throws {
    let h = try await DatasetHarness()
    func alphaNames(_ recipe: DatasetRecipe) async throws -> [String]? {
        let result = try await h.datasets.build(recipe: recipe, in: h.output, appVersion: "test")
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: result.url.appendingPathComponent("manifest.json"))) as? [String: Any])
        let labels = try #require(manifest["labels"] as? [[String: Any]])
        return labels.first { $0["model_id"] as? String == "m-alpha" }?["display_names"] as? [String]
    }
    #expect(try await alphaNames(DatasetRecipe()) == ["Alpha Chat", "Alpha Chat Two"])
    #expect(try await alphaNames(DatasetRecipe(accounts: [accountA])) == ["Alpha Chat"])
}

@Test func relatedSamplesShareAGroupAndASplit() async throws {
    let h = try await DatasetHarness()
    let d = try await h.decisions()
    func group(_ id: String) -> String? { groups(d[id])["split_group"] as? String }
    func split(_ id: String) -> String? { d[id]?["split"] as? String }
    // Lanes of one battle, later turns, the same prompt family, a near-duplicate prompt in another
    // account, and the same conversation ID in another account: all one connected group.
    let connected = [
        "A/revealed/revealed-a1", "A/revealed/revealed-b1", "A/again/again-a1", "A/again/again-b1", "B/b-near/b-near-a1",
        "B/revealed/revealed-a1",
    ]
    for id in connected {
        #expect(group(id) != nil && group(id) == group(connected[0]), "\(id)")
        #expect(split(id) == split(connected[0]))
    }
    #expect(groups(d["A/revealed/revealed-a1"])["prompt_family"] as? String == groups(d["A/again/again-a1"])["prompt_family"] as? String)
    #expect(groups(d["A/revealed/revealed-a1"])["turn"] as? String == groups(d["A/revealed/revealed-b1"])["turn"] as? String)
    #expect(group("A/multi/multi-a1") == group("A/multi/multi-a2"))
    #expect(group("B/b-solo/b-solo-a1") != group(connected[0]))

    let audit = try await h.datasets.validate(recipe: DatasetRecipe())
    #expect(audit.isClean, "\(audit.violations)")
    #expect(audit.violations.count == 9 && audit.violations.values.allSatisfy { $0 == 0 })
    let report = try #require(try JSONSerialization.jsonObject(with: audit.report) as? [String: Any])
    let links = try #require((report["grouping"] as? [String: Any])?["links"] as? [String: Int])
    #expect(links["same_prompt"]! >= 1 && links["near_duplicate_prompt"]! >= 1 && links["shared_conversation"]! >= 1)
    #expect((report["origins"] as? [String: Int]) == ["history_import": audit.candidates])
}

@Test func buildIsDeterministicPrivateAndNeverOverwrites() async throws {
    let h = try await DatasetHarness()
    let recipe = DatasetRecipe()
    let first = try await h.datasets.build(recipe: recipe, in: h.output, appVersion: "test", now: Date(timeIntervalSince1970: 1_800_000_000))
    let second = try await h.datasets.build(recipe: recipe, in: h.output, appVersion: "test", now: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(first.url != second.url && second.url.lastPathComponent.hasSuffix(" 2"))
    let names = ["samples.jsonl", "excluded.jsonl", "audit.json", "recipe.json", "manifest.json", "run.json"]
    #expect(try FileManager.default.contentsOfDirectory(atPath: first.url.path).sorted() == names.sorted())
    for name in names where name != "run.json" {
        #expect(try Data(contentsOf: first.url.appendingPathComponent(name)) == Data(contentsOf: second.url.appendingPathComponent(name)), "\(name)")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: h.output.path).filter { $0.hasPrefix(".") }.isEmpty, "no staging left")
    #expect((try FileManager.default.attributesOfItem(atPath: first.url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    for name in names {
        let mode = try FileManager.default.attributesOfItem(atPath: first.url.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600, "\(name)")
        let text = String(decoding: try Data(contentsOf: first.url.appendingPathComponent(name)), as: UTF8.self)
        #expect(!text.contains("telemetry-marker") && !text.contains("botScore"), "telemetry in \(name)")
    }

    let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: first.url.appendingPathComponent("manifest.json"))) as? [String: Any])
    #expect(manifest["recipe_sha256"] as? String == (try recipe.sha256()))
    let source = try #require(manifest["source"] as? [String: Any])
    #expect(source["decoder"] as? String == "arena-decoder/1")
    #expect(source["projection_digest"] as? String == (try h.archive.contentDigest()))
    #expect((source["checkpoints"] as? [String: String])?[accountA.rawValue.uuidString] == String(try h.archive.checkpoint(for: accountA)))
    let snapshots = try #require(source["snapshots"] as? [[String: Any]])
    #expect(!snapshots.isEmpty && snapshots.allSatisfy { ($0["record_digest"] as? String)?.count == 64 && $0["origin"] as? String == "history_import" })
    let files = try #require(manifest["files"] as? [String: [String: Any]])
    for (name, info) in files {
        #expect(info["sha256"] as? String == first.files[name], "\(name)")
    }

    // Every sample line: allowlisted features only, a split, and provenance back to a journal record.
    let lines = String(decoding: try Data(contentsOf: first.url.appendingPathComponent("samples.jsonl")), as: UTF8.self)
        .split(separator: "\n").map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    #expect(lines.count == first.audit.included && !lines.isEmpty)
    for line in lines {
        #expect((line["features"] as? [String: Any]).map { Array($0.keys) } == ["response_text"])
        #expect(["train", "validation", "test"].contains(line["split"] as? String ?? ""))
        #expect(((line["provenance"] as? [String: Any])?["record_digest"] as? String)?.count == 64)
    }
    let excluded = String(decoding: try Data(contentsOf: first.url.appendingPathComponent("excluded.jsonl")), as: UTF8.self)
    #expect(!excluded.contains("\"features\"") && !excluded.contains("Rain on the roof"), "exclusions carry no text")

    // The written recipe rebuilds the same dataset.
    let reread = try DatasetRecipe.parse(try Data(contentsOf: first.url.appendingPathComponent("recipe.json")))
    #expect(try reread == recipe.validated())
    let third = try await h.datasets.build(recipe: reread, in: h.output, appVersion: "other", now: Date())
    #expect(third.files["samples.jsonl"] == first.files["samples.jsonl"] && third.files["manifest.json"] == first.files["manifest.json"])
}

@Test func selfIdentificationCanBeKeptWithAFlag() async throws {
    let h = try await DatasetHarness()
    let d = try await h.decisions(DatasetRecipe(selfIdentification: .flag))
    #expect(included(d["A/selfid/selfid-a1"]))
    #expect(warnings(d["A/selfid/selfid-a1"]).contains("own_label_term"))
}

@Test func holdoutsBecomeTheWholeTestSplit() async throws {
    let h = try await DatasetHarness()
    let byAccount = try await h.decisions(DatasetRecipe(trainPercent: 80, validationPercent: 20, testPercent: 0, holdout: .account(accountB)))
    for (id, line) in byAccount where included(line) {
        if id.hasPrefix("B/") { #expect(line["split"] as? String == "test", "\(id)") }
    }
    // A-samples grouped with B-samples are pulled into test with them.
    #expect(byAccount["A/revealed/revealed-a1"]?["split"] as? String == "test")
    #expect(byAccount.filter { included($0.value) && $0.value["split"] as? String == "test" }.count > 0)

    let cutoff = try #require(DatasetRecipe.Holdout.updatedAfter("2026-09-25T00:00:00Z"))
    let recipe = DatasetRecipe(trainPercent: 90, validationPercent: 10, testPercent: 0, holdout: cutoff)
    let byTime = try await h.decisions(recipe)
    #expect(byTime["B/b-solo/b-solo-a1"]?["split"] as? String == "test")
    #expect(byTime["A/multi/multi-a1"]?["split"] as? String != "test", "updated before the cutoff and not grouped with later work")
    let audit = try await h.datasets.validate(recipe: recipe)
    #expect(audit.isClean)
    let report = try #require(try JSONSerialization.jsonObject(with: audit.report) as? [String: Any])
    #expect((report["holdout"] as? [String: Any])?["kind"] as? String == "updated_after")
}

@Test func previewAndValidateWriteNothing() async throws {
    let h = try await DatasetHarness()
    func state() throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: h.root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.hasSuffix("-shm") { continue }  // WAL readers coordinate through it
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                files[url.path] = try Data(contentsOf: url)
            }
        }
        return files
    }
    let before = try state()
    _ = try await h.datasets.preview(recipe: DatasetRecipe(), limit: 5)
    _ = try await h.datasets.validate(recipe: DatasetRecipe())
    #expect(try state() == before)
    #expect(!FileManager.default.fileExists(atPath: h.output.path))
}

@Test func damagedSourceRecordExcludesItsSamples() async throws {
    let h = try await DatasetHarness()
    let conversation = try #require(try h.archive.datasetSource().conversations.first { $0.summary.remoteID == "revealed" && $0.summary.account == accountA })
    let location = try #require(conversation.snapshotLocation)
    let segment = JournalStore(archiveRoot: h.root).root(for: accountA).appendingPathComponent(String(format: "segments/%06d.asj", location.segment))
    var bytes = try Data(contentsOf: segment)
    bytes[location.offset + location.length / 2] ^= 0xFF
    try bytes.write(to: segment)

    let d = try await h.decisions()
    #expect(reasons(d["A/revealed/revealed-a1"]).contains("source_record_unavailable"))
    #expect(included(d["A/multi/multi-a1"]), "other records are unaffected")
}

@Test func cancelledOrFailedBuildsLeaveNothing() async throws {
    let h = try await DatasetHarness()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await h.datasets.build(recipe: DatasetRecipe(), in: h.output, appVersion: "test")
    }
    await #expect(throws: DatasetError.cancelled) { _ = try await task.value }
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: h.output.path)) ?? []).isEmpty)

    let blocker = h.root.appendingPathComponent("blocker")
    try Data("file".utf8).write(to: blocker)
    await #expect(throws: DatasetError.self) {
        _ = try await h.datasets.build(recipe: DatasetRecipe(), in: blocker.appendingPathComponent("sub"), appVersion: "test")
    }
    #expect(try Data(contentsOf: blocker) == Data("file".utf8))
}

/// §14 datasets on a real archive: default recipe and the requested-selection variant, built twice.
/// Read-only on the journals; the index and the datasets live in a temporary folder that is removed
/// afterwards (the samples hold real text). Prints counts only, never content or identifiers.
/// `ARENA_SUITE_REAL_ARCHIVE=<archive> swift test --package-path Packages/ArenaProtocol --filter realArchiveDataset`
@Test(.enabled(if: ProcessInfo.processInfo.environment["ARENA_SUITE_REAL_ARCHIVE"] != nil))
func realArchiveDatasetIsCleanDeterministicAndTelemetryFree() async throws {
    let archiveRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ARENA_SUITE_REAL_ARCHIVE"]!)
    let journals = JournalStore(archiveRoot: archiveRoot)
    let accounts = journals.accountsOnDisk()
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("real-dataset-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temp) }
    let service = ArchiveService(
        index: try ArchiveIndex(url: temp.appendingPathComponent("index/archive.sqlite")), journals: journals,
        decoder: ArenaArchiveDecoder(), accounts: { accounts })
    for account in accounts { _ = try await service.project(account) }
    let datasets = DatasetService(archive: service)

    for recipe in [DatasetRecipe(), DatasetRecipe(name: "with-requested", acceptedTiers: [.revealedMessageClaim, .requestedSelection])] {
        let audit = try await datasets.validate(recipe: recipe)
        print("dataset \(recipe.name): candidates \(audit.candidates), included \(audit.included), excluded \(audit.excluded)")
        print("  exclusion reasons \(audit.exclusionReasons.sorted { $0.key < $1.key })")
        print("  included warnings \(audit.includedWarnings.sorted { $0.key < $1.key })")
        print("  tiers \(audit.tiers.sorted { $0.key < $1.key }); splits \(audit.splits.sorted { $0.key < $1.key })")
        print("  groups \(audit.groups), largest \(audit.largestGroup), labels \(audit.labels); violations all zero \(audit.isClean)")
        print("  notes \(audit.notes.count)")
        #expect(audit.isClean, "\(audit.violations)")

        let out = temp.appendingPathComponent("out-\(recipe.name)", isDirectory: true)
        let first = try await datasets.build(recipe: recipe, in: out, appVersion: "test")
        let second = try await datasets.build(recipe: recipe, in: out, appVersion: "test")
        for name in ["samples.jsonl", "excluded.jsonl", "audit.json", "recipe.json", "manifest.json"] {
            #expect(first.files[name] == second.files[name], "\(name) deterministic")
        }
        for name in first.files.keys {
            let text = String(decoding: try Data(contentsOf: first.url.appendingPathComponent(name)), as: UTF8.self)
            for marker in ["recaptchaV3Score", "arenaLionScoreCurrent", "hashedClientIp", "cf_client_asn", "ja4_browser_ratio_1h", "reasoningEncryptedContent"] {
                #expect(!text.contains(marker), "\(marker) in \(name)")
            }
        }
        print("  built twice: identical except run.json; telemetry markers absent")
        // Compare these across two processes (Swift seeds hashing per process).
        for name in ["samples.jsonl", "excluded.jsonl", "audit.json", "recipe.json", "manifest.json"] {
            print("  sha256 \(name) \(first.files[name] ?? "-")")
        }
    }
}

/// v2 §12: source Unicode and text bytes are preserved unless the recipe declares normalization.
@Test func featureTextIsKeptByteForByte() async throws {
    let text = "Line one\r\nZweite Zeile: e\u{301} vs \u{E9}, emoji 🧪🏳️‍🌈, quote \" backslash \\ and </script>\u{2028}end"
    let h = try await DatasetHarness([
        Record(account: accountA, role: "detail", body: battle("bytes", prompt: "Show unicode.", a: text, b: "plain"), entryID: "bytes")
    ])
    let result = try await h.datasets.build(recipe: DatasetRecipe(), in: h.output, appVersion: "test")
    let samples = String(decoding: try Data(contentsOf: result.url.appendingPathComponent("samples.jsonl")), as: UTF8.self)
    let line = try #require(samples.split(separator: "\n").first { $0.contains("bytes-a1") })
    let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    let kept = try #require((object["features"] as? [String: String])?["response_text"])
    #expect(Array(kept.utf8) == Array(text.utf8), "code points and bytes unchanged, including the decomposed accent")
}
