import ApplicationActions
import ArchiveIndex
import CaptureJournal
import CryptoKit
import Foundation
import FoundationTransport
import SuiteDomain
import Testing

@testable import ArenaAdapter

// Attachment downloads (Docs/attachments-2026-10-20.md).

// MARK: - Fixtures

/// A link shaped like the 138 recorded ones (N-019): R2 host, `/<id>/<id>.<ext>`, S3 presigned query.
func signedLink(_ object: String, signedAt: String = "20261020T100000Z", expires: String = "3600", host: String? = nil) -> String {
    let host = host ?? "messages-prod.0123abcd.r2.cloudflarestorage.com"
    return "https://\(host)/f00d/\(object)?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Content-Sha256=UNSIGNED-PAYLOAD"
        + "&X-Amz-Credential=KEY%2F20261020%2Fauto%2Fs3%2Faws4_request&X-Amz-Date=\(signedAt)&X-Amz-Expires=\(expires)"
        + "&X-Amz-Signature=5ec2e7&X-Amz-SignedHeaders=host&x-amz-checksum-mode=ENABLED&x-id=GetObject"
}

/// 2026-10-20T10:00:05Z: five seconds after the fixture links were signed.
let fixtureNow = Date(timeIntervalSince1970: 1_792_490_405)

func attachmentDetail(_ id: String, _ links: [[String?]]) -> HTTPExchange {
    let messages = links.enumerated().map { index, urls -> String in
        let attachments = urls.enumerated().map { n, url -> String in
            #"{"name":"file\#(n).png","contentType":"image/png""# + (url.map { #","url":"\#($0)""# } ?? "") + "}"
        }.joined(separator: ",")
        return #"{"id":"m\#(index)","content":"private text","experimental_attachments":[\#(attachments)]}"#
    }.joined(separator: ",")
    return HTTPExchange(
        status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"id":"\#(id)","messages":[\#(messages)]}"#.utf8))
}

private func list(_ ids: [String], updated: String = "2026-10-20T10:00:00Z") -> HTTPExchange {
    let items = ids.map { id -> String in #"{"id":"\#(id)","type":"evaluation","title":"t","updatedAt":"\#(updated)"}"# }
        .joined(separator: ",")
    return HTTPExchange(
        status: 200, headers: ["Content-Type": "application/json"],
        body: Data(#"{"entries":[\#(items)],"pagination":{"hasMore":false,"cursor":null},"partial":false,"failedSources":[]}"#.utf8))
}

func file(_ text: String, type: String = "image/png", status: Int = 200, end: HTTPExchange.TransferEnd = .complete) -> HTTPExchange {
    HTTPExchange(
        status: status, headers: ["Content-Type": type, "ETag": "\"e\"", "Set-Cookie": "r2=1"], body: Data(text.utf8),
        transferEnd: end)
}

private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// One record as the journal returns it.
private func testRecord(kind: String, payload: Data, metadata: [String: JournalValue]) throws -> JournalRecord {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("record-\(UUID().uuidString)")
    let writer = try JournalWriter.open(at: root, options: JournalOptions(durability: .fsync))
    _ = try writer.append(JournalDraft(kind: kind, payload: payload, metadata: metadata))
    try writer.close()
    return try #require(try JournalReader(root: root).readAll().first)
}

/// One account in an archive laid out as the app lays it out: `accounts/<uuid>/journal` and
/// `accounts/<uuid>/objects`.
struct FileArchive {
    let root: URL
    let account = AccountID()
    let journals: JournalStore
    let journal: JournalWriter
    let session: FakeTransport
    let files: FakeTransport
    let provider: ArenaAccountSessions
    let record: AccountRecord
    let vault = MemoryVault()

    init(_ replies: [HTTPExchange], files: [HTTPExchange] = []) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("files-\(UUID().uuidString)", isDirectory: true)
        journals = JournalStore(archiveRoot: root)
        journal = try JournalWriter.open(at: journals.root(for: account), options: JournalOptions(durability: .fsync))
        try vault.save(StoredSession(principal: principalA, cookies: Data("c".utf8)), account: account)
        session = FakeTransport([me(), me()] + replies)
        self.files = FakeTransport(files)
        let factory = TransportFactory([session])
        provider = ArenaAccountSessions(vault: vault, makeTransport: { factory.make() })
        record = AccountRecord(id: account, displayName: "A", principal: principalA, createdAt: Date(), credentialGeneration: 1)
        #expect(await provider.restore(account: account, expected: principalA) == .verified)
    }

    var objects: ObjectStore { ObjectStore(root: journals.objects(for: account).root, durability: .fsync) }

    var sleep: ArenaHistorySync.Sleeper = { _ in }
    var now: @Sendable () -> Date = { fixtureNow }

    private var engine: ArenaHistorySync {
        ArenaHistorySync(sessions: provider, downloads: files, sleep: sleep, now: now)
    }

    func sync(_ replies: [HTTPExchange] = [], files more: [HTTPExchange] = []) async -> SyncManifest {
        if !replies.isEmpty { session.appendReplies([me()] + replies) }
        files.appendReplies(more)
        return await engine.sync(
            account: record.context, principal: principalA, journal: journal, journalRoot: journals.root(for: account),
            objects: objects, options: .testing(), progress: { _ in })
    }

    func refresh(_ id: String, _ replies: [HTTPExchange], files more: [HTTPExchange] = []) async -> SyncManifest {
        session.appendReplies([me()] + replies)
        files.appendReplies(more)
        return await engine.refresh(
            account: record.context, principal: principalA, journal: journal, journalRoot: journals.root(for: account),
            objects: objects, conversationID: id, options: .testing())
    }

    var records: [JournalRecord] { (try? JournalReader(root: journals.root(for: account)).readAll()) ?? [] }
    var downloads: [JournalRecord] { records.filter { $0.envelope.kind == "attachment.download" } }
    var fileHosts: [String] { files.requests.compactMap { $0.url?.host } }
}

// MARK: - Downloads in a sync

@Test func aDetailsFilesAreDownloadedRightAfterItAndStored() async throws {
    let a = try await FileArchive(
        [list(["e1", "e2"]), attachmentDetail("e1", [[signedLink("one.png"), signedLink("two.png")]]), attachmentDetail("e2", [])],
        files: [file("first image"), file("second image", type: "image/jpeg")])
    let manifest = await a.sync()
    #expect(manifest.outcome == .completed)
    #expect(manifest.attachmentsStored == 2 && manifest.attachmentsFailed == 0 && manifest.attachmentsAlreadyStored == 0)

    // Arena's session never fetches a file, and the file transport fetches nothing else.
    #expect(a.session.paths.filter { $0.hasPrefix("/api/evaluation/") } == ["/api/evaluation/e1", "/api/evaluation/e2"])
    #expect(!a.session.requests.contains { $0.url?.host?.hasSuffix("r2.cloudflarestorage.com") == true })
    #expect(a.files.requests.map(\.url?.absoluteString) == [signedLink("one.png"), signedLink("two.png")])
    #expect(a.files.requests.allSatisfy { $0.httpMethod == "GET" && ($0.allHTTPHeaderFields ?? [:]).isEmpty })

    // Recorded in order: the detail, then its files, then the next detail.
    let kinds = a.records.map(\.envelope.kind)
    let detailIndex = try #require(a.records.firstIndex { $0.envelope.metadata["entry_id"] == .string("e1") && $0.envelope.kind == "exchange" })
    #expect(a.records[detailIndex + 1].envelope.kind == "attachment.download")
    #expect(a.records[detailIndex + 2].envelope.kind == "attachment.download")
    #expect(a.records[detailIndex + 3].envelope.metadata["entry_id"] == .string("e2"), "\(kinds)")

    let detail = a.records[detailIndex]
    for (n, record) in a.downloads.enumerated() {
        let bytes = Data((n == 0 ? "first image" : "second image").utf8)
        let metadata = record.envelope.metadata
        #expect(record.payload.isEmpty)
        #expect(record.envelope.payloadRepresentation == "object_reference")
        #expect(record.envelope.transformations == ["credential_omitted", "signed_query_omitted"])
        #expect(metadata["entry_id"] == .string("e1"))
        #expect(metadata["detail_sequence"] == .string(String(detail.envelope.sequence)))
        #expect(metadata["message_id"] == .string("m0") && metadata["attachment_ordinal"] == .integer(Int64(n)))
        #expect(metadata["object_key"] == .string("https://messages-prod.0123abcd.r2.cloudflarestorage.com/f00d/\(n == 0 ? "one" : "two").png"))
        #expect(metadata["outcome"] == .string("stored") && metadata["status"] == .integer(200))
        #expect(metadata["object_sha256"] == .string(hex(bytes)) && metadata["object_size"] == .integer(Int64(bytes.count)))
        guard case .object(let headers) = metadata["response_headers"] else { Issue.record("no headers"); continue }
        #expect(headers["Set-Cookie"] == .string("[omitted]") && headers["ETag"] == .string("\"e\""))
        // The signed query stays in the detail record only.
        let envelope = String(decoding: try JSONEncoder().encode(record.envelope.metadata), as: UTF8.self)
        #expect(!envelope.contains("Signature") && !envelope.contains("X-Amz"))
        #expect(try a.objects.read(hex(bytes)) == bytes)
    }
}

@Test func linksDownloadsDontAcceptSendNothing() async throws {
    let links: [String?] = [
        signedLink("a.png", host: "evil.example.com"),
        signedLink("b.png").replacingOccurrences(of: "https://", with: "http://"),
        signedLink("c.png").replacingOccurrences(of: ".com/", with: ".com:8443/"),
        "https://user@messages-prod.0123abcd.r2.cloudflarestorage.com/f00d/d.png",
        "https://r2.cloudflarestorage.com/f00d/e.png",
        signedLink("f.png", signedAt: "20261020T080000Z"),  // signed two hours before `now`: expired
        "", nil,
    ]
    let a = try await FileArchive([list(["e1"]), attachmentDetail("e1", [links])])
    let manifest = await a.sync()
    #expect(manifest.outcome == .completed)
    #expect(a.files.requests.isEmpty && a.downloads.isEmpty)
    #expect(manifest.attachmentsNotRecognized == 5 && manifest.attachmentsExpired == 1)
    #expect(manifest.attachmentsStored == 0 && manifest.attachmentsFailed == 0)
}

@Test func aLinkWithoutItsLifetimeIsRequested() async throws {
    let bare = "https://messages-prod.0123abcd.r2.cloudflarestorage.com/f00d/bare.png"
    let odd = signedLink("odd.png", expires: "soon")
    let a = try await FileArchive([list(["e1"]), attachmentDetail("e1", [[bare, odd]])], files: [file("x"), file("y")])
    let manifest = await a.sync()
    #expect(manifest.attachmentsStored == 2 && a.files.requests.count == 2)
}

@Test func aFileAlreadyStoredIsNotRequestedAgainUnlessItIsGone() async throws {
    let a = try await FileArchive([list(["e1"]), attachmentDetail("e1", [[signedLink("one.png")]])], files: [file("bytes")])
    #expect(await a.sync().attachmentsStored == 1)

    // A refresh signs the same object anew: same key, nothing requested.
    let again = await a.refresh("e1", [attachmentDetail("e1", [[signedLink("one.png", signedAt: "20261020T100003Z")]])])
    #expect(again.outcome == .completed)
    #expect(again.attachmentsAlreadyStored == 1 && again.attachmentsStored == 0)
    #expect(a.files.requests.count == 1 && a.downloads.count == 1)

    // The file is gone: it is downloaded again.
    try FileManager.default.removeItem(at: try #require(a.objects.url(for: hex(Data("bytes".utf8)))))
    let third = await a.refresh("e1", [attachmentDetail("e1", [[signedLink("one.png")]])], files: [file("bytes")])
    #expect(third.attachmentsStored == 1 && a.files.requests.count == 2)
    #expect(try a.objects.read(hex(Data("bytes".utf8))) == Data("bytes".utf8))

    // The same key twice in one detail is requested once.
    let twice = await a.refresh("e1", [attachmentDetail("e1", [[signedLink("new.png"), signedLink("new.png")]])], files: [file("new")])
    #expect(twice.attachmentsStored == 1 && twice.attachmentsAlreadyStored == 1 && a.files.requests.count == 3)
}

@Test(arguments: [(403, AttachmentOutcome.denied), (401, .denied), (429, .unavailable), (503, .unavailable)])
func aRefusalStopsTheDownloadsButNotTheSync(status: Int, outcome: AttachmentOutcome) async throws {
    let refusal = HTTPExchange(status: status, headers: ["Content-Type": "application/xml"], body: Data("<Error><Code>X</Code></Error>".utf8))
    let a = try await FileArchive(
        [list(["e1", "e2"]), attachmentDetail("e1", [[signedLink("1.png"), signedLink("2.png"), signedLink("3.png")]]),
         attachmentDetail("e2", [[signedLink("4.png")]])],
        files: [refusal])
    let manifest = await a.sync()
    #expect(manifest.outcome == .completed && manifest.detailsFetched == 2, "the history is still synced")
    #expect(a.files.requests.count == 1)
    #expect(manifest.attachmentsFailed == 1 && manifest.attachmentsStored == 0)
    #expect(manifest.warnings.contains("attachment downloads stopped after HTTP \(status); 3 attachment(s) not requested"))
    let record = try #require(a.downloads.first)
    #expect(record.envelope.metadata["outcome"] == .string(outcome.rawValue))
    #expect(record.payload == refusal.body && record.envelope.payloadRepresentation == "foundation_decoded_entity")
    #expect(record.envelope.metadata["object_sha256"] == nil)
}

@Test func otherFailuresAreRecordedAndTheNextFileIsTried() async throws {
    let a = try await FileArchive(
        [list(["e1"]), attachmentDetail("e1", [[signedLink("1.png"), signedLink("2.png"), signedLink("3.png"), signedLink("4.png")]])],
        files: [
            file("<Error/>", type: "application/xml", status: 404), file("half", end: .interrupted),
            file("big", end: .captureLimit), file("fine"),
        ])
    let manifest = await a.sync()
    #expect(manifest.outcome == .completed)
    #expect(manifest.attachmentsFailed == 3 && manifest.attachmentsStored == 1)
    #expect(a.downloads.map { $0.envelope.metadata["outcome"] } == ["unavailable", "unavailable", "unavailable", "stored"].map { .string($0) })
    #expect(a.downloads.map { $0.envelope.metadata["transfer_end"] } == ["complete", "interrupted", "captureLimit", "complete"].map { .string($0) })
    #expect(a.downloads[1].payload == Data("half".utf8), "a body that isn't stored is kept in the record")
    #expect(try a.objects.names() == [hex(Data("fine".utf8))])
    #expect(manifest.warnings.isEmpty)
}

@Test func aTransportErrorIsCountedAndTheSyncGoesOn() async throws {
    let a = try await FileArchive([list(["e1"]), attachmentDetail("e1", [[signedLink("1.png")]])])  // no file replies: it throws
    let manifest = await a.sync()
    #expect(manifest.outcome == .completed && manifest.attachmentsFailed == 1 && a.downloads.isEmpty)
    #expect(manifest.warnings == ["attachment request failed before a response"])
}

@Test func aRefreshDownloadsItsConversationsFiles() async throws {
    let a = try await FileArchive([list(["e1"]), attachmentDetail("e1", [])])
    #expect(await a.sync().outcome == .completed)
    let manifest = await a.refresh("e1", [attachmentDetail("e1", [[signedLink("late.png")]])], files: [file("late")])
    #expect(manifest.outcome == .completed && manifest.attachmentsStored == 1)
    #expect(a.downloads.first?.envelope.jobID == manifest.jobID)
}

@Test func aFileThatCannotBeStoredIsKeptInTheJournalAndStopsTheJob() async throws {
    let a = try await FileArchive([list(["e1", "e2"]), attachmentDetail("e1", [[signedLink("1.png")]])], files: [file("the bytes")])
    // Something that isn't a folder where the object store goes.
    try FileManager.default.createDirectory(at: a.objects.root.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("in the way".utf8).write(to: a.objects.root)
    let manifest = await a.sync()
    #expect(manifest.outcome == .storageFailed && manifest.reason == "attachment file could not be stored")
    #expect(manifest.attachmentsStored == 0 && manifest.attachmentsFailed == 1)
    // The response is not lost: its body is the record's payload, and no record names a file.
    let record = try #require(a.downloads.first)
    #expect(a.downloads.count == 1)
    #expect(record.envelope.metadata["outcome"] == .string("not_stored") && record.envelope.metadata["status"] == .integer(200))
    #expect(record.payload == Data("the bytes".utf8) && record.envelope.payloadRepresentation == "foundation_decoded_entity")
    #expect(record.envelope.metadata["object_sha256"] == nil)
    #expect(!a.session.paths.contains("/api/evaluation/e2"), "nothing else is requested")
    #expect(a.records.last?.envelope.kind == JournalKind.jobFinished)
    let key = try #require(AttachmentLink.parse(signedLink("1.png"))).objectKey
    #expect(ArenaArchiveDecoder().decode(record, account: a.account).events
        == [.attachmentDownload(AttachmentDownload(objectKey: key, outcome: .notStored, status: 200, contentType: "image/png"))])
}

@Test func aRedirectsSignedQueryIsNotJournaled() async throws {
    let redirect = HTTPExchange(
        status: 302, headers: ["Location": signedLink("moved.png"), "content-location": "https://elsewhere.invalid/a?token=1",
                               "Content-Type": "text/plain"],
        body: Data())
    let a = try await FileArchive([list(["e1"]), attachmentDetail("e1", [[signedLink("1.png")]])], files: [redirect])
    let manifest = await a.sync()
    #expect(manifest.outcome == .completed && manifest.attachmentsFailed == 1)
    #expect(a.files.requests.count == 1, "never followed")
    let record = try #require(a.downloads.first)
    #expect(record.envelope.metadata["outcome"] == .string("unavailable"))
    guard case .object(let headers) = record.envelope.metadata["response_headers"] else { throw CocoaError(.coderInvalidValue) }
    #expect(headers["Location"] == .string("https://messages-prod.0123abcd.r2.cloudflarestorage.com/f00d/moved.png?[omitted]"))
    #expect(headers["content-location"] == .string("https://elsewhere.invalid/a?[omitted]"))
    #expect(record.envelopeBytes.range(of: Data("X-Amz-Signature".utf8)) == nil)
    #expect(record.envelopeBytes.range(of: Data("X-Amz-Credential".utf8)) == nil)
    #expect(record.envelope.transformations.contains("signed_query_omitted"))
}

/// Advances one second on every sleep (the job's spacing).
private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = fixtureNow
    var now: Date { lock.withLock { current } }
    func step() { lock.withLock { current += 1 } }
}

@Test(arguments: [("8", false), ("9", true)])
func aLinkThatExpiresDuringTheSpacingIsNotRequested(expires: String, requested: Bool) async throws {
    // The list and the detail each wait once (10:00:07 when the link is checked); the download's own
    // wait brings the clock to 10:00:08. Signed at 10:00:00, the link ends at 10:00:08 or 10:00:09.
    var a = try await FileArchive([list(["e1"]), attachmentDetail("e1", [[signedLink("1.png", expires: expires)]])], files: [file("x")])
    let clock = SteppingClock()
    a.sleep = { _ in clock.step() }
    a.now = { clock.now }
    let manifest = await a.sync()
    #expect(manifest.outcome == .completed)
    #expect(a.files.requests.count == (requested ? 1 : 0))
    #expect(manifest.attachmentsExpired == (requested ? 0 : 1) && manifest.attachmentsStored == (requested ? 1 : 0))
}

// MARK: - Decoder and index

@Test func theLinkRuleKeepsTheKeyAndLifetime() throws {
    let parsed = try #require(AttachmentLink.parse(signedLink("one.png")))
    #expect(parsed.objectKey == "https://messages-prod.0123abcd.r2.cloudflarestorage.com/f00d/one.png")
    #expect(parsed.expiresAt.map(AttachmentLink.timestamp) == "2026-10-20T11:00:00Z")
    #expect(AttachmentLink.parse(signedLink("x.png", signedAt: "2026-10-20T10:00:00Z"))?.expiresAt == nil)
    #expect(AttachmentLink.parse(signedLink("x.png", expires: "999999999"))?.expiresAt == nil)
    #expect(AttachmentLink.parse(signedLink("x.png", signedAt: "20261320T100000Z"))?.expiresAt == nil)
    #expect(AttachmentLink.parse("https://MESSAGES-PROD.X.R2.CLOUDFLARESTORAGE.COM/a/b.png")?.objectKey
        == "https://messages-prod.x.r2.cloudflarestorage.com/a/b.png")
    for bad in ["https://messages-prod.x.r2.cloudflarestorage.com/", "https://messages-prod.x.r2.cloudflarestorage.com",
                "ftp://messages-prod.x.r2.cloudflarestorage.com/a", "https://x.r2.cloudflarestorage.com.evil.com/a", "not a url"] {
        #expect(AttachmentLink.parse(bad) == nil, "\(bad)")
    }
}

@Test func attachmentsAreNumberedAsTheDecoderNumbersThem() throws {
    let body = Data(#"""
        {"id":"e1","messages":[
          {"id":"m1","experimental_attachments":[7,{"url":"u1"},{"name":"n"},{"url":"u2"}]},
          {"content":"no id","experimental_attachments":[{"url":"skipped"}]},
          {"id":"m1","experimental_attachments":[{"url":"duplicate"}]},
          "not a message",
          {"id":"m2","experimental_attachments":{"url":"not an array"}},
          {"id":"m3","experimental_attachments":[{"url":"u3"}]}]}
        """#.utf8)
    #expect(AttachmentLink.located(in: body) == [
        .init(messageID: "m1", ordinal: 0, link: "u1"), .init(messageID: "m1", ordinal: 1, link: nil),
        .init(messageID: "m1", ordinal: 2, link: "u2"), .init(messageID: "m3", ordinal: 0, link: "u3"),
    ])
    let record = try testRecord(kind: "exchange", payload: body, metadata: [
        "role": .string("detail"), "status": .integer(200), "transfer_end": .string("complete"), "entry_id": .string("e1"),
    ])
    let decoded = ArenaArchiveDecoder().decode(record, account: AccountID())
    guard case .snapshot(let snapshot) = decoded.events.first else { Issue.record("no snapshot"); return }
    #expect(snapshot.messages.map { $0.attachments.count } == [3, 0, 1])
}

@Test func syncedFilesShowInTheIndexForEverySnapshotWithTheirKey() async throws {
    let a = try await FileArchive(
        [list(["e1"]), attachmentDetail("e1", [[signedLink("one.png"), signedLink("gone.png"), "https://elsewhere.example/x.png", nil]])],
        files: [file("bytes"), file("<Error/>", type: "application/xml", status: 404)])
    _ = await a.sync()
    // A later snapshot with the same key (nothing downloaded) shows the stored file too.
    _ = await a.refresh("e1", [attachmentDetail("e1", [[signedLink("one.png", signedAt: "20261020T100004Z")]])])

    let index = try ArchiveIndex(url: a.root.appendingPathComponent("index/archive.sqlite"))
    let archive = ArchiveService(index: index, journals: a.journals, decoder: ArenaArchiveDecoder(), accounts: { [a.account] })
    _ = try await archive.project(a.account)
    let latest = try #require(try archive.conversation(account: a.account, remoteID: "e1"))
    let stored = try #require(latest.messages.first?.attachments.first)
    #expect(stored.objectKey == "https://messages-prod.0123abcd.r2.cloudflarestorage.com/f00d/one.png")
    #expect(stored.linkExpiresAt == "2026-10-20T11:00:04Z")
    #expect(stored.file?.download.outcome == .stored && stored.file?.download.sha256 == hex(Data("bytes".utf8)))
    #expect(stored.file?.download.size == 5 && stored.file?.download.contentType == "image/png")

    #expect(latest.snapshotSequences.count == 2)
    let first = try #require(try archive.conversation(account: a.account, remoteID: "e1", snapshot: latest.snapshotSequences.min()))
    let attachments = try #require(first.messages.first?.attachments)
    #expect(attachments.map { $0.file?.download.outcome } == [.stored, .unavailable, nil, nil])
    #expect(attachments[1].file?.download.status == 404)
    #expect(attachments[2].hasURL && attachments[2].objectKey == nil, "a link downloads don't accept")
    #expect(!attachments[3].hasURL)
    #expect(try archive.attachmentData(account: a.account, sha256: hex(Data("bytes".utf8))) == Data("bytes".utf8))

    // The same journal replays to the same index.
    let check = try await archive.checkAgainstJournal(scratch: a.root.appendingPathComponent("scratch"))
    #expect(check.matches)
}

@Test func aDownloadRecordThatDoesntNameItsFileIsAWarning() throws {
    let decoder = ArenaArchiveDecoder()
    func decode(_ metadata: [String: JournalValue]) throws -> [ArchiveEvent] {
        decoder.decode(try testRecord(kind: "attachment.download", payload: Data(), metadata: metadata), account: AccountID()).events
    }
    let key: JournalValue = .string("https://messages-prod.x.r2.cloudflarestorage.com/a/b.png")
    #expect(try decode(["object_key": key, "outcome": .string("stored")]) == [.warning(code: "download_unrecognized", detail: "stored file not named")])
    #expect(try decode(["object_key": key, "outcome": .string("teleported")]) == [.warning(code: "download_unrecognized", detail: "attachment.download")])
    #expect(try decode(["object_key": key, "outcome": .string("denied"), "status": .integer(403)])
        == [.attachmentDownload(AttachmentDownload(objectKey: "https://messages-prod.x.r2.cloudflarestorage.com/a/b.png", outcome: .denied, status: 403))])
}


// MARK: - Verify and backup

private func folder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A synced archive with two stored files, in the account registry.
private func archiveWithFiles() async throws -> FileArchive {
    let a = try await FileArchive(
        [list(["e1"]), attachmentDetail("e1", [[signedLink("one.png"), signedLink("two.png")]])],
        files: [file("first image"), file("second image")])
    #expect(await a.sync().attachmentsStored == 2)
    try AccountRegistryStore(url: a.root.appendingPathComponent("accounts/registry.json")).save([a.record])
    return a
}

private func backups(_ root: URL) -> BackupService {
    BackupService(archiveRoot: root, decoder: ArenaArchiveDecoder(), appVersion: "test")
}

private func verify(_ a: FileArchive) async throws -> VerificationReport {
    let index = try ArchiveIndex(url: a.root.appendingPathComponent("index/archive.sqlite"))
    let account = a.account
    let archive = ArchiveService(index: index, journals: a.journals, decoder: ArenaArchiveDecoder(), accounts: { [account] })
    _ = try await archive.project(account)
    return await VerificationService(
        archive: archive, journals: a.journals, accounts: { [account] }, scratch: try folder()
    ).run()
}

private func rewriteManifest(_ backup: URL, _ change: (inout [String: Any]) -> Void) throws {
    let url = backup.appendingPathComponent("backup-manifest.json")
    var manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    change(&manifest)
    try JSONSerialization.data(withJSONObject: manifest).write(to: url)
}

@Test func verifyChecksEveryFileARecordNames() async throws {
    let a = try await archiveWithFiles()
    let clean = try await verify(a)
    #expect(clean.isClean && clean.journals.first?.objects == 2)

    let names = try a.objects.names()
    try Data("tampered".utf8).write(to: try #require(a.objects.url(for: names[0])))
    try FileManager.default.removeItem(at: try #require(a.objects.url(for: names[1])))
    let report = try await verify(a)
    #expect(!report.isClean)
    let sequences = a.downloads.map(\.envelope.sequence)
    let issues = try #require(report.journals.first?.issues)
    #expect(issues.count == 2)
    #expect(issues.allSatisfy { $0.hasPrefix("record ") && ($0.hasSuffix("is missing") || $0.hasSuffix("bytes differ")) })
    #expect(Set(issues.compactMap { $0.split(separator: " ").dropFirst().first.flatMap { UInt64($0) } }) == Set(sequences))
    #expect(try a.objects.names().count == 1, "verify repairs nothing")
}

@Test func aBackupHoldsTheFilesAndRestoresThem() async throws {
    let a = try await archiveWithFiles()
    let backup = try await backups(a.root).create(in: try folder())
    let account = a.account.rawValue.uuidString
    let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: backup.appendingPathComponent("backup-manifest.json")))
    #expect(manifest.format == "arena-suite-backup/2")
    let listed = try #require(manifest.journals.first?.objects)
    #expect(listed.map(\.sha256) == (try a.objects.names()))
    #expect(listed.map(\.size).sorted() == ["first image", "second image"].map { $0.utf8.count }.sorted())
    for object in listed {
        let copy = backup.appendingPathComponent("accounts/\(account)/objects/sha256/\(object.sha256)")
        #expect(try Data(contentsOf: copy) == a.objects.read(object.sha256))
    }
    let check = try await backups(a.root).check(backup)
    #expect(check.objects == 2 && check.digestCompared)

    let target = try folder()
    let restored = try await backups(target).restore(from: backup)
    #expect(restored.objects == 2)
    let objects = JournalStore(archiveRoot: target).objects(for: a.account)
    for object in listed { #expect(try objects.read(object.sha256).count == object.size) }
    let restoredIndex = try ArchiveIndex(url: target.appendingPathComponent("index/archive.sqlite"))
    let archive = ArchiveService(
        index: restoredIndex, journals: JournalStore(archiveRoot: target), decoder: ArenaArchiveDecoder(), accounts: { [a.account] })
    try await archive.rebuild()
    let shown = try #require(try archive.conversation(account: a.account, remoteID: "e1")?.messages.first?.attachments)
    #expect(shown.allSatisfy { $0.file?.download.outcome == .stored })
    #expect(try archive.attachmentData(account: a.account, sha256: listed[0].sha256).count == listed[0].size)
}

@Test func aDamagedOrMissingFileRefusesTheBackup() async throws {
    let a = try await archiveWithFiles()
    let out = try folder()
    let first = try #require(a.downloads.first?.envelope)
    guard case .string(let name) = try #require(first.metadata[ObjectStore.digestKey]) else { throw CocoaError(.coderInvalidValue) }
    let file = try #require(a.objects.url(for: name))
    let bytes = try Data(contentsOf: file)
    let account = a.account.rawValue.uuidString
    try Data("tampered".utf8).write(to: file)
    await #expect(throws: BackupError.objectDamaged(account: account, issue: "record \(first.sequence) names a file whose bytes differ")) {
        try await backups(a.root).create(in: out)
    }
    try FileManager.default.removeItem(at: file)
    await #expect(throws: BackupError.objectDamaged(account: account, issue: "record \(first.sequence) names a file that is missing")) {
        try await backups(a.root).create(in: out)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty, "nothing left behind")
    try bytes.write(to: file)
    _ = try await backups(a.root).create(in: out)
}

@Test func aFileNoRecordNamesIsLeftOutOfTheBackup() async throws {
    let a = try await archiveWithFiles()
    let named = try a.objects.names()
    // Stored before its record could be written (the app stopped): nothing names it, damaged or not.
    let orphan = try a.objects.put(Data("never recorded".utf8))
    try Data("tampered".utf8).write(to: try #require(a.objects.url(for: orphan.sha256)))
    let backup = try await backups(a.root).create(in: try folder())
    let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: backup.appendingPathComponent("backup-manifest.json")))
    #expect(manifest.journals.first?.objects?.map(\.sha256) == named)
    let copied = ObjectStore(root: backup.appendingPathComponent("accounts/\(a.account.rawValue.uuidString)/objects"))
    #expect(try copied.names() == named)
    #expect(try await backups(a.root).check(backup).objects == 2)
}

@Test func aChangedOrMissingFileInABackupIsRefused() async throws {
    let a = try await archiveWithFiles()
    let backup = try await backups(a.root).create(in: try folder())
    let name = try #require(try a.objects.names().first)
    let path = "accounts/\(a.account.rawValue.uuidString)/objects/sha256/\(name)"
    let copy = backup.appendingPathComponent(path)
    let bytes = try Data(contentsOf: copy)
    try Data("changed".utf8).write(to: copy)
    await #expect(throws: BackupError.fileMismatch("changed \(path)")) { try await backups(a.root).check(backup) }
    await #expect(throws: BackupError.fileMismatch("changed \(path)")) { try await backups(try folder()).restore(from: backup) }
    try FileManager.default.removeItem(at: copy)
    await #expect(throws: BackupError.fileMismatch("missing \(path)")) { try await backups(a.root).check(backup) }

    // Listed in neither the manifest nor the journal: refused as an extra file.
    try bytes.write(to: copy)
    try rewriteManifest(backup) { manifest in
        var journals = manifest["journals"] as! [[String: Any]]
        journals[0]["objects"] = (journals[0]["objects"] as! [[String: Any]]).filter { $0["sha256"] as? String != name }
        manifest["journals"] = journals
    }
    await #expect(throws: BackupError.fileMismatch("unexpected \(path)")) { try await backups(a.root).check(backup) }
    // Left out of the manifest and the folder, while a record names it: refused.
    try FileManager.default.removeItem(at: copy)
    await #expect {
        try await backups(a.root).check(backup)
    } throws: { error in
        guard case BackupError.objectDamaged(_, let issue) = error else { return false }
        return issue.hasSuffix("is missing")
    }
}

@Test func aBackupThatListsAFileNoRecordNamesIsRefused() async throws {
    let a = try await archiveWithFiles()
    let backup = try await backups(a.root).create(in: try folder())
    let extra = Data("not named by any record".utf8)
    let name = SHA256.hash(data: extra).map { String(format: "%02x", $0) }.joined()
    let path = "accounts/\(a.account.rawValue.uuidString)/objects/sha256/\(name)"
    try extra.write(to: backup.appendingPathComponent(path))
    try rewriteManifest(backup) { manifest in
        var journals = manifest["journals"] as! [[String: Any]]
        journals[0]["objects"] = (journals[0]["objects"] as! [[String: Any]]) + [["sha256": name, "size": extra.count]]
        manifest["journals"] = journals
    }
    await #expect(throws: BackupError.fileMismatch("unnamed \(path)")) { try await backups(a.root).check(backup) }
    await #expect(throws: BackupError.fileMismatch("unnamed \(path)")) { try await backups(try folder()).restore(from: backup) }
}

@Test func aListedSizeThatDiffersIsRefusedByCheckAsByRestore() async throws {
    let a = try await archiveWithFiles()
    let backup = try await backups(a.root).create(in: try folder())
    var name = ""
    try rewriteManifest(backup) { manifest in
        var journals = manifest["journals"] as! [[String: Any]]
        var objects = journals[0]["objects"] as! [[String: Any]]
        name = objects[0]["sha256"] as! String
        objects[0]["size"] = (objects[0]["size"] as! Int) + 1
        journals[0]["objects"] = objects
        manifest["journals"] = journals
    }
    let path = "accounts/\(a.account.rawValue.uuidString)/objects/sha256/\(name)"
    await #expect(throws: BackupError.fileMismatch("size of \(path)")) { try await backups(a.root).check(backup) }
    await #expect(throws: BackupError.fileMismatch("size of \(path)")) { try await backups(try folder()).restore(from: backup) }
}

@Test func aLinkedFolderInABackupIsRefused() async throws {
    let a = try await archiveWithFiles()
    let backup = try await backups(a.root).create(in: try folder())
    try FileManager.default.createSymbolicLink(
        at: backup.appendingPathComponent("accounts/elsewhere"), withDestinationURL: try folder())
    await #expect(throws: BackupError.fileMismatch("not a regular file: elsewhere")) { try await backups(a.root).check(backup) }
}

@Test func verifyChecksTheFilesOfAJournalThatEndsInATornRecord() async throws {
    let a = try await archiveWithFiles()
    let name = try #require(try a.objects.names().first)
    try FileManager.default.removeItem(at: try #require(a.objects.url(for: name)))
    let segment = a.journals.root(for: a.account).appendingPathComponent("segments/000001.asj")
    let handle = try FileHandle(forWritingTo: segment)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("ASJ1 torn".utf8))
    try handle.close()
    let check = try #require(try await verify(a).journals.first)
    #expect(check.issues.count == 2)
    #expect(check.issues.contains { $0.hasSuffix("names a file that is missing") })
    #expect(check.objects == 2)
}

@Test func aVersion1BackupStillChecksAndRestores() async throws {
    let source = try await MaintenanceArchive(conversations: 2)
    let backup = try await source.backups.create(in: try folder())
    try rewriteManifest(backup) { manifest in
        manifest["format"] = "arena-suite-backup/1"
        manifest["journals"] = (manifest["journals"] as! [[String: Any]]).map { journal in
            var journal = journal
            journal["objects"] = nil
            return journal
        }
    }
    let check = try await source.backups.check(backup)
    #expect(check.objects == 0 && check.digestCompared)
    let target = try folder()
    #expect(try await backups(target).restore(from: backup).accounts == 2)

    try rewriteManifest(backup) { manifest in
        manifest["journals"] = (manifest["journals"] as! [[String: Any]]).map { journal in
            var journal = journal
            journal["objects"] = []
            return journal
        }
    }
    await #expect(throws: BackupError.fileMismatch("objects in a arena-suite-backup/1 backup")) { try await source.backups.check(backup) }
}

@Test func anotherDecodersDigestIsNotComparedButTheSameDecodersIs() async throws {
    let a = try await archiveWithFiles()
    let backup = try await backups(a.root).create(in: try folder())
    try rewriteManifest(backup) { $0["replay_digest"] = String(repeating: "0", count: 64) }
    await #expect(throws: BackupError.replayMismatch) { try await backups(a.root).check(backup) }

    try rewriteManifest(backup) { $0["decoder_version"] = "arena-decoder/2" }
    let check = try await backups(a.root).check(backup)
    #expect(!check.digestCompared && check.records == a.records.count && check.objects == 2)
    let restored = try await backups(try folder()).restore(from: backup)
    #expect(!restored.digestCompared)
}

// In the serialized suite: its tests check that no plain copy is left in the temporary folder,
// which an encrypted backup running beside them would briefly create.
extension EncryptedBackupTests {
    @Test func anEncryptedBackupCarriesTheFiles() async throws {
        let a = try await archiveWithFiles()
        let passphrase = "synthetic passphrase for tests"
        let file = try await backups(a.root).createEncrypted(in: try folder(), passphrase: passphrase)
        #expect(try await backups(a.root).checkEncrypted(file, passphrase: passphrase).objects == 2)
        let target = try folder()
        #expect(try await backups(target).restoreEncrypted(from: file, passphrase: passphrase).objects == 2)
        let objects = JournalStore(archiveRoot: target).objects(for: a.account)
        #expect(try objects.names() == a.objects.names())
        for name in try objects.names() { #expect(try objects.read(name) == a.objects.read(name)) }
    }
}
