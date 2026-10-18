import ArchiveIndex
import CryptoKit
import Foundation
import SuiteDomain

// Training/attribution datasets (plan v3 §14, with v2 §12's hygiene rules). A dataset is built from
// one frozen view of the projection plus the digest-checked journal record behind every snapshot it
// uses. Labels are claims with evidence tiers, never identities; related samples are grouped before
// splitting; features hold allowlisted text only and are scanned for label terms. Nothing here talks
// to Arena, votes, reveals, or suggests a vote.

public enum DatasetError: Error, Equatable, Sendable {
    /// Checks that must all be zero were not (cross-split overlap, features outside the allowlist).
    case auditFailed([String])
    case cancelled
    case io(String)
}

/// The split audit (v2 §12). `report` is the exact `audit.json`; the other fields summarize it.
public struct DatasetAudit: Sendable, Equatable {
    public let recipeSHA256: String
    public let candidates: Int
    public let included: Int
    /// Exclusion reason → candidates excluded for it (a candidate can have several reasons).
    public let exclusionReasons: [String: Int]
    /// Warning → included samples carrying it.
    public let includedWarnings: [String: Int]
    /// Evidence tier → included samples.
    public let tiers: [String: Int]
    /// Split → included samples.
    public let splits: [String: Int]
    public let groups: Int
    public let largestGroup: Int
    /// Distinct labels among included samples.
    public let labels: Int
    /// Counts that must all be zero: cross-split overlaps and structural feature violations.
    public let violations: [String: Int]
    public let notes: [String]
    public let report: Data

    public var excluded: Int { candidates - included }
    public var isClean: Bool { violations.values.allSatisfy { $0 == 0 } }
}

public struct DatasetPreviewEntry: Sendable, Equatable {
    public let sampleID: String
    public let included: Bool
    public let reasons: [String]
    public let warnings: [String]
    public let tier: String?
    public let modelID: String?
    public let split: String?
    /// The exact line a build writes for this candidate: to `samples.jsonl` when included (it
    /// holds the feature text), to `excluded.jsonl` otherwise (no text).
    public let line: String
}

public struct DatasetPreview: Sendable, Equatable {
    public let entries: [DatasetPreviewEntry]
    public let audit: DatasetAudit
}

public struct DatasetBuildResult: Sendable, Equatable {
    public let url: URL
    public let audit: DatasetAudit
    /// File name → SHA-256 of every file written.
    public let files: [String: String]
}

public struct DatasetService: Sendable {
    public static let builderVersion = "arena-suite.dataset-builder/1"
    public static let sampleSchema = "arena-suite.training/1"
    public static let exclusionSchema = "arena-suite.training-exclusion/1"
    public static let manifestSchema = "arena-suite.dataset-manifest/1"
    public static let auditSchema = "arena-suite.dataset-audit/1"
    public static let runSchema = "arena-suite.dataset-run/1"
    static let files = ["samples.jsonl", "excluded.jsonl", "audit.json", "recipe.json", "manifest.json", "run.json"]

    private let archive: ArchiveService

    public init(archive: ArchiveService) { self.archive = archive }

    /// The first `limit` candidates in output order with their decisions. Writes nothing.
    public func preview(recipe: DatasetRecipe, limit: Int = 20) async throws -> DatasetPreview {
        let plan = try await makePlan(recipe)
        let entries = plan.candidates.prefix(max(0, limit)).map { candidate in
            DatasetPreviewEntry(
                sampleID: candidate.sampleID, included: candidate.included, reasons: candidate.reasons,
                warnings: candidate.warnings, tier: candidate.label.tier?.rawValue, modelID: candidate.label.modelID,
                split: candidate.split?.rawValue, line: candidate.line)
        }
        return DatasetPreview(entries: Array(entries), audit: plan.audit)
    }

    /// The audit report of the dataset this recipe would build. Writes nothing.
    public func validate(recipe: DatasetRecipe) async throws -> DatasetAudit {
        try await makePlan(recipe).audit
    }

    /// Writes a new dataset folder inside `directory` and returns it. The folder appears only when
    /// complete (staged, synced, renamed without replacing anything); on failure or cancellation
    /// nothing is left. Refuses to write a dataset whose audit finds a violation.
    public func build(recipe: DatasetRecipe, in directory: URL, appVersion: String, now: Date = Date()) async throws
        -> DatasetBuildResult
    {
        let plan = try await makePlan(recipe)
        guard plan.audit.isClean else {
            throw DatasetError.auditFailed(plan.audit.violations.filter { $0.value != 0 }.keys.sorted())
        }
        guard !Task.isCancelled else { throw DatasetError.cancelled }
        return try Self.write(plan, into: directory, appVersion: appVersion, now: now)
    }

    // MARK: Plan

    enum Split: String, CaseIterable, Sendable {
        case train, validation, test
    }

    struct EvidenceRef: Hashable, Comparable {
        let source: String
        let sequence: UInt64
        let feedbackID: String?

        static func < (l: EvidenceRef, r: EvidenceRef) -> Bool {
            (l.source, l.sequence, l.feedbackID ?? "") < (r.source, r.sequence, r.feedbackID ?? "")
        }

        var json: [String: Any] {
            var object: [String: Any] = ["source": source, "sequence": String(sequence)]
            if let feedbackID { object["feedback_id"] = feedbackID }
            return object
        }
    }

    struct LabelEvidence {
        var modelID: String?
        var tier: DatasetRecipe.Tier?
        var problems: [String] = []
        var labelSources: [String] = []
        var corroboratedBy: [String] = []
        var evidence: [EvidenceRef] = []
        var unrecognizedClaims = 0
    }

    enum SourceRecord {
        case available(digest: String, origin: String)
        case unavailable
        case accountMismatch
    }

    struct Candidate {
        let sampleID: String
        let account: AccountID
        let conversationID: String
        let conversationKind: String
        let mode: String?
        let modality: String?
        let updatedOrder: Int64?
        let message: DetailMessage
        let snapshotSequence: UInt64
        let record: SourceRecord
        let promptID: String?
        let label: LabelEvidence
        let features: [String: Any]
        /// Normalized texts used for grouping and duplicate checks only.
        let responseKey: String
        let promptKey: String?
        var reasons: [String]
        var warnings: [String]
        var groupID: String?
        var promptFamilyID: String?
        var split: Split?
        var line = ""

        var included: Bool { reasons.isEmpty }
        var conversationGroupID: String {
            DatasetService.digestID("c-", "arena-suite.conversation/1", [account.rawValue.uuidString, conversationID])
        }
        var turnID: String {
            DatasetService.digestID(
                "t-", "arena-suite.turn/1",
                [account.rawValue.uuidString, conversationID, promptID ?? "response:\(message.remoteID)"])
        }
        var recordDigest: String? {
            if case .available(let digest, _) = record { return digest }
            return nil
        }
        var origin: String? {
            if case .available(_, let origin) = record { return origin }
            return nil
        }
    }

    struct Plan {
        let recipe: DatasetRecipe
        let recipeSHA256: String
        let source: DatasetSource
        let candidates: [Candidate]
        let audit: DatasetAudit
        let manifestSource: [String: Any]
        let labels: [[String: Any]]
    }

    /// What a dataset covers ("complete" always names its scope).
    static let scope =
        "The latest archived snapshot of each selected conversation in the local index, which covers each account's journal through the listed checkpoint. It holds only what the history syncs behind those journals observed (completed observed pagination), not all of an account's Arena history."

    struct ConversationCounts {
        var inIndex = 0
        var withoutSnapshot = 0
        var modeNotSelected = 0
        var modalityNotSelected = 0
        var considered = 0
    }

    func makePlan(_ unvalidated: DatasetRecipe) async throws -> Plan {
        let recipe = try unvalidated.validated()
        let recipeSHA256 = try recipe.sha256()
        let source = try archive.datasetSource(accounts: recipe.accounts.map(Set.init))
        // Claims cover every account (the leakage vocabulary is deliberately global); the manifest's
        // label table names only what the selected accounts observed.
        let selectedAccounts = recipe.accounts.map(Set.init)
        func selected(_ account: AccountID) -> Bool { selectedAccounts?.contains(account) ?? true }
        let context = LabelContext(source.claims, source.feedback)
        let terms = LabelTerms(claims: source.claims.map(\.claim), minimumLength: DatasetRecipe.minimumTermLength)
        let unknownFields = Dictionary(
            source.accounts.map { ($0.account, $0.unknownFields) }, uniquingKeysWith: { first, _ in first })

        var counts = ConversationCounts()
        var candidates: [Candidate] = []
        var snapshots: [[String: Any]] = []
        for conversation in source.conversations {
            counts.inIndex += 1
            guard let sequence = conversation.summary.latestSnapshotSequence else {
                counts.withoutSnapshot += 1
                continue
            }
            if let modes = recipe.modes, !(conversation.summary.mode.map(modes.contains) ?? false) {
                counts.modeNotSelected += 1
                continue
            }
            if let modalities = recipe.modalities, !(conversation.summary.modality.map(modalities.contains) ?? false) {
                counts.modalityNotSelected += 1
                continue
            }
            counts.considered += 1
            guard !Task.isCancelled else { throw DatasetError.cancelled }
            let record = await sourceRecord(conversation)
            var entry: [String: Any] = [
                "account_id": conversation.summary.account.rawValue.uuidString,
                "conversation_id": conversation.summary.remoteID, "sequence": String(sequence),
            ]
            switch record {
            case .available(let digest, let origin): (entry["record_digest"], entry["origin"]) = (digest, origin)
            case .unavailable: entry["problem"] = "record unavailable, failed the journal's record digest or sequence check, or has no readable account"
            case .accountMismatch: entry["problem"] = "record envelope names another account"
            }
            snapshots.append(entry)
            let byID = Dictionary(conversation.messages.map { ($0.remoteID, $0) }, uniquingKeysWith: { first, _ in first })
            for message in conversation.messages where message.role == "assistant" {
                candidates.append(
                    Self.evaluate(
                        message, conversation: conversation, sequence: sequence, byID: byID, record: record,
                        unknownFields: unknownFields[conversation.summary.account] ?? [], context: context, terms: terms,
                        recipe: recipe))
            }
        }

        let grouping = Self.group(&candidates, recipe: recipe)
        Self.assignSplits(&candidates, recipe: recipe)
        for index in candidates.indices {
            candidates[index].line = try Self.line(candidates[index], recipeSHA256: recipeSHA256, decoder: source.decoderVersion)
        }
        let audit = try Self.audit(
            candidates, grouping: grouping, counts: counts, recipe: recipe, recipeSHA256: recipeSHA256, source: source,
            terms: terms)
        let manifestSource: [String: Any] = [
            "scope": Self.scope,
            "decoder": source.decoderVersion ?? NSNull(),
            "projection_digest": source.contentDigest,
            "checkpoints": Dictionary(
                source.accounts.map { ($0.account.rawValue.uuidString, String($0.checkpoint)) }, uniquingKeysWith: { first, _ in first }),
            "snapshots": snapshots,
            "observation_layer": "foundation_decoded_entity",
            "record_check": "Each snapshot's journal record is re-read at its indexed location; the journal reader verifies its framing and stored SHA-256 record digest, and its sequence and envelope account must match. record_digest is that verified digest; the index holds no independent copy.",
        ]
        return Plan(
            recipe: recipe, recipeSHA256: recipeSHA256, source: source, candidates: candidates, audit: audit,
            manifestSource: manifestSource,
            labels: Self.labelTable(candidates, claims: source.claims.filter { selected($0.account) }))
    }

    /// The journal record behind a snapshot, re-read at its indexed location. The journal reader
    /// verifies the record's framing and its stored SHA-256 record digest; the record must carry the
    /// snapshot's sequence. The index keeps no independent copy of that digest: the manifest's
    /// `record_digest` is the one verified here, so a later reader can check the journal against it.
    private func sourceRecord(_ conversation: DatasetSourceConversation) async -> SourceRecord {
        guard let location = conversation.snapshotLocation,
            let evidence = try? await archive.rawEvidence(at: location)
        else { return .unavailable }
        return Self.classify(envelope: evidence.envelope, digest: evidence.digest, account: conversation.summary.account)
    }

    /// An unreadable envelope, or one without a valid `account_id`, is unavailable evidence; only a
    /// readable envelope naming another account is a mismatch.
    static func classify(envelope bytes: Data, digest: String, account: AccountID) -> SourceRecord {
        guard let envelope = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
            let recorded = (envelope["account_id"] as? String).flatMap(UUID.init(uuidString:))
        else { return .unavailable }
        guard recorded == account.rawValue else { return .accountMismatch }
        // v1 records conversations only through user-started history sync, as `exchange` records;
        // Arena Suite cannot generate turns, so nothing here can come from the app or MCP.
        return .available(digest: digest, origin: envelope["kind"] as? String == "exchange" ? "history_import" : "unknown")
    }

    // MARK: Candidates

    static func evaluate(
        _ message: DetailMessage, conversation: DatasetSourceConversation, sequence: UInt64, byID: [String: DetailMessage],
        record: SourceRecord, unknownFields: [UnknownFieldRange], context: LabelContext, terms: LabelTerms,
        recipe: DatasetRecipe
    ) -> Candidate {
        let account = conversation.summary.account
        var reasons = Set<String>()
        var warnings = Set<String>()
        func finding(_ name: String, exclude: Bool) {
            if exclude { reasons.insert(name) } else { warnings.insert(name) }
        }

        if !recipe.statuses.contains(message.status ?? "") { reasons.insert("status_not_accepted") }
        if message.lane == nil { reasons.insert("lane_not_exposed") }

        let lineage = Self.lineage(of: message, in: byID)
        if lineage.unresolved || lineage.cyclic { finding("ancestry_unresolved", exclude: recipe.excludeUnresolvedAncestry) }
        if lineage.ancestors.contains(where: { $0.role == "assistant" && $0.lane != message.lane }) {
            finding("cross_lane_ancestry", exclude: recipe.excludeCrossLaneAncestry)
        }
        if !conversation.snapshotWarnings.isEmpty { finding("parser_warnings", exclude: recipe.excludeParserFindings) }
        // The index keeps unknown paths per account with first and last record; a message-level path
        // whose range covers this record may have been in it. Conservative by design.
        if unknownFields.contains(where: {
            $0.path.hasPrefix("$.messages[]") && $0.firstSequence <= sequence && sequence <= $0.lastSequence
        }) {
            finding("parser_unknown_fields", exclude: recipe.excludeParserFindings)
        }

        switch record {
        case .unavailable: reasons.insert("source_record_unavailable")
        case .accountMismatch: reasons.insert("source_record_account_mismatch")
        case .available(_, let origin): if !DatasetRecipe.origins.contains(origin) { reasons.insert("origin_not_accepted") }
        }

        let label = Self.label(for: message, conversation: conversation, context: context, recipe: recipe)
        reasons.formUnion(label.problems)
        if let tier = label.tier, label.problems.isEmpty, !recipe.acceptedTiers.contains(tier) { reasons.insert("tier_not_accepted") }
        if label.unrecognizedClaims > 0 { warnings.insert("unrecognized_claim") }

        let prompt: DetailMessage? = {
            guard message.parentIDs.count == 1, let parent = byID[message.parentIDs[0]], parent.role == "user" else { return nil }
            return parent
        }()
        if prompt == nil { warnings.insert("prompt_not_resolved") }
        let response = Self.text(of: message, kind: .text)
        if (response ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { reasons.insert("empty_response_text") }

        var features: [String: Any] = [:]
        for feature in recipe.features {
            switch feature {
            case .responseText: features[feature.rawValue] = response ?? NSNull()
            case .promptText: features[feature.rawValue] = prompt.flatMap { Self.text(of: $0, kind: .text) } ?? NSNull()
            case .reasoningText: features[feature.rawValue] = Self.text(of: message, kind: .reasoning) ?? NSNull()
            }
        }
        if let model = label.modelID {
            for relation in terms.findings(in: features, label: model) {
                finding(relation.rawValue, exclude: relation == .ownLabel && recipe.selfIdentification == .exclude)
            }
        }

        // Defensive: every path without a label already names a reason, so this should never fire.
        if reasons.isEmpty && (label.modelID == nil || label.tier == nil) { reasons.insert("incomplete_label") }

        let promptKey = prompt.flatMap { Self.text(of: $0, kind: .text) }.map(DatasetText.normalized)
        return Candidate(
            sampleID: digestID("s-", "arena-suite.sample/1", [account.rawValue.uuidString, conversation.summary.remoteID, message.remoteID]),
            account: account, conversationID: conversation.summary.remoteID, conversationKind: conversation.summary.kind,
            mode: conversation.summary.mode, modality: conversation.summary.modality, updatedOrder: conversation.updatedOrder,
            message: message, snapshotSequence: sequence, record: record, promptID: prompt?.remoteID, label: label,
            features: features, responseKey: DatasetText.normalized(response ?? ""),
            promptKey: promptKey?.isEmpty == false ? promptKey : nil, reasons: reasons.sorted(), warnings: warnings.sorted())
    }

    /// Text blocks of one kind joined by the recipe's blank line; nil when there are none.
    static func text(of message: DetailMessage, kind: BlockKind) -> String? {
        let parts = message.blocks.filter { $0.kind == kind }.compactMap(\.text)
        return parts.isEmpty ? nil : DatasetText.joined(parts)
    }

    /// Every ancestor reachable through parent links inside the snapshot. `unresolved`: a parent is
    /// missing from the snapshot; `cyclic`: the links loop (through the message or among ancestors).
    static func lineage(of message: DetailMessage, in byID: [String: DetailMessage]) -> (
        ancestors: [DetailMessage], unresolved: Bool, cyclic: Bool
    ) {
        var queue = message.parentIDs
        var next = 0
        var visited = Set<String>()
        var ancestors: [DetailMessage] = []
        var unresolved = false
        var cyclic = false
        while next < queue.count {
            let id = queue[next]
            next += 1
            if id == message.remoteID {
                cyclic = true
                continue
            }
            guard visited.insert(id).inserted else { continue }
            guard let parent = byID[id] else {
                unresolved = true
                continue
            }
            ancestors.append(parent)
            queue.append(contentsOf: parent.parentIDs)
        }
        if !cyclic {
            // Kahn's algorithm: ancestors that cannot be ordered sit on a loop.
            let nodes = Set(ancestors.map(\.remoteID))
            var pending: [String: Int] = [:]
            var children: [String: [String]] = [:]
            for ancestor in ancestors {
                let parents = Set(ancestor.parentIDs).intersection(nodes)
                pending[ancestor.remoteID] = parents.count
                for parent in parents { children[parent, default: []].append(ancestor.remoteID) }
            }
            var ready = pending.filter { $0.value == 0 }.map(\.key)
            var ordered = 0
            while let id = ready.popLast() {
                ordered += 1
                for child in children[id] ?? [] {
                    pending[child, default: 0] -= 1
                    if pending[child] == 0 { ready.append(child) }
                }
            }
            cyclic = ordered < nodes.count
        }
        return (ancestors, unresolved, cyclic)
    }

    // MARK: Labels

    /// Claims indexed by what they are about.
    struct LabelContext {
        struct MessageKey: Hashable {
            let account: AccountID
            let conversation: String
            let message: String
        }
        struct ConversationKey: Hashable {
            let account: AccountID
            let conversation: String
        }
        struct VoteKey: Hashable {
            let account: AccountID
            let conversation: String
            let feedback: String
            let sequence: UInt64
        }

        var messageClaims: [MessageKey: [SequencedClaim]] = [:]
        var voteClaims: [VoteKey: [SequencedClaim]] = [:]
        var votesByMessage: [MessageKey: [(vote: SequencedFeedback, role: String)]] = [:]
        var conversationClaims: [ConversationKey: [SequencedClaim]] = [:]
        /// Claims whose subject and source this builder does not interpret, by conversation.
        var unrecognized: [ConversationKey: Int] = [:]

        init(_ claims: [SequencedClaim], _ votes: [SequencedFeedback]) {
            for item in claims {
                let claim = item.claim
                let conversation = ConversationKey(account: item.account, conversation: item.conversationID)
                switch (claim.subject, claim.source) {
                case (.message, "message_model_id"):
                    messageClaims[MessageKey(account: item.account, conversation: item.conversationID, message: claim.subjectID), default: []]
                        .append(item)
                case (.feedback, "pairwise_feedback"):
                    voteClaims[
                        VoteKey(account: item.account, conversation: item.conversationID, feedback: claim.subjectID, sequence: item.sequence),
                        default: []
                    ].append(item)
                case (.conversation, "history_list"), (.conversation, "detail_revealed"):
                    conversationClaims[conversation, default: []].append(item)
                default:
                    unrecognized[conversation, default: 0] += 1
                }
            }
            for vote in votes {
                for (role, message) in [("a", vote.feedback.messageA), ("b", vote.feedback.messageB)] {
                    guard let message else { continue }
                    votesByMessage[MessageKey(account: vote.account, conversation: vote.conversationID, message: message), default: []]
                        .append((vote, role))
                }
            }
        }
    }

    /// A label comes only from claims scoped to this exact message: its own `modelId` and the
    /// model a vote names for it. Conversation-level claims only corroborate or contradict; they are
    /// never propagated to a message (v2 §12). Any disagreement leaves the sample unlabeled.
    static func label(
        for message: DetailMessage, conversation: DatasetSourceConversation, context: LabelContext, recipe: DatasetRecipe
    ) -> LabelEvidence {
        let account = conversation.summary.account
        let conversationID = conversation.summary.remoteID
        let key = LabelContext.MessageKey(account: account, conversation: conversationID, message: message.remoteID)
        var result = LabelEvidence()
        result.unrecognizedClaims = context.unrecognized[LabelContext.ConversationKey(account: account, conversation: conversationID)] ?? 0
        var models = Set<String>()
        var sources = Set<String>()
        var refs = Set<EvidenceRef>()
        for item in context.messageClaims[key] ?? [] {
            models.insert(item.claim.modelID)
            sources.insert(item.claim.source)
            refs.insert(EvidenceRef(source: item.claim.source, sequence: item.sequence, feedbackID: nil))
        }
        for (vote, role) in context.votesByMessage[key] ?? [] {
            let voteKey = LabelContext.VoteKey(
                account: account, conversation: conversationID, feedback: vote.feedback.remoteID, sequence: vote.sequence)
            for item in context.voteClaims[voteKey] ?? [] where item.claim.role == role {
                models.insert(item.claim.modelID)
                sources.insert(item.claim.source)
                refs.insert(EvidenceRef(source: item.claim.source, sequence: item.sequence, feedbackID: vote.feedback.remoteID))
            }
        }
        guard !models.isEmpty else {
            result.problems = ["no_message_scoped_claim"]
            return result
        }
        guard models.count == 1, let model = models.first else {
            result.problems = ["conflicting_claims"]
            result.evidence = refs.sorted()
            return result
        }

        let conversationClaims = context.conversationClaims[LabelContext.ConversationKey(account: account, conversation: conversationID)] ?? []
        let laneClaims = conversationClaims.filter { $0.claim.source == "history_list" && message.lane != nil && $0.claim.role == message.lane }
        let revealed = conversationClaims.filter { $0.claim.source == "detail_revealed" }
        let inRevealedSet = revealed.contains { $0.claim.modelID == model }
        var problems: [String] = []
        if laneClaims.contains(where: { $0.claim.modelID != model }) || (!revealed.isEmpty && !inRevealedSet) {
            problems.append("conflicting_claims")
        }
        var corroboration: [String] = []
        if !laneClaims.isEmpty, !problems.contains("conflicting_claims") {
            corroboration.append("history_list")
            laneClaims.forEach { refs.insert(EvidenceRef(source: "history_list", sequence: $0.sequence, feedbackID: nil)) }
        }
        if inRevealedSet {
            corroboration.append("detail_revealed")
            revealed.filter { $0.claim.modelID == model }.forEach {
                refs.insert(EvidenceRef(source: "detail_revealed", sequence: $0.sequence, feedbackID: nil))
            }
        }
        var tier: DatasetRecipe.Tier?
        switch conversation.summary.mode.flatMap({ recipe.modeClasses[$0] }) {
        case .anonymous?: tier = inRevealedSet ? .revealedMessageClaim : .messageClaimWithoutReveal
        case .userSelected?: tier = .requestedSelection
        case nil: problems.append("mode_unclassified")
        }
        result.modelID = model
        result.tier = problems.isEmpty ? tier : nil
        result.problems = problems
        result.labelSources = sources.sorted()
        result.corroboratedBy = corroboration.sorted()
        result.evidence = refs.sorted()
        return result
    }

    // MARK: Grouping and splits

    static let relations = [
        "same_conversation", "shared_conversation", "same_prompt", "near_duplicate_prompt", "duplicate_response",
        "near_duplicate_response",
    ]

    struct Grouping {
        var groups = 0
        var largest = 0
        /// Relation → unions that joined two different groups.
        var links: [String: Int] = [:]
        /// Near-duplicate pairs of distinct normalized texts (the audit checks them against splits).
        var promptPairs: [(String, String)] = []
        var responsePairs: [(String, String)] = []
    }

    /// Connected groups over included samples (v2 §12: group before splitting, connected grouping
    /// when relationships overlap). Assigns `groupID` and `promptFamilyID`.
    static func group(_ candidates: inout [Candidate], recipe: DatasetRecipe) -> Grouping {
        let positions = candidates.indices.filter { candidates[$0].included }
        var sets = UnionFind(count: positions.count)
        var grouping = Grouping()
        for relation in relations { grouping.links[relation] = 0 }
        func link(_ relation: String, _ members: [Int]) {
            for member in members.dropFirst() where sets.union(members[0], member) { grouping.links[relation, default: 0] += 1 }
        }
        func linkEqual(_ relation: String, _ key: (Candidate) -> String?) {
            var byKey: [String: [Int]] = [:]
            for (slot, position) in positions.enumerated() {
                if let value = key(candidates[position]) { byKey[value, default: []].append(slot) }
            }
            for value in byKey.keys.sorted() { link(relation, byKey[value]!) }
        }
        func linkNear(_ relation: String, _ key: (Candidate) -> String?) -> [(String, String)] {
            var byKey: [String: [Int]] = [:]
            for (slot, position) in positions.enumerated() {
                if let value = key(candidates[position]), !value.isEmpty { byKey[value, default: []].append(slot) }
            }
            let texts = byKey.keys.sorted()
            let pairs = NearDuplicates.pairs(texts, thresholdPercent: recipe.nearDuplicateThresholdPercent)
            for (a, b) in pairs { link(relation, [byKey[texts[a]]![0], byKey[texts[b]]![0]]) }
            return pairs.map { (texts[$0.0], texts[$0.1]) }
        }
        linkEqual("same_conversation") { "\($0.account.rawValue.uuidString)\u{0}\($0.conversationID)" }
        linkEqual("shared_conversation") { "\($0.conversationKind)\u{0}\($0.conversationID)" }
        linkEqual("same_prompt") { $0.promptKey }
        grouping.promptPairs = linkNear("near_duplicate_prompt") { $0.promptKey }
        linkEqual("duplicate_response") { $0.responseKey.isEmpty ? nil : $0.responseKey }
        grouping.responsePairs = linkNear("near_duplicate_response") { $0.responseKey }

        var members: [Int: [Int]] = [:]
        for slot in positions.indices { members[sets.find(slot), default: []].append(positions[slot]) }
        for group in members.values {
            let first = group.map { candidates[$0].sampleID }.min()!
            let id = digestID("g-", "arena-suite.group/1", [first])
            for position in group { candidates[position].groupID = id }
        }
        grouping.groups = members.count
        grouping.largest = members.values.map(\.count).max() ?? 0

        var families: [String: [Int]] = [:]
        for position in positions { if let key = candidates[position].promptKey { families[key, default: []].append(position) } }
        for family in families.values {
            let id = digestID("p-", "arena-suite.prompt-family/1", [family.map { candidates[$0].sampleID }.min()!])
            for position in family { candidates[position].promptFamilyID = id }
        }
        return grouping
    }

    /// `group-hash/1`: a group's bucket is SHA-256(seed, group ID) mod 100 against the integer
    /// percentages. A holdout sends its whole groups to test and splits the rest train/validation.
    static func assignSplits(_ candidates: inout [Candidate], recipe: DatasetRecipe) {
        var byGroup: [String: [Int]] = [:]
        for index in candidates.indices { if let group = candidates[index].groupID { byGroup[group, default: []].append(index) } }
        for (group, members) in byGroup {
            let heldOut: Bool
            switch recipe.holdout {
            case .none: heldOut = false
            case .account(let account)?: heldOut = members.contains { candidates[$0].account == account }
            case .updatedAfter(_, let after)?:
                // Unknown times go to test: never train on what may be later than the cutoff.
                heldOut = members.contains { candidates[$0].updatedOrder.map { $0 > after } ?? true }
            }
            let split: Split
            if heldOut {
                split = .test
            } else {
                let bucket = Self.bucket(seed: recipe.seed, group: group)
                split = bucket < recipe.trainPercent ? .train : bucket < recipe.trainPercent + recipe.validationPercent ? .validation : .test
            }
            for index in members { candidates[index].split = split }
        }
    }

    static func bucket(seed: String, group: String) -> Int {
        let digest = SHA256.hash(data: framed("arena-suite.split/1", [seed, group]))
        return Int(digest.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % 100)
    }

    // MARK: Lines

    static func line(_ candidate: Candidate, recipeSHA256: String, decoder: String?) throws -> String {
        let message = candidate.message
        let provenance: [String: Any] = [
            "account_id": candidate.account.rawValue.uuidString, "conversation_id": candidate.conversationID,
            "message_id": message.remoteID, "lane": message.lane ?? NSNull(), "mode": candidate.mode ?? NSNull(),
            "modality": candidate.modality ?? NSNull(), "status": message.status ?? NSNull(),
            "snapshot_sequence": String(candidate.snapshotSequence), "record_digest": candidate.recordDigest ?? NSNull(),
            "origin": candidate.origin ?? NSNull(), "decoder": decoder ?? NSNull(), "recipe_sha256": recipeSHA256,
        ]
        let object: [String: Any]
        if candidate.included {
            // An included sample always has a label (see `evaluate`); a missing split or group is an
            // audit violation, so `build` refuses before such a line could be written.
            object = [
                "schema": sampleSchema, "sample_id": candidate.sampleID, "split": candidate.split?.rawValue ?? NSNull(),
                "features": candidate.features,
                "target": [
                    "model_id": candidate.label.modelID ?? NSNull(), "evidence_tier": candidate.label.tier?.rawValue ?? NSNull(),
                    "verified_identity": false, "label_sources": candidate.label.labelSources,
                    "corroborated_by": candidate.label.corroboratedBy, "evidence": candidate.label.evidence.map(\.json),
                ] as [String: Any],
                "groups": [
                    "split_group": candidate.groupID ?? NSNull(), "conversation": candidate.conversationGroupID,
                    "turn": candidate.turnID, "prompt_family": candidate.promptFamilyID ?? NSNull(),
                ] as [String: Any],
                "eligibility": ["status": "included", "warnings": candidate.warnings] as [String: Any],
                "provenance": provenance,
            ]
        } else {
            object = [
                "schema": exclusionSchema, "sample_id": candidate.sampleID, "reasons": candidate.reasons,
                "warnings": candidate.warnings,
                "label": [
                    "model_id": candidate.label.modelID ?? NSNull(), "evidence_tier": candidate.label.tier?.rawValue ?? NSNull(),
                ] as [String: Any],
                "provenance": provenance,
            ]
        }
        return String(decoding: try compact(object), as: UTF8.self)
    }

    /// Model ID → the names, organizations and providers claimed for it, and included samples per split.
    static func labelTable(_ candidates: [Candidate], claims: [SequencedClaim]) -> [[String: Any]] {
        var perSplit: [String: [String: Int]] = [:]
        for candidate in candidates where candidate.included {
            if let model = candidate.label.modelID, let split = candidate.split { perSplit[model, default: [:]][split.rawValue, default: 0] += 1 }
        }
        var names: [String: Set<String>] = [:]
        var organizations: [String: Set<String>] = [:]
        var providers: [String: Set<String>] = [:]
        for item in claims where perSplit[item.claim.modelID] != nil {
            if let name = item.claim.displayName { names[item.claim.modelID, default: []].insert(name) }
            if let organization = item.claim.organization { organizations[item.claim.modelID, default: []].insert(organization) }
            if let provider = item.claim.provider { providers[item.claim.modelID, default: []].insert(provider) }
        }
        return perSplit.keys.sorted().map { model in
            [
                "model_id": model, "display_names": (names[model] ?? []).sorted(),
                "organizations": (organizations[model] ?? []).sorted(), "providers": (providers[model] ?? []).sorted(),
                "samples": Split.allCases.reduce(into: [String: Int]()) { $0[$1.rawValue] = perSplit[model]?[$1.rawValue] ?? 0 },
            ]
        }
    }

    // MARK: Audit

    static func audit(
        _ candidates: [Candidate], grouping: Grouping, counts: ConversationCounts, recipe: DatasetRecipe, recipeSHA256: String,
        source: DatasetSource, terms: LabelTerms
    ) throws -> DatasetAudit {
        let included = candidates.filter(\.included)
        func tally<S: Sequence>(_ values: S) -> [String: Int] where S.Element == String {
            values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        let reasons = tally(candidates.flatMap(\.reasons))
        let includedWarnings = tally(included.flatMap(\.warnings))
        let tiers = tally(included.compactMap { $0.label.tier?.rawValue })

        // `groups_across_splits` checks the split assignment against the grouping (consistency). Every
        // other overlap key is recounted from each sample's own fields and final split, independently
        // of the grouping, and near-duplicates independently of its LSH candidates (see `nearAcross`).
        func spanning(_ key: (Candidate) -> String?) -> Int {
            var splits: [String: Set<Split>] = [:]
            for candidate in included { if let value = key(candidate), let split = candidate.split { splits[value, default: []].insert(split) } }
            return splits.values.filter { $0.count > 1 }.count
        }
        let promptRecount = nearAcross(included, grouping.promptPairs, recipe: recipe) { $0.promptKey }
        let responseRecount = nearAcross(included, grouping.responsePairs, recipe: recipe) { $0.responseKey }
        var structural = 0
        let allowlist = Set(recipe.features.map(\.rawValue))
        for candidate in included { structural += LabelTerms.structuralViolations(candidate.features, allowlist: allowlist).count }
        let violations: [String: Int] = [
            "groups_across_splits": spanning(\.groupID),
            "conversations_across_splits": spanning { "\($0.account.rawValue.uuidString)\u{0}\($0.conversationID)" },
            "shared_conversations_across_splits": spanning { "\($0.conversationKind)\u{0}\($0.conversationID)" },
            "prompt_families_across_splits": spanning(\.promptKey),
            "duplicate_responses_across_splits": spanning { $0.responseKey.isEmpty ? nil : $0.responseKey },
            "near_duplicate_prompt_pairs_across_splits": promptRecount.pairs,
            "near_duplicate_response_pairs_across_splits": responseRecount.pairs,
            "structural_feature_violations": structural,
            "samples_without_split": included.filter { $0.split == nil || $0.groupID == nil }.count,
        ]

        var splitReports: [String: Any] = [:]
        var splitCounts: [String: Int] = [:]
        var labelsBySplit: [Split: Set<String>] = [:]
        for split in Split.allCases {
            let members = included.filter { $0.split == split }
            splitCounts[split.rawValue] = members.count
            labelsBySplit[split] = Set(members.compactMap { $0.label.modelID })
            splitReports[split.rawValue] = [
                "samples": members.count, "groups": Set(members.compactMap(\.groupID)).count,
                "labels": tally(members.compactMap { $0.label.modelID }),
                "tiers": tally(members.compactMap { $0.label.tier?.rawValue }),
                "accounts": tally(members.map(\.account.rawValue.uuidString)),
                "modes": tally(members.map { $0.mode ?? "(none)" }),
            ] as [String: Any]
        }

        var notes: [String] = []
        for split in Split.allCases where splitCounts[split.rawValue] == 0 && !included.isEmpty {
            if split == .test && recipe.holdout == nil && recipe.testPercent == 0 { continue }
            if split == .validation && recipe.validationPercent == 0 { continue }
            notes.append("The \(split.rawValue) split has no samples.")
        }
        let unseen = (labelsBySplit[.validation] ?? []).union(labelsBySplit[.test] ?? []).subtracting(labelsBySplit[.train] ?? [])
        if !unseen.isEmpty { notes.append("\(unseen.count) label(s) appear in validation or test but not in train.") }
        let single = tally(included.compactMap { $0.label.modelID }).filter { $0.value == 1 }.count
        if single > 0 { notes.append("\(single) label(s) have a single sample.") }
        if included.isEmpty { notes.append("No candidate met the recipe; nothing would be written to samples.jsonl.") }
        for (kind, recount) in [("prompt", promptRecount), ("response", responseRecount)] where !recount.exhaustive {
            notes.append(
                "More than \(exhaustiveRecountLimit) distinct \(kind) texts: the near-duplicate overlap check rechecked only the grouping's LSH pairs, so a pair LSH missed is not counted.")
        }

        var holdout: Any = NSNull()
        switch recipe.holdout {
        case .none: break
        case .account(let account)?:
            let test = included.filter { $0.split == .test }
            holdout = [
                "kind": "account", "account_id": account.rawValue.uuidString,
                "test_samples_from_account": test.filter { $0.account == account }.count,
                "test_samples_joined_by_group": test.filter { $0.account != account }.count,
            ] as [String: Any]
        case .updatedAfter(let text, let after)?:
            let test = included.filter { $0.split == .test }
            holdout = [
                "kind": "updated_after", "after": text,
                "test_samples_after": test.filter { ($0.updatedOrder ?? .min) > after }.count,
                "test_samples_time_unknown": test.filter { $0.updatedOrder == nil }.count,
                "test_samples_joined_by_group": test.filter { $0.updatedOrder.map { $0 <= after } ?? false }.count,
            ] as [String: Any]
        }

        func perValue(_ key: (Candidate) -> String) -> [String: Any] {
            var result: [String: [String: Int]] = [:]
            for candidate in candidates {
                result[key(candidate), default: ["candidates": 0, "included": 0]]["candidates", default: 0] += 1
                if candidate.included { result[key(candidate)]!["included", default: 0] += 1 }
            }
            return result
        }
        let leakageCandidates = candidates.filter { $0.label.modelID != nil }
        var leakage: [String: Any] = [
            "policy": DatasetRecipe.leakagePolicy, "terms": terms.count,
            "self_identification": recipe.selfIdentification.rawValue, "scanned_candidates": leakageCandidates.count,
        ]
        for relation in LabelTerms.Relation.allCases {
            let hits = candidates.filter { $0.reasons.contains(relation.rawValue) || $0.warnings.contains(relation.rawValue) }
            leakage[relation.rawValue] = ["candidates": hits.count, "included": hits.filter(\.included).count]
        }

        let report: [String: Any] = [
            "schema": auditSchema,
            "recipe_sha256": recipeSHA256,
            "source": [
                "scope": scope, "decoder": source.decoderVersion ?? NSNull(), "projection_digest": source.contentDigest,
                "checkpoints": Dictionary(
                    source.accounts.map { ($0.account.rawValue.uuidString, String($0.checkpoint)) }, uniquingKeysWith: { first, _ in first }),
            ] as [String: Any],
            "conversations": [
                "in_index": counts.inIndex, "without_snapshot": counts.withoutSnapshot, "mode_not_selected": counts.modeNotSelected,
                "modality_not_selected": counts.modalityNotSelected, "considered": counts.considered,
            ],
            "candidates": ["total": candidates.count, "included": included.count, "excluded": candidates.count - included.count],
            "exclusion_reasons": reasons,
            "included_warnings": includedWarnings,
            "label_tiers": perValue { $0.label.tier?.rawValue ?? "(none)" },
            "label_sources": tally(included.flatMap(\.label.labelSources)),
            "corroboration": tally(included.flatMap(\.label.corroboratedBy)),
            "leakage": leakage,
            "context_lineage": [
                "cross_lane_ancestry": candidates.filter { $0.reasons.contains("cross_lane_ancestry") || $0.warnings.contains("cross_lane_ancestry") }.count,
                "ancestry_unresolved": candidates.filter { $0.reasons.contains("ancestry_unresolved") || $0.warnings.contains("ancestry_unresolved") }.count,
                "prompt_not_resolved": candidates.filter { $0.warnings.contains("prompt_not_resolved") }.count,
            ],
            "origins": tally(candidates.map { $0.origin ?? "(record unavailable)" }),
            "modes": perValue { $0.mode ?? "(none)" },
            "modalities": perValue { $0.modality ?? "(none)" },
            "grouping": [
                "groups": grouping.groups, "largest_group": grouping.largest, "links": grouping.links,
                "near_duplicate_pairs": ["prompts": grouping.promptPairs.count, "responses": grouping.responsePairs.count],
                "near_duplicate_recount": [
                    "prompts": promptRecount.exhaustive ? "exhaustive_exact_jaccard" : "lsh_pairs_only",
                    "responses": responseRecount.exhaustive ? "exhaustive_exact_jaccard" : "lsh_pairs_only",
                ],
            ] as [String: Any],
            "splits": splitReports,
            "holdout": holdout,
            "violations": violations,
            "notes": notes,
        ]
        return DatasetAudit(
            recipeSHA256: recipeSHA256, candidates: candidates.count, included: included.count, exclusionReasons: reasons,
            includedWarnings: includedWarnings, tiers: tiers, splits: splitCounts, groups: grouping.groups,
            largestGroup: grouping.largest, labels: Set(included.compactMap { $0.label.modelID }).count, violations: violations,
            notes: notes, report: try pretty(report))
    }

    /// Above this many distinct texts the audit falls back to the grouping's LSH pairs (2 million
    /// exact comparisons at most).
    static let exhaustiveRecountLimit = 2000

    /// Near-duplicate pairs of included texts whose samples sit in more than one split. Every pair of
    /// distinct texts is compared by exact Jaccard (after a size bound: J ≤ smaller/larger), so a pair
    /// the grouping's LSH missed is still counted; above `exhaustiveRecountLimit` texts, only the
    /// grouping's verified pairs are rechecked.
    static func nearAcross(
        _ included: [Candidate], _ lshPairs: [(String, String)], recipe: DatasetRecipe, _ key: (Candidate) -> String?
    ) -> (pairs: Int, exhaustive: Bool) {
        var splits: [String: Set<Split>] = [:]
        for candidate in included {
            if let value = key(candidate), !value.isEmpty, let split = candidate.split { splits[value, default: []].insert(split) }
        }
        func across(_ a: String, _ b: String) -> Bool { (splits[a] ?? []).union(splits[b] ?? []).count > 1 }
        let texts = splits.keys.sorted()
        guard texts.count <= exhaustiveRecountLimit else { return (lshPairs.filter { across($0.0, $0.1) }.count, false) }
        let threshold = recipe.nearDuplicateThresholdPercent
        let shingles = texts.map(NearDuplicates.shingles)
        var count = 0
        for i in texts.indices {
            for j in texts.indices where j > i && across(texts[i], texts[j]) {
                let (small, large) = (min(shingles[i].count, shingles[j].count), max(shingles[i].count, shingles[j].count))
                guard small * 100 >= threshold * large else { continue }
                if NearDuplicates.similar(shingles[i], shingles[j], thresholdPercent: threshold) { count += 1 }
            }
        }
        return (count, true)
    }

    // MARK: Writing

    static func write(_ plan: Plan, into directory: URL, appVersion: String, now: Date) throws -> DatasetBuildResult {
        func data(_ lines: [String]) -> Data { Data(lines.map { $0 + "\n" }.joined().utf8) }
        let included = plan.candidates.filter(\.included)
        var contents: [String: Data] = [
            "samples.jsonl": data(included.map(\.line)),
            "excluded.jsonl": data(plan.candidates.filter { !$0.included }.map(\.line)),
            "audit.json": plan.audit.report,
            "recipe.json": try plan.recipe.fileData(),
        ]
        var fileTable: [String: Any] = [:]
        for name in contents.keys.sorted() {
            let bytes = contents[name]!
            fileTable[name] = [
                "sha256": hex(SHA256.hash(data: bytes)), "bytes": bytes.count,
                "lines": bytes.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) },
            ]
        }
        let manifest: [String: Any] = [
            "schema": manifestSchema,
            "builder": builderVersion,
            "recipe": try plan.recipe.jsonObject(),
            "recipe_sha256": plan.recipeSHA256,
            "source": plan.manifestSource,
            "labels": plan.labels,
            "counts": ["candidates": plan.audit.candidates, "included": plan.audit.included, "excluded": plan.audit.excluded],
            "files": fileTable,
            "contract": [
                "features": "Train only on `features`. `target`, `groups`, `eligibility` and `provenance` are labels and metadata, never model inputs.",
                "labels": "Every label is a claim from Arena with its evidence tier, sources and journal records; none is a verified identity.",
                "splits": "Samples are split by `groups.split_group`; related samples never cross splits (see audit.json violations).",
                "determinism": "For the same source (checkpoints and projection digest) and recipe, every file except run.json is byte-identical.",
                "excluded_content": "Arena per-message metadata telemetry, encrypted reasoning, tool calls and results, sources, attachments and their URLs, and vote values are never features.",
            ],
        ]
        contents["manifest.json"] = try pretty(manifest)
        contents["run.json"] = try pretty([
            "schema": runSchema, "builder": builderVersion, "app_version": appVersion,
            "created_at": ISO8601DateFormatter().string(from: now),
            "note": "Execution record: the only file that differs between two builds of the same source and recipe.",
        ])

        // Staging folders of ours that an earlier crash left behind (older than an hour).
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix(".arena-suite-dataset-") && name.hasSuffix(".partial") {
            let url = directory.appendingPathComponent(name)
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                now.timeIntervalSince(modified) > 3600
            {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let staging = directory.appendingPathComponent(".arena-suite-dataset-\(UUID().uuidString).partial", isDirectory: true)
        var finished = false
        defer { if !finished { try? FileManager.default.removeItem(at: staging) } }
        do {
            try PrivateFile.prepareDirectory(staging)
            for name in files {
                guard !Task.isCancelled else { throw DatasetError.cancelled }
                try PrivateFile.write(contents[name]!, to: staging.appendingPathComponent(name), exclusive: true)
            }
        } catch let error as DatasetError {
            throw error
        } catch {
            throw DatasetError.io("write the dataset files (\(error))")
        }
        guard !Task.isCancelled else { throw DatasetError.cancelled }
        let stamp = BackupService.stamp(now)
        for attempt in 1...100 {
            let name = attempt == 1 ? "Arena Suite Dataset \(stamp)" : "Arena Suite Dataset \(stamp) \(attempt)"
            let final = directory.appendingPathComponent(name, isDirectory: true)
            // RENAME_EXCL never replaces an existing folder.
            if renamex_np(staging.path, final.path, UInt32(RENAME_EXCL)) == 0 {
                finished = true
                let parent = open(directory.path, O_RDONLY)
                if parent >= 0 {
                    _ = fcntl(parent, F_FULLFSYNC) == 0 || fsync(parent) == 0
                    close(parent)
                }
                return DatasetBuildResult(
                    url: final, audit: plan.audit, files: contents.mapValues { hex(SHA256.hash(data: $0)) })
            }
            guard errno == EEXIST else { throw DatasetError.io("rename the dataset folder (errno \(errno))") }
        }
        throw DatasetError.io("no free dataset folder name")
    }

    // MARK: Encoding

    /// Length-framed SHA-256 input: unambiguous for any strings, including ones with NUL bytes.
    static func framed(_ domain: String, _ parts: [String]) -> Data {
        var data = Data(domain.utf8)
        for part in parts {
            withUnsafeBytes(of: UInt64(part.utf8.count).littleEndian) { data.append(contentsOf: $0) }
            data.append(contentsOf: part.utf8)
        }
        return data
    }

    static func digestID(_ prefix: String, _ domain: String, _ parts: [String]) -> String {
        prefix + SHA256.hash(data: framed(domain, parts)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    static func compact(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func pretty(_ object: Any) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
}
