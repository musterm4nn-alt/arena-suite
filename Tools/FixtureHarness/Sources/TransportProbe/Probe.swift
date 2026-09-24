import Darwin
import Foundation
import FoundationTransport
import NativeAuthResearch

struct Unit: Sendable {
    let offset: Int
    let ticks: UInt64
    let bytes: Data
}

struct Observation: Sendable {
    let units: [Unit]
    let response: HTTPURLResponse
    let redirects: Int
    var bytes: Data { units.reduce(into: Data()) { $0.append($1.bytes) } }
}

/// Test-only single-request collector. Lock protects delegate state; completion transfers a value snapshot.
/// No production capture/durability guarantee; bounded synthetic input only.
final class Collector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var units: [Unit] = []
    private var offset = 0
    private var redirects = 0
    private var completion: (@Sendable (Result<Observation, any Error>) -> Void)?

    func install(_ completion: @escaping @Sendable (Result<Observation, any Error>) -> Void) {
        lock.withLock { self.completion = completion }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let ticks = mach_continuous_time()
        lock.withLock {
            units.append(Unit(offset: offset, ticks: ticks, bytes: data))
            offset += data.count
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        lock.withLock { redirects += 1 }
        // Phase 0 test policy: refuse ALL redirects. Never forward synthetic credentials.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (callback, result) = lock.withLock {
            () -> (
                (@Sendable (Result<Observation, any Error>) -> Void)?, Result<Observation, any Error>
            ) in
            let callback = completion
            completion = nil
            if let error { return (callback, .failure(error)) }
            guard let response = task.response as? HTTPURLResponse else {
                return (callback, .failure(URLError(.badServerResponse)))
            }
            return (callback, .success(Observation(units: units, response: response, redirects: redirects)))
        }
        callback?(result)
    }
}

func configuration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.urlCredentialStorage = nil
    config.connectionProxyDictionary = [:]
    config.timeoutIntervalForRequest = 5
    config.timeoutIntervalForResource = 10
    return config
}

func observe(_ url: URL, headers: [String: String] = [:]) async throws -> Observation {
    let collector = Collector()
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    let session = URLSession(configuration: configuration(), delegate: collector, delegateQueue: queue)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.allHTTPHeaderFields = headers
    return try await withCheckedThrowingContinuation { continuation in
        collector.install { continuation.resume(with: $0) }
        session.dataTask(with: request).resume()
    }
}

enum ProbeFailure: Error { case assertion(String) }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ProbeFailure.assertion(message) }
}

@main struct Probe {
    static func main() async throws {
        guard CommandLine.arguments.count == 2,
            let port = UInt16(CommandLine.arguments[1]), port > 0
        else {
            throw ProbeFailure.assertion("Expected local fixture port")
        }
        // No arbitrary-host input: this research executable can only address the local synthetic server.
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let expected = Data("data: café\r\n\r\n: synthetic\n\ndata: tail".utf8)
        for path in ["fragmented", "gzip", "trailers"] {
            let result = try await observe(base.appendingPathComponent(path))
            try require(result.bytes == expected, "Delivered entity byte mismatch: \(path)")
            var offset = 0
            var ticks: UInt64 = 0
            for unit in result.units {
                try require(unit.offset == offset && unit.ticks >= ticks, "Callback mapping invalid")
                offset += unit.bytes.count
                ticks = unit.ticks
            }
            print("\(path): entity bytes match; callback units=\(result.units.count)")
            if path == "trailers" {
                print("duplicate header: \(result.response.value(forHTTPHeaderField: "X-Probe") ?? "absent")")
                print("trailer exposed: \(result.response.value(forHTTPHeaderField: "X-Trailer") != nil)")
            }
        }
        let redirect = try await observe(
            base.appendingPathComponent("redirect"),
            headers: [
                "Authorization": "synthetic-test-only", "Cookie": "probe=synthetic-test-only",
                "X-Probe-CSRF": "synthetic-test-only",
            ])
        try require(redirect.response.statusCode == 302 && redirect.redirects == 1, "Redirect not refused")

        let a = configuration()
        let b = configuration()
        try require(a.httpCookieStorage != nil && b.httpCookieStorage != nil, "Missing private jars")
        try require(a.httpCookieStorage !== b.httpCookieStorage, "Shared account jars")
        try require(a.httpCookieStorage !== HTTPCookieStorage.shared, "Global jar used")
        let sa = URLSession(configuration: a)
        let sb = URLSession(configuration: b)
        defer {
            sa.invalidateAndCancel()
            sb.invalidateAndCancel()
        }
        _ = try await sa.data(from: base.appendingPathComponent("set-a"))
        _ = try await sb.data(from: base.appendingPathComponent("set-b"))
        async let ar = sa.data(from: base.appendingPathComponent("cookies"))
        async let br = sb.data(from: base.appendingPathComponent("cookies"))
        let (av, bv) = try await (ar, br)
        try require(String(decoding: av.0, as: UTF8.self) == "probe=A", "Account A contaminated")
        try require(String(decoding: bv.0, as: UTF8.self) == "probe=B", "Account B contaminated")
        let sc = URLSession(configuration: configuration())
        defer { sc.invalidateAndCancel() }
        let fresh = try await sc.data(from: base.appendingPathComponent("cookies"))
        try require(fresh.0.isEmpty, "Fresh session inherited cookies")
        print("cookie isolation: two simultaneous jars and fresh session passed")

        // Exercise the actual disposable native-auth executor, not just this probe's collector.
        let nativeA = NativeHTTPExecutor()
        let nativeB = NativeHTTPExecutor()
        _ = try await nativeA.perform(URLRequest(url: base.appendingPathComponent("set-a")))
        _ = try await nativeB.perform(URLRequest(url: base.appendingPathComponent("set-b")))
        async let nativeAR = nativeA.perform(URLRequest(url: base.appendingPathComponent("cookies")))
        async let nativeBR = nativeB.perform(URLRequest(url: base.appendingPathComponent("cookies")))
        let nativeReplies = try await (nativeAR, nativeBR)
        try require(nativeReplies.0.body == Data("probe=A".utf8), "Native proof A cookie contamination")
        try require(nativeReplies.1.body == Data("probe=B".utf8), "Native proof B cookie contamination")
        var nativeRedirect = URLRequest(url: base.appendingPathComponent("redirect"))
        nativeRedirect.setValue("synthetic-test-only", forHTTPHeaderField: "Authorization")
        let refused = try await nativeA.perform(nativeRedirect)
        try require(refused.status == 302, "Native proof followed a redirect")
        print("native auth executor: isolated cookie sessions and redirect refusal passed")

        let cancelExecutor = NativeHTTPExecutor()
        let transfer = Task {
            try await cancelExecutor.perform(URLRequest(url: base.appendingPathComponent("cancel-prefix")))
        }
        // Synthetic server sends an SSE-typed prefix then holds the connection for four seconds.
        try await Task.sleep(for: .seconds(1))
        let cancellationStart = ContinuousClock.now
        transfer.cancel()
        let canceled = try await transfer.value
        try require(cancellationStart.duration(to: .now) < .seconds(2), "Cancellation did not promptly resume")
        try require(
            canceled.transferEnd == .interrupted && canceled.body == expected, "Cancellation lost delivered prefix")
        let preCanceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cancelExecutor.perform(URLRequest(url: base.appendingPathComponent("cancel-prefix")))
        }
        let preCanceledReply = try await preCanceled.value
        try require(
            preCanceledReply.transferEnd == .interrupted && preCanceledReply.body.isEmpty,
            "Pre-start cancellation failed")
        print("native cancellation: prompt completion, delivered prefix preserved, pre-start cancellation passed")

        let freshNative = NativeHTTPExecutor()
        let freshNativeReply = try await freshNative.perform(URLRequest(url: base.appendingPathComponent("cookies")))
        try require(freshNativeReply.body.isEmpty, "Fresh native executor inherited cookies")
        for status in [307, 308] {
            var request = URLRequest(url: base.appendingPathComponent("redirect-\(status)"))
            request.httpMethod = "POST"
            request.httpBody = Data("synthetic-test-only".utf8)
            request.setValue("synthetic-test-only", forHTTPHeaderField: "Authorization")
            let reply = try await nativeA.perform(request)
            try require(
                reply.status == status && reply.transferEnd == .complete, "Native POST redirect was not refused")
        }
        for path in ["fragmented", "gzip"] {
            let reply = try await nativeA.perform(URLRequest(url: base.appendingPathComponent(path)))
            try require(reply.transferEnd == .complete && reply.body == expected, "Native callback byte mismatch")
            try require(!reply.units.isEmpty, "Native callback observations missing")
            var position = 0
            var lastTick: UInt64 = 0
            var reconstructed = Data()
            for unit in reply.units {
                try require(
                    unit.offset == position && unit.observedLength == unit.bytes.count && unit.ticks >= lastTick,
                    "Native callback mapping mismatch")
                position += unit.bytes.count
                lastTick = unit.ticks
                reconstructed.append(unit.bytes)
            }
            try require(reconstructed == expected, "Native units fail reassembly")
        }
        let truncated = try await nativeA.perform(URLRequest(url: base.appendingPathComponent("truncated")))
        try require(
            truncated.transferEnd == .interrupted && truncated.body == expected,
            "Interrupted native prefix was not preserved: end=\(truncated.transferEnd.rawValue), bytes=\(truncated.body.count), expected=\(expected.count)"
        )
        let limitedNative = NativeHTTPExecutor(maximumBodyBytes: 64)
        let limited = try await limitedNative.perform(URLRequest(url: base.appendingPathComponent("large")))
        try require(
            limited.transferEnd == .captureLimit && limited.body == Data(repeating: 120, count: 64),
            "Native capture limit did not retain exact prefix")
        try require(limited.observedByteCount > limited.body.count, "Native truncation counter missing")
        print(
            "native research capture: callback bytes/offsets/ticks, interrupted prefix, explicit cap, fresh jar and POST 307/308 refusal passed"
        )

        // Production per-account transport (Phase 2): same contract, exercised against real sockets.
        let host: Set<String> = [base.host ?? "127.0.0.1"]
        let accountA = AccountHTTPSession()
        let accountB = AccountHTTPSession()
        _ = try await accountA.perform(URLRequest(url: base.appendingPathComponent("set-a")))
        _ = try await accountB.perform(URLRequest(url: base.appendingPathComponent("set-b")))
        async let accountAR = accountA.perform(URLRequest(url: base.appendingPathComponent("cookies")))
        async let accountBR = accountB.perform(URLRequest(url: base.appendingPathComponent("cookies")))
        let accountReplies = try await (accountAR, accountBR)
        try require(accountReplies.0.body == Data("probe=A".utf8), "Account A cookie contamination")
        try require(accountReplies.1.body == Data("probe=B".utf8), "Account B cookie contamination")
        try require(accountReplies.0.startTicks > 0 && accountReplies.0.endTicks >= accountReplies.0.startTicks, "Ticks missing")
        // Saved cookies restore into a fresh session and nowhere else.
        let restored = AccountHTTPSession()
        try restored.importCookies(try accountA.exportCookies(domains: host), domains: host)
        let restoredReply = try await restored.perform(URLRequest(url: base.appendingPathComponent("cookies")))
        try require(restoredReply.body == Data("probe=A".utf8), "Exported session did not restore")
        try require(
            restored.cookieFingerprint(domains: host) == accountA.cookieFingerprint(domains: host),
            "Fingerprint differs for identical jars")
        let untouched = try await AccountHTTPSession().perform(URLRequest(url: base.appendingPathComponent("cookies")))
        try require(untouched.body.isEmpty, "Fresh account session inherited cookies")
        var accountRedirect = URLRequest(url: base.appendingPathComponent("redirect"))
        accountRedirect.setValue("synthetic-test-only", forHTTPHeaderField: "Authorization")
        try require(try await accountA.perform(accountRedirect).status == 302, "Account session followed a redirect")
        for status in [307, 308] {
            var request = URLRequest(url: base.appendingPathComponent("redirect-\(status)"))
            request.httpMethod = "POST"
            request.httpBody = Data("synthetic-test-only".utf8)
            try require(try await accountA.perform(request).status == status, "Account POST redirect followed")
        }
        let gzipReply = try await accountA.perform(URLRequest(url: base.appendingPathComponent("gzip")))
        try require(gzipReply.transferEnd == .complete && gzipReply.body == expected, "Account gzip body mismatch")
        let accountTruncated = try await accountA.perform(URLRequest(url: base.appendingPathComponent("truncated")))
        try require(
            accountTruncated.transferEnd == .interrupted && accountTruncated.body == expected,
            "Account interrupted prefix not preserved")
        let accountLimited = try await AccountHTTPSession(maximumBodyBytes: 64).perform(
            URLRequest(url: base.appendingPathComponent("large")))
        try require(
            accountLimited.transferEnd == .captureLimit && accountLimited.body == Data(repeating: 120, count: 64)
                && accountLimited.observedByteCount > 64, "Account capture limit not declared")
        let accountCancel = AccountHTTPSession()
        let accountTransfer = Task {
            try await accountCancel.perform(URLRequest(url: base.appendingPathComponent("cancel-prefix")))
        }
        try await Task.sleep(for: .seconds(1))
        let accountCancelStart = ContinuousClock.now
        accountTransfer.cancel()
        let accountCanceled = try await accountTransfer.value
        try require(accountCancelStart.duration(to: .now) < .seconds(2), "Account cancellation not prompt")
        try require(accountCanceled.transferEnd == .interrupted, "Account cancellation not declared")
        print(
            "account transport: isolated jars, export/import restore, redirect refusal, gzip, interrupted prefix, capture limit, cancellation passed"
        )

        let ws = sa.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws")!)
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }
        let first = try await ws.receive()
        let second = try await ws.receive()
        guard case .string(let text) = first, case .data(let binary) = second else {
            throw ProbeFailure.assertion("WebSocket message kinds changed")
        }
        try require(text == "café" && binary == Data([0, 255, 1]), "WebSocket payload mismatch")
        print("websocket: fragmented text plus ping delivered as one string; binary message matches")

        let below = sa.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws-below-limit")!)
        below.maximumMessageSize = 1024
        below.resume()
        defer { below.cancel(with: .normalClosure, reason: nil) }
        let smallMessage = try await below.receive()
        guard case .data(let smallBytes) = smallMessage else {
            throw ProbeFailure.assertion("Below-limit message kind changed")
        }
        try require(smallBytes == Data(repeating: 120, count: 512), "Below-limit fragmented message mismatch")

        let above = sa.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/ws-above-limit")!)
        above.maximumMessageSize = 1024
        above.resume()
        defer { above.cancel(with: .normalClosure, reason: nil) }
        do {
            _ = try await above.receive()
            throw ProbeFailure.assertion("Oversized fragmented message delivered as complete content")
        } catch {
            let failure = error as NSError
            try require(
                failure.domain == NSPOSIXErrorDomain && failure.code == Int(EMSGSIZE),
                "Unexpected limit failure: \(failure.domain)/\(failure.code)"
            )
            print(
                "websocket limit: 512 bytes accepted; 2048 bytes in 64-byte frames rejected at limit 1024; NSPOSIXErrorDomain/EMSGSIZE"
            )
        }
    }
}
