import Foundation
import SuiteDomain

// Deterministic helpers for dataset hygiene (plan v3 §14, v2 §12): text keys for grouping,
// near-duplicate detection, connected groups, and the label-term leakage scan. No random state;
// nothing here depends on dictionary iteration order.

enum DatasetText {
    /// `normalized-exact/1`: NFKC, lowercase, whitespace runs collapsed to one space, trimmed. Used
    /// only for grouping and duplicate checks; features keep the text as written.
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The recipe's declared `text_join`: text blocks are joined with one blank line.
    static func joined(_ parts: [String]) -> String { parts.joined(separator: "\n\n") }
}

/// `minhash-lsh/1`: character 5-gram shingles over the Unicode scalars of normalized text, 128
/// seeded 64-bit MinHash permutations in 32 bands of 4 rows, and every LSH candidate pair verified by
/// the exact Jaccard similarity of the two shingle sets. LSH only proposes pairs; verification
/// decides, so a pair is never reported on a hash coincidence.
enum NearDuplicates {
    static let shingleLength = 5
    static let permutations = DatasetRecipe.permutations
    static let bands = DatasetRecipe.bands
    static var rows: Int { permutations / bands }

    private static let seeds: [UInt64] = {
        var state: UInt64 = 0x6A09_E667_F3BC_C908
        return (0..<permutations).map { _ in
            state &+= 0x9E37_79B9_7F4A_7C15
            return mix(state)
        }
    }()

    /// SplitMix64 finalizer.
    static func mix(_ value: UInt64) -> UInt64 {
        var z = value
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// FNV-1a over the scalar values (4 little-endian bytes each).
    private static func fnv(_ scalars: ArraySlice<UInt32>) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for scalar in scalars {
            for shift in stride(from: UInt32(0), to: 32, by: 8) {
                hash ^= UInt64((scalar >> shift) & 0xFF)
                hash = hash &* 0x0000_0100_0000_01B3
            }
        }
        return hash
    }

    /// Shingles of already normalized text; a text shorter than 5 scalars is one shingle.
    static func shingles(_ normalized: String) -> Set<UInt64> {
        let scalars = normalized.unicodeScalars.map(\.value)
        guard !scalars.isEmpty else { return [] }
        guard scalars.count > shingleLength else { return [fnv(scalars[...])] }
        var result = Set<UInt64>()
        for start in 0...(scalars.count - shingleLength) {
            result.insert(fnv(scalars[start..<start + shingleLength]))
        }
        return result
    }

    static func signature(_ shingles: Set<UInt64>) -> [UInt64] {
        seeds.map { seed in shingles.reduce(UInt64.max) { min($0, mix($1 ^ seed)) } }
    }

    /// |A ∩ B| / |A ∪ B| ≥ threshold%, in integers.
    static func similar(_ a: Set<UInt64>, _ b: Set<UInt64>, thresholdPercent: Int) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let shared = a.intersection(b).count
        return shared * 100 >= thresholdPercent * (a.count + b.count - shared)
    }

    private struct Pair: Hashable, Comparable {
        let first: Int
        let second: Int
        static func < (l: Pair, r: Pair) -> Bool { (l.first, l.second) < (r.first, r.second) }
    }

    /// Index pairs (i < j) of `texts` (normalized) that are near-duplicates, in ascending order.
    /// Empty texts never pair.
    static func pairs(_ texts: [String], thresholdPercent: Int) -> [(Int, Int)] {
        let sets = texts.map(shingles)
        let signatures = sets.map(signature)
        var candidates = Set<Pair>()
        for band in 0..<bands {
            var buckets: [[UInt64]: [Int]] = [:]
            for index in texts.indices where !sets[index].isEmpty {
                buckets[Array(signatures[index][band * rows..<(band + 1) * rows]), default: []].append(index)
            }
            for members in buckets.values where members.count > 1 {
                for i in 0..<members.count - 1 {
                    for j in (i + 1)..<members.count { candidates.insert(Pair(first: members[i], second: members[j])) }
                }
            }
        }
        return candidates.filter { similar(sets[$0.first], sets[$0.second], thresholdPercent: thresholdPercent) }
            .sorted().map { ($0.first, $0.second) }
    }
}

/// Disjoint sets over sample positions. The final partition does not depend on the order of unions.
struct UnionFind {
    private var parent: [Int]

    init(count: Int) { parent = Array(0..<count) }

    mutating func find(_ element: Int) -> Int {
        var root = element
        while parent[root] != root { root = parent[root] }
        var node = element
        while parent[node] != root {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }

    /// True when two different sets were joined.
    @discardableResult
    mutating func union(_ a: Int, _ b: Int) -> Bool {
        let (rootA, rootB) = (find(a), find(b))
        guard rootA != rootB else { return false }
        if rootA < rootB { parent[rootB] = rootA } else { parent[rootA] = rootB }
        return true
    }
}

/// Leakage policy `label-terms/1`: every model ID, display name, organization and provider named by
/// any claim in the archive is a term (at least 3 characters). Terms and scanned text are compared
/// in the `normalized-exact/1` form (NFKC, lowercase, whitespace collapsed), so canonically or
/// compatibly equivalent spellings match alike; the features themselves are never changed. Matches are
/// word-bounded: the characters around a match must not be letters or digits, so `gpt-4o` also
/// matches inside `gpt-4o-mini` (over-flagging is the safe side for leakage).
struct LabelTerms {
    enum Kind: Sendable { case modelID, displayName, organization, provider }

    enum Relation: String, CaseIterable, Sendable {
        /// The sample's own model ID or display name.
        case ownLabel = "own_label_term"
        /// The sample's own organization or provider.
        case ownOrganization = "own_organization_term"
        /// A term that belongs only to other models.
        case otherModel = "other_model_term"
    }

    /// Lowercased term → model ID → how the term names that model.
    private let terms: [String: [String: Set<Kind>]]
    private let ordered: [String]

    var count: Int { ordered.count }

    init(claims: [ModelClaim], minimumLength: Int) {
        var terms: [String: [String: Set<Kind>]] = [:]
        func add(_ text: String?, _ model: String, _ kind: Kind) {
            guard let text else { return }
            let term = DatasetText.normalized(text)
            guard term.count >= minimumLength else { return }
            terms[term, default: [:]][model, default: []].insert(kind)
        }
        for claim in claims {
            add(claim.modelID, claim.modelID, .modelID)
            add(claim.displayName, claim.modelID, .displayName)
            add(claim.organization, claim.modelID, .organization)
            add(claim.provider, claim.modelID, .provider)
        }
        self.terms = terms
        ordered = terms.keys.sorted()
    }

    /// Relations of every term found in any string of `value`, searched recursively through
    /// dictionaries and arrays (v2 §12: scan the feature object, not just its top level).
    func findings(in value: Any, label: String) -> Set<Relation> {
        var found = Set<Relation>()
        Self.visitStrings(value) { string in
            let normalized = DatasetText.normalized(string)
            for term in ordered where Self.contains(normalized, term) {
                let models = terms[term] ?? [:]
                if let own = models[label] {
                    found.insert(own.contains(.modelID) || own.contains(.displayName) ? .ownLabel : .ownOrganization)
                } else if !models.isEmpty {
                    found.insert(.otherModel)
                }
            }
        }
        return found
    }

    static func visitStrings(_ value: Any, _ body: (String) -> Void) {
        if let string = value as? String {
            body(string)
        } else if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() { visitStrings(dictionary[key]!, body) }
        } else if let array = value as? [Any] {
            for element in array { visitStrings(element, body) }
        }
    }

    /// Word-bounded literal search; both arguments are already in normalized form.
    static func contains(_ haystack: String, _ term: String) -> Bool {
        var start = haystack.startIndex
        while start < haystack.endIndex, let found = haystack.range(of: term, options: .literal, range: start..<haystack.endIndex) {
            let before = found.lowerBound == haystack.startIndex || !isWord(haystack[haystack.index(before: found.lowerBound)])
            let after = found.upperBound == haystack.endIndex || !isWord(haystack[found.upperBound])
            if before && after { return true }
            start = haystack.index(after: found.lowerBound)
        }
        return false
    }

    private static func isWord(_ character: Character) -> Bool { character.isLetter || character.isNumber }

    /// Keys outside the allowlist and values that are not text or null. Must be empty for every sample.
    static func structuralViolations(_ features: [String: Any], allowlist: Set<String>) -> [String] {
        var problems: [String] = []
        for key in features.keys.sorted() {
            if !allowlist.contains(key) { problems.append("feature \(key) is not in the allowlist") }
            if !(features[key] is String || features[key] is NSNull) { problems.append("feature \(key) is not text") }
        }
        return problems
    }
}
