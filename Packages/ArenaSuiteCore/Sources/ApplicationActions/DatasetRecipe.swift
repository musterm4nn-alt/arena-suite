import CryptoKit
import Foundation
import SuiteDomain

/// A dataset recipe (plan v3 §14, with v2 §12's hygiene rules). It decides which archived responses
/// become samples, what their features and labels are, and how they are grouped and split. The
/// canonical form also names every fixed algorithm, so a recipe file states exactly what built a
/// dataset and rebuilds it byte for byte from the same source.
public struct DatasetRecipe: Sendable, Equatable {
    public static let schema = "arena-suite.dataset-recipe/1"

    /// How a label is evidenced. No tier is a verified identity.
    public enum Tier: String, CaseIterable, Sendable {
        /// Anonymous mode: message-scoped claims agree and the conversation's revealed set holds the label.
        case revealedMessageClaim = "revealed_message_claim"
        /// The user chose the model, so the label is what was requested (v2 §12).
        case requestedSelection = "requested_selection"
        /// Anonymous mode: message-scoped claims agree, but the conversation has no revealed set.
        case messageClaimWithoutReveal = "message_claim_without_reveal"
    }

    public enum ModeClass: String, CaseIterable, Sendable {
        /// Model identity is hidden until the user votes.
        case anonymous
        /// The user picked the model or models.
        case userSelected = "user_selected"
    }

    public enum Feature: String, CaseIterable, Sendable {
        case responseText = "response_text"
        case promptText = "prompt_text"
        case reasoningText = "reasoning_text"
    }

    public enum LeakageAction: String, CaseIterable, Sendable {
        case exclude, flag
    }

    public enum Holdout: Sendable, Equatable {
        /// Every group holding a sample from this account is the test split.
        case account(AccountID)
        /// Every group holding a conversation whose Arena `updatedAt` is after this instant, or is
        /// unknown, is the test split. `text` is the ISO 8601 instant as written.
        case updatedAfter(text: String, microseconds: Int64)
    }

    public var name: String
    /// nil = every account in the index.
    public var accounts: [AccountID]?
    /// nil = every mode.
    public var modes: [String]?
    /// nil = every modality.
    public var modalities: [String]?
    /// Response statuses accepted as samples.
    public var statuses: [String]
    public var acceptedTiers: [Tier]
    /// Arena mode → how model identity is exposed in it. Modes not listed get no label tier.
    public var modeClasses: [String: ModeClass]
    public var features: [Feature]
    public var excludeCrossLaneAncestry: Bool
    public var excludeUnresolvedAncestry: Bool
    public var excludeParserFindings: Bool
    /// What to do when a sample's own model ID or display name appears in its features.
    public var selfIdentification: LeakageAction
    public var nearDuplicateThresholdPercent: Int
    public var seed: String
    public var trainPercent: Int
    public var validationPercent: Int
    public var testPercent: Int
    public var holdout: Holdout?

    /// The default "clean labels" recipe: revealed battle labels only, response text only.
    public init(
        name: String = "clean-labels", accounts: [AccountID]? = nil, modes: [String]? = nil, modalities: [String]? = nil,
        statuses: [String] = ["success"], acceptedTiers: [Tier] = [.revealedMessageClaim],
        modeClasses: [String: ModeClass] = ["battle": .anonymous, "side-by-side": .userSelected, "direct-battle": .userSelected],
        features: [Feature] = [.responseText], excludeCrossLaneAncestry: Bool = true, excludeUnresolvedAncestry: Bool = true,
        excludeParserFindings: Bool = true, selfIdentification: LeakageAction = .exclude, nearDuplicateThresholdPercent: Int = 80,
        seed: String = "arena-suite", trainPercent: Int = 80, validationPercent: Int = 10, testPercent: Int = 10,
        holdout: Holdout? = nil
    ) {
        self.name = name
        self.accounts = accounts
        self.modes = modes
        self.modalities = modalities
        self.statuses = statuses
        self.acceptedTiers = acceptedTiers
        self.modeClasses = modeClasses
        self.features = features
        self.excludeCrossLaneAncestry = excludeCrossLaneAncestry
        self.excludeUnresolvedAncestry = excludeUnresolvedAncestry
        self.excludeParserFindings = excludeParserFindings
        self.selfIdentification = selfIdentification
        self.nearDuplicateThresholdPercent = nearDuplicateThresholdPercent
        self.seed = seed
        self.trainPercent = trainPercent
        self.validationPercent = validationPercent
        self.testPercent = testPercent
        self.holdout = holdout
    }

    // Fixed in version 1 and written into every canonical recipe, so a recipe file names them.
    static let snapshotPolicy = "latest"
    static let origins = ["history_import"]
    static let roles = ["assistant"]
    static let branchPolicy = "keep_all_grouped"
    static let textJoin = "blank_line"
    static let textNormalization = "none"
    static let leakagePolicy = "label-terms/1"
    static let minimumTermLength = 3
    static let groupingAlgorithm = "connected-groups/1"
    static let promptFamilyAlgorithm = "normalized-exact/1"
    static let nearDuplicateAlgorithm = "minhash-lsh/1"
    static let shingle = "char-5"
    static let permutations = 128
    static let bands = 32
    static let splitAlgorithm = "group-hash/1"

    // MARK: Validation

    /// Checks every value. Throws the first problem found, naming its JSON path.
    public func validated() throws -> DatasetRecipe {
        func invalid(_ path: String, _ reason: String) -> DatasetRecipeError { .invalidValue(path, reason) }
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw invalid("$.name", "1 to 80 characters, no control characters")
        }
        if let accounts, accounts.isEmpty { throw invalid("$.selection.accounts", "null or a non-empty list") }
        if let modes, modes.isEmpty { throw invalid("$.selection.modes", "null or a non-empty list") }
        if let modalities, modalities.isEmpty { throw invalid("$.selection.modalities", "null or a non-empty list") }
        guard !statuses.isEmpty, !statuses.contains("") else { throw invalid("$.responses.statuses", "a non-empty list of non-empty statuses") }
        guard !acceptedTiers.isEmpty else { throw invalid("$.labels.accepted_tiers", "a non-empty list") }
        guard features.contains(.responseText) else { throw invalid("$.features.allowlist", "must contain response_text") }
        guard (50...100).contains(nearDuplicateThresholdPercent) else {
            throw invalid("$.grouping.near_duplicates.threshold_percent", "an integer from 50 to 100")
        }
        guard !seed.isEmpty, seed.count <= 200 else { throw invalid("$.split.seed", "1 to 200 characters") }
        let percents = [trainPercent, validationPercent, testPercent]
        guard percents.allSatisfy({ (0...100).contains($0) }), percents.reduce(0, +) == 100, trainPercent > 0 else {
            throw invalid("$.split.percent", "integers from 0 to 100 that sum to 100, with train above 0")
        }
        if holdout != nil, testPercent != 0 {
            throw invalid("$.split.percent.test", "must be 0 with a holdout: the holdout is the whole test split")
        }
        var copy = self
        if case .updatedAfter(let text, _) = holdout {
            // The instant is always derived from the text as written, never taken on trust.
            guard let microseconds = Self.instant(text) else {
                throw invalid("$.split.holdout.updated_after", "an ISO 8601 instant, e.g. 2026-09-01T00:00:00Z")
            }
            copy.holdout = .updatedAfter(text: text, microseconds: microseconds)
        }
        copy.accounts = accounts.map { Array(Set($0)).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString } }
        copy.modes = modes.map { Array(Set($0)).sorted() }
        copy.modalities = modalities.map { Array(Set($0)).sorted() }
        copy.statuses = Array(Set(statuses)).sorted()
        copy.acceptedTiers = Tier.allCases.filter(acceptedTiers.contains)
        copy.features = Feature.allCases.filter(features.contains)
        return copy
    }

    // MARK: Canonical form

    /// The canonical JSON object: every field explicit, lists sorted, fixed algorithms named.
    public func jsonObject() throws -> [String: Any] {
        let recipe = try validated()
        func list(_ values: [String]?) -> Any { values.map { $0 as Any } ?? NSNull() }
        let holdout: Any
        switch recipe.holdout {
        case .none: holdout = NSNull()
        case .account(let account): holdout = ["account": account.rawValue.uuidString]
        case .updatedAfter(let text, _): holdout = ["updated_after": text]
        }
        return [
            "schema": Self.schema,
            "name": recipe.name,
            "selection": [
                "accounts": list(recipe.accounts?.map(\.rawValue.uuidString)), "modes": list(recipe.modes),
                "modalities": list(recipe.modalities), "snapshot_policy": Self.snapshotPolicy, "origins": Self.origins,
            ] as [String: Any],
            "responses": ["roles": Self.roles, "statuses": recipe.statuses, "branch_policy": Self.branchPolicy] as [String: Any],
            "labels": [
                "accepted_tiers": recipe.acceptedTiers.map(\.rawValue),
                "mode_classes": recipe.modeClasses.mapValues(\.rawValue),
            ] as [String: Any],
            "features": [
                "allowlist": recipe.features.map(\.rawValue), "text_join": Self.textJoin,
                "text_normalization": Self.textNormalization,
            ] as [String: Any],
            "quality": [
                "exclude_cross_lane_ancestry": recipe.excludeCrossLaneAncestry,
                "exclude_unresolved_ancestry": recipe.excludeUnresolvedAncestry,
                "exclude_parser_findings": recipe.excludeParserFindings,
            ],
            "leakage": [
                "policy": Self.leakagePolicy, "min_term_length": Self.minimumTermLength,
                "self_identification": recipe.selfIdentification.rawValue,
            ] as [String: Any],
            "grouping": [
                "algorithm": Self.groupingAlgorithm, "prompt_family": Self.promptFamilyAlgorithm,
                "near_duplicates": [
                    "algorithm": Self.nearDuplicateAlgorithm, "shingle": Self.shingle, "permutations": Self.permutations,
                    "bands": Self.bands, "threshold_percent": recipe.nearDuplicateThresholdPercent,
                ] as [String: Any],
            ] as [String: Any],
            "split": [
                "algorithm": Self.splitAlgorithm, "seed": recipe.seed, "holdout": holdout,
                "percent": ["train": recipe.trainPercent, "validation": recipe.validationPercent, "test": recipe.testPercent],
            ] as [String: Any],
        ]
    }

    /// Compact canonical bytes; `sha256` is computed over these.
    public func canonicalData() throws -> Data {
        try JSONSerialization.data(withJSONObject: try jsonObject(), options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Pretty-printed canonical form for `recipe.json`.
    public func fileData() throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: try jsonObject(), options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    public func sha256() throws -> String {
        SHA256.hash(data: try canonicalData()).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Parsing

    /// Parses a recipe strictly: unknown keys, wrong types and unsupported values are errors, so a
    /// typo cannot silently change a dataset. Omitted keys take the defaults of `init()`. Fixed
    /// algorithm fields may be omitted but, when present, must name the supported algorithm.
    public static func parse(_ data: Data) throws -> DatasetRecipe {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DatasetRecipeError.notJSONObject }
        let top = try RecipeObject(root, path: "$", keys: [
            "schema", "name", "selection", "responses", "labels", "features", "quality", "leakage", "grouping", "split",
        ])
        guard let schema = try top.string("schema") else { throw DatasetRecipeError.invalidValue("$.schema", "required") }
        guard schema == Self.schema else { throw DatasetRecipeError.unsupportedSchema(schema) }
        var recipe = DatasetRecipe()
        if let name = try top.string("name") { recipe.name = name }

        if let selection = try top.object("selection", keys: ["accounts", "modes", "modalities", "snapshot_policy", "origins"]) {
            if case .some(let accounts) = try selection.optionalStrings("accounts") {
                recipe.accounts = try accounts.map { list in
                    try list.map { text in
                        guard let uuid = UUID(uuidString: text) else {
                            throw DatasetRecipeError.invalidValue("$.selection.accounts", "account IDs (UUIDs)")
                        }
                        return AccountID(rawValue: uuid)
                    }
                }
            }
            if case .some(let modes) = try selection.optionalStrings("modes") { recipe.modes = modes }
            if case .some(let modalities) = try selection.optionalStrings("modalities") { recipe.modalities = modalities }
            try selection.fixed("snapshot_policy", Self.snapshotPolicy)
            try selection.fixedList("origins", Self.origins)
        }
        if let responses = try top.object("responses", keys: ["roles", "statuses", "branch_policy"]) {
            try responses.fixedList("roles", Self.roles)
            if let statuses = try responses.strings("statuses") { recipe.statuses = statuses }
            try responses.fixed("branch_policy", Self.branchPolicy)
        }
        if let labels = try top.object("labels", keys: ["accepted_tiers", "mode_classes"]) {
            if let tiers = try labels.strings("accepted_tiers") {
                recipe.acceptedTiers = try tiers.map { text in
                    guard let tier = Tier(rawValue: text) else {
                        throw DatasetRecipeError.invalidValue("$.labels.accepted_tiers", "one of \(Tier.allCases.map(\.rawValue))")
                    }
                    return tier
                }
            }
            if let classes = try labels.stringMap("mode_classes") {
                recipe.modeClasses = try classes.mapValues { text in
                    guard let value = ModeClass(rawValue: text) else {
                        throw DatasetRecipeError.invalidValue("$.labels.mode_classes", "anonymous or user_selected")
                    }
                    return value
                }
            }
        }
        if let features = try top.object("features", keys: ["allowlist", "text_join", "text_normalization"]) {
            if let allowlist = try features.strings("allowlist") {
                recipe.features = try allowlist.map { text in
                    guard let feature = Feature(rawValue: text) else {
                        throw DatasetRecipeError.invalidValue("$.features.allowlist", "one of \(Feature.allCases.map(\.rawValue))")
                    }
                    return feature
                }
            }
            try features.fixed("text_join", Self.textJoin)
            try features.fixed("text_normalization", Self.textNormalization)
        }
        if let quality = try top.object(
            "quality", keys: ["exclude_cross_lane_ancestry", "exclude_unresolved_ancestry", "exclude_parser_findings"])
        {
            if let value = try quality.bool("exclude_cross_lane_ancestry") { recipe.excludeCrossLaneAncestry = value }
            if let value = try quality.bool("exclude_unresolved_ancestry") { recipe.excludeUnresolvedAncestry = value }
            if let value = try quality.bool("exclude_parser_findings") { recipe.excludeParserFindings = value }
        }
        if let leakage = try top.object("leakage", keys: ["policy", "min_term_length", "self_identification"]) {
            try leakage.fixed("policy", Self.leakagePolicy)
            if let length = try leakage.int("min_term_length"), length != Self.minimumTermLength {
                throw DatasetRecipeError.invalidValue("$.leakage.min_term_length", "\(Self.minimumTermLength) in this version")
            }
            if let text = try leakage.string("self_identification") {
                guard let action = LeakageAction(rawValue: text) else {
                    throw DatasetRecipeError.invalidValue("$.leakage.self_identification", "exclude or flag")
                }
                recipe.selfIdentification = action
            }
        }
        if let grouping = try top.object("grouping", keys: ["algorithm", "prompt_family", "near_duplicates"]) {
            try grouping.fixed("algorithm", Self.groupingAlgorithm)
            try grouping.fixed("prompt_family", Self.promptFamilyAlgorithm)
            if let near = try grouping.object(
                "near_duplicates", keys: ["algorithm", "shingle", "permutations", "bands", "threshold_percent"])
            {
                try near.fixed("algorithm", Self.nearDuplicateAlgorithm)
                try near.fixed("shingle", Self.shingle)
                if let value = try near.int("permutations"), value != Self.permutations {
                    throw DatasetRecipeError.invalidValue(near.path + ".permutations", "\(Self.permutations) in this version")
                }
                if let value = try near.int("bands"), value != Self.bands {
                    throw DatasetRecipeError.invalidValue(near.path + ".bands", "\(Self.bands) in this version")
                }
                if let value = try near.int("threshold_percent") { recipe.nearDuplicateThresholdPercent = value }
            }
        }
        if let split = try top.object("split", keys: ["algorithm", "seed", "percent", "holdout"]) {
            try split.fixed("algorithm", Self.splitAlgorithm)
            if let seed = try split.string("seed") { recipe.seed = seed }
            if let percent = try split.object("percent", keys: ["train", "validation", "test"]) {
                recipe.trainPercent = try percent.int("train") ?? recipe.trainPercent
                recipe.validationPercent = try percent.int("validation") ?? recipe.validationPercent
                recipe.testPercent = try percent.int("test") ?? recipe.testPercent
            }
            if let holdout = try split.nullableObject("holdout", keys: ["account", "updated_after"]) {
                recipe.holdout = try Self.holdout(holdout)
            }
        }
        return try recipe.validated()
    }

    private static func holdout(_ object: RecipeObject) throws -> Holdout {
        let account = try object.string("account")
        let after = try object.string("updated_after")
        switch (account, after) {
        case (let text?, nil):
            guard let uuid = UUID(uuidString: text) else { throw DatasetRecipeError.invalidValue(object.path + ".account", "an account ID") }
            return .account(AccountID(rawValue: uuid))
        case (nil, let text?):
            guard let microseconds = instant(text) else {
                throw DatasetRecipeError.invalidValue(object.path + ".updated_after", "an ISO 8601 instant, e.g. 2026-09-01T00:00:00Z")
            }
            return .updatedAfter(text: text, microseconds: microseconds)
        default:
            throw DatasetRecipeError.invalidValue(object.path, "exactly one of account or updated_after")
        }
    }

    /// Whole-second ISO 8601 instant with a zone designator → microseconds since 1970.
    public static func instant(_ text: String) -> Int64? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text) else { return nil }
        let seconds = date.timeIntervalSince1970.rounded(.down)
        guard seconds == date.timeIntervalSince1970, abs(seconds) < 1e11 else { return nil }
        return Int64(seconds) * 1_000_000
    }
}

extension DatasetRecipe.Holdout {
    /// `updated_after` from a whole-second ISO 8601 instant such as `2026-09-01T00:00:00Z`; nil if it
    /// does not parse.
    public static func updatedAfter(_ text: String) -> Self? {
        DatasetRecipe.instant(text).map { .updatedAfter(text: text, microseconds: $0) }
    }
}

public enum DatasetRecipeError: Error, Equatable, Sendable {
    case notJSONObject
    case unsupportedSchema(String)
    /// A key this recipe version does not define (JSON path).
    case unknownKey(String)
    case wrongType(String, expected: String)
    case invalidValue(String, String)
}

/// Strict reader over one JSON object of a recipe.
private struct RecipeObject {
    let values: [String: Any]
    let path: String

    init(_ values: [String: Any], path: String, keys: Set<String>) throws {
        if let unknown = values.keys.sorted().first(where: { !keys.contains($0) }) {
            throw DatasetRecipeError.unknownKey("\(path).\(unknown)")
        }
        self.values = values
        self.path = path
    }

    private func present(_ key: String) -> Any? {
        guard let value = values[key], !(value is NSNull) else { return nil }
        return value
    }

    func string(_ key: String) throws -> String? {
        guard let value = present(key) else { return nil }
        guard let text = value as? String else { throw DatasetRecipeError.wrongType("\(path).\(key)", expected: "string") }
        return text
    }

    func bool(_ key: String) throws -> Bool? {
        guard let value = present(key) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw DatasetRecipeError.wrongType("\(path).\(key)", expected: "true or false")
        }
        return number.boolValue
    }

    func int(_ key: String) throws -> Int? {
        guard let value = present(key) else { return nil }
        // Booleans, fractions and integers that do not fit `Int` (whose `intValue` would wrap) are refused.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            !CFNumberIsFloatType(number as CFNumber), number.stringValue == String(number.intValue)
        else { throw DatasetRecipeError.wrongType("\(path).\(key)", expected: "integer") }
        return number.intValue
    }

    /// A list of strings; null is refused (the field needs a list).
    func strings(_ key: String) throws -> [String]? {
        guard let value = values[key] else { return nil }
        guard let list = value as? [Any], list.allSatisfy({ $0 is String }) else {
            throw DatasetRecipeError.wrongType("\(path).\(key)", expected: "list of strings")
        }
        return list.compactMap { $0 as? String }
    }

    /// A list of strings or null (null and absence both mean "all").
    func optionalStrings(_ key: String) throws -> [String]?? {
        guard let value = values[key] else { return .none }
        if value is NSNull { return .some(nil) }
        return .some(try strings(key))
    }

    func stringMap(_ key: String) throws -> [String: String]? {
        guard let value = present(key) else { return nil }
        guard let map = value as? [String: Any], map.values.allSatisfy({ $0 is String }) else {
            throw DatasetRecipeError.wrongType("\(path).\(key)", expected: "object of strings")
        }
        return map.compactMapValues { $0 as? String }
    }

    func object(_ key: String, keys: Set<String>) throws -> RecipeObject? {
        guard let value = present(key) else { return nil }
        guard let object = value as? [String: Any] else { throw DatasetRecipeError.wrongType("\(path).\(key)", expected: "object") }
        return try RecipeObject(object, path: "\(path).\(key)", keys: keys)
    }

    /// An object or null; null is returned as nil.
    func nullableObject(_ key: String, keys: Set<String>) throws -> RecipeObject? { try object(key, keys: keys) }

    /// A fixed algorithm field: may be omitted, must equal `expected` when present.
    func fixed(_ key: String, _ expected: String) throws {
        guard let value = try string(key) else { return }
        guard value == expected else { throw DatasetRecipeError.invalidValue("\(path).\(key)", "\(expected) in this version") }
    }

    func fixedList(_ key: String, _ expected: [String]) throws {
        guard let value = try strings(key) else { return }
        guard value == expected else { throw DatasetRecipeError.invalidValue("\(path).\(key)", "\(expected) in this version") }
    }
}
