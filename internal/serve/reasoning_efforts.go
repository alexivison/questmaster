//go:build linux || darwin

package serve

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/modelsuggest"
	"github.com/alexivison/questmaster/internal/state"
)

type reasoningEffortsPayload struct {
	Agent string `json:"agent"`
	Role  string `json:"role"`
	Model string `json:"model"`
}

// ReasoningEffortSuggestions is the reasoning-effort picker's wire shape: the
// levels an agent, role and model accept, and the level applied when no
// --reasoning-effort override is given.
type ReasoningEffortSuggestions struct {
	Agent   string   `json:"agent"`
	Role    string   `json:"role"`
	Default string   `json:"default"`
	Efforts []string `json:"efforts"`
}

// reasoningEfforts answers the request/response reasoning_efforts topic: the
// selectable --reasoning-effort levels for one agent, role and model. Like the
// models topic, it is advisory — start and spawn accept any level the harness
// understands, listed or not. Unlike models, resolving it never touches the
// network or a subprocess: agent.SupportedReasoningEfforts and
// agent.DefaultReasoningEffortFor are both pure lookups, so there is no cache
// to bypass and no refresh flag.
func (s *Server) reasoningEfforts(req Request) (any, error) {
	payload, err := decodeReasoningEffortsPayload(req.Data)
	if err != nil {
		return nil, err
	}
	agentName, err := requiredValue("agent", payload.Agent)
	if err != nil {
		return nil, err
	}
	agentName = strings.ToLower(strings.TrimSpace(agentName))
	role := modelsuggest.ParseRole(payload.Role)

	root := state.StateRoot()
	if s.Snapshotter != nil {
		root = s.Snapshotter.StateRoot()
	}
	defaultEffort := agent.DefaultReasoningEffortFor(agentName, role)
	if def, ok, _ := state.NewRoleDefaultsStore(root).Get(agentName, agent.RoleDefaultsKey(role)); ok && def.ReasoningEffort != "" {
		defaultEffort = def.ReasoningEffort
	}

	return ReasoningEffortSuggestions{
		Agent:   agentName,
		Role:    modelsuggest.RoleName(role),
		Default: defaultEffort,
		Efforts: agent.SupportedReasoningEfforts(agentName, strings.TrimSpace(payload.Model)),
	}, nil
}

func decodeReasoningEffortsPayload(raw json.RawMessage) (reasoningEffortsPayload, error) {
	if len(bytes.TrimSpace(raw)) == 0 {
		return reasoningEffortsPayload{}, nil
	}
	var payload reasoningEffortsPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return reasoningEffortsPayload{}, fmt.Errorf("decode reasoning_efforts data: %w", err)
	}
	return payload, nil
}
