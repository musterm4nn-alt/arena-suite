import Foundation
import Testing

@testable import NativeAuthResearch

/// Synthetic page shaped like arena-exporter's lead: flight chunks holding a `{"messages":[…]}` object.
@Test func theInspectorFindsTheTranscriptInFlightChunks() throws {
    let transcript = #"{"messages":[{"id":"m1","role":"user","parts":[{"type":"text","text":"hi {not json"}]},{"id":"m2","role":"assistant","parts":[{"type":"text","text":"ok"},{"type":"tool-call","toolName":"x"}]}],"id":"s"}"#
    // Each chunk is its own JS string literal, so the transcript is split before escaping.
    func escaped(_ part: Substring) throws -> Substring {
        String(data: try JSONEncoder().encode(String(part)), encoding: .utf8)!.dropFirst().dropLast()
    }
    let half = transcript.index(transcript.startIndex, offsetBy: 40)
    let first = try escaped(transcript[..<half])
    let second = try escaped(transcript[half...])
    let html = """
        <html><script>self.__next_f.push([1,"\(first)"])</script>\
        <script>self.__next_f.push([1,"\(second)"])</script>\
        <script>fetch("/api/agent/0f8fad5b-d9cb-469f-a165-70867728950e/workspace/latest")</script></html>
        """
    let page = AgentPageInspector.inspect(Data(html.utf8))
    #expect(page.flightChunks == 2)
    #expect(page.flightChunksUndecodable == 0)
    #expect(page.messageObjectsFound == 1)
    #expect(page.transcriptKeys == ["id", "messages"])
    #expect(page.messages == 2)
    #expect(page.roleCounts == ["assistant": 1, "user": 1])
    #expect(page.partTypeCounts == ["text": 2, "tool-call": 1])
    #expect(page.partKeysByType["tool-call"] == ["toolName", "type"])
    #expect(page.apiPaths == ["/api/agent/{id}/workspace/latest"])
    #expect(page.mentionsWorkspace)
    #expect(!page.mentionsRealtimeSession)
}

@Test func aPageWithoutATranscriptReportsNone() {
    let page = AgentPageInspector.inspect(Data(#"<html>{"messages":[1,2] and {"messages":[{"x":1}]}</html>"#.utf8))
    #expect(page.flightChunks == 0)
    #expect(page.messageObjectsFound == 0)
    #expect(page.messages == 0)
}

@Test func anUnclosedObjectStopsTheScan() {
    let page = AgentPageInspector.inspect(Data(#"{"messages":[{"role":"user""#.utf8))
    #expect(page.messageObjectsFound == 0)
}
