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
	catalogue := agent.Names()
	names := make([]string, 0, len(catalogue))
	for _, name := range catalogue {
		if enabled, ok := settings[name]; !ok || enabled {
			names = append(names, name)
		}
	}
	return names, nil
}

// RequireBuiltinEnabled validates the harness before reading saved settings.
func RequireBuiltinEnabled(root, name string) error {
	name = strings.ToLower(strings.TrimSpace(name))
	if !agent.IsBuiltin(name) {
		return fmt.Errorf("unknown agent %q (want one of %s)", name, strings.Join(agent.Names(), ", "))
	}
	return RequireEnabled(root, name)
}

// RequireEnabled rejects a name only when it has an explicit disabled setting.
// Names without a saved preference keep their existing availability.
func RequireEnabled(root, name string) error {
	name = strings.ToLower(strings.TrimSpace(name))
	enabled, err := state.NewAgentAvailabilityStore(root).Enabled(name)
	if err != nil {
		return err
	}
	if !enabled {
		return fmt.Errorf("agent %q is disabled. Re-enable it in Settings under Models and Reasoning.", name)
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
		return fmt.Errorf("all agents are disabled. Enable at least one in Settings under Models and Reasoning.")
	}
	return fmt.Errorf("agent %q is disabled. To launch a session, re-enable it in Settings under Models and Reasoning or use --agent with an enabled agent from `qm agent query names`.", name)
}
