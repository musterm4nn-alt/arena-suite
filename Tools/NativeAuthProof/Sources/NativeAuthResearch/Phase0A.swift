import CryptoKit
import Foundation
import Security

// Phase 0-A experiments A2–A8 (plan v3 §4). Disposable research code.
// Reports contain counts, shapes, names and booleans only: never IDs, titles, message text,
// cookie values or cursor values. The one exception is the A8 fixture candidate, which is a
// sanitized projection written to a local file for manual review before anything enters Git.

public struct SigningInfo: Sendable, Encodable {
    public let adhoc: Bool
    public let teamIdentifier: String?
    public let cdhashPrefix: String?
    public let bundleVersion: String?

    public static func current() -> SigningInfo {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
            let values = info as? [String: Any]
        else { return SigningInfo(adhoc: true, teamIdentifier: nil, cdhashPrefix: nil, bundleVersion: version) }
        let flags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let cdhash = (values[kSecCodeInfoUnique as String] as? Data).map {
            $0.prefix(6).map { String(format: "%02x", $0) }.joined()
        }
        return SigningInfo(
            adhoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0,
            teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String, cdhashPrefix: cdhash,
            bundleVersion: version)
    }
}

public struct PageSummary: Sendable, Encodable, Equatable {
    public let status: Int?
    public let transfer: String
    public let bytes: Int
    public let decoded: Bool
    public let topLevelKeys: [String]
    public let entries: Int
    public let typeCounts: [String: Int]
    public let modeCounts: [String: Int]
    public let modalityCounts: [String: Int]
    public let paginationKeys: [String]
    public let hasMore: Bool?
    public let cursorPresent: Bool
    public let cursorLength: Int?
    public let partial: Bool?
    public let failedSources: Int?

    struct Parsed {
        let summary: PageSummary
        let ids: [String]
        let cursor: String?
        let entries: [[String: Any]]
    }

    static func parse(_ reply: HTTPReply) -> Parsed {
        let object =
            reply.status == 200 && reply.transferEnd == .complete
            ? (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] : nil
        let entries = object?["entries"] as? [[String: Any]] ?? []
        let pagination = object?["pagination"] as? [String: Any]
        let cursor = pagination?["cursor"] as? String
        func counts(_ key: String) -> [String: Int] {
            entries.reduce(into: [:]) { $0[($1[key] as? String) ?? "[absent]", default: 0] += 1 }
        }
        let summary = PageSummary(
            status: reply.status, transfer: reply.transferEnd.rawValue, bytes: reply.body.count,
            decoded: object != nil, topLevelKeys: object.map { $0.keys.sorted() } ?? [], entries: entries.count,
            typeCounts: counts("type"), modeCounts: counts("mode"), modalityCounts: counts("modality"),
            paginationKeys: pagination.map { $0.keys.sorted() } ?? [], hasMore: pagination?["hasMore"] as? Bool,
            cursorPresent: cursor != nil, cursorLength: cursor?.utf8.count, partial: object?["partial"] as? Bool,
            failedSources: (object?["failedSources"] as? [Any])?.count)
        return Parsed(summary: summary, ids: entries.compactMap { $0["id"] as? String }, cursor: cursor, entries: entries)
    }
}

public struct Phase0AReport: Sendable, Encodable {
    public struct Keychain: Sendable, Encodable {
        public let preflight: KeychainPreflight
        public let preflightStatus: Int32
        public let restored: Bool
        public init(preflight: KeychainPreflight, preflightStatus: Int32, restored: Bool) {
            self.preflight = preflight
            self.preflightStatus = preflightStatus
            self.restored = restored
        }
    }
    public struct Cookies: Sendable, Encodable {
        public let beforeIdentity: [CookieMetadata]
        public let afterIdentity: [CookieMetadata]
        /// Names whose value changed, appeared or disappeared across one identity request.
        public let changedByIdentityRequest: [String]
    }
    public struct Pagination: Sendable, Encodable {
        public let cursorParameterEvidence: String
        public let pageLimit: Int
        public let pages: [PageSummary]
        public let overlapBetweenPages: Int
        public let repeatedCursor: Bool
        public let unionEqualsSinglePageList: Bool?
        public let stoppedBecause: String
    }
    public struct Fixture: Sendable, Encodable {
        public let selected: Bool
        public let detail: PageSummaryLite?
        public let candidateFile: String?
        public let aliasedIdentifiers: Int
        public let replacedStrings: Int
        public let keptSyntheticTexts: Int
        public let sourceSHA256: String?
    }
    public struct PageSummaryLite: Sendable, Encodable {
        public let status: Int?
        public let transfer: String
        public let bytes: Int
    }

    public var schema = "phase0a-report/1"
    public var startedAt: String
    public var finishedAt: String?
    public var signing: SigningInfo
    public var keychain: Keychain
    public var identityVerifiedAtStart = false
    public var identityVerifiedAtEnd = false
    public var cookies: Cookies?
    public var entryTypes: [String: PageSummary] = [:]
    public var pagination: Pagination?
    public var anonymousIdentity: AnonymousIdentityResult?
    public var fixture: Fixture?
    public var requestsSent = 0
    public var stoppedEarly: String?
}

public enum Phase0ARunner {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void
    public static let spacing: Duration = .seconds(1)
    static let pageLimit = 5
    static let maximumPages = 8

    /// Runs A2–A5 and A8 against an already restored or signed-in client, one request at a time.
    public static func run(
        client: NativeAuthClient, keychain: Phase0AReport.Keychain, signing: SigningInfo,
        fixtureCandidate: URL?, anonymousExecutor: any HTTPExecuting = NativeHTTPExecutor(),
        sleep: Sleeper = { try await Task.sleep(for: $0) }
    ) async -> Phase0AReport {
        var report = Phase0AReport(startedAt: now(), signing: signing, keychain: keychain)
        func stop(_ reason: String) -> Phase0AReport {
            report.stoppedEarly = reason
            report.finishedAt = now()
            return report
        }

        // A4: cookie names/lifetimes around one identity request.
        let before = (try? await client.cookieMetadata()) ?? []
        report.requestsSent += 1
        do { _ = try await client.recheckIdentity() } catch { return stop("identity verification failed at start") }
        report.identityVerifiedAtStart = true
        let after = (try? await client.cookieMetadata()) ?? []
        report.cookies = Phase0AReport.Cookies(
            beforeIdentity: before, afterIdentity: after, changedByIdentityRequest: changedCookies(before, after))

        // A3: entry types, without and with archived entries.
        var fullList: PageSummary.Parsed?
        for includeArchived in [false, true] {
            try? await sleep(spacing)
            report.requestsSent += 1
            guard let reply = try? await client.historyPage(limit: 20, includeArchived: includeArchived, cursor: nil)
            else { return stop("list request failed (includeArchived=\(includeArchived))") }
            let parsed = PageSummary.parse(reply)
            report.entryTypes["includeArchived=\(includeArchived)"] = parsed.summary
            if reply.status != 200 { return stop("list returned HTTP \(reply.status.map(String.init) ?? "none")") }
            if !includeArchived { fullList = parsed }
        }

        // A2: cursor pagination with a small page.
        var pages: [PageSummary] = []
        var seen = Set<String>()
        var overlap = 0
        var cursors = Set<String>()
        var repeated = false
        var cursor: String?
        var stoppedBecause = "page limit reached"
        for _ in 0..<maximumPages {
            try? await sleep(spacing)
            report.requestsSent += 1
            guard let reply = try? await client.historyPage(limit: pageLimit, includeArchived: false, cursor: cursor)
            else {
                stoppedBecause = "transport failure"
                break
            }
            let parsed = PageSummary.parse(reply)
            pages.append(parsed.summary)
            overlap += parsed.ids.filter { seen.contains($0) }.count
            seen.formUnion(parsed.ids)
            guard reply.status == 200, parsed.summary.decoded else {
                stoppedBecause = "HTTP \(reply.status.map(String.init) ?? "none") or undecodable page"
                break
            }
            guard parsed.summary.hasMore == true else {
                stoppedBecause = "hasMore=false"
                break
            }
            guard let next = parsed.cursor else {
                stoppedBecause = "hasMore=true without cursor"
                break
            }
            if cursors.contains(next) {
                repeated = true
                stoppedBecause = "repeated cursor"
                break
            }
            cursors.insert(next)
            cursor = next
        }
        let singlePageComplete = fullList.map { $0.summary.hasMore == false } ?? false
        report.pagination = Phase0AReport.Pagination(
            cursorParameterEvidence:
                "repository_evidence R-001: arena-exporter history-backfill.js sends cursor=<pagination.cursor>",
            pageLimit: pageLimit, pages: pages, overlapBetweenPages: overlap, repeatedCursor: repeated,
            unionEqualsSinglePageList: singlePageComplete ? Set(fullList?.ids ?? []) == seen : nil,
            stoppedBecause: stoppedBecause)

        // A5: identity request with an empty cookie jar.
        try? await sleep(spacing)
        report.requestsSent += 1
        report.anonymousIdentity = await NativeAuthClient.anonymousIdentityProbe(executor: anonymousExecutor)

        // A8: sanitized detail candidate of the synthetic research conversation only.
        report.fixture = await captureFixtureCandidate(
            client: client, list: fullList, destination: fixtureCandidate, report: &report, sleep: sleep)

        try? await sleep(spacing)
        report.requestsSent += 1
        report.identityVerifiedAtEnd = (try? await client.recheckIdentity()) != nil
        report.finishedAt = now()
        return report
    }

    private static func captureFixtureCandidate(
        client: NativeAuthClient, list: PageSummary.Parsed?, destination: URL?, report: inout Phase0AReport,
        sleep: Sleeper
    ) async -> Phase0AReport.Fixture {
        let empty = Phase0AReport.Fixture(
            selected: false, detail: nil, candidateFile: nil, aliasedIdentifiers: 0, replacedStrings: 0,
            keptSyntheticTexts: 0, sourceSHA256: nil)
        guard
            let entry = list?.entries.first(where: {
                ($0["type"] as? String) == "evaluation"
                    && DetailSanitizer.isSyntheticResearchTitle($0["title"] as? String)
            }), let id = entry["id"] as? String
        else { return empty }
        try? await sleep(spacing)
        report.requestsSent += 1
        guard let reply = try? await client.historyDetail(id: id) else { return empty }
        let lite = Phase0AReport.PageSummaryLite(
            status: reply.status, transfer: reply.transferEnd.rawValue, bytes: reply.body.count)
        guard reply.status == 200, reply.transferEnd == .complete,
            let sanitized = DetailSanitizer.sanitize(reply.body)
        else {
            return Phase0AReport.Fixture(
                selected: true, detail: lite, candidateFile: nil, aliasedIdentifiers: 0, replacedStrings: 0,
                keptSyntheticTexts: 0, sourceSHA256: nil)
        }
        var written: String?
        if let destination, (try? sanitized.projection.write(to: destination, options: .atomic)) != nil {
            written = destination.lastPathComponent
        }
        return Phase0AReport.Fixture(
            selected: true, detail: lite, candidateFile: written, aliasedIdentifiers: sanitized.aliased,
            replacedStrings: sanitized.replaced, keptSyntheticTexts: sanitized.kept,
            sourceSHA256: sanitized.sourceSHA256)
    }

    static func changedCookies(_ before: [CookieMetadata], _ after: [CookieMetadata]) -> [String] {
        func key(_ cookie: CookieMetadata) -> String { "\(cookie.name)|\(cookie.domain)|\(cookie.path)" }
        let old = Dictionary(before.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(after.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        return Set(old.keys).union(new.keys).filter {
            old[$0]?.valueDigest != new[$0]?.valueDigest || old[$0]?.expires != new[$0]?.expires
        }.compactMap { (old[$0] ?? new[$0])?.name }.sorted()
    }

    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }
}

// MARK: - A7 two-account isolation in one process

public struct IsolationReport: Sendable, Encodable {
    public var schema = "phase0a-isolation/1"
    public var startedAt: String
    public var finishedAt: String?
    public var signing: SigningInfo
    public var restoredA = false
    public var restoredB = false
    public var principalsDiffer: Bool?
    public var identityStableA = false
    public var identityStableB = false
    public var entriesA: Int?
    public var entriesB: Int?
    public var overlappingEntryIDs: Int?
    public var cookieNamesA: [String] = []
    public var cookieNamesB: [String] = []
    /// Cookies with the same name/domain/path and the same value in both jars (must be 0).
    public var sharedCookieValues: Int?
    public var stoppedEarly: String?
}

public enum IsolationRunner {
    /// Both clients must already be restored (identity verified against each slot's saved IDs).
    public static func run(
        a: NativeAuthClient, identityA: ObservedIdentity, b: NativeAuthClient, identityB: ObservedIdentity,
        signing: SigningInfo, sleep: Phase0ARunner.Sleeper = { try await Task.sleep(for: $0) }
    ) async -> IsolationReport {
        var report = IsolationReport(startedAt: Phase0ARunner.now(), signing: signing)
        report.restoredA = true
        report.restoredB = true
        report.principalsDiffer = identityA.id != identityB.id && identityA.supabaseUserID != identityB.supabaseUserID

        // One request in flight per account; the two accounts run concurrently.
        async let listA = try? a.historyPage(limit: 20, includeArchived: false, cursor: nil)
        async let listB = try? b.historyPage(limit: 20, includeArchived: false, cursor: nil)
        let (replyA, replyB) = await (listA, listB)
        guard let replyA, let replyB else {
            report.stoppedEarly = "list request failed"
            report.finishedAt = Phase0ARunner.now()
            return report
        }
        let parsedA = PageSummary.parse(replyA)
        let parsedB = PageSummary.parse(replyB)
        report.entriesA = parsedA.summary.entries
        report.entriesB = parsedB.summary.entries
        report.overlappingEntryIDs = Set(parsedA.ids).intersection(parsedB.ids).count

        try? await sleep(Phase0ARunner.spacing)
        async let checkA = try? a.recheckIdentity()
        async let checkB = try? b.recheckIdentity()
        let (stableA, stableB) = await (checkA, checkB)
        report.identityStableA = stableA == identityA
        report.identityStableB = stableB == identityB

        let cookiesA = (try? await a.cookieMetadata()) ?? []
        let cookiesB = (try? await b.cookieMetadata()) ?? []
        report.cookieNamesA = cookiesA.map(\.name)
        report.cookieNamesB = cookiesB.map(\.name)
        let valuesA = Set(cookiesA.map { "\($0.name)|\($0.domain)|\($0.path)|\($0.valueDigest)" })
        report.sharedCookieValues = cookiesB.filter {
            valuesA.contains("\($0.name)|\($0.domain)|\($0.path)|\($0.valueDigest)")
        }.count
        report.finishedAt = Phase0ARunner.now()
        return report
    }
}

// MARK: - A8 sanitizer

enum DetailSanitizer {
    /// The only free text allowed through: the synthetic prompts/answers from C-001/C-002.
    static let syntheticTexts: Set<String> = [
        "Reply with exactly this text and nothing else: Arena Suite feasibility check.",
        "Reply with exactly this text and nothing else: Arena Suite continuation check.",
        "Arena Suite feasibility check.",
        "Arena Suite continuation check.",
    ]
    /// Short enumeration-like values kept under these keys.
    static let enumerationKeys: Set<String> = ["role", "status", "mode", "visibility", "modality", "type", "finishReason"]

    static func isSyntheticResearchTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        return syntheticTexts.contains(title) || title.hasPrefix("Reply with exactly this text and nothing else: Arena Suite")
    }

    struct Result {
        let projection: Data
        let aliased: Int
        let replaced: Int
        let kept: Int
        let sourceSHA256: String
    }

    static func sanitize(_ body: Data) -> Result? {
        guard let root = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else { return nil }
        var aliases: [String: String] = [:]
        var replaced = 0
        var kept = 0
        let uuid = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
        let timestamp = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
        let enumeration = /^[A-Za-z0-9_.\-]{1,48}$/

        func alias(_ value: String) -> String {
            if let existing = aliases[value] { return existing }
            let name = "id-\(aliases.count + 1)"
            aliases[value] = name
            return name
        }
        func string(_ value: String, key: String?) -> String {
            if syntheticTexts.contains(value) {
                kept += 1
                return value
            }
            if value.wholeMatch(of: uuid) != nil { return alias(value) }
            if let key, enumerationKeys.contains(key), value.wholeMatch(of: enumeration) != nil { return value }
            replaced += 1
            // Lengths are withheld too: under `metadata` they narrow e.g. the email domain or location.
            if value.prefixMatch(of: timestamp) != nil { return "[timestamp]" }
            return "[string]"
        }
        // Message `metadata` carries per-user anti-abuse telemetry (bot/reCAPTCHA scores, JA4
        // fingerprint ratios, activity counts, account age). Inside it, numbers and booleans are
        // replaced by type markers too; only structure survives.
        func walk(_ value: Any, key: String?, inMetadata: Bool) -> Any {
            switch value {
            case let object as [String: Any]:
                var out: [String: Any] = [:]
                for (childKey, child) in object {
                    let safeKey = childKey.wholeMatch(of: uuid) != nil ? alias(childKey) : childKey
                    out[safeKey] = walk(child, key: childKey, inMetadata: inMetadata || childKey == "metadata")
                }
                return out
            case let array as [Any]: return array.map { walk($0, key: key, inMetadata: inMetadata) }
            case let text as String: return string(text, key: key)
            case is NSNull: return value
            case let number as NSNumber where inMetadata:
                replaced += 1
                return CFGetTypeID(number) == CFBooleanGetTypeID() ? "[bool]" : "[number]"
            default: return value  // numbers and booleans outside metadata
            }
        }
        let projected = walk(root, key: nil, inMetadata: false)
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: projected, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return Result(projection: data, aliased: aliases.count, replaced: replaced, kept: kept, sourceSHA256: digest)
    }
}
