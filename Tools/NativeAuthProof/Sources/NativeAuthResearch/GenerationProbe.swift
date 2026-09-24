import Foundation

/// Exact bytes remain in process memory for optional local inspection, not a durable archive.
public struct GenerationObservation: Sendable {
    public let preparedBody: Data
    public let response: HTTPReply
}

enum GenerationRecipe {
    static let prompt = "Reply with exactly this text and nothing else: Arena Suite feasibility check."

    /// One observed mode/model combination from C-001. No automatic model selection/fallback.
    static func request(at date: Date = Date()) throws -> URLRequest {
        let body: [String: Any] = [
            "id": try uuidV7(at: date),
            "mode": "direct-battle",
            "modelAId": "019b24bb-5caf-71c3-b854-37d0c7086f21",
            "userMessageId": try uuidV7(at: date),
            "modelAMessageId": try uuidV7(at: date),
            "userMessage": ["content": prompt, "experimental_attachments": [], "metadata": [:]] as [String: Any],
            "modality": "chat",
            // S-002 explicitly attempts null when normal token acquisition fails.
            // No browser token, browser automation, CAPTCHA solving or escalation is used here.
            "recaptchaV3Token": NSNull(),
        ]
        var request = URLRequest(url: URL(string: "https://arena.ai/nextjs-api/stream/create-evaluation")!)
        request.httpMethod = "POST"
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// RFC 9562 layout. This is a local request-ID choice supported by inspected client source,
    /// not an assertion that remote identifiers universally have UUID syntax.
    static func uuidV7(at date: Date, randomness: UUID = UUID()) throws -> String {
        let milliseconds = floor(date.timeIntervalSince1970 * 1000)
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < 281_474_976_710_656 else {
            throw ResearchFailure.invalidLocalClock
        }
        let timestamp = UInt64(milliseconds)
        var tuple = randomness.uuid
        var bytes = withUnsafeBytes(of: &tuple) { Array($0) }
        for index in 0..<6 { bytes[index] = UInt8(truncatingIfNeeded: timestamp >> (8 * (5 - index))) }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let positions = [8, 12, 16, 20]
        return hex.enumerated().map { (positions.contains($0.offset) ? "-" : "") + String($0.element) }.joined()
    }
}
