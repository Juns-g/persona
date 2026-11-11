package persona.core.data

import kotlinx.serialization.json.Json
import persona.core.contracts.AssistantLeadersEvent
import persona.core.contracts.ServerEvent
import persona.core.contracts.api.LeaderCounts
import persona.core.contracts.api.LeaderLine
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// The drawer's Directions (docs/assistant/unified-entry.md "Leader conversations"): `assistant.leaders` in the hub's order,
// named by GET /api/v1/assistant/leaders.
class DirectionNamesTest {
    private fun json(text: String): JsonObject = Json.parseToJsonElement(text).jsonObject

    @Test fun leadersKeepTheHubsOrderWithoutTheMainOne() {
        assertEquals(listOf("b", "a"), leadersOf(json("""{"main": "m", "leaders": ["b", "", "m", "a"]}""")))
        assertEquals(emptyList<String>(), leadersOf(json("""{"main": "m"}""")))
    }

    // #4331: the same answer says what each leader has open, for its row 「在做 N · 等你 N」.
    @Test fun countsComeWithTheLeaders() {
        val counts = leaderCountsOf(json("""{"leaders": [
            {"id": "a", "counts": {"working": 2, "needs_you": 1}},
            {"id": "b"},
            {"id": "c", "counts": {"working": 0, "needs_you": 0}, "ended": true},
            {"id": "", "counts": {"working": 5}}
        ]}"""))
        assertEquals(mapOf("a" to LeaderCounts(working = 2, needsYou = 1), "b" to LeaderCounts()), counts)
        assertEquals(emptyMap<String, LeaderCounts>(), leaderCountsOf(json("{}")))
    }

    // An open drawer follows the hub: leaders, names and counts, in its order (#4331).
    @Test fun theHubPushesTheLeadersWithTheirNamesAndCounts() {
        val event = ServerEvent.decode("""{"type": "assistant_leaders", "manager": "second", "leaders": [
            {"id": "a", "title": "Growth", "name": "Growth work", "counts": {"working": 1, "needs_you": 2}}
        ]}""")
        assertTrue(event is AssistantLeadersEvent)
        val leaders = event as AssistantLeadersEvent
        assertEquals("second", leaders.manager)
        assertEquals(listOf(LeaderLine("a", "Growth", "Growth work", LeaderCounts(working = 1, needsYou = 2))), leaders.leaders)
        val own = ServerEvent.decode("""{"type": "assistant_leaders", "leaders": []}""") as AssistantLeadersEvent
        assertNull("no manager: the default assistant's", own.manager)
        assertTrue(own.leaders.isEmpty())
    }

    @Test fun namesSkipEndedAndBlankOnes() {
        val names = directionNamesOf(json("""{"leaders": [
            {"id": "a", "name": " Product "},
            {"id": "b", "name": ""},
            {"id": "c", "name": "Old", "ended": true},
            {"id": "", "name": "Nobody"}
        ]}"""))
        assertEquals(mapOf("a" to "Product"), names)
        assertEquals(emptyMap<String, String>(), directionNamesOf(json("{}")))
    }
}
