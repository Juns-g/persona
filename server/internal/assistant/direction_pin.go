package assistant

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"

	"github.com/nwverse/persona/server/internal/apierr"
)

// A direction's pin (#4331; docs/assistant/unified-entry.md "Leader conversations"): the sidebar's Directions group
// lists every leader, the pinned ones first in assistant.leaders' order, then the ones the owner unpinned. Pinning only
// orders the group: an unpinned direction stays a direction. The hub keeps it (assistant.leaders_unpinned) so every
// device draws the same group, and nothing pins it back by itself.

// setDirectionPinned pins or unpins leader id. Ids that are no longer leaders are dropped from the list on the way.
func (s *Service) setDirectionPinned(ctx context.Context, id string, pinned bool) error {
	if s.store() == nil {
		return errors.New("no database on this hub")
	}
	_, err := s.updateSettings(ctx, func(v *Settings) error {
		if !slices.Contains(v.Leaders, id) {
			return errNoDirection
		}
		out := []string{}
		for _, u := range v.LeadersUnpinned {
			if u != id && slices.Contains(v.Leaders, u) && !slices.Contains(out, u) {
				out = append(out, u)
			}
		}
		if !pinned {
			out = append(out, id)
		}
		if len(out) == 0 {
			out = nil
		}
		v.LeadersUnpinned = out
		return nil
	})
	if err != nil {
		return err
	}
	s.settingsChanged(ctx)
	return nil
}

// directionPinRoutes: PUT /api/v1/assistant/directions/{id}/pinned {"pinned": bool}.
func (s *Service) directionPinRoutes() {
	s.handle("PUT /api/v1/assistant/directions/{id}/pinned", func(w http.ResponseWriter, r *http.Request) {
		if !fullRole(r) {
			apierr.Write(w, http.StatusForbidden, errors.New("read-only role cannot change directions"))
			return
		}
		var in struct {
			Pinned *bool `json:"pinned"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<12)).Decode(&in); err != nil || in.Pinned == nil {
			apierr.Write(w, http.StatusBadRequest, errors.New(`body must be {"pinned": true|false}`))
			return
		}
		err := s.setDirectionPinned(r.Context(), r.PathValue("id"), *in.Pinned)
		switch {
		case errors.Is(err, errNoDirection):
			apierr.Write(w, http.StatusNotFound, err)
			return
		case err != nil:
			apierr.Write(w, http.StatusServiceUnavailable, err)
			return
		}
		apierr.WriteJSON(w, map[string]any{"pinned": *in.Pinned})
	})
}
