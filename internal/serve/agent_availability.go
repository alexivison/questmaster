//go:build linux || darwin

package serve

import (
	"fmt"
	"slices"
	"strings"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
)

type agentAvailabilityDefault struct {
	Model           string `json:"model"`
	ReasoningEffort string `json:"reasoning_effort"`
}

type agentAvailabilityEntry struct {
	Name     string                              `json:"name"`
	Enabled  bool                                `json:"enabled"`
	Defaults map[string]agentAvailabilityDefault `json:"defaults"`
}

type agentAvailabilityResponse struct {
	Agents []agentAvailabilityEntry `json:"agents"`
}

func (s *Server) agentAvailability() (agentAvailabilityResponse, error) {
	root := s.mutationStore().Root()
	availability, err := state.NewAgentAvailabilityStore(root).Load()
	if err != nil {
		return agentAvailabilityResponse{}, err
	}
	roleDefaults, err := state.NewRoleDefaultsStore(root).Load()
	if err != nil {
		roleDefaults = map[string]state.RoleDefault{}
	}

	response := agentAvailabilityResponse{Agents: make([]agentAvailabilityEntry, 0, len(agent.Names()))}
	for _, name := range agent.Names() {
		enabled, ok := availability[name]
		if !ok {
			enabled = true
		}
		entry := agentAvailabilityEntry{
			Name:     name,
			Enabled:  enabled,
			Defaults: make(map[string]agentAvailabilityDefault),
		}
		for _, role := range []string{"master", "worker"} {
			if def, ok := roleDefaults[name+":"+role]; ok {
				entry.Defaults[role] = agentAvailabilityDefault{
					Model:           def.Model,
					ReasoningEffort: def.ReasoningEffort,
				}
			}
		}
		response.Agents = append(response.Agents, entry)
	}
	return response, nil
}

func (s *Server) mutateAgentAvailabilitySet(payload mutationPayload) (any, error) {
	name := strings.ToLower(strings.TrimSpace(payload.Agent))
	if name == "" {
		return nil, fmt.Errorf("agent is required")
	}
	if !slices.Contains(agent.Names(), name) {
		return nil, fmt.Errorf("unknown agent %q (want one of %s)", name, strings.Join(agent.Names(), ", "))
	}
	var enabled bool
	switch payload.AgentEnabled {
	case "true":
		enabled = true
	case "false":
		enabled = false
	default:
		return nil, fmt.Errorf("enabled must be the string \"true\" or \"false\"")
	}
	if err := state.NewAgentAvailabilityStore(s.mutationStore().Root()).Set(name, enabled); err != nil {
		return nil, err
	}
	return struct {
		Agent   string `json:"agent"`
		Enabled bool   `json:"enabled"`
	}{Agent: name, Enabled: enabled}, nil
}
