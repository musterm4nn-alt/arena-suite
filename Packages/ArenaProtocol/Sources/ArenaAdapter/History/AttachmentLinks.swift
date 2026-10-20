import Foundation

/// Arena's attachment links (N-019, Docs/attachments-2026-10-20.md): the one rule for which links
/// are downloaded, used by the sync job and by the decoder.
enum AttachmentLink {
    /// The only file host observed (N-019: `messages-prod.<id>.r2.cloudflarestorage.com`).
    static let hostSuffix = ".r2.cloudflarestorage.com"
    /// S3 presigned-URL parameters (N-019). `X-Amz-Expires` is at most 7 days in S3.
    static let maximumLifetime = 7 * 24 * 3600

    struct Parsed: Equatable {
        let url: URL
        /// Scheme, host and path: the link without its signed query.
        let objectKey: String
        /// `X-Amz-Date` + `X-Amz-Expires`, when both are present and valid. Assumption: the link
        /// stops working then (the S3 presigned-URL rule; not observed for R2).
        let expiresAt: Date?
    }

    /// nil for anything but `https` on the observed host, with no user, password or port and a
    /// non-empty path.
    static func parse(_ text: String) -> Parsed? {
        guard let url = URL(string: text), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
            host.hasSuffix(hostSuffix), host.count > hostSuffix.count,
            parts.user == nil, parts.password == nil, parts.port == nil,
            parts.percentEncodedPath.count > 1, parts.percentEncodedPath.hasPrefix("/")
        else { return nil }
        return Parsed(url: url, objectKey: "https://\(host)\(parts.percentEncodedPath)", expiresAt: expiry(parts.queryItems ?? []))
    }

    private static func expiry(_ items: [URLQueryItem]) -> Date? {
        func value(_ name: String) -> String? {
            let matches = items.filter { $0.name == name }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard let signed = value("X-Amz-Date").flatMap(signingTime),
            let text = value("X-Amz-Expires"), text.allSatisfy(\.isASCII), let seconds = Int(text),
            (0...maximumLifetime).contains(seconds)
        else { return nil }
        return signed.addingTimeInterval(TimeInterval(seconds))
    }

    /// `X-Amz-Date`'s basic ISO 8601 form, e.g. `20261020T101500Z`.
    private static func signingTime(_ text: String) -> Date? {
        guard text.utf8.count == 16, text.allSatisfy(\.isASCII) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    /// The end of life as the index stores it: ISO 8601, UTC, whole seconds.
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// An attachment as the decoder numbers it: messages with a non-empty string `id`, first of each
    /// ID only; `ordinal` counts the object elements of its `experimental_attachments`.
    struct Located: Equatable {
        let messageID: String
        let ordinal: Int
        let link: String?
    }

    /// Every attachment of a detail body, in order. Empty for a body that isn't a JSON object.
    static func located(in body: Data) -> [Located] {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
            let messages = object["messages"] as? [Any]
        else { return [] }
        var seen = Set<String>()
        var result: [Located] = []
        for case let message as [String: Any] in messages {
            guard let id = message["id"] as? String, !id.isEmpty, seen.insert(id).inserted else { continue }
            let attachments = (message["experimental_attachments"] as? [Any]) ?? []
            for (ordinal, attachment) in attachments.compactMap({ $0 as? [String: Any] }).enumerated() {
                result.append(Located(messageID: id, ordinal: ordinal, link: attachment["url"] as? String))
            }
        }
        return result
    }
}
