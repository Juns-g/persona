package persona.feature.agents

import androidx.activity.ComponentActivity
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertHasClickAction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.emptyPreferences
import androidx.navigation3.runtime.NavKey
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.serialization.json.JsonObject
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import persona.core.contracts.*
import persona.core.contracts.api.*
import persona.core.designsystem.HomeChrome
import persona.core.designsystem.LocalHomeChrome
import persona.core.designsystem.PersonaTheme
import persona.core.navigation.AppTab
import persona.core.navigation.Navigator

/**
 * Home grouping opens a menu, while the request-history row keeps its navigation action. A row under "Subtasks" offers
 * no Pin (#4494).
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [35], qualifiers = "en-w400dp-h900dp")
class AgentsHomeAffordancesTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    @Test fun groupingIsAMenuButtonAndQuickFiltersStayToggles() {
        showScreen()
        val grouping = rule.onNodeWithText("Grouping: By repository")
        grouping.assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button))
            .assert(SemanticsMatcher.keyNotDefined(SemanticsProperties.Selected))
            .assertHasClickAction()
        rule.onAllNodes(
            SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Tab) and
                SemanticsMatcher.expectValue(SemanticsProperties.Selected, true),
        ).assertCountEquals(1)
        grouping.performClick()
        rule.onNodeWithText("By status").assertIsDisplayed()
    }

    @Test fun requestHistoryKeepsItsNavigationAction() {
        showScreen()
        val history = rule.onNodeWithText("Requests and history")
        history.assert(SemanticsMatcher.expectValue(SemanticsProperties.Role, Role.Button)).performClick()
        rule.onNodeWithText("Requests waiting for you").assertIsDisplayed()
    }

    /** A runtime's agent and one it created (#4494), which the list draws under "Subtasks (1)". */
    private val family = listOf(Session("box", "lead", title = "Plan the release", state = "working", sourceKind = "runtime", agent = "claude"),
        Session("box", "review", title = "Review the plan", state = "working", sourceKind = "runtime", agent = "claude",
            isSubagent = true, parentSessionId = "lead"))

    /** The menu a long press on the row titled [title] opens, after "Subtasks (1)" was opened. */
    private fun menuOf(title: String) {
        rule.onNodeWithText("Subtasks (1)").performClick()
        rule.onNodeWithText(title).performTouchInput { longClick() }
        rule.onNodeWithText("Mute").assertIsDisplayed()
    }

    @Test fun aRowUnderSubtasksOffersNoPin() {
        showScreen(family)
        menuOf("Review the plan")
        rule.onNodeWithText("Pin").assertDoesNotExist()
        rule.onNodeWithText("Unpin").assertDoesNotExist()
    }

    @Test fun aRowOfItsOwnOffersPin() {
        showScreen(family)
        menuOf("Plan the release")
        rule.onNodeWithText("Pin").assertIsDisplayed()
    }

    @Test fun aPinnedRowUnderSubtasksOffersUnpin() {
        showScreen(family, pins = listOf("box/review"))
        menuOf("Review the plan")
        rule.onNodeWithText("Unpin").assertIsDisplayed()
        rule.onNodeWithText("Pin").assertDoesNotExist()
    }

    private fun showScreen(
        rows: List<Session> = listOf(Session("box", "s1", title = "Example task", state = "working")), pins: List<String> = emptyList(),
    ) {
        val model = AgentsViewModel(object : SessionsRepository {
            override val sessions = MutableStateFlow(rows)
            override val machines = MutableStateFlow(listOf(Machine("box", "Example computer", online = true)))
            override suspend fun refresh() = Unit
        }, object : InteractionCenter {
            override val pending = MutableStateFlow<List<Interaction>>(emptyList())
            override suspend fun refresh() = Unit
            override suspend fun resolve(id: String, resolution: Resolution) = Unit
        }, object : HubConnection {
            override val state = MutableStateFlow(ConnectionState.Online)
            override val events = MutableSharedFlow<ServerEvent>()
            override fun reconnect() = Unit
            override fun send(message: JsonObject) = true
        }, object : MessageSender {
            override val outbox = MutableStateFlow<List<OutboxMessage>>(emptyList())
            override suspend fun send(session: SessionKey, text: String, clientMessageId: String, clearDraft: String?) = Unit
        }, AgentsPreferences(object : DataStore<Preferences> {
            override val data = MutableStateFlow<Preferences>(emptyPreferences())
            override suspend fun updateData(transform: suspend (Preferences) -> Preferences) =
                transform(data.value).also { data.value = it }
        }, object : HubPreferences {
            override val preferences = MutableStateFlow(HubPreferencesSnapshot(pins = HubPreferenceSet(sessions = pins)))
            override suspend fun refresh() = Unit
            override suspend fun togglePin(path: String, space: Boolean) = Unit
            override suspend fun toggleMute(path: String, space: Boolean) = Unit
            override suspend fun markSeen(session: SessionKey, version: String) = Unit
        }))
        rule.setContent {
            PersonaTheme(darkTheme = false, reduceMotion = true) {
                CompositionLocalProvider(LocalHomeChrome provides HomeChrome(emptyList(), "Agents", onSelect = {}, leading = {})) {
                    AgentsScreen(model, Nowhere, AgentsMetadata())
                }
            }
        }
        rule.waitUntil(5_000) { model.page.value.loaded }
    }

    private object Nowhere : Navigator {
        override fun navigate(key: NavKey) = Unit
        override fun back() = Unit
        override fun selectTab(tab: AppTab) = Unit
    }
}
