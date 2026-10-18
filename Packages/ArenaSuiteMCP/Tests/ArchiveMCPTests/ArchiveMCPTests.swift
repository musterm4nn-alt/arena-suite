import ApplicationActions
import ArchiveIndex
import CaptureJournal
import CryptoKit
import Foundation
import SuiteDomain
import Testing

@testable import ArchiveMCP
@testable import ArenaAdapter

private let detailBody = Data(#"""
{"id":"c1","title":"Harbour notes","mode":"battle","updatedAt":"2026-09-24 10:00:00.000000+00",
 "lastMessageIds":["a1","b1"],
 "messages":[
  {"id":"u1","role":"user","status":"success","content":"Tell me about lighthouses","parentMessageIds":[],"metadata":{"botScore":0.9,"hashedClientIp":"abc"}},
  {"id":"a1","role":"assistant","status":"success","participantPosition":"a","modelId":"m-a","parentMessageIds":["u1"],
   "content":[{"type":"reasoning","text":"ponder foghorn"},{"type":"text","text":"Lighthouses guide ships"}],
   "metadata":{"recaptchaV3Score":1}},
  {"id":"b1","role":"assistant","status":"success","participantPosition":"b","modelId":"m-b","parentMessageIds":["u1"],"content":"Beacons on coasts"}
 ]}
"""#.utf8)

/// An archive with one account, one registered name and one archived conversation, built by the
/// app's own write path. The writing service is released before the fixture is handed out.
private struct Fixture {
    let root: URL
    let account = AccountID()
    /// Normalized/Markdown/raw renders from the writable service, for byte comparison.
    let expected: [ExportFormat: Data]

    init() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)", isDirectory: true)
        let journals = JournalStore(archiveRoot: root)
        let writer = try await journals.writer(for: account)
        _ = try writer.append(
            JournalDraft(
                kind: "exchange", payload: detailBody, accountID: account.rawValue,
                metadata: [
                    "role": .string("detail"), "status": .integer(200), "transfer_end": .string("complete"),
                    "entry_id": .string("c1"), "entry_type": .string("evaluation"),
                ]))
        try writer.synchronize()
        try AccountRegistryStore(url: root.appendingPathComponent("accounts/registry.json")).save([
            AccountRecord(
                id: account, displayName: "Main", principal: PrincipalIdentity(namespace: "arena", claims: ["supabaseUserId": "s-secret"]),
                createdAt: Date(timeIntervalSince1970: 0), credentialGeneration: 1)
        ])
        var expected: [ExportFormat: Data] = [:]
        do {
            let index = try ArchiveIndex(url: root.appendingPathComponent("index/archive.sqlite"))
            let account = self.account
            let service = ArchiveService(index: index, journals: journals, decoder: ArenaArchiveDecoder(), accounts: { [account] })
            _ = try await service.project(account)
            for format in ExportFormat.allCases {
                expected[format] = try await ExportService(archive: service).render(
                    account: account, remoteID: "c1", snapshot: nil, options: ExportOptions(format: format)
                ).data
            }
        }
        self.expected = expected
    }

    func server() throws -> MCPServer {
        MCPServer(tools: try ArchiveTools.readOnly(archiveRoot: root), unavailable: nil, version: "test")
    }
}

private func send(_ server: MCPServer, _ json: String) async throws -> JSONValue? {
    guard let data = await server.handle(line: Data(json.utf8)) else { return nil }
    #expect(!data.contains(UInt8(ascii: "\n")), "one line per message")
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

private func callTool(_ server: MCPServer, _ name: String, _ arguments: JSONValue = [:]) async throws -> (text: String, isError: Bool) {
    let request: JSONValue = ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": .string(name), "arguments": arguments]]
    let response = try #require(try await send(server, String(decoding: try request.encoded(), as: UTF8.self)))
    let result = try #require(response["result"])
    guard case .array(let content)? = result["content"], let text = content.first?["text"]?.stringValue else {
        Issue.record("no text content")
        return ("", true)
    }
    return (text, result["isError"]?.boolValue ?? false)
}

private func parse(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

// MARK: Protocol

@Test func initializeNegotiatesVersionAndAdvertisesToolsOnly() async throws {
    let server = try await Fixture().server()
    let known = try #require(try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
    #expect(known["result"]?["protocolVersion"] == "2025-06-18")
    #expect(known["result"]?["capabilities"] == ["tools": ["listChanged": false]])
    let unknown = try #require(try await send(server, #"{"jsonrpc":"2.0","id":"x","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
    #expect(unknown["result"]?["protocolVersion"]?.stringValue == MCPServer.supportedProtocolVersions[0])
    #expect(unknown["id"] == "x")
}

@Test func protocolErrorsAndNotifications() async throws {
    let server = try await Fixture().server()
    #expect(try await send(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    #expect(try await send(server, #"{"jsonrpc":"2.0","id":3,"result":{}}"#) == nil, "client responses are ignored")
    #expect(try await send(server, "{not json")?["error"]?["code"] == .int(-32700))
    #expect(try await send(server, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)?["error"]?["code"] == .int(-32600))
    #expect(try await send(server, #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#)?["error"]?["code"] == .int(-32600))
    #expect(try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)?["error"]?["code"] == .int(-32601))
    #expect(try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"sync_account"}}"#)?["error"]?["code"] == .int(-32602))
    #expect(try await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search","arguments":[1]}}"#)?["error"]?["code"] == .int(-32602))
    #expect(try await send(server, #"{"jsonrpc":"2.0","id":9,"method":"ping"}"#) == ["jsonrpc": "2.0", "id": 9, "result": [:]])
}

@Test func toolListIsExactlyTheReadOnlySet() async throws {
    let server = try await Fixture().server()
    let response = try #require(try await send(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
    guard case .array(let tools)? = response["result"]?["tools"] else { Issue.record("no tools"); return }
    let names = tools.compactMap { $0["name"]?.stringValue }
    #expect(names == ["list_accounts", "list_conversations", "search", "get_conversation", "export_conversation"])
    for tool in tools {
        #expect(tool["annotations"]?["readOnlyHint"] == true)
        #expect(tool["annotations"]?["openWorldHint"] == false)
        #expect(tool["inputSchema"]?["additionalProperties"] == false)
    }
    // Nothing in the surface names a write, network or Track B action.
    let surface = String(decoding: try JSONValue.array(tools).encoded(), as: UTF8.self).lowercased()
    for word in ["include_exact", "exact_raw", "raw_bodies\"", "\"vote\"", "reveal_", "send_", "sync_"] {
        #expect(!surface.contains(word), "\(word)")
    }
}

// MARK: Tools

@Test func listsAccountsWithIndexedScopeAndConversations() async throws {
    let fixture = try await Fixture()
    let server = try fixture.server()
    let accounts = try parse(try await callTool(server, "list_accounts").text)
    guard case .array(let rows)? = accounts["accounts"] else { Issue.record("no accounts"); return }
    #expect(rows.count == 1)
    #expect(rows[0]["account_id"]?.stringValue == fixture.account.rawValue.uuidString)
    #expect(rows[0]["display_name"] == "Main")
    #expect(rows[0]["indexed_through_sequence"] == "1")
    #expect(rows[0]["conversation_count"] == 1)
    #expect(accounts["decoder"]?.stringValue == ArenaArchiveDecoder().version)
    let text = try await callTool(server, "list_accounts").text
    #expect(!text.contains("supabase") && !text.contains("s-secret"), "principal identity is not exposed")

    let list = try parse(try await callTool(server, "list_conversations", ["account_id": .string(fixture.account.rawValue.uuidString)]).text)
    #expect(list["total"] == 1)
    #expect(list["conversations"] == .array([
        [
            "account_id": .string(fixture.account.rawValue.uuidString), "conversation_id": "c1", "kind": "evaluation",
            "title": "Harbour notes", "mode": "battle", "modality": .null, "updated_at": "2026-09-24 10:00:00.000000+00",
            "snapshot_count": 1, "latest_snapshot": "1", "message_count": 3, "absent_from_latest_history_list": false,
        ]
    ]))
    let empty = try parse(try await callTool(server, "list_conversations", ["offset": 1]).text)
    #expect(empty["conversations"] == .array([]))
    #expect(try await callTool(server, "list_conversations", ["limit": 201]).isError)
    #expect(try await callTool(server, "list_conversations", ["account_id": "not-a-uuid"]).isError)
}

@Test func searchHonoursKindsLimitsAndBounds() async throws {
    let fixture = try await Fixture()
    let server = try fixture.server()
    let text = try parse(try await callTool(server, "search", ["query": "lighthouses"]).text)
    guard case .array(let hits)? = text["hits"] else { Issue.record("no hits"); return }
    #expect(Set(hits.compactMap { $0["message_id"]?.stringValue }) == ["u1", "a1"])
    #expect(text["scope"] == "message text only")
    let reasoning = try parse(try await callTool(server, "search", ["query": "foghorn"]).text)
    #expect(reasoning["hits"] == .array([]))
    let withReasoning = try parse(try await callTool(server, "search", ["query": "foghorn", "include_reasoning_and_tools": true]).text)
    guard case .array(let reasoningHits)? = withReasoning["hits"] else { Issue.record("no hits"); return }
    #expect(reasoningHits.map { $0["kind"] } == ["reasoning"])
    let limited = try parse(try await callTool(server, "search", ["query": "lighthouses", "limit": 1]).text)
    #expect(limited["limit_reached"] == true)
    #expect(try await callTool(server, "search", ["query": "  "]).isError)
    #expect(try await callTool(server, "search", ["query": .string(String(repeating: "a", count: 501))]).isError)
    #expect(try await callTool(server, "search", ["query": "a", "limit": 51]).isError)
    #expect(try await callTool(server, "search", ["query": "\"unbalanced OR NEAR("]).isError == false, "FTS syntax is neutralised")
}

@Test func conversationsMatchTheAppsExportsByteForByte() async throws {
    let fixture = try await Fixture()
    let server = try fixture.server()
    let ids: JSONValue = ["account_id": .string(fixture.account.rawValue.uuidString), "conversation_id": "c1"]
    let get = try await callTool(server, "get_conversation", ids)
    #expect(!get.isError)
    #expect(Data(get.text.utf8) == fixture.expected[.normalizedJSON])
    for (name, format) in [("markdown", ExportFormat.markdown), ("normalized_json", .normalizedJSON), ("raw_json", .rawJSON)] {
        guard case .object(var arguments) = ids else { return }
        arguments["format"] = .string(name)
        let result = try await callTool(server, "export_conversation", .object(arguments))
        #expect(!result.isError)
        #expect(Data(result.text.utf8) == fixture.expected[format], "\(name)")
    }
    guard case .object(var snapshot) = ids else { return }
    snapshot["snapshot"] = "1"
    #expect(try await callTool(server, "get_conversation", .object(snapshot)).text == get.text)
    snapshot["snapshot"] = "2"
    #expect(try await callTool(server, "get_conversation", .object(snapshot)).isError)
}

@Test func telemetryAndExactBodiesNeverLeave() async throws {
    let fixture = try await Fixture()
    let server = try fixture.server()
    let account = JSONValue.string(fixture.account.rawValue.uuidString)
    var everything = ""
    everything += try await callTool(server, "list_accounts").text
    everything += try await callTool(server, "list_conversations").text
    everything += try await callTool(server, "search", ["query": "lighthouses", "include_reasoning_and_tools": true]).text
    everything += try await callTool(server, "get_conversation", ["account_id": account, "conversation_id": "c1"]).text
    for format in ["markdown", "normalized_json", "raw_json"] {
        let text = try await callTool(server, "export_conversation", ["account_id": account, "conversation_id": "c1", "format": .string(format)]).text
        everything += text
        if format == "raw_json" {
            // The payload is base64; decode it and check the masked body too.
            let raw = try parse(text)
            guard case .array(let records)? = raw["records"], let base64 = records.first?["payload_base64"]?.stringValue,
                let payload = Data(base64Encoded: base64)
            else { Issue.record("no payload"); continue }
            everything += String(decoding: payload, as: UTF8.self)
            #expect(raw["redaction_policy"] == "mask-metadata/1")
        }
    }
    for secret in ["botScore", "hashedClientIp", "recaptchaV3Score"] {
        #expect(!everything.contains(secret), "\(secret)")
    }
    let exact = try await callTool(
        server, "export_conversation",
        ["account_id": account, "conversation_id": "c1", "format": "raw_json", "include_exact_raw_bodies": true])
    #expect(exact.isError && exact.text.contains("Unknown argument include_exact_raw_bodies"))
}

// MARK: Read-only guarantees

private func fingerprint(_ root: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    for case let url as URL in enumerator {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { continue }
        let relative = String(url.path.dropFirst(root.path.count))
        if info.st_mode & S_IFMT == S_IFREG {
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            result[relative] = "\(info.st_mode & 0o7777) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) \(digest)"
        } else {
            result[relative] = "\(info.st_mode)"
        }
    }
    return result
}

@Test func aFullSessionChangesNothingOnDisk() async throws {
    let fixture = try await Fixture()
    let before = try fingerprint(fixture.root)
    do {
        let server = try fixture.server()
        let account = JSONValue.string(fixture.account.rawValue.uuidString)
        _ = try await callTool(server, "list_accounts")
        _ = try await callTool(server, "list_conversations")
        _ = try await callTool(server, "search", ["query": "lighthouses"])
        for format in ["markdown", "normalized_json", "raw_json"] {
            _ = try await callTool(server, "export_conversation", ["account_id": account, "conversation_id": "c1", "format": .string(format)])
        }
    }
    // SQLite readers of a WAL database update the shared-memory index (`-shm`) to coordinate with
    // writers; it holds no archive data and is rebuilt on demand. Everything else is unchanged.
    let after = try fingerprint(fixture.root)
    #expect(after.keys.sorted() == before.keys.sorted())
    #expect(after.filter { !$0.key.hasSuffix("-shm") } == before.filter { !$0.key.hasSuffix("-shm") })
}

@Test func readOnlyServiceRefusesProjectionAndSQLiteRefusesWrites() async throws {
    let fixture = try await Fixture()
    let index = try ArchiveIndex(readingExistingAt: fixture.root.appendingPathComponent("index/archive.sqlite"))
    let service = ArchiveService(readOnly: index, journals: JournalStore(archiveRoot: fixture.root))
    await #expect(throws: ArchiveServiceError.readOnly) { _ = try await service.project(fixture.account) }
    await #expect(throws: ArchiveServiceError.readOnly) { try await service.rebuild() }
    await #expect(throws: ArchiveServiceError.readOnly) {
        _ = try await service.checkAgainstJournal(scratch: fixture.root.appendingPathComponent("scratch"))
    }
    #expect(throws: (any Error).self) { try index.reset() }
    #expect(try service.counts() == ArchiveIndex(readingExistingAt: fixture.root.appendingPathComponent("index/archive.sqlite")).counts())
    #expect(service.decoderVersion == ArenaArchiveDecoder().version, "reports the decoder that built the projection")
}

@Test func missingOrLooseIndexIsRefusedAndNothingIsCreated() async throws {
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-empty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { _ = try ArchiveTools.readOnly(archiveRoot: empty) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: empty.path).isEmpty)
    let server = MCPServer(tools: nil, unavailable: "no index", version: "test")
    let result = try await callTool(server, "list_accounts")
    #expect(result.isError && result.text == "no index")

    let fixture = try await Fixture()
    let database = fixture.root.appendingPathComponent("index/archive.sqlite")
    chmod(database.path, 0o644)
    #expect(throws: ArchiveIndex.ReadOnlyOpenError.notOwnerOnly(database.path)) { _ = try ArchiveTools.readOnly(archiveRoot: fixture.root) }
    chmod(database.path, 0o600)
    let moved = fixture.root.appendingPathComponent("index/real.sqlite")
    try FileManager.default.moveItem(at: database, to: moved)
    try FileManager.default.createSymbolicLink(at: database, withDestinationURL: moved)
    #expect(throws: ArchiveIndex.OpenError.symlink(database.path)) { _ = try ArchiveTools.readOnly(archiveRoot: fixture.root) }
}

// MARK: End to end

@Test func binarySpeaksMCPOverStdio() async throws {
    let fixture = try await Fixture()
    // `swift test` builds every product of the package, including the server binary, into .build/debug.
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let binary = package.appendingPathComponent(".build/debug/arena-suite-mcp")
    try #require(FileManager.default.isExecutableFile(atPath: binary.path), "build the arena-suite-mcp product first")
    let process = Process()
    process.executableURL = binary
    process.arguments = ["--archive-root", fixture.root.path]
    let input = Pipe(), output = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let requests = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{"query":"beacons"}}}"#,
    ]
    input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
    #expect(lines.count == 2)
    let initialize = try parse(lines[0])
    #expect(initialize["result"]?["serverInfo"]?["name"] == "arena-suite")
    let search = try parse(lines[1])
    guard case .array(let content)? = search["result"]?["content"], let text = content.first?["text"]?.stringValue else {
        Issue.record("no content"); return
    }
    #expect(try parse(text)["hits"].map { if case .array(let hits) = $0 { hits.count } else { -1 } } == 1)
    #expect(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
}

// MARK: Review follow-ups (Docs/reviews/2026-09-25-mcp.md)

@Test func looseRegistryIsRefusedNotTightened() async throws {
    let fixture = try await Fixture()
    let registry = fixture.root.appendingPathComponent("accounts/registry.json")
    chmod(registry.path, 0o644)
    let before = try fingerprint(fixture.root)
    let result = try await callTool(try fixture.server(), "list_accounts")
    #expect(result.isError && result.text.contains("owner-only"))
    let after = try fingerprint(fixture.root)
    #expect(after.filter { !$0.key.hasSuffix("-shm") } == before.filter { !$0.key.hasSuffix("-shm") }, "mode unchanged")
    // Narrower than owner-only is fine.
    chmod(registry.path, 0o400)
    #expect(try await callTool(try fixture.server(), "list_accounts").isError == false)
}

@Test func sessionWithoutSharedMemoryFileOnlyCreatesIt() async throws {
    let fixture = try await Fixture()
    let database = fixture.root.appendingPathComponent("index/archive.sqlite")
    unlink(database.path + "-shm")
    let before = try fingerprint(fixture.root)
    let result = try await callTool(try fixture.server(), "search", ["query": "lighthouses"])
    #expect(!result.isError)
    let after = try fingerprint(fixture.root)
    #expect(Set(after.keys).subtracting(before.keys).allSatisfy { $0.hasSuffix("-shm") })
    #expect(after.filter { !$0.key.hasSuffix("-shm") } == before)
}

@Test func framerHandlesSplitsCRLFBlanksEOFAndOversizedLines() {
    var framer = LineFramer(limit: 16)
    #expect(framer.feed(Data(#"{"a":"#.utf8)) == [])
    #expect(framer.feed(Data("1}\r\n\n  \r\n{\"b\":2}\n".utf8)) == [.message(Data(#"{"a":1}"#.utf8)), .message(Data(#"{"b":2}"#.utf8))])
    #expect(framer.feed(Data(String(repeating: "x", count: 10).utf8)) == [])
    #expect(framer.feed(Data(String(repeating: "x", count: 10).utf8)) == [.oversized], "reported once")
    #expect(framer.feed(Data(String(repeating: "x", count: 40).utf8)) == [], "rest of the long line is dropped")
    #expect(framer.feed(Data("xx\n{\"c\":3}\n".utf8)) == [.message(Data(#"{"c":3}"#.utf8))], "recovers at the next line")
    #expect(framer.feed(Data(String(repeating: "y", count: 20).utf8) + Data("\n".utf8)) == [.oversized], "long line within one chunk")
    #expect(framer.feed(Data(#"{"d":4}"#.utf8)) == [])
    #expect(framer.finish() == [.message(Data(#"{"d":4}"#.utf8))], "unterminated final line delivered at EOF")
    #expect(framer.finish() == [])
}

@Test func jsonValueKeepsBoolsIntsAndDoublesApart() throws {
    func decode(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    #expect(try decode("true") == .bool(true))
    #expect(try decode("1") == .int(1), "1 is not true")
    #expect(try decode("0") == .int(0))
    #expect(try decode("1.5") == .double(1.5))
    #expect(try decode("9223372036854775807") == .int(.max))
    #expect(try decode("9223372036854775808").uint64Value == nil, "past Int64 is not trusted as an exact sequence")
    #expect(try decode(#""18446744073709551615""#).uint64Value == .max, "large sequences travel as strings")
    #expect(try decode("-1").uint64Value == nil)
    #expect(try decode("1.0").intValue == nil || (try decode("1.0")) == .int(1))
    #expect(try decode("2.5").intValue == nil)
    #expect(try decode(#"{"k":[null,"s"]}"#) == ["k": [.null, "s"]])
}

@Test func argumentsAreBoundedAndErrorsCarryNoContent() async throws {
    let fixture = try await Fixture()
    let server = try fixture.server()
    let account = JSONValue.string(fixture.account.rawValue.uuidString)
    let long = String(repeating: "c", count: 100_000)
    let result = try await callTool(server, "get_conversation", ["account_id": account, "conversation_id": .string(long)])
    #expect(result.isError && result.text.count < 200, "not echoed")
    #expect(try await callTool(server, "list_conversations", ["limit": .double(1.5)]).isError)
    #expect(try await callTool(server, "get_conversation", ["account_id": account, "conversation_id": "c1", "snapshot": -1]).isError)
    #expect(try await callTool(server, "list_conversations", ["offset": .int(.max)]).isError == false)

    // A journal read failure surfaces as a fixed message, not a library description.
    let journal = fixture.root.appendingPathComponent("accounts/\(fixture.account.rawValue.uuidString)/journal/segments")
    let segments = try FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: [.isRegularFileKey])
        .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    try #require(!segments.isEmpty, "journal layout changed")
    for segment in segments {
        let handle = try FileHandle(forWritingTo: segment)
        try handle.truncate(atOffset: 8)
        try handle.close()
    }
    let broken = try await callTool(server, "export_conversation", ["account_id": account, "conversation_id": "c1", "format": "raw_json"])
    #expect(broken.isError)
    for word in ["Lighthouses", "lighthouses", "botScore", "metadata", fixture.root.path] {
        #expect(!broken.text.contains(word), "\(word)")
    }
}

// MARK: Review follow-ups (2026-10-18 full review, finding 7)

/// The server binary answers out-of-range snapshot sequences with tool errors and keeps running;
/// before, UInt64.max trapped in the index's Int64 conversion (signal 5).
@Test func outOfRangeSnapshotsAreToolErrorsNotCrashes() async throws {
    let fixture = try await Fixture()
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let binary = package.appendingPathComponent(".build/debug/arena-suite-mcp")
    try #require(FileManager.default.isExecutableFile(atPath: binary.path), "build the arena-suite-mcp product first")
    let process = Process()
    process.executableURL = binary
    process.arguments = ["--archive-root", fixture.root.path]
    let input = Pipe(), output = Pipe(), errors = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let account = fixture.account.rawValue.uuidString
    let snapshots = [#""0""#, "\"\(Int64.max)\"", "\"\(UInt64(Int64.max) + 1)\"", "\"\(UInt64.max)\"", "\(Int64.max)", #""1""#]
    var requests = [
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
    ]
    for (n, snapshot) in snapshots.enumerated() {
        requests.append(
            #"{"jsonrpc":"2.0","id":\#(n + 2),"method":"tools/call","params":{"name":"get_conversation","arguments":{"account_id":"\#(account)","conversation_id":"c1","snapshot":\#(snapshot)}}}"#)
    }
    input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
    try input.fileHandleForWriting.close()
    process.waitUntilExit()
    #expect(process.terminationReason == .exit && process.terminationStatus == 0, "the process stays alive until EOF")
    let lines = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
    #expect(lines.count == 1 + snapshots.count)
    let outcomes = try lines.dropFirst().map { try parse($0)["result"]?["isError"]?.boolValue ?? false }
    #expect(outcomes == [true, true, true, true, true, false], "only snapshot 1 exists")
    #expect(errors.fileHandleForReading.readDataToEndOfFile().isEmpty)
}
