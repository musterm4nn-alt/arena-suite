import CryptoKit
import Darwin
import Foundation

public enum ResearchTransferEnd: String, Sendable {
    case complete, interrupted, captureLimit, nonHTTPResponse
}

public struct ResearchBodyUnit: Sendable {
    public let offset: Int
    public let observedLength: Int
    public let ticks: UInt64
    public let bytes: Data
}

public struct HTTPReply: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "HTTPReply(redacted)" }
    public var debugDescription: String { description }
    public let status: Int?
    public let body: Data
    public let contentType: String?
    public let units: [ResearchBodyUnit]
    public let observedByteCount: Int
    public let transferEnd: ResearchTransferEnd

    public init(
        status: Int?, body: Data, contentType: String? = nil,
        units: [ResearchBodyUnit] = [], observedByteCount: Int? = nil,
        transferEnd: ResearchTransferEnd = .complete
    ) {
        self.status = status
        self.body = body
        self.contentType = contentType
        self.units = units
        self.observedByteCount = observedByteCount ?? body.count
        self.transferEnd = transferEnd
    }
}

/// Research-only injection seam. Not a production recorded transport.
public protocol HTTPExecuting: Sendable {
    func perform(_ request: URLRequest) async throws -> HTTPReply
}

/// Register the delegate continuation before installing a task here. The lock orders pre-start
/// cancellation against resume, so cancellation cannot lose completion or start an already canceled call.
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

/// All mutable task state is lock-protected; callbacks are also serialized by the session queue.
/// Small, bounded, in-memory research capture only. No durability or archive claim.
private final class ResearchSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let continuation: CheckedContinuation<HTTPReply, any Error>
        var body = Data()
        var units: [ResearchBodyUnit] = []
        var observed = 0
        var limited = false
        init(_ continuation: CheckedContinuation<HTTPReply, any Error>) { self.continuation = continuation }
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private let maximumBodyBytes: Int
    private let maximumCallbacks: Int

    init(maximumBodyBytes: Int, maximumCallbacks: Int) {
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumCallbacks = maximumCallbacks
    }

    func register(_ task: URLSessionDataTask, continuation: CheckedContinuation<HTTPReply, any Error>) {
        lock.withLock { pending[task.taskIdentifier] = Pending(continuation) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let ticks = mach_continuous_time()
        let cancel = lock.withLock { () -> Bool in
            guard let capture = pending[dataTask.taskIdentifier] else { return true }
            capture.observed += data.count
            guard !capture.limited, capture.units.count < maximumCallbacks else {
                capture.limited = true
                return true
            }
            let length = min(data.count, maximumBodyBytes - capture.body.count)
            let bytes = Data(data.prefix(length))
            capture.units.append(
                ResearchBodyUnit(
                    offset: capture.body.count, observedLength: data.count, ticks: ticks, bytes: bytes))
            capture.body.append(bytes)
            capture.limited = length != data.count
            return capture.limited
        }
        if cancel { dataTask.cancel() }  // Local interruption, never a claim of remote stop.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let capture = lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
        guard let capture else { return }
        let response = task.response as? HTTPURLResponse
        let end: ResearchTransferEnd =
            capture.limited
            ? .captureLimit
            : error != nil ? .interrupted : response == nil ? .nonHTTPResponse : .complete
        capture.continuation.resume(
            returning: HTTPReply(
                status: response?.statusCode, body: capture.body,
                contentType: response?.value(forHTTPHeaderField: "Content-Type"),
                units: capture.units, observedByteCount: capture.observed, transferEnd: end))
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public final class NativeHTTPExecutor: CookieSessionExecuting {
    private let session: URLSession
    private let delegate: ResearchSessionDelegate

    public init(maximumBodyBytes: Int = 4 * 1024 * 1024, maximumCallbacks: Int = 4096) {
        precondition(maximumBodyBytes > 0 && maximumCallbacks > 0)
        delegate = ResearchSessionDelegate(maximumBodyBytes: maximumBodyBytes, maximumCallbacks: maximumCallbacks)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        // Foundation owns this configuration's private cookie store. No browser-cookie extraction.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    deinit { session.invalidateAndCancel() }

    func exportCookieData() throws -> Data {
        guard let jar = session.configuration.httpCookieStorage else { throw ResearchFailure.sessionStorageFailed }
        return try ResearchCookieCodec.encode(
            (jar.cookies ?? []).filter {
                ["arena.ai", ".arena.ai"].contains($0.domain.lowercased())
            })
    }

    /// A4: names and lifetimes only. Values never leave this process; a digest is kept in memory
    /// solely to detect rotation.
    func cookieMetadata() -> [CookieMetadata] {
        let cookies = session.configuration.httpCookieStorage?.cookies ?? []
        return cookies.map { cookie in
            CookieMetadata(
                name: cookie.name, domain: cookie.domain, path: cookie.path,
                expires: cookie.expiresDate.map { ISO8601DateFormatter().string(from: $0) },
                secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly, sameSite: cookie.sameSitePolicy?.rawValue,
                valueDigest: SHA256.hash(data: Data(cookie.value.utf8)).description)
        }.sorted { ($0.name, $0.domain, $0.path) < ($1.name, $1.domain, $1.path) }
    }

    func importCookieData(_ data: Data) throws {
        let cookies = try ResearchCookieCodec.decode(data)
        guard let jar = session.configuration.httpCookieStorage,
            (jar.cookies ?? []).isEmpty
        else { throw ResearchFailure.sessionStorageFailed }
        for cookie in cookies { jar.setCookie(cookie) }
    }

    public func perform(_ request: URLRequest) async throws -> HTTPReply {
        let cancellation = CancellationRelay()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                delegate.register(task, continuation: continuation)
                cancellation.start(task)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}
