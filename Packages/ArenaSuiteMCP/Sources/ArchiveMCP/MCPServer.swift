import Foundation

/// A minimal MCP server over newline-delimited JSON-RPC 2.0 (the MCP stdio transport). It only
/// offers tools; every tool is read-only (`ArchiveTools`).
public struct MCPServer: Sendable {
    /// Newest first. A client asking for one of these gets it back; otherwise the newest.
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let tools: ArchiveTools?
    private let unavailable: String?
    private let version: String

    /// `tools` is nil when the archive could not be opened; `unavailable` then explains why, and
    /// every tool call reports it instead of failing the whole session.
    public init(tools: ArchiveTools?, unavailable: String?, version: String) {
        self.tools = tools
        self.unavailable = unavailable
        self.version = version
    }

    /// Handles one line of input. Returns the response line, or nil for notifications.
    public func handle(line: Data) async -> Data? {
        let message: JSONValue
        do {
            message = try JSONDecoder().decode(JSONValue.self, from: line)
        } catch {
            return Self.encode(Self.error(id: .null, code: -32700, message: "Parse error"))
        }
        // Batches were removed from MCP in 2025-06-18; reject them explicitly.
        guard case .object = message else {
            return Self.encode(Self.error(id: .null, code: -32600, message: "Invalid Request"))
        }
        let id = message["id"]
        guard message["jsonrpc"]?.stringValue == "2.0", let method = message["method"]?.stringValue else {
            // A response from the client (we never send requests) or a malformed message.
            if message["method"] == nil, id != nil, message["result"] != nil || message["error"] != nil { return nil }
            return Self.encode(Self.error(id: id ?? .null, code: -32600, message: "Invalid Request"))
        }
        guard let id else { return nil }  // notifications (initialized, cancelled, …) need no reply
        switch id {
        case .string, .int: break
        default: return Self.encode(Self.error(id: .null, code: -32600, message: "Invalid Request"))
        }
        let params = message["params"] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue
            let chosen = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? Self.supportedProtocolVersions[0]
            return Self.encode(
                Self.result(
                    id: id,
                    [
                        "protocolVersion": .string(chosen),
                        "capabilities": ["tools": ["listChanged": false]],
                        "serverInfo": ["name": "arena-suite", "version": .string(version)],
                        "instructions": "Read-only access to the local Arena Suite archive: list accounts and conversations, search, get or export a conversation. It never contacts Arena, never syncs, votes or reveals, and never writes files.",
                    ]))
        case "ping":
            return Self.encode(Self.result(id: id, [:]))
        case "tools/list":
            return Self.encode(Self.result(id: id, ["tools": .array(ArchiveTools.definitions)]))
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.encode(Self.error(id: id, code: -32602, message: "Invalid params: name is required"))
            }
            var arguments: [String: JSONValue] = [:]
            switch params["arguments"] {
            case nil, .null?: break
            case .object(let object)?: arguments = object
            default: return Self.encode(Self.error(id: id, code: -32602, message: "Invalid params: arguments must be an object"))
            }
            guard ArchiveTools.definitions.contains(where: { $0["name"]?.stringValue == name }) else {
                return Self.encode(Self.error(id: id, code: -32602, message: "Unknown tool: \(name)"))
            }
            return Self.encode(Self.result(id: id, await call(name, arguments: arguments)))
        default:
            return Self.encode(Self.error(id: id, code: -32601, message: "Method not found"))
        }
    }

    private func call(_ name: String, arguments: [String: JSONValue]) async -> JSONValue {
        guard let tools else {
            return Self.toolResult(text: unavailable ?? "The archive is unavailable.", isError: true)
        }
        do {
            let value = try await tools.call(name, arguments: arguments)
            if case .string(let text) = value { return Self.toolResult(text: text, isError: false) }
            let text = String(decoding: try value.encoded(), as: UTF8.self)
            return Self.toolResult(text: text, isError: false)
        } catch let error as ArchiveTools.ToolError {
            return Self.toolResult(text: error.message, isError: true)
        } catch {
            // Only the error's type goes to the client: library error descriptions are not ours to
            // vouch for, and could echo arguments or SQL values.
            return Self.toolResult(text: "The archive could not be read (\(type(of: error))).", isError: true)
        }
    }

    private static func toolResult(text: String, isError: Bool) -> JSONValue {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: JSONValue, code: Int64, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }

    private static func encode(_ value: JSONValue) -> Data {
        // Encoding a JSONValue cannot fail (no non-finite doubles are ever produced here).
        (try? value.encoded()) ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }

    /// Reads newline-delimited messages from `input` until EOF, writing one line per response to
    /// `output`. Requests are handled one at a time, in order.
    public func serve(input: FileHandle, output: FileHandle) async {
        var framer = LineFramer()
        while true {
            let chunk = input.availableData
            let lines = chunk.isEmpty ? framer.finish() : framer.feed(chunk)
            for line in lines {
                let response: Data?
                switch line {
                case .message(let data): response = await handle(line: data)
                case .oversized: response = Self.encode(Self.error(id: .null, code: -32600, message: "Message too large"))
                }
                if let response { output.write(response + Data("\n".utf8)) }
            }
            if chunk.isEmpty { break }
        }
    }
}

/// Splits stdio input into messages: LF-terminated lines, a trailing CR removed, blank lines
/// skipped, and a final unterminated line delivered at EOF. A line longer than `limit` is reported
/// once as `.oversized` and its bytes are discarded up to the next newline, so memory stays bounded.
public struct LineFramer: Sendable {
    public enum Line: Equatable, Sendable {
        case message(Data)
        case oversized
    }

    public static let defaultLimit = 16 * 1024 * 1024
    private let limit: Int
    private var buffer = Data()
    private var discarding = false

    public init(limit: Int = LineFramer.defaultLimit) { self.limit = limit }

    public mutating func feed(_ chunk: Data) -> [Line] {
        var lines: [Line] = []
        var rest = chunk[...]
        while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
            let piece = rest[rest.startIndex..<newline]
            rest = rest[rest.index(after: newline)...]
            if discarding {
                discarding = false
                buffer.removeAll()
                continue
            }
            buffer.append(contentsOf: piece)
            if let line = take() { lines.append(line) }
        }
        if !discarding {
            buffer.append(contentsOf: rest)
            if buffer.count > limit {
                buffer.removeAll()
                discarding = true
                lines.append(.oversized)
            }
        }
        return lines
    }

    public mutating func finish() -> [Line] {
        defer {
            buffer.removeAll()
            discarding = false
        }
        guard !discarding, let line = take() else { return [] }
        return [line]
    }

    private mutating func take() -> Line? {
        defer { buffer.removeAll(keepingCapacity: true) }
        if buffer.count > limit { return .oversized }
        var line = buffer
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        let blank = line.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\r") }
        return blank ? nil : .message(line)
    }
}
