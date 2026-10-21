import CryptoKit
import Foundation

// Agent detail observation (gap analysis item 1). Disposable research code.
// The report holds counts, key names, statuses and booleans only: never IDs, titles, message text
// or cursor values. The page bytes go to a private local candidate file (DerivedData, git-ignored)
// for offline structure work; they never enter Git or chat.
//
// Leads, not evidence: arena-exporter's backfill reads `GET /agent/{id}` (HTML with Next.js flight
// chunks `self.__next_f.push([1,"…"])`) and looks for an object starting `{"messages":[` whose
// messages carry `parts` or `role`. It falls back to that page when `/api/evaluation/{id}` is 404.

public struct AgentDetailReport: Sendable, Encodable {
    public struct ListEntry: Sendable, Encodable {
        public let pagesRead: Int
        public let agenticEntriesSeen: Int
        public let selectedEntryKeys: [String]
    }
    public struct Response: Sendable, Encodable {
        public let status: Int?
        public let transfer: String
        public let bytes: Int
        public let contentType: String?
        public let jsonTopLevelKeys: [String]?
    }
    public struct Page: Sendable, Encodable, Equatable {
        public var flightChunks = 0
        public var flightChunksUndecodable = 0
        public var flightBytes = 0
        public var messageObjectsFound = 0
        public var transcriptKeys: [String] = []
        public var messages = 0
        public var messageKeys: [String] = []
        public var roleCounts: [String: Int] = [:]
        public var partTypeCounts: [String: Int] = [:]
        public var partKeysByType: [String: [String]] = [:]
        /// `/api/…` paths named in the page, with opaque IDs replaced by `{id}`.
        public var apiPaths: [String] = []
        /// Other route families named in the page that the leads mention.
        public var mentionsWorkspace = false
        public var mentionsRealtimeSession = false
    }

    public var schema = "agent-detail-report/1"
    public var startedAt: String
    public var finishedAt: String?
    public var identityVerified = false
    public var list: ListEntry?
    public var evaluationRoute: Response?
    public var agentRoute: Response?
    public var page: Page?
    public var candidateFile: String?
    public var candidateSHA256: String?
    public var requestsSent = 0
    public var stoppedEarly: String?
}

public enum AgentPageInspector {
    /// Structure of an agent page: flight chunks, the first transcript-like object, and named routes.
    public static func inspect(_ html: Data) -> AgentDetailReport.Page {
        var page = AgentDetailReport.Page()
        let text = String(decoding: html, as: UTF8.self)
        var flight = ""
        let chunk = /self\.__next_f\.push\(\[1,"((?:\\.|[^"\\])*)"\]\)/
        for match in text.matches(of: chunk) {
            page.flightChunks += 1
            let literal = "\"" + String(match.output.1) + "\""
            if let decoded = try? JSONDecoder().decode(String.self, from: Data(literal.utf8)) {
                flight += decoded
            } else {
                page.flightChunksUndecodable += 1
            }
        }
        page.flightBytes = flight.utf8.count
        let search = flight.isEmpty ? text : flight
        page.apiPaths = apiPaths(in: text + "\n" + flight)
        page.mentionsWorkspace = search.contains("workspace/latest") || text.contains("workspace/latest")
        page.mentionsRealtimeSession = search.contains("realtime/v1/sessions") || text.contains("realtime/v1/sessions")

        var index = search.startIndex
        while let start = search.range(of: "{\"messages\":[", range: index..<search.endIndex)?.lowerBound {
            guard let object = balancedObject(in: search, from: start) else { break }
            if let parsed = (try? JSONSerialization.jsonObject(with: Data(object.utf8))) as? [String: Any],
                let messages = parsed["messages"] as? [[String: Any]],
                messages.contains(where: { $0["parts"] is [Any] || $0["role"] != nil })
            {
                page.messageObjectsFound += 1
                if page.messageObjectsFound == 1 { describe(parsed, messages, into: &page) }
            }
            index = search.index(after: start)
        }
        return page
    }

    private static func describe(_ object: [String: Any], _ messages: [[String: Any]], into page: inout AgentDetailReport.Page) {
        page.transcriptKeys = object.keys.sorted()
        page.messages = messages.count
        page.messageKeys = Array(Set(messages.flatMap(\.keys))).sorted()
        for message in messages {
            page.roleCounts[(message["role"] as? String) ?? "[absent]", default: 0] += 1
            for part in message["parts"] as? [[String: Any]] ?? [] {
                let type = (part["type"] as? String) ?? "[absent]"
                page.partTypeCounts[type, default: 0] += 1
                page.partKeysByType[type] = Array(Set((page.partKeysByType[type] ?? []) + part.keys)).sorted()
            }
        }
    }

    /// The JSON object starting at `start`, by brace depth outside strings; nil if it never closes.
    static func balancedObject(in text: String, from start: String.Index) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let c = text[index]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func apiPaths(in text: String) -> [String] {
        let path = /\/api\/[A-Za-z0-9_\-\/{}\[\]:.]+/
        let opaque = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[A-Za-z0-9_\-]{20,}/
        var found = Set<String>()
        for match in text.matches(of: path) {
            found.insert(String(match.output).replacing(opaque, with: "{id}"))
        }
        return found.sorted()
    }
}

public enum AgentDetailRunner {
    static let pageLimit = 20
    static let maximumPages = 8
    static let spacing: Duration = .seconds(1)

    /// One request at a time, 1 s apart: pages of the history until the first `agentic` entry, then
    /// `/api/evaluation/{id}` and `/agent/{id}` for it. Stops on any non-200 list page.
    public static func run(client: NativeAuthClient, candidate: URL) async -> AgentDetailReport {
        var report = AgentDetailReport(startedAt: ISO8601DateFormatter().string(from: Date()))
        defer { report.finishedAt = ISO8601DateFormatter().string(from: Date()) }
        do {
            _ = try await client.recheckIdentity()
            report.requestsSent += 1
            report.identityVerified = true
            var cursor: String?
            var pages = 0
            var seen = 0
            var selected: [String: Any]?
            while pages < maximumPages {
                try await Task.sleep(for: spacing)
                let reply = try await client.historyPage(limit: pageLimit, includeArchived: false, cursor: cursor)
                report.requestsSent += 1
                pages += 1
                let parsed = PageSummary.parse(reply)
                guard parsed.summary.decoded else {
                    report.stoppedEarly = "list page \(pages): HTTP \(reply.status.map(String.init) ?? "none"), not decoded"
                    return report
                }
                let agentic = parsed.entries.filter { $0["type"] as? String == "agentic" }
                seen += agentic.count
                if selected == nil { selected = agentic.first }
                if selected != nil || parsed.summary.hasMore != true { break }
                guard let next = parsed.cursor, next != cursor else { break }
                cursor = next
            }
            report.list = .init(
                pagesRead: pages, agenticEntriesSeen: seen, selectedEntryKeys: selected.map { $0.keys.sorted() } ?? [])
            guard let id = selected?["id"] as? String else {
                report.stoppedEarly = "no agentic entry in \(pages) page(s)"
                return report
            }

            try await Task.sleep(for: spacing)
            let evaluation = try await client.historyDetail(id: id)
            report.requestsSent += 1
            report.evaluationRoute = describe(evaluation)

            try await Task.sleep(for: spacing)
            let agent = try await client.agentPage(id: id)
            report.requestsSent += 1
            report.agentRoute = describe(agent)
            if agent.status == 200, agent.transferEnd == .complete {
                report.page = AgentPageInspector.inspect(agent.body)
                try agent.body.write(to: candidate, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: candidate.path)
                report.candidateFile = candidate.lastPathComponent
                report.candidateSHA256 = SHA256.hash(data: agent.body).map { String(format: "%02x", $0) }.joined()
            }
        } catch {
            report.stoppedEarly = "stopped: " + ((error as? ResearchFailure).map { String(describing: $0) } ?? "transport or local error")
        }
        return report
    }

    static func describe(_ reply: HTTPReply) -> AgentDetailReport.Response {
        let json =
            reply.transferEnd == .complete ? (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] : nil
        return .init(
            status: reply.status, transfer: reply.transferEnd.rawValue, bytes: reply.body.count,
            contentType: reply.contentType, jsonTopLevelKeys: json.map { $0.keys.sorted() })
    }
}
