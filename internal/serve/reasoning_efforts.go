//go:build linux || darwin

package serve

import (
	"bytes"
	"context"
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
// levels an agent, role and model accept, and the persisted role-defaults
// override level, or "" when nothing is configured for this agent+role —
// Settings is the only source of a default.
type ReasoningEffortSuggestions struct {
	Agent   string   `json:"agent"`
	Role    string   `json:"role"`
	Default string   `json:"default"`
	Efforts []string `json:"efforts"`
}

// reasoningEfforts answers the request/response reasoning_efforts topic: the
// selectable --reasoning-effort levels for one agent, role and model. Like the
// models topic, it is advisory — start and spawn accept any level when the
// harness did not report a list for that model.
func (s *Server) reasoningEfforts(ctx context.Context, req Request) (any, error) {
	payload, err := decodeReasoningEffortsPayload(req.Data)
	if err != nil {
		return nil, err
	}
	agentName, err := requiredValue("agent", payload.Agent)
	if err != nil {
		return nil, err
	}
	agentName = strings.ToLower(strings.TrimSpace(agentName))
	role, err := modelsuggest.ParseRole(payload.Role)
	if err != nil {
		return nil, err
	}

	root := state.StateRoot()
	if s.Snapshotter != nil {
		root = s.Snapshotter.StateRoot()
	}
	def, hasDefault, _ := state.NewRoleDefaultsStore(root).Get(agentName, agent.RoleDefaultsKey(role))

	defaultEffort := ""
	if hasDefault {
		defaultEffort = def.ReasoningEffort
	}

	// The Settings sheet resolves a row's model and its reasoning-effort
	// levels in parallel, so the first ever request for a row arrives before
	// the client knows what model is actually in effect and sends "". An
	// empty model must not be read as "nothing configured" in that case: a
	// persisted model override can support levels an empty model's baseline
	// does not. Computing Efforts against the wrong model would silently drop
	// that override from the selectable list. Resolve the same way session.Start
	// does: caller's model, else the persisted override's model, else
	// genuinely unknown (empty — there is no further fallback).
	effectiveModel := strings.TrimSpace(payload.Model)
	if effectiveModel == "" && hasDefault {
		effectiveModel = def.Model
	}

	return ReasoningEffortSuggestions{
		Agent:   agentName,
		Role:    modelsuggest.RoleName(role),
		Default: defaultEffort,
		Efforts: s.resolveReasoningEfforts(ctx, agentName, effectiveModel),
	}, nil
}

func (s *Server) resolveReasoningEfforts(ctx context.Context, agentName, model string) []string {
	if s.ReasoningEfforts != nil {
		return s.ReasoningEfforts(ctx, agentName, model)
	}
	return modelsuggest.ResolveReasoningEfforts(ctx, agentName, model, "")
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
