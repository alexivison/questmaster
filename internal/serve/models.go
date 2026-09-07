//go:build linux || darwin

package serve

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/modelsuggest"
	"github.com/alexivison/questmaster/internal/state"
)

const (
	maxServeModelSuggestions = 60
	modelsOperationTimeout   = 25 * time.Second
)

type modelsPayload struct {
	Agent   string `json:"agent"`
	Role    string `json:"role"`
	Query   string `json:"query"`
	Limit   int    `json:"limit"`
	Refresh bool   `json:"refresh"`
}

// models answers the request/response models topic: the selectable models for
// one agent and role, resolved at runtime so a newly released model needs no
// app or backend change. It is deliberately advisory — the start and spawn
// mutations accept any model string, whether or not it appears here.
func (s *Server) models(ctx context.Context, req Request) (any, error) {
	payload, err := decodeModelsPayload(req.Data)
	if err != nil {
		return nil, err
	}
	agentName, err := requiredValue("agent", payload.Agent)
	if err != nil {
		return nil, err
	}
	limit := payload.Limit
	if limit <= 0 || limit > maxServeModelSuggestions {
		limit = maxServeModelSuggestions
	}

	root := state.StateRoot()
	if s.Snapshotter != nil {
		root = s.Snapshotter.StateRoot()
	}

	ctx, cancel := context.WithTimeout(ctx, modelsOperationTimeout)
	defer cancel()

	return modelsuggest.Resolve(ctx, modelsuggest.ResolveOptions{
		Agent:   agentName,
		Role:    modelsuggest.ParseRole(payload.Role),
		Query:   strings.TrimSpace(payload.Query),
		Limit:   limit,
		Refresh: payload.Refresh,
		Root:    root,
		Store:   state.OpenStore(root),
	}), nil
}

func decodeModelsPayload(raw json.RawMessage) (modelsPayload, error) {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return modelsPayload{}, nil
	}
	if raw[0] == '"' {
		var agentName string
		if err := json.Unmarshal(raw, &agentName); err != nil {
			return modelsPayload{}, fmt.Errorf("decode models agent: %w", err)
		}
		return modelsPayload{Agent: agentName}, nil
	}
	var payload modelsPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return modelsPayload{}, fmt.Errorf("decode models data: %w", err)
	}
	return payload, nil
}
