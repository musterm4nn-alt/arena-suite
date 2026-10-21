import Foundation

/// The `/agent/{id}` page of an `agentic` conversation (ledger N-022, Docs/agent-detail-2026-10-21.md).
/// Arena serves it as HTML whose Next.js flight chunks (`self.__next_f.push([1,"…"])`, each a JS string
/// literal) hold one object with the transcript: `messages`, `pagination`, `transcriptReadStrategy`,
/// `triggerAddress` (observed equal to the conversation ID) and a `session` with a `publicAccessToken`.
enum AgentPage {
    static let template = "/agent/{id}"
    /// Replaces each JWT-shaped string in the journaled page (plan v3 §5 invariant 7).
    static let omitted = Data("[omitted]".utf8)

    static func request(id: String) -> URLRequest? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".utf8)
        guard !id.isEmpty, id.utf8.count <= 256, id.utf8.allSatisfy({ allowed.contains($0) }),
            let url = URL(string: ArenaRoutes.origin.absoluteString + "/agent/" + id)
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    // MARK: Tokens

    /// The page with every JWT-shaped string (`eyJ…` then two more dot-separated base64url segments,
    /// each at least 8 bytes) replaced by `[omitted]`, and how many were replaced. Byte-level, so all
    /// other bytes stay exact, whatever their encoding. N-022 observed one: `session.publicAccessToken`.
    static func withoutTokens(_ body: Data) -> (body: Data, omitted: Int) {
        let bytes = [UInt8](body)
        var out = Data(capacity: bytes.count)
        var count = 0
        var index = 0
        while index < bytes.count {
            if let end = tokenEnd(bytes, from: index), index == 0 || !isBase64URL(bytes[index - 1]) {
                out.append(omitted)
                count += 1
                index = end
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return (out, count)
    }

    private static func isBase64URL(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x2D || byte == 0x5F
    }

    /// The index just past a JWT-shaped string starting at `start`, or nil.
    private static func tokenEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        guard start + 3 <= bytes.count, bytes[start] == 0x65, bytes[start + 1] == 0x79, bytes[start + 2] == 0x4A else {
            return nil
        }
        var index = start
        for segment in 0..<3 {
            let begin = index
            while index < bytes.count, isBase64URL(bytes[index]) { index += 1 }
            guard index - begin >= 8 else { return nil }
            if segment < 2 {
                guard index < bytes.count, bytes[index] == 0x2E else { return nil }
                index += 1
            }
        }
        return index
    }

    // MARK: Transcript

    /// The flight data: every chunk's string literal decoded and joined in page order. nil when the
    /// page has no chunks or one doesn't decode (the page is then not recognized, never half-read).
    static func flight(_ body: Data) -> String? {
        guard let html = String(data: body, encoding: .utf8) else { return nil }
        let chunk = /self\.__next_f\.push\(\[1,"((?:\\.|[^"\\])*)"\]\)/
        var flight = ""
        var found = false
        for match in html.matches(of: chunk) {
            found = true
            guard let text = try? JSONDecoder().decode(String.self, from: Data(("\"" + match.output.1 + "\"").utf8)) else {
                return nil
            }
            flight += text
        }
        return found ? flight : nil
    }

    /// The transcript object: the first object in the flight rows (`<hex id>:<JSON>`) with a
    /// `messages` array and a `transcriptReadStrategy` key. Rows that aren't JSON are skipped.
    static func transcript(_ body: Data) -> [String: Any]? {
        guard let flight = flight(body) else { return nil }
        for line in flight.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].allSatisfy(\.isHexDigit),
                line[line.index(after: colon)...].first.map({ $0 == "{" || $0 == "[" }) == true,
                let json = try? JSONSerialization.jsonObject(with: Data(line[line.index(after: colon)...].utf8))
            else { continue }
            if let found = find(in: json) { return found }
        }
        return nil
    }

    private static func find(in value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            if object["messages"] is [Any], object["transcriptReadStrategy"] != nil { return object }
            for child in object.values { if let found = find(in: child) { return found } }
        } else if let items = value as? [Any] {
            for child in items { if let found = find(in: child) { return found } }
        }
        return nil
    }

    /// Every agent page is HTML, so HTML alone says nothing; the markers of Cloudflare's interstitial
    /// do. Ordinary pages load a `challenge-platform` script too (N-022), so that name is no sign.
    /// Assumption: an unrecognized page without these markers is drift, warned about, not a block.
    static func looksLikeChallenge(_ body: Data) -> Bool {
        let markers = ["cf-chl", "cf_chl", "Just a moment..."].map { Data($0.utf8) }
        return markers.contains { body.range(of: $0) != nil }
    }

    /// A page counts as this conversation's snapshot only if its transcript names the conversation
    /// (`triggerAddress`, N-022) and has a `messages` array.
    static func isValid(_ body: Data, id: String) -> Bool {
        guard let transcript = transcript(body) else { return false }
        return transcript["triggerAddress"] as? String == id
    }
}
