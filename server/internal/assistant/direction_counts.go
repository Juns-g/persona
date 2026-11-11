package assistant

import (
	"bytes"
	"context"
	"encoding/json"
	"slices"
	"sync"
	"time"
)

// What each leader's line in the clients' sidebar says, and keeping it current (#4331, #4352;
// docs/assistant/unified-entry.md "Leader conversations").
//
// Counts: of a leader's open tasks (supervision.supervisor is the leader, not done), how many are Working and how many
// are Waiting on you, by the same rules the To-dos page files them under (todo_triage.go, docs/assistant/todo-status-sop.md),
// so a number on the sidebar and the To-dos page's section agree.
//
// The clients learn the leaders from GET /api/v1/assistant (`leaders`) when they load and from GET
// /api/v1/assistant/leaders (names, counts); a leader made or ended later (a tap, the secretary's assistant.leaders, a
// direction offer) reached a client only on its next reload or reconnect (#4331: a sixth leader never showed). Now the
// hub tells the clients the current leaders with their names and counts (`assistant_leaders`) whenever any of it
// changes: after each publish (directionsSync) and every leaderCountsEvery for agents that started or stopped meanwhile.

// leaderCountsEvery is how often the counts are worked out again without a change of the assistant's own.
const leaderCountsEvery = 20 * time.Second

// leaderCounts is a leader's open tasks by section.
type leaderCounts struct {
	Working  int `json:"working"`
	NeedsYou int `json:"needs_you"`
}

// leaderLine is a current leader as the clients' sidebar shows it.
type leaderLine struct {
	ID     string       `json:"id"`
	Title  string       `json:"title,omitempty"`
	Name   string       `json:"name,omitempty"`
	Counts leaderCounts `json:"counts"`
}

// countLeaderTasks files each open task supervised by one of leads into its To-dos section and counts Working and
// Waiting on you per leader. Every lead has an entry, zero when it has no such task.
func countLeaderTasks(leads []string, tasks []listedTodo, look triageLookup, now time.Time, loc *time.Location) map[string]leaderCounts {
	out := make(map[string]leaderCounts, len(leads))
	for _, id := range leads {
		out[id] = leaderCounts{}
	}
	for _, t := range tasks {
		if t.DoneAt != nil || t.Supervision == nil {
			continue
		}
		c, ok := out[t.Supervision.Supervisor]
		if !ok {
			continue
		}
		switch triageTodo(t, look, now, time.Time{}, loc, false).Section {
		case triageWorking:
			c.Working++
		case triageWaiting:
			c.NeedsYou++
		}
		out[t.Supervision.Supervisor] = c
	}
	return out
}

// currentLeaders are the leaders in assistant.leaders' order (never the main one) with their names and counts.
func (s *Service) currentLeaders(ctx context.Context) []leaderLine {
	cfg := s.settings(ctx)
	var leads []string
	for _, id := range cfg.Leaders {
		if id != "" && id != cfg.Main && !slices.Contains(leads, id) {
			leads = append(leads, id)
		}
	}
	out := make([]leaderLine, 0, len(leads))
	if len(leads) == 0 {
		return out
	}
	var tasks []listedTodo
	var plain []Todo
	if s.todosLoaded() {
		s.todos.mu.RLock()
		for _, t := range s.todos.todos {
			if t.DoneAt == nil && t.Supervision != nil && slices.Contains(leads, t.Supervision.Supervisor) {
				plain = append(plain, copyTodoLocked(t))
			}
		}
		s.todos.mu.RUnlock()
	}
	var counts map[string]leaderCounts
	if len(plain) > 0 {
		asks := s.todoAsks(ctx)
		look, _ := s.leaderSessions(ctx, plain)
		for _, t := range plain {
			lt := listedTodo{Todo: t}
			if a, ok := asks[t.ID]; ok {
				lt.Ask = &a
			}
			tasks = append(tasks, lt)
		}
		counts = countLeaderTasks(leads, tasks, look, time.Now(), s.location(ctx))
	}
	titles, _ := s.conversationTitles()
	names := s.leaderNames(ctx, leads)
	for _, id := range leads {
		out = append(out, leaderLine{ID: id, Title: titles[id].title, Name: names[id], Counts: counts[id]})
	}
	return out
}

// leaderBroadcast is what the clients were last told.
type leaderBroadcast struct {
	mu   sync.Mutex
	last []byte
}

// tellLeaders sends `assistant_leaders` to the clients when the leaders, their names or their counts changed since
// the last one this hub sent (the first one after a start always goes: a client may have missed a change meanwhile).
func (s *Service) tellLeaders(ctx context.Context) {
	b := &s.leaderTold
	b.mu.Lock()
	defer b.mu.Unlock()
	raw, err := json.Marshal(map[string]any{"type": "assistant_leaders", "manager": s.managerIdentity(), "leaders": s.currentLeaders(ctx)})
	if err != nil || bytes.Equal(raw, b.last) {
		return
	}
	b.last = raw
	s.hub.Broadcast(context.WithoutCancel(ctx), Broadcast{Message: raw})
}

// leaderCountsLoop tells the clients of counts that changed with no change of the assistant's own (an agent
// started, stopped or began to ask).
func (s *Service) leaderCountsLoop(ctx context.Context) {
	t := time.NewTicker(leaderCountsEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.tellLeaders(ctx)
		}
	}
}
