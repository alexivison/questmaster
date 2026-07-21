//go:build linux || darwin

package session

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func TestContinueAgentlessManifestLaunchesShell(t *testing.T) {
	t.Parallel()

	svc, runner := setupService(t)
	setMissingPrimaryRegistry(t, svc)
	sessionID := "qm-shell-continue"
	if err := svc.Store.Create(state.Manifest{
		SessionID: sessionID,
		Title:     "plain",
		Cwd:       t.TempDir(),
		AgentPath: "/missing-agent-path",
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	result, err := svc.Continue(t.Context(), sessionID)
	if err != nil {
		t.Fatalf("Continue shell: %v", err)
	}
	if result.Reattach {
		t.Fatal("agentless stopped session should be recreated, not reattached")
	}
	if !runner.sessions[sessionID] {
		t.Fatal("tmux session not recreated")
	}
	if got := runner.paneRoles[sessionID+":0.0"]; got != tmux.RoleShell {
		t.Fatalf("pane role = %q, want shell", got)
	}
	if runner.hasCall("split-window") {
		t.Fatalf("shell continue should not split panes, calls=%v", runner.calls)
	}

	updated, err := svc.Store.Read(sessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if len(updated.Agents) != 0 {
		t.Fatalf("continued shell agents = %+v, want none", updated.Agents)
	}
	if updated.ExtraString("last_resumed_at") == "" {
		t.Fatal("last_resumed_at was not set")
	}
}

func TestContinue_MissingAgentBinaryErrorNamesOverrideAndFallback(t *testing.T) {
	t.Setenv("PATH", "/nonexistent")
	t.Setenv("CLAUDE_BIN", "")
	t.Setenv("HOME", t.TempDir())
	// Isolate the login-shell PATH probe: a real agent CLI on the dev/CI
	// machine's interactive shell would otherwise let resolution succeed and
	// skip the expected "CLI not found" return.
	t.Setenv("SHELL", "/bin/false")

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{
		SessionID: "qm-missing-cli",
		Cwd:       t.TempDir(),
		Agents: []state.AgentManifest{
			{Name: "claude", Role: "primary", Window: 1},
		},
	}); err != nil {
		t.Fatal(err)
	}

	runner := &testRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1}
		}
		t.Fatalf("Continue should fail before invoking tmux command %v", args)
		return "", nil
	}}
	// Now/RandSuffix are set defensively: if resolution ever unexpectedly
	// succeeds, Continue fails on a clear assertion instead of a nil-func panic.
	svc := &Service{
		Store:      store,
		Client:     tmux.NewClient(runner),
		Now:        func() int64 { return 16 },
		RandSuffix: func() int64 { return 1 },
	}

	_, err = svc.Continue(t.Context(), "qm-missing-cli")
	if err == nil {
		t.Fatal("Continue error = nil, want missing binary error")
	}

	msg := err.Error()
	for _, want := range []string{"claude CLI not found", `PATH lookup for "claude"`, "CLAUDE_BIN", "~/.local/bin/claude"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("Continue error %q does not contain %q", msg, want)
		}
	}
}

// #98: when the slow (reconstruct) path fails during launch, Continue must
// best-effort kill the partial tmux session it just created. Unlike Start's
// rollback, the pre-existing manifest MUST be preserved so a later retry can
// rebuild the session from it.
func TestContinueKillsTmuxSessionOnLaunchFailureButPreservesManifest(t *testing.T) {
	setTestStateRoot(t, t.TempDir())

	svc, runner := setupService(t)
	svc.Now = func() int64 { return 298 }
	sessionID := "qm-298"
	createTestManifest(t, svc.Store, sessionID, "doomed", t.TempDir(), "")

	// Fail the first launchSession tmux step (set-environment), which runs
	// after new-session has already created the session.
	runner.fn = func(ctx context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "set-environment" {
			return "", errors.New("set-environment failed")
		}
		return runner.defaultHandler(ctx, args...)
	}

	if _, err := svc.Continue(t.Context(), sessionID); err == nil {
		t.Fatal("Continue error = nil, want launch failure")
	}

	if !runner.hasCall("kill-session", "-t", sessionID) {
		t.Fatal("Continue should best-effort kill the partial tmux session on launch failure")
	}
	if runner.sessions[sessionID] {
		t.Fatal("partial tmux session should be gone after launch failure")
	}
	if _, err := svc.Store.Read(sessionID); err != nil {
		t.Fatalf("manifest must be preserved on Continue failure for retry, got: %v", err)
	}
}

func TestContinueRefreshesQuestmasterPrefixInPersistedAgentPath(t *testing.T) {
	prefix := filepath.Join(t.TempDir(), "qm-shim")
	t.Setenv("QUESTMASTER_PATH_PREFIX", prefix)

	svc, _ := setupService(t)
	sessionID := "qm-refresh-prefix"
	createTestManifest(t, svc.Store, sessionID, "old-work", t.TempDir(), "")

	if _, err := svc.Continue(t.Context(), sessionID); err != nil {
		t.Fatalf("continue: %v", err)
	}

	m, err := svc.Store.Read(sessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	parts := filepath.SplitList(m.AgentPath)
	if len(parts) == 0 || parts[0] != prefix {
		t.Fatalf("continued manifest agent path = %q, want prefix %q first", m.AgentPath, prefix)
	}
}

func TestContinueAliveRefreshesAppOwnedEnvironment(t *testing.T) {
	setTestStateRoot(t, t.TempDir())
	bin := filepath.Join(t.TempDir(), "qm")
	prefix := filepath.Join(t.TempDir(), "qm-shim")
	t.Setenv("QUESTMASTER_BIN", bin)
	t.Setenv("QUESTMASTER_PATH_PREFIX", prefix)
	t.Setenv("QUESTMASTER_APP", "1")

	svc, runner := setupService(t)
	sessionID := "qm-alive-refresh-env"
	runner.sessions[sessionID] = true
	createTestManifest(t, svc.Store, sessionID, "alive", t.TempDir(), "")

	result, err := svc.Continue(t.Context(), sessionID)
	if err != nil {
		t.Fatalf("continue: %v", err)
	}
	if !result.Reattach {
		t.Fatal("alive continue should reattach")
	}

	wants := map[string]string{
		"QUESTMASTER_BIN":         bin,
		"QUESTMASTER_PATH_PREFIX": prefix,
		"QUESTMASTER_APP":         "1",
	}
	for key, want := range wants {
		if got := runner.envVars[sessionID+":"+key]; got != want {
			t.Fatalf("tmux env %s = %q, want %q", key, got, want)
		}
	}
	if !runner.hasCall("set-environment", "-t", sessionID, "-u", "QUESTMASTER_HOME") {
		t.Fatal("legacy QUESTMASTER_HOME must be cleared")
	}
	if got := runner.envVars[sessionID+":PATH"]; filepath.SplitList(got)[0] != prefix {
		t.Fatalf("alive continue PATH = %q, want prefix %q first", got, prefix)
	}
}

// W3: cascadeWorkers should distinguish missing manifests (intentionally
// stopped workers) from corrupt manifests (unreadable data). Missing
// manifests are skipped silently; corrupt manifests are added to failed.
func TestCascadeWorkers_MissingVsCorruptManifest(t *testing.T) {
	t.Parallel()

	storeDir := t.TempDir()
	store, err := state.NewStore(storeDir)
	if err != nil {
		t.Fatal(err)
	}

	masterID := "qm-master"

	// Create master manifest with three workers.
	master := state.Manifest{
		SessionID:   masterID,
		SessionType: "master",
		Workers:     []string{"qm-missing", "qm-corrupt", "qm-alive"},
	}
	if err := store.Create(master); err != nil {
		t.Fatal(err)
	}

	// qm-missing: no manifest on disk (intentionally stopped) — should skip.
	// (no file created)

	// qm-corrupt: invalid JSON at manifest path — should appear in failed.
	corruptPath := filepath.Join(storeDir, "qm-corrupt.json")
	if err := os.WriteFile(corruptPath, []byte("{not valid json"), 0o644); err != nil {
		t.Fatal(err)
	}

	// qm-alive: has manifest and tmux session — should skip (already running).
	aliveManifest := state.Manifest{SessionID: "qm-alive"}
	aliveManifest.SetExtra("parent_session", masterID)
	if err := store.Create(aliveManifest); err != nil {
		t.Fatal(err)
	}

	runner := &testRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if args[0] == "has-session" {
			for i, a := range args {
				if a == "-t" && i+1 < len(args) && args[i+1] == "qm-alive" {
					return "", nil // alive session exists
				}
			}
			return "", &tmux.ExitError{Code: 1} // session doesn't exist
		}
		return "", nil
	}}

	svc := &Service{
		Store:       store,
		Client:      tmux.NewClient(runner),
		CLIResolver: func(string) (string, error) { return "echo noop", nil },
		Now:         func() int64 { return 200 },
		RandSuffix:  func() int64 { return 99 },
	}

	_, failed := svc.cascadeWorkers(t.Context(), masterID)

	// qm-missing should be skipped, NOT in failed.
	for _, f := range failed {
		if f == "qm-missing" {
			t.Error("missing-manifest worker should be skipped, not marked as failed")
		}
	}

	// qm-corrupt should be in failed.
	corruptFound := false
	for _, f := range failed {
		if f == "qm-corrupt" {
			corruptFound = true
			break
		}
	}
	if !corruptFound {
		t.Error("corrupt-manifest worker should appear in failed list")
	}

	// qm-alive should not be in failed (it's running).
	for _, f := range failed {
		if f == "qm-alive" {
			t.Error("already-running worker should not appear in failed list")
		}
	}
}
