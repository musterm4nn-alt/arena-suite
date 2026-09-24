import Foundation

/// One bounded list/detail pair. Private bytes remain in memory before structural interpretation.
public struct HistoryDetailObservation: Sendable {
    public let list: HTTPReply
    public let detail: HTTPReply?
    let requestedID: String?

    public var summary: String {
        guard let detail else {
            return "Detail not requested. " + HistoryObservation(response: list).summary
                + " No safely addressable evaluation entry was selected."
        }
        let prefix =
            HistoryObservation(response: list).summary + " "
            + "Detail HTTP \(detail.status.map(String.init) ?? "unavailable") · transport \(detail.transferEnd.rawValue) · \(detail.body.count) bytes."
        guard detail.status == 200, detail.transferEnd == .complete,
            let decoded = try? JSONDecoder().decode(Detail.self, from: detail.body)
        else { return prefix + " Detail structure unverified; captured bytes retained and may be incomplete." }
        let ids = Set(decoded.messages.map(\.id))
        let match = decoded.id == requestedID
        let sessionsMatch = decoded.messages.allSatisfy { $0.evaluationSessionId == decoded.id }
        let outsideParents = decoded.messages.flatMap(\.parentMessageIds).filter { !ids.contains($0) }.count
        let outsideLast = decoded.lastMessageIds.filter { !ids.contains($0) }.count
        return prefix
            + " ID matches selected list entry: \(match); message session IDs match: \(sessionsMatch); messages: \(decoded.messages.count); duplicate message IDs: \(decoded.messages.count - ids.count); parent references outside response: \(outsideParents); last-message references outside response: \(outsideLast). No continuation attempted."
    }

    private struct Detail: Decodable {
        struct Message: Decodable {
            let id: String
            let evaluationSessionId: String
            let parentMessageIds: [String]
        }
        let id: String
        let messages: [Message]
        let lastMessageIds: [String]
    }
}

enum HistoryDetailRecipe {
    /// Supports the path-safe opaque IDs actually observed. Other representations are unverified,
    /// not normalized, truncated, or reinterpreted as a different route.
    static func request(for id: String) -> URLRequest? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".utf8)
        guard !id.isEmpty, id.utf8.count <= 256, id.utf8.allSatisfy({ allowed.contains($0) }) else { return nil }
        // H-002: observed official GET route, selected only from an identity-checked native list.
        var request = URLRequest(url: URL(string: "https://arena.ai/api/evaluation/" + id)!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
}
