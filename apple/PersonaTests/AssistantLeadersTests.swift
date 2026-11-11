import Foundation
import Testing
@testable import Persona

/// The directions' counts and the hub's `assistant_leaders` push (#4331).
struct AssistantLeadersTests {
    /// Each direction in GET /api/v1/assistant/leaders carries how much of its work is in flight.
    @Test func leadersCarryTheirCounts() throws {
        let raw = #"""
        {"leaders":[{"id":"lead-a","name":"Product","counts":{"working":3,"needs_you":1}},
                    {"id":"lead-b","title":"1110 | explore | x"},
                    {"id":"old","name":"Done","ended":true,"counts":{"working":9,"needs_you":9}}]}
        """#
        struct Body: Decodable { var leaders: [APIClient.LeaderInfo]? }
        let list = try JSON.decoder.decode(Body.self, from: Data(raw.utf8)).leaders ?? []
        #expect(list.count == 3)
        #expect(list[0].counts == APIClient.LeaderCounts(working: 3, needsYou: 1))
        #expect(list[1].counts == nil)
        #expect(APIClient.directionCounts(list) == ["lead-a": APIClient.LeaderCounts(working: 3, needsYou: 1)])
    }

    /// The row reads "N working · N need you", only the non-zero parts, and nothing while both are zero.
    @Test func countsLabelShowsOnlyWhatIsThere() {
        #expect(DirectionCountsText.label(working: 0, needsYou: 0) == nil)
        let working = DirectionCountsText.label(working: 2, needsYou: 0)
        #expect(working?.contains("2") == true)
        #expect(working?.contains("0") == false)
        let waiting = DirectionCountsText.label(working: 0, needsYou: 4)
        #expect(waiting?.contains("4") == true)
        #expect(waiting?.contains("0") == false)
        let both = DirectionCountsText.label(working: 3, needsYou: 1)
        #expect(both?.contains("3") == true)
        #expect(both?.contains("1") == true)
        #expect(both?.contains("·") == true)
    }

    /// The hub's push: its manager, and each direction's id, name and counts, in its order.
    @Test func theLeadersPushIsRead() throws {
        let raw = #"""
        {"type":"assistant_leaders","manager":"assistant","leaders":[
            {"id":"lead-a","title":"1110 | explore | a","name":"Product","counts":{"working":2,"needs_you":1}},
            {"id":"lead-b","title":"1110 | explore | b"}]}
        """#
        let event = try #require(ServerEvent.decode(Data(raw.utf8)))
        guard case .assistantLeaders(let manager, let leaders) = event else {
            Issue.record("not assistant_leaders")
            return
        }
        #expect(manager == "assistant")
        #expect(leaders.map(\.id) == ["lead-a", "lead-b"])
        #expect(leaders.first?.name == "Product")
        #expect(leaders.first?.counts == APIClient.LeaderCounts(working: 2, needsYou: 1))
    }

    /// An empty push is how the hub says the last direction ended: it still arrives, with no manager named.
    @Test func anEmptyPushClears() throws {
        let event = try #require(ServerEvent.decode(Data(#"{"type":"assistant_leaders","leaders":[]}"#.utf8)))
        guard case .assistantLeaders(let manager, let leaders) = event else {
            Issue.record("not assistant_leaders")
            return
        }
        #expect(manager == nil)
        #expect(leaders.isEmpty)
    }
}
