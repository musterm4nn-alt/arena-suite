import Foundation

/// Private response retained before optional structural inspection. Never log or export this value.
public struct HistoryObservation: Sendable {
    public let response: HTTPReply

    var firstEvaluationID: String? {
        guard response.status == 200, response.transferEnd == .complete,
            let page = try? JSONDecoder().decode(HistoryPage.self, from: response.body)
        else { return nil }
        return page.entries.first(where: { $0.type == "evaluation" })?.id
    }

    public var summary: String {
        let prefix =
            "History HTTP \(response.status.map(String.init) ?? "unavailable") · transport \(response.transferEnd.rawValue) · \(response.body.count) bytes."
        guard response.status == 200, response.transferEnd == .complete,
            let page = try? JSONDecoder().decode(HistoryPage.self, from: response.body)
        else {
            return prefix
                + " List structure unverified; captured response bytes retained in memory and may be incomplete."
        }
        return prefix
            + " Entries: \(page.entries.count); hasMore: \(page.pagination.hasMore); partial: \(page.partial); failed sources: \(page.failedSources.count). No further page requested."
    }
}

private struct HistoryPage: Decodable {
    struct Entry: Decodable {
        let id: String
        let type: String
    }
    struct Pagination: Decodable { let hasMore: Bool }
    let entries: [Entry]
    let pagination: Pagination
    let partial: Bool
    let failedSources: [String]
}
