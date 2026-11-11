package persona.core.contracts.api

import persona.core.contracts.Session
import persona.core.contracts.SessionKey
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * A current leader's open tasks (#4331), by the same rules the To-dos page files them under: [working] in its Working
 * section, [needsYou] waiting on the user. Both zero when it has none.
 */
@Serializable
data class LeaderCounts(
    val working: Int = 0,
    @SerialName("needs_you") val needsYou: Int = 0,
)

/**
 * A current leader as `GET /api/v1/assistant/leaders` and the hub's `assistant_leaders` message list it (#4331): its
 * conversation id, [title] (the conversation's title), [name] (the direction's name) and its open tasks' [counts].
 */
@Serializable
data class LeaderLine(
    val id: String = "", val title: String = "", val name: String = "", val counts: LeaderCounts = LeaderCounts(),
)

data class AssistantSnapshot(
    val mainSession: SessionKey? = null, val conversations: List<Session> = emptyList(),
    /** Whose conversations these are (docs/assistant/managers.md step 4): the manager the page showed when read; null: the default. */
    val manager: String? = null,
    /** Stable owner identity, including when this manager becomes or ceases to be the default. */
    val managerId: String = manager ?: ManagerRoster.ASSISTANT_MANAGER,
    /**
     * The leader conversations (`assistant.leaders`, docs/assistant/unified-entry.md "Leader conversations"), in the hub's
     * order: the drawer's 常驻 group. Empty when there are none or from an older hub.
     */
    val leaders: List<String> = emptyList(),
    /** Each direction's name by leader conversation id (`GET /api/v1/assistant/leaders`), shown instead of its title. */
    val directionNames: Map<String, String> = emptyMap(),
    /**
     * Each current leader's open tasks (`GET /api/v1/assistant/leaders`'s `counts`), by conversation id (#4331): its
     * row says 「在做 N · 等你 N」. A leader without open tasks is left out or says zero; empty from an older hub.
     */
    val leaderCounts: Map<String, LeaderCounts> = emptyMap(),
)

/** The assistant's spaces besides its own (docs/assistant/health.md): their names on the wire (`space`). */
object AssistantSpace {
    const val HEALTH = "health"
}

interface AssistantRepository {
    val assistant: StateFlow<AssistantSnapshot>
    suspend fun refresh()
}
