//go:build linux || darwin

package agentavailability

import (
	"slices"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
)

func TestEnabledNamesFiltersInCatalogueOrder(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	if err := state.NewAgentAvailabilityStore(root).Set("codex", false); err != nil {
		t.Fatalf("disable codex: %v", err)
	}
	got, err := EnabledNames(root)
	if err != nil {
		t.Fatalf("EnabledNames: %v", err)
	}
	want := []string{"claude", "opencode", "pi"}
	if !slices.Equal(got, want) {
		t.Fatalf("EnabledNames = %v, want %v (from %v)", got, want, agent.Names())
	}
}

func TestRequireEnabledLeavesUnconfiguredLegacyProvidersAvailable(t *testing.T) {
	t.Parallel()

	if err := RequireEnabled(t.TempDir(), "stub"); err != nil {
		t.Fatalf("RequireEnabled(stub) = %v, want unset provider to remain available", err)
	}
}

func TestRequireLaunchUsesGenericRecoveryHintAndAllOffError(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	store := state.NewAgentAvailabilityStore(root)
	if err := store.Set("claude", false); err != nil {
		t.Fatal(err)
	}
	err := RequireLaunch(root, "claude")
	if err == nil || !strings.Contains(err.Error(), "--agent") || !strings.Contains(err.Error(), "re-enable") {
		t.Fatalf("RequireLaunch with enabled alternatives = %v, want generic recovery hint", err)
	}
	for _, name := range agent.Names() {
		if err := store.Set(name, false); err != nil {
			t.Fatal(err)
		}
	}
	err = RequireLaunch(root, "claude")
	if err == nil || !strings.Contains(err.Error(), "all agents are disabled") {
		t.Fatalf("RequireLaunch with every built-in disabled = %v, want all-off error", err)
	}
}
