//go:build linux || darwin

package serve

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/alexivison/questmaster/internal/picker"
	"github.com/alexivison/questmaster/internal/state"
)

const maxServeDirSuggestions = 8

type dirSuggestPayload struct {
	Query string `json:"query"`
	Limit int    `json:"limit"`
}

func (s *Server) dirSuggest(req Request) (any, error) {
	payload, err := decodeDirSuggestPayload(req.Data)
	if err != nil {
		return nil, err
	}
	limit := payload.Limit
	if limit <= 0 || limit > maxServeDirSuggestions {
		limit = maxServeDirSuggestions
	}

	querier := s.DirQuerier
	if querier == nil {
		querier = picker.NewZoxideDirQuerier()
	}
	store := state.OpenStore(state.StateRoot())
	if s.Snapshotter != nil {
		store = state.OpenStore(s.Snapshotter.StateRoot())
	}
	return picker.QueryDirSuggestions(store, querier, payload.Query, limit)
}

func decodeDirSuggestPayload(raw json.RawMessage) (dirSuggestPayload, error) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return dirSuggestPayload{}, nil
	}
	if raw[0] == '"' {
		var query string
		if err := json.Unmarshal(raw, &query); err != nil {
			return dirSuggestPayload{}, fmt.Errorf("decode dir_suggest query: %w", err)
		}
		return dirSuggestPayload{Query: strings.TrimSpace(query)}, nil
	}
	var payload dirSuggestPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return dirSuggestPayload{}, fmt.Errorf("decode dir_suggest data: %w", err)
	}
	payload.Query = strings.TrimSpace(payload.Query)
	return payload, nil
}
