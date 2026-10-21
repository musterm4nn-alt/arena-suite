import ApplicationActions
import CaptureJournal
import Foundation
import FoundationTransport
import SuiteDomain
import Testing

@testable import ArenaAdapter

// Agent conversations' pages (N-022, Docs/agent-detail-2026-10-21.md). Synthetic pages shaped like
// the observed one: HTML whose flight chunks hold the transcript object.

let agentToken = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0LW9ubHkifQ.c2lnbmF0dXJlLXRlc3Q"

/// A synthetic agent page for `id`. The transcript is split across two flight chunks; `extraPart`
/// adds one part to the assistant message.
func agentPage(
    _ id: String, triggerAddress: String? = nil, hasMore: Bool = false, extraPart: String? = nil, extraTopKey: Bool = false
) -> Data {
    let parts = [
        #"{"type":"step-start"}"#,
        #"{"type":"reasoning","text":"private thinking","state":"done"}"#,
        #"{"type":"tool-write_file","toolCallId":"call1","state":"output-available","input":{"path":"a.txt"},"output":{"ok":true}}"#,
        #"{"type":"text","text":"private answer","state":"done"}"#,
    ] + (extraPart.map { [$0] } ?? [])
    let transcript =
        #"{"taskId":"task-1","triggerAddress":"\#(triggerAddress ?? id)","messages":["#
        + #"{"id":"u1","metadata":{"pending":false},"role":"user","parts":[{"type":"text","text":"private prompt"}]},"#
        + #"{"id":"r1","metadata":{"timing":{}},"role":"assistant","parts":[\#(parts.joined(separator: ","))]}],"#
        + #""pagination":{"hasMore":\#(hasMore),"cursor":null,"limit":20},"transcriptReadStrategy":"bounded","#
        + #""session":{"publicAccessToken":"\#(agentToken)","lastEventId":"12","taskId":"task-1","triggerAddress":"\#(id)"},"#
        + #""productMode":"chat"\#(extraTopKey ? #","newKey":1"# : "")}"#
    let row = "2f:" + transcript + "\n"
    func literal(_ text: Substring) -> String {
        String(data: try! JSONEncoder().encode(String(text)), encoding: .utf8)!
    }
    let half = row.index(row.startIndex, offsetBy: row.count / 2)
    let html =
        #"<!DOCTYPE html><html><head><script src="/cdn-cgi/challenge-platform/scripts/jsd/main.js"></script></head><body>"#
        + #"<script>self.__next_f.push([1,"0:[\"$\",\"div\",null,{}]\n"])</script>"#
        + "<script>self.__next_f.push([1,\(literal(row[..<half]))])</script>"
        + "<script>self.__next_f.push([1,\(literal(row[half...]))])</script></body></html>"
    return Data(html.utf8)
}

func agentReply(_ body: Data, status: Int = 200) -> HTTPExchange {
    HTTPExchange(status: status, headers: ["Content-Type": "text/html; charset=utf-8"], body: body)
}

// MARK: - Page

@Test func tokensAreReplacedAndEveryOtherByteKept() throws {
    let page = agentPage("a1")
    let cleaned = AgentPage.withoutTokens(page)
    #expect(cleaned.omitted == 1)
    #expect(cleaned.body.range(of: Data(agentToken.utf8)) == nil)
    let expected = String(decoding: page, as: UTF8.self).replacingOccurrences(of: agentToken, with: "[omitted]")
    #expect(cleaned.body == Data(expected.utf8))
    // Not tokens: too short, no three segments, or `eyJ` inside a longer word.
    for text in ["eyJabc.def.ghi", "eyJaaaaaaaaaa.bbbbbbbbbb", "xeyJaaaaaaaaaa.bbbbbbbbbb.cccccccccc"] {
        #expect(AgentPage.withoutTokens(Data(text.utf8)) == (Data(text.utf8), 0))
    }
    // Bytes that aren't UTF-8 survive.
    let binary = Data([0xFF, 0xFE]) + Data(agentToken.utf8) + Data([0x00])
    #expect(AgentPage.withoutTokens(binary) == (Data([0xFF, 0xFE]) + AgentPage.omitted + Data([0x00]), 1))
}

@Test func theTranscriptIsFoundAcrossChunksAndMustNameTheConversation() throws {
    let transcript = try #require(AgentPage.transcript(agentPage("a1")))
    #expect((transcript["messages"] as? [Any])?.count == 2)
    #expect(AgentPage.isValid(agentPage("a1"), id: "a1"))
    #expect(!AgentPage.isValid(agentPage("a1"), id: "a2"))
    #expect(!AgentPage.isValid(agentPage("a1", triggerAddress: "other"), id: "a1"))
    // Without its token, the page is still the same snapshot.
    #expect(AgentPage.isValid(AgentPage.withoutTokens(agentPage("a1")).body, id: "a1"))
    #expect(AgentPage.transcript(Data("<html>no chunks</html>".utf8)) == nil)
    #expect(AgentPage.transcript(Data(#"<script>self.__next_f.push([1,"bad \u12"])</script>"#.utf8)) == nil)
    // An ordinary page loads a `challenge-platform` script; that alone is no challenge.
    #expect(!AgentPage.looksLikeChallenge(agentPage("a1")))
    #expect(AgentPage.looksLikeChallenge(Data("<title>Just a moment...</title>".utf8)))
}

// MARK: - Decoder

private func decode(_ payload: Data, id: String = "a1", status: Int = 200) throws -> DecodedRecord {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
    let writer = try JournalWriter.open(at: root, options: JournalOptions(durability: .fsync))
    _ = try writer.append(
        JournalDraft(
            kind: "exchange", payload: payload, accountID: AccountID().rawValue,
            metadata: [
                "role": .string("agent_detail"), "status": .integer(Int64(status)), "transfer_end": .string("complete"),
                "entry_id": .string(id), "entry_type": .string("agentic"),
            ]))
    try writer.synchronize()
    let record = try #require(try JournalReader(root: root).readAll().last)
    return ArenaArchiveDecoder().decode(record, account: AccountID())
}

@Test func anAgentPageDecodesIntoMessagesAndBlocks() throws {
    let decoded = try decode(AgentPage.withoutTokens(agentPage("a1", extraPart: #"{"type":"data-thing","x":1}"#)).body)
    guard case .snapshot(let snapshot) = try #require(decoded.events.first) else {
        Issue.record("no snapshot")
        return
    }
    #expect(snapshot.facts.remoteID == "a1" && snapshot.facts.kind == "agentic" && snapshot.facts.title == nil)
    #expect(snapshot.messages.map(\.remoteID) == ["u1", "r1"])
    #expect(snapshot.messages.map(\.role) == ["user", "assistant"])
    #expect(snapshot.messages.allSatisfy { $0.lane == nil && $0.parentIDs.isEmpty })
    #expect(snapshot.messages[0].blocks == [ArchivedBlock(kind: .text, text: "private prompt", pointer: "agent:$.messages[].parts[0]")])
    let blocks = snapshot.messages[1].blocks
    #expect(blocks.map(\.kind) == [.reasoning, .toolCall, .toolResult, .text, .opaque], "step-start is not projected")
    #expect(blocks[1].toolName == "write_file" && blocks[1].toolCallID == "call1" && blocks[1].payload == #"{"path":"a.txt"}"#)
    #expect(blocks[2].toolName == "write_file" && blocks[2].payload == #"{"ok":true}"#)
    #expect(blocks[4].payload == #"{"type":"data-thing","x":1}"#)
    #expect(decoded.unknownFields == ["agent:$.messages[].parts[].x": 1])
    #expect(decoded.events.count == 1, "no warnings for a complete first page")
}

@Test func driftAndPartialTranscriptsAreReportedNotGuessed() throws {
    let partial = try decode(agentPage("a1", hasMore: true, extraTopKey: true))
    #expect(partial.events.contains(.warning(code: "agent_transcript_partial", detail: "agent:$.pagination.hasMore ×1")))
    #expect(partial.unknownFields == ["agent:$.newKey": 1])

    let other = try decode(agentPage("a1", triggerAddress: "zz"))
    #expect(other.events == [.warning(code: "agent_page_unrecognized", detail: "agent:$.triggerAddress ×1")])
    let html = try decode(Data("<html></html>".utf8))
    #expect(html.events == [.warning(code: "agent_page_unrecognized", detail: "agent:$ ×1")])
    #expect(try decode(Data(), status: 404).events == [.absent(remoteID: "a1")])
}
