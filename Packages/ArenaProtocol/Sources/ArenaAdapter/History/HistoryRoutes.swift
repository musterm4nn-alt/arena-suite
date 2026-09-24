import Foundation

/// Observed history recipes (N-005, N-007, N-008; ledger H-001/H-002, R-001). Nothing guessed.
enum HistoryRoutes {
    static let listTemplate = "/api/history/unified"
    static let detailTemplate = "/api/evaluation/{id}"
    /// Observed page sizes: 5 and 20. v1 uses 20.
    static let pageLimit = 20

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// `includeArchived=true` (N-008) so archived conversations are kept too. `cursor` is the exact
    /// `pagination.cursor` string from the previous page, percent-encoded as an opaque value.
    static func list(cursor: String?) -> URLRequest? {
        var query = "limit=\(pageLimit)&includeArchived=true"
        if let cursor {
            guard !cursor.isEmpty, cursor.utf8.count <= 4096,
                let encoded = cursor.addingPercentEncoding(withAllowedCharacters: unreserved)
            else { return nil }
            query += "&cursor=" + encoded
        }
        guard let url = URL(string: ArenaRoutes.origin.absoluteString + listTemplate + "?" + query) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    /// Only for `evaluation` entries (the only type with an observed detail route) and only for
    /// path-safe IDs; anything else is refused rather than escaped into another route.
    static func detail(id: String) -> URLRequest? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".utf8)
        guard !id.isEmpty, id.utf8.count <= 256, id.utf8.allSatisfy({ allowed.contains($0) }),
            let url = URL(string: ArenaRoutes.origin.absoluteString + "/api/evaluation/" + id)
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
}

struct ListEntry: Equatable, Sendable {
    let id: String
    let type: String
    /// Server-supplied string, compared verbatim (never parsed or reinterpreted).
    let updatedAt: String?
}

struct ListPage: Equatable, Sendable {
    let entries: [ListEntry]
    let hasMore: Bool?
    let cursor: String?
    let partial: Bool?
    let failedSources: Int

    /// Lenient structural decode. Unknown fields stay only in the journal's raw bytes.
    static func decode(_ data: Data) -> ListPage? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let rawEntries = object["entries"] as? [[String: Any]]
        else { return nil }
        let entries = rawEntries.compactMap { entry -> ListEntry? in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            return ListEntry(id: id, type: entry["type"] as? String ?? "[absent]", updatedAt: entry["updatedAt"] as? String)
        }
        guard entries.count == rawEntries.count else { return nil }
        let pagination = object["pagination"] as? [String: Any]
        return ListPage(
            entries: entries, hasMore: pagination?["hasMore"] as? Bool, cursor: pagination?["cursor"] as? String,
            partial: object["partial"] as? Bool, failedSources: (object["failedSources"] as? [Any])?.count ?? 0)
    }
}

enum DetailCheck {
    /// A detail snapshot counts only if its body decodes and names the requested conversation.
    static func isValid(_ data: Data, id: String) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return object["id"] as? String == id && object["messages"] is [Any]
    }
}
