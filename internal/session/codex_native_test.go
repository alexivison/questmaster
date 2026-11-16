package session

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/codexnative"
)

func TestCodexNativeRuntimeFollowsLaunchOptIn(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "qm-native-runtime-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	lc := launchConfig{runtimeDir: dir, agents: map[agent.Role]agent.Agent{agent.RoleAgent: agent.NewCodex(agent.AgentConfig{})}}
	t.Setenv(agent.CodexNativeEnv, "1")
	if err := prepareCodexNativeRuntime(lc); err != nil {
		t.Fatal(err)
	}
	if enabled, err := codexnative.Enabled(dir); err != nil || !enabled {
		t.Fatalf("enabled=%v error=%v", enabled, err)
	}
	t.Setenv(agent.CodexNativeEnv, "")
	if err := prepareCodexNativeRuntime(lc); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, codexnative.MarkerName)); !os.IsNotExist(err) {
		t.Fatalf("opt-out retained marker: %v", err)
	}
}
