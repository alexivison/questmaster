package session

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/codexnative"
	"github.com/alexivison/questmaster/internal/state"
)

func TestCodexNativeRuntimeFollowsProvider(t *testing.T) {
	t.Parallel()
	dir, err := os.MkdirTemp("/tmp", "qm-native-runtime-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	lc := launchConfig{runtimeDir: dir, agents: map[agent.Role]agent.Agent{agent.RoleAgent: agent.NewCodex(agent.AgentConfig{})}}
	if err := prepareCodexNativeRuntime(lc); err != nil {
		t.Fatal(err)
	}
	if enabled, err := codexnative.Enabled(dir); err != nil || !enabled {
		t.Fatalf("enabled=%v error=%v", enabled, err)
	}
	lc.agents[agent.RoleAgent] = agent.NewClaude(agent.AgentConfig{})
	if err := prepareCodexNativeRuntime(lc); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, codexnative.MarkerName)); !os.IsNotExist(err) {
		t.Fatalf("non-Codex provider retained marker: %v", err)
	}
}

func TestContinueCodexMigratesOnlyWhenRespawning(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name           string
		legacy         bool
		dead           bool
		oldRuntime     bool
		missingRuntime bool
	}{
		{name: "legacy dead pane", legacy: true, dead: true},
		{name: "native dead pane", dead: true},
		{name: "old manifest", legacy: true, dead: true, oldRuntime: true},
		{name: "recreate runtime", dead: true, missingRuntime: true},
		{name: "live legacy", legacy: true},
		{name: "live native"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			svc, runner := setupService(t)
			svc.Now = uniqueSessionClock()
			registry, err := agent.NewRegistry(&agent.Config{
				Agents: map[string]agent.AgentConfig{"codex": {CLI: "/bin/sh"}},
				Roles:  agent.RolesConfig{Agent: &agent.RoleConfig{Agent: "codex"}},
			})
			if err != nil {
				t.Fatal(err)
			}
			svc.Registry = registry
			started, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), ResumeIDs: map[string]string{"codex": "example-thread"}})
			if err != nil {
				t.Fatal(err)
			}
			pane := runner.sessionPane(started.SessionID)
			if tc.legacy {
				if err := os.Remove(filepath.Join(started.RuntimeDir, codexnative.MarkerName)); err != nil {
					t.Fatal(err)
				}
			}
			if tc.oldRuntime {
				if err := svc.Store.Update(started.SessionID, func(m *state.Manifest) { m.RuntimeDir = "" }); err != nil {
					t.Fatal(err)
				}
			}
			if tc.oldRuntime || tc.missingRuntime {
				if err := os.RemoveAll(started.RuntimeDir); err != nil {
					t.Fatal(err)
				}
			}
			if tc.dead {
				runner.deadPanes[pane] = "17"
			}
			before := len(runner.calls)
			continued, err := svc.Continue(t.Context(), started.SessionID)
			if err != nil {
				t.Fatal(err)
			}
			if continued.Respawned != tc.dead {
				t.Fatalf("respawned=%v, want %v", continued.Respawned, tc.dead)
			}
			m, err := svc.Store.Read(started.SessionID)
			if err != nil {
				t.Fatal(err)
			}
			if m.RuntimeDir != started.RuntimeDir || runner.envVars[started.SessionID+":"+state.RuntimeDirEnv] != m.RuntimeDir {
				t.Fatalf("runtime manifest=%q environment=%q, want %q", m.RuntimeDir, runner.envVars[started.SessionID+":"+state.RuntimeDirEnv], started.RuntimeDir)
			}
			wantNative := !tc.legacy || tc.dead
			if tc.dead {
				respawns := callsAfter(runner, before, "respawn-pane")
				if len(respawns) != 1 || strings.Contains(respawns[0][len(respawns[0])-1], " agent codex ") != wantNative {
					t.Fatalf("respawn commands=%v, want native=%v", respawns, wantNative)
				}
			}
			if enabled, err := codexnative.Enabled(started.RuntimeDir); err != nil || enabled != wantNative {
				t.Fatalf("runtime native=%v error=%v, want %v", enabled, err, wantNative)
			}
		})
	}
}
