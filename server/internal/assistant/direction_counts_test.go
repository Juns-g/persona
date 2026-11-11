package assistant

import (
	"context"
	"encoding/json"
	"slices"
	"testing"
	"time"

	"github.com/nwverse/persona/server/internal/proto"
)

// The leaders' lines on the clients' sidebar (#4331, #4352). All ids are placeholders.

// A leader's counts are its open tasks in the To-dos page's Working and Waiting on you sections: a task of another
// leader, of none, or a closed one is not counted, and a leader with nothing still has its zeros.
func TestLeaderCountsFollowTheTodoSections(t *testing.T) {
	now := time.Date(2026, 11, 11, 12, 0, 0, 0, time.UTC)
	task := func(id, lead, agent string) listedTodo {
		td := Todo{ID: id, Origin: "c", CreatedAt: now.Add(-time.Hour), UpdatedAt: now.Add(-time.Hour)}
		if lead != "" {
			td.Supervision = &Supervision{Supervisor: lead}
		}
		if agent != "" {
			td.Agents = []TodoAgent{{MachineID: "m", SessionID: agent}}
		}
		return listedTodo{Todo: td}
	}
	done := task("closed", "lead-a", "run")
	done.DoneAt = &now
	look := lookupOf([]proto.Session{
		{MachineID: "m", SessionID: "run", State: proto.StateWorking, Status: proto.StatusWorking, UpdatedAt: now},
		{MachineID: "m", SessionID: "ask", State: proto.StateNeedsYou, UpdatedAt: now},
		{MachineID: "m", SessionID: "idle", State: proto.StateIdle, UpdatedAt: now},
	})
	got := countLeaderTasks([]string{"lead-a", "lead-b", "lead-c"}, []listedTodo{
		task("a1", "lead-a", "run"), task("a2", "lead-a", "run"), task("a3", "lead-a", "ask"), task("a4", "lead-a", "idle"),
		task("b1", "lead-b", "ask"), task("x1", "other", "run"), task("n1", "", "run"), done,
	}, look, now, time.UTC)
	want := map[string]leaderCounts{"lead-a": {Working: 2, NeedsYou: 1}, "lead-b": {NeedsYou: 1}, "lead-c": {}}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for id, w := range want {
		if got[id] != w {
			t.Errorf("%s: %+v, want %+v", id, got[id], w)
		}
	}
}

// The clients are told the current leaders (assistant_leaders) as soon as they change, whoever changed them, and not
// again while nothing changed (#4331: a sixth leader set by the secretary never reached an open sidebar).
func TestLeadersAreToldToTheClients(t *testing.T) {
	e := directionEnv(t, &memStore{})
	setSettings(t, e.s, func(v *Settings) { v.Main = "conv_main" })
	e.title("conv_lead_a", "1110 | 探索 | 你是「基建」这条线的主管")
	e.title("conv_lead_b", "Docs sync")
	told := func() int {
		e.f.mu.Lock()
		defer e.f.mu.Unlock()
		n := 0
		for _, ev := range e.f.events {
			if ev == "assistant_leaders" {
				n++
			}
		}
		return n
	}
	last := func() []leaderLine {
		var v struct {
			Type    string       `json:"type"`
			Leaders []leaderLine `json:"leaders"`
		}
		if err := json.Unmarshal(e.s.leaderTold.last, &v); err != nil || v.Type != "assistant_leaders" {
			t.Fatalf("last told: %s %v", e.s.leaderTold.last, err)
		}
		return v.Leaders
	}
	ctx := context.Background()
	e.leaders("conv_lead_a")
	e.s.tellLeaders(ctx)
	if n := told(); n != 1 {
		t.Fatalf("first: told %d times", n)
	}
	if got := last(); len(got) != 1 || got[0].ID != "conv_lead_a" || got[0].Name != "基建" || got[0].Counts != (leaderCounts{}) {
		t.Fatalf("first: %+v", got)
	}
	e.s.tellLeaders(ctx)
	if n := told(); n != 1 {
		t.Fatalf("nothing changed, yet told again: %d", n)
	}
	// the secretary adds a leader: the clients hear of it at once, in assistant.leaders' order, main left out
	e.leaders("conv_lead_a", "conv_main", "conv_lead_b")
	e.s.tellLeaders(ctx)
	if n := told(); n != 2 {
		t.Fatalf("a new leader: told %d times", n)
	}
	got := last()
	if ids := []string{got[0].ID, got[len(got)-1].ID}; len(got) != 2 || !slices.Equal(ids, []string{"conv_lead_a", "conv_lead_b"}) {
		t.Fatalf("after adding: %+v", got)
	}
	// ended: gone from the next one
	if _, err := e.s.endDirection(ctx, "conv_lead_a"); err != nil {
		t.Fatal(err)
	}
	e.s.tellLeaders(ctx)
	if got := last(); len(got) != 1 || got[0].ID != "conv_lead_b" {
		t.Fatalf("after ending: %+v", got)
	}
}
