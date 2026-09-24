import ArchiveIndex
import Foundation
import SuiteDomain

/// Arranges one snapshot's messages for display without inventing structure (plan v3 §5, §8):
/// - a turn starts at each `user` message;
/// - only `assistant` messages go into lanes, keyed by the exposed lane value; a response whose lane
///   is not exposed goes into an explicitly labeled column, never into a battle lane;
/// - messages with a missing or other role are listed separately, never shown as responses;
/// - lanes are never merged; replies to something other than the turn's prompt are marked;
/// - a vote belongs to a turn only if every message it references is in that turn.
public struct TranscriptLayout: Equatable, Sendable {
    public struct Lane: Equatable, Sendable {
        /// The exposed lane value, or nil when the server did not expose one.
        public let lane: String?
        public let messages: [Entry]
        /// More than one response in this lane (regenerations or branches).
        public var hasAlternatives: Bool { messages.count > 1 }
    }

    public struct Entry: Equatable, Sendable {
        public let message: DetailMessage
        /// Parents other than the turn's prompt (e.g. a reply to an earlier response); empty if none.
        public let otherParents: [String]
    }

    public struct Turn: Equatable, Sendable, Identifiable {
        public let id: String
        public let prompt: DetailMessage?
        public let lanes: [Lane]
        /// Messages whose role is missing or not `user`/`assistant`.
        public let otherRoles: [DetailMessage]
        public let votes: [ArchivedFeedback]
    }

    public let turns: [Turn]
    /// Votes that do not fall entirely inside one turn.
    public let unmatchedVotes: [ArchivedFeedback]

    public init(_ detail: ConversationDetail) {
        var turns: [(prompt: DetailMessage?, responses: [DetailMessage], others: [DetailMessage])] = []
        for message in detail.messages {
            switch message.role {
            case "user":
                turns.append((message, [], []))
            case "assistant":
                if turns.isEmpty { turns.append((nil, [], [])) }
                turns[turns.count - 1].responses.append(message)
            default:
                if turns.isEmpty { turns.append((nil, [], [])) }
                turns[turns.count - 1].others.append(message)
            }
        }
        var placed = Set<String>()
        var result: [Turn] = []
        for (index, turn) in turns.enumerated() {
            var laneOrder: [String?] = []
            var byLane: [String?: [Entry]] = [:]
            for message in turn.responses {
                if byLane[message.lane] == nil { laneOrder.append(message.lane) }
                let others = message.parentIDs.filter { $0 != turn.prompt?.remoteID }
                byLane[message.lane, default: []].append(Entry(message: message, otherParents: others))
            }
            let ids = Set(([turn.prompt] + turn.responses + turn.others).compactMap { $0?.remoteID })
            let votes = detail.feedback.filter { vote in
                let referenced = [vote.messageA, vote.messageB].compactMap { $0 }
                return !referenced.isEmpty && referenced.allSatisfy(ids.contains)
            }
            votes.forEach { placed.insert($0.remoteID) }
            let id = turn.prompt?.remoteID ?? turn.responses.first?.remoteID ?? turn.others.first?.remoteID ?? "turn-\(index)"
            result.append(
                Turn(
                    id: id, prompt: turn.prompt, lanes: laneOrder.map { Lane(lane: $0, messages: byLane[$0] ?? []) },
                    otherRoles: turn.others, votes: votes))
        }
        self.turns = result
        self.unmatchedVotes = detail.feedback.filter { !placed.contains($0.remoteID) }
    }
}
