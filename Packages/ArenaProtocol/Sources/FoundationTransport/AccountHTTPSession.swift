import Darwin
import Foundation

/// One HTTP request/response as delivered by Foundation (declared layer: `foundation_decoded_entity`).
public struct HTTPExchange: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum TransferEnd: String, Sendable, Codable {
        case complete, interrupted, captureLimit, nonHTTPResponse
    }

    public let status: Int?
    /// Response header fields as Foundation exposes them (duplicates already merged by Foundation).
    public let headers: [String: String]
    public let body: Data
    /// Bytes received, including any beyond the capture limit.
    public let observedByteCount: Int
    public let transferEnd: TransferEnd
    /// `mach_continuous_time()` just before `resume()` and at completion.
    public let startTicks: UInt64
    public let endTicks: UInt64

    public init(
        status: Int?, headers: [String: String] = [:], body: Data, observedByteCount: Int? = nil,
        transferEnd: TransferEnd = .complete, startTicks: UInt64 = 0, endTicks: UInt64 = 0
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.observedByteCount = observedByteCount ?? body.count
        self.transferEnd = transferEnd
        self.startTicks = startTicks
        self.endTicks = endTicks
    }

    public var contentType: String? {
        headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
    }

    // Bodies and headers can hold private data; never print them by accident.
    public var description: String { "HTTPExchange(status: \(status.map(String.init) ?? "none"), redacted)" }
    public var debugDescription: String { description }
}

/// Transport seam used by the adapter. `AccountHTTPSession` is the production implementation.
public protocol HTTPTransporting: Sendable {
    func perform(_ request: URLRequest) async throws -> HTTPExchange
    /// Serialized cookies for the given domains (exact, lowercase). Credential material: Keychain only.
    func exportCookies(domains: Set<String>) throws -> Data
    /// Loads cookies into an empty jar. Fails if the jar is not empty or a cookie is for another domain.
    func importCookies(_ data: Data, domains: Set<String>) throws
    /// Order-independent digest of the jar's cookies for `domains`, to detect rotation. Never logged.
    func cookieFingerprint(domains: Set<String>) -> String
}

public enum TransportError: Error, Equatable, Sendable {
    case cookieStorageUnavailable
    case cookieJarNotEmpty
    case invalidCookieData
    case foreignCookieDomain
}

/// A per-account HTTP session: its own ephemeral configuration and private cookie jar, no URL cache,
/// no credential storage, redirects refused, bounded in-memory capture, no automatic retries.
public final class AccountHTTPSession: HTTPTransporting {
    private let session: URLSession
    private let delegate: CaptureDelegate

    /// `cookies: false` makes a session with no cookie jar that never sends or accepts a cookie (for
    /// attachment files, Docs/attachments-2026-10-20.md); its cookie methods then throw
    /// `cookieStorageUnavailable`.
    public init(
        maximumBodyBytes: Int = 32 << 20, requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 120,
        cookies: Bool = true
    ) {
        precondition(maximumBodyBytes > 0)
        delegate = CaptureDelegate(maximumBodyBytes: maximumBodyBytes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        if cookies {
            configuration.httpShouldSetCookies = true
            configuration.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        } else {
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
        }
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    deinit { session.invalidateAndCancel() }

    public func perform(_ request: URLRequest) async throws -> HTTPExchange {
        let relay = CancellationRelay()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.register(task, continuation: continuation)
                relay.start(task)
            }
        } onCancel: {
            relay.cancel()
        }
    }

    private var jar: HTTPCookieStorage? { session.configuration.httpCookieStorage }

    private func cookies(in domains: Set<String>) -> [HTTPCookie] {
        (jar?.cookies ?? []).filter { domains.contains(Self.normalized($0.domain)) }
    }

    public func exportCookies(domains: Set<String>) throws -> Data {
        guard jar != nil else { throw TransportError.cookieStorageUnavailable }
        return try CookieCodec.encode(cookies(in: domains))
    }

    public func importCookies(_ data: Data, domains: Set<String>) throws {
        guard let jar else { throw TransportError.cookieStorageUnavailable }
        guard (jar.cookies ?? []).isEmpty else { throw TransportError.cookieJarNotEmpty }
        let cookies = try CookieCodec.decode(data)
        guard cookies.allSatisfy({ domains.contains(Self.normalized($0.domain)) }) else {
            throw TransportError.foreignCookieDomain
        }
        cookies.forEach { jar.setCookie($0) }
    }

    public func cookieFingerprint(domains: Set<String>) -> String {
        CookieCodec.fingerprint(cookies(in: domains))
    }

    /// Cookie domains may carry a leading dot; compare without it.
    static func normalized(_ domain: String) -> String {
        let lower = domain.lowercased()
        return lower.hasPrefix(".") ? String(lower.dropFirst()) : lower
    }
}

/// Orders pre-start cancellation against `resume()` so a cancelled call never starts and never
/// loses its completion.
private final class CancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func start(_ task: URLSessionDataTask) {
        lock.withLock {
            self.task = task
            if cancelled { task.cancel() } else { task.resume() }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            task?.cancel()
        }
    }
}

/// All mutable state is lock-protected; callbacks are also serialized by the session queue.
private final class CaptureDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let continuation: CheckedContinuation<HTTPExchange, any Error>
        let startTicks = mach_continuous_time()
        var body = Data()
        var observed = 0
        var limited = false
        init(_ continuation: CheckedContinuation<HTTPExchange, any Error>) { self.continuation = continuation }
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private let maximumBodyBytes: Int

    init(maximumBodyBytes: Int) { self.maximumBodyBytes = maximumBodyBytes }

    func register(_ task: URLSessionDataTask, continuation: CheckedContinuation<HTTPExchange, any Error>) {
        lock.withLock { pending[task.taskIdentifier] = Pending(continuation) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let stop = lock.withLock { () -> Bool in
            guard let capture = pending[dataTask.taskIdentifier] else { return true }
            capture.observed += data.count
            guard !capture.limited else { return true }
            let room = maximumBodyBytes - capture.body.count
            capture.body.append(data.prefix(room))
            capture.limited = data.count > room
            return capture.limited
        }
        // Local interruption at the capture limit; declared as `captureLimit`, never silent truncation.
        if stop { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let capture = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        let response = task.response as? HTTPURLResponse
        let end: HTTPExchange.TransferEnd =
            capture.limited ? .captureLimit : error != nil ? .interrupted : response == nil ? .nonHTTPResponse : .complete
        var headers: [String: String] = [:]
        for (key, value) in response?.allHeaderFields ?? [:] {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        capture.continuation.resume(
            returning: HTTPExchange(
                status: response?.statusCode, headers: headers, body: capture.body,
                observedByteCount: capture.observed, transferEnd: end, startTicks: capture.startTicks,
                endTicks: mach_continuous_time()))
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // Observed Arena routes and attachment links do not redirect; a redirect is surfaced as the
        // 3xx response itself.
        completionHandler(nil)
    }
}

enum CookieCodec {
    static let maximumBytes = 1 << 20
    static let maximumCookies = 256

    static func encode(_ cookies: [HTTPCookie]) throws -> Data {
        let list = try cookies.map { cookie -> [String: Any] in
            guard let properties = cookie.properties else { throw TransportError.invalidCookieData }
            // Defensive: `HTTPCookie(properties:)` raises an Objective-C exception for URL-typed
            // values on macOS 27 (observed 2026-09-24), so any URL is stored as its string.
            return Dictionary(
                uniqueKeysWithValues: properties.map { key, value in
                    (key.rawValue, (value as? URL).map { $0.absoluteString as Any } ?? value)
                })
        }
        do {
            return try PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
        } catch { throw TransportError.invalidCookieData }
    }

    static func decode(_ data: Data) throws -> [HTTPCookie] {
        guard data.count <= maximumBytes,
            let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]],
            list.count <= maximumCookies
        else { throw TransportError.invalidCookieData }
        return try list.map { values in
            let properties = Dictionary(uniqueKeysWithValues: values.map { (HTTPCookiePropertyKey($0.key), $0.value) })
            guard let cookie = HTTPCookie(properties: properties) else { throw TransportError.invalidCookieData }
            return cookie
        }
    }

    static func fingerprint(_ cookies: [HTTPCookie]) -> String {
        cookies.map { "\($0.name)\u{1}\($0.domain)\u{1}\($0.path)\u{1}\($0.value)\u{1}\($0.expiresDate?.timeIntervalSince1970 ?? 0)" }
            .sorted().joined(separator: "\u{2}").utf8.reduce(into: UInt64(14_695_981_039_346_656_037)) {
                $0 = ($0 ^ UInt64($1)) &* 1_099_511_628_211
            }.description
    }
}
