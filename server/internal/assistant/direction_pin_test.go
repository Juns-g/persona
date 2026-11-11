package assistant

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
)

// A direction's pin (#4331): the owner unpins and pins a leader; the hub keeps it in assistant.leaders_unpinned, which
// GET /api/v1/assistant carries to every device. All ids are placeholders.

func putPinned(t *testing.T, s *Service, id, body string, readonly bool) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPut, "/api/v1/assistant/directions/"+id+"/pinned", strings.NewReader(body))
	if readonly {
		req.Header.Set(RoleHeader, "readonly")
	}
	s.ServeHTTP(rec, req)
	return rec
}

func unpinnedNow(t *testing.T, s *Service) []string {
	t.Helper()
	rec := httptest.NewRecorder()
	s.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/assistant", nil))
	var v struct {
		Unpinned []string `json:"leaders_unpinned"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &v); err != nil {
		t.Fatalf("GET assistant: %v %s", err, rec.Body)
	}
	return v.Unpinned
}

func TestDirectionPin(t *testing.T) {
	e := directionEnv(t, &memStore{})
	setSettings(t, e.s, func(v *Settings) { v.Main = "conv_main" })
	e.leaders("conv_lead_a", "conv_lead_b")
	if got := unpinnedNow(t, e.s); len(got) != 0 {
		t.Fatalf("a new direction is pinned: %v", got)
	}

	if rec := putPinned(t, e.s, "conv_lead_b", `{"pinned":false}`, false); rec.Code != 200 || !strings.Contains(rec.Body.String(), `"pinned":false`) {
		t.Fatalf("unpin: %d %s", rec.Code, rec.Body)
	}
	if got := unpinnedNow(t, e.s); !slices.Equal(got, []string{"conv_lead_b"}) {
		t.Fatalf("unpinned: %v", got)
	}
	// unpinning again changes nothing; the leader stays a leader
	putPinned(t, e.s, "conv_lead_b", `{"pinned":false}`, false)
	if got := unpinnedNow(t, e.s); !slices.Equal(got, []string{"conv_lead_b"}) {
		t.Fatalf("unpinned twice: %v", got)
	}
	if got := e.s.settings(context.Background()).Leaders; !slices.Equal(got, []string{"conv_lead_a", "conv_lead_b"}) {
		t.Fatalf("an unpinned direction left the leaders: %v", got)
	}

	// pinned back: the list is empty again
	if rec := putPinned(t, e.s, "conv_lead_b", `{"pinned":true}`, false); rec.Code != 200 {
		t.Fatalf("pin: %d %s", rec.Code, rec.Body)
	}
	if got := unpinnedNow(t, e.s); len(got) != 0 {
		t.Fatalf("pinned back: %v", got)
	}

	// an ended leader drops out of the list on the next change
	putPinned(t, e.s, "conv_lead_a", `{"pinned":false}`, false)
	e.leaders("conv_lead_b", "conv_lead_c")
	putPinned(t, e.s, "conv_lead_c", `{"pinned":false}`, false)
	if got := unpinnedNow(t, e.s); !slices.Equal(got, []string{"conv_lead_c"}) {
		t.Fatalf("after conv_lead_a ended: %v", got)
	}

	for _, c := range []struct {
		name, id, body string
		readonly       bool
		code           int
	}{
		{"not a leader", "conv_other", `{"pinned":false}`, false, http.StatusNotFound},
		{"the main conversation", "conv_main", `{"pinned":false}`, false, http.StatusNotFound},
		{"no pinned field", "conv_lead_b", `{}`, false, http.StatusBadRequest},
		{"not JSON", "conv_lead_b", `x`, false, http.StatusBadRequest},
		{"read-only device", "conv_lead_b", `{"pinned":false}`, true, http.StatusForbidden},
	} {
		if rec := putPinned(t, e.s, c.id, c.body, c.readonly); rec.Code != c.code {
			t.Errorf("%s: %d, want %d (%s)", c.name, rec.Code, c.code, rec.Body)
		}
	}
	if got := unpinnedNow(t, e.s); !slices.Equal(got, []string{"conv_lead_c"}) {
		t.Fatalf("a refused request changed the list: %v", got)
	}
}
