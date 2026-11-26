// Package agentavailability combines the built-in agent catalogue with the
// user's persisted launch-permission preferences.
package agentavailability

import (
	"fmt"
	"strings"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
)

// EnabledNames returns the built-in agents that can currently be launched,
// preserving the catalogue order.
func EnabledNames(root string) ([]string, error) {
	settings, err := state.NewAgentAvailabilityStore(root).Load()
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(agent.Names()))
	for _, name := range agent.Names() {
		if enabled, ok := settings[name]; !ok || enabled {
			names = append(names, name)
		}
	}
	return names, nil
}

// RequireEnabled rejects a name only when it has an explicit disabled setting.
// Names without a saved preference keep their existing availability.
func RequireEnabled(root, name string) error {
	name = strings.ToLower(strings.TrimSpace(name))
	settings, err := state.NewAgentAvailabilityStore(root).Load()
	if err != nil {
		return err
	}
	if enabled, saved := settings[name]; saved && !enabled {
		return fmt.Errorf("agent %q is disabled; re-enable it in Settings under Models and Reasoning before launching or querying it", name)
	}
	return nil
}

// RequireLaunch applies the same discovery and recovery guidance to any
// disabled binding, without assuming it belongs to the current built-in
// catalogue. This keeps legacy and test providers on their existing path.
func RequireLaunch(root, name string) error {
	name = strings.ToLower(strings.TrimSpace(name))
	settings, err := state.NewAgentAvailabilityStore(root).Load()
	if err != nil {
		return err
	}
	if enabled, saved := settings[name]; !saved || enabled {
		return nil
	}
	allBuiltinsDisabled := true
	for _, builtin := range agent.Names() {
		if enabled, saved := settings[builtin]; !saved || enabled {
			allBuiltinsDisabled = false
			break
		}
	}
	if allBuiltinsDisabled {
		return fmt.Errorf("all agents are disabled; enable at least one in Settings under Models and Reasoning before launching an agent")
	}
	return fmt.Errorf("agent %q is disabled; re-enable it in Settings under Models and Reasoning or choose an enabled agent with --agent (run `qm agent query names` to see available agents)", name)
}
