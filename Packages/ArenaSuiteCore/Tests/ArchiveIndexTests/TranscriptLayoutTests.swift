import ApplicationActions
import ArchiveIndex
import Foundation
import SuiteDomain
import Testing

private func msg(_ id: String, _ role: String?, lane: String? = nil, parents: [String] = []) -> DetailMessage {
    DetailMessage(remoteID: id, role: role, status: "success", lane: lane, parentIDs: parents, modelRemoteID: nil, createdAt: nil, blocks: [], attachments: [])
}

private func detail(_ messages: [DetailMessage], feedback: [ArchivedFeedback] = []) -> ConversationDetail {
    ConversationDetail(
        summary: ConversationSummary(
            account: AccountID(), remoteID: "c", kind: "evaluation", title: nil, mode: nil, modality: nil, updatedAt: nil,
            snapshotCount: 1, latestSnapshotSequence: 1, messageCount: messages.count, isAbsent: false),
        snapshotSequences: [1], messages: messages, claims: [], feedback: feedback)
}

@Test func battleTurnsKeepLanesSeparateAndInOrder() {
    let layout = TranscriptLayout(detail([
        msg("u1", "user"), msg("a1", "assistant", lane: "a", parents: ["u1"]), msg("b1", "assistant", lane: "b", parents: ["u1"]),
        msg("u2", "user", parents: ["a1"]), msg("b2", "assistant", lane: "b", parents: ["u2"]), msg("a2", "assistant", lane: "a", parents: ["u2"]),
    ]))
    #expect(layout.turns.map(\.id) == ["u1", "u2"])
    #expect(layout.turns[0].lanes.map(\.lane) == ["a", "b"])
    #expect(layout.turns[1].lanes.map(\.lane) == ["b", "a"], "lane order follows arrival, never merged")
    #expect(layout.turns.allSatisfy { $0.lanes.allSatisfy { $0.messages.count == 1 && $0.messages[0].otherParents.isEmpty } })
}

@Test func regenerationsAreFlaggedAndForeignParentsMarked() {
    let layout = TranscriptLayout(detail([
        msg("u1", "user"), msg("a1", "assistant", lane: "a", parents: ["u1"]), msg("a1b", "assistant", lane: "a", parents: ["a1"]),
    ]))
    let lane = layout.turns[0].lanes[0]
    #expect(lane.hasAlternatives)
    #expect(lane.messages.map(\.otherParents) == [[], ["a1"]])
}

@Test func unknownRolesAndUnlanedResponsesAreNeverBattleLanes() {
    let layout = TranscriptLayout(detail([
        msg("s0", nil), msg("u1", "user"), msg("x1", "assistant"), msg("t1", "tool"), msg("a1", "assistant", lane: "a"),
    ]))
    #expect(layout.turns.count == 2)
    #expect(layout.turns[0].prompt == nil && layout.turns[0].otherRoles.map(\.remoteID) == ["s0"])
    #expect(layout.turns[1].otherRoles.map(\.remoteID) == ["t1"])
    #expect(layout.turns[1].lanes.map(\.lane) == [nil, "a"], "an unexposed lane is its own column, not a battle lane")
}

@Test func votesAttachOnlyToTheTurnContainingAllTheirMessages() {
    let inside = ArchivedFeedback(remoteID: "v1", value: "a", messageA: "a1", messageB: "b1")
    let spanning = ArchivedFeedback(remoteID: "v2", value: "tie", messageA: "a1", messageB: "b2")
    let empty = ArchivedFeedback(remoteID: "v3", value: nil, messageA: nil, messageB: nil)
    let layout = TranscriptLayout(detail([
        msg("u1", "user"), msg("a1", "assistant", lane: "a"), msg("b1", "assistant", lane: "b"),
        msg("u2", "user"), msg("b2", "assistant", lane: "b"),
    ], feedback: [inside, spanning, empty]))
    #expect(layout.turns[0].votes == [inside])
    #expect(layout.turns[1].votes.isEmpty)
    #expect(layout.unmatchedVotes == [spanning, empty])
}

@Test func everyMessageAppearsExactlyOnce() {
    let messages = [msg("s", "system"), msg("a0", "assistant"), msg("u1", "user"), msg("a1", "assistant", lane: "a"), msg("q", nil)]
    let layout = TranscriptLayout(detail(messages))
    let shown = layout.turns.flatMap { turn in
        [turn.prompt?.remoteID].compactMap { $0 } + turn.lanes.flatMap { $0.messages.map(\.message.remoteID) } + turn.otherRoles.map(\.remoteID)
    }
    #expect(shown.sorted() == messages.map(\.remoteID).sorted())
}
