//go:build linux || darwin

package session

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

// C2: TOCTOU race — generateSessionID checks HasSession but not the manifest
// store. When another process creates a manifest between check and create,
// Start should retry with a different ID instead of failing.
func TestStart_RetriesOnIDCollision(t *testing.T) {
	t.Parallel()

	storeDir := t.TempDir()
	store, err := state.NewStore(storeDir)
	if err != nil {
		t.Fatal(err)
	}

	// Pre-create manifest for the base ID to simulate a concurrent process
	// claiming it between HasSession and Store.Create.
	if err := store.Create(state.Manifest{PartyID: "party-100"}); err != nil {
		t.Fatal(err)
	}

	runner := &testRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1} // no tmux session exists
		}
		return "", nil // all other tmux commands succeed
	}}
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"claude": {CLI: "/bin/sh"},
			"codex":  {CLI: "/bin/sh"},
		},
		Roles: agent.RolesConfig{
			Primary: &agent.RoleConfig{Agent: "claude", Window: -1},
		},
	})
	if err != nil {
		t.Fatal(err)
	}

	svc := &Service{
		Store:       store,
		Client:      tmux.NewClient(runner),
		Registry:    registry,
		Now:         func() int64 { return 100 },
		RandSuffix:  func() int64 { return 42 },
		CLIResolver: func(string) (string, error) { return "echo noop", nil },
	}

	result, err := svc.Start(t.Context(), StartOpts{
		Cwd: t.TempDir(),
	})
	if err != nil {
		t.Fatalf("Start should retry on ID collision, got: %v", err)
	}
	if result.SessionID == "party-100" {
		t.Error("should have generated a different session ID after collision")
	}
}

func TestStart_MissingAgentBinaryErrorNamesOverrideAndFallback(t *testing.T) {
	t.Setenv("PATH", "/nonexistent")
	t.Setenv("CLAUDE_BIN", "")
	t.Setenv("HOME", t.TempDir())

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	runner := &testRunner{fn: func(_ context.Context, _ ...string) (string, error) {
		t.Fatal("Start should fail before invoking tmux")
		return "", nil
	}}
	svc := &Service{
		Store:  store,
		Client: tmux.NewClient(runner),
	}

	_, err = svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()})
	if err == nil {
		t.Fatal("Start error = nil, want missing binary error")
	}

	msg := err.Error()
	for _, want := range []string{"claude CLI not found", `PATH lookup for "claude"`, "CLAUDE_BIN", "~/.local/bin/claude"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("Start error %q does not contain %q", msg, want)
		}
	}
}

// W4: Cleanup script uses jq without checking availability.
// The parent session ID is now embedded at generation time so jq is only
// used behind availability checks for best-effort JSON rewrites.
func TestWriteCleanupScript_ChecksJqAvailability(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "cleanup.sh")

	if err := writeCleanupScript(path, "/tmp/state", "party-test", "party-master"); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	script := string(data)

	// jq usage (worker-list rewrite) should be guarded.
	if !strings.Contains(script, "command -v jq") {
		t.Error("cleanup script should check for jq availability before using it")
	}

	// Parent ID should be embedded, not discovered at runtime.
	if !strings.Contains(script, "party-master") {
		t.Error("cleanup script should embed the parent session ID")
	}
}

func TestWriteCleanupScript_PersistsPiResumeID(t *testing.T) {
	if _, err := exec.LookPath("jq"); err != nil {
		t.Skip("jq not available")
	}

	storeDir := t.TempDir()
	store, err := state.NewStore(storeDir)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	sessionID := "party-pi-cleanup-resume"
	resumeID := "019dee69-5623-75c9-9317-04bf7f94e92b"
	if err := store.Create(state.Manifest{
		PartyID: sessionID,
		Agents: []state.AgentManifest{
			{Name: "pi", Role: "primary", CLI: "/usr/bin/pi", Window: 1},
		},
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}
	writePiResumeState(t, store, sessionID, resumeID)

	scriptPath := filepath.Join("/tmp", sessionID, "cleanup.sh")
	if err := writeCleanupScript(scriptPath, store.Root(), sessionID, ""); err != nil {
		t.Fatalf("write cleanup script: %v", err)
	}
	if out, err := exec.Command("/bin/sh", scriptPath, sessionID).CombinedOutput(); err != nil {
		t.Fatalf("run cleanup script: %v\n%s", err, out)
	}

	m, err := store.Read(sessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if got := manifestAgentResumeID(m.Agents, "primary"); got != resumeID {
		t.Fatalf("primary resume_id: got %q, want %q", got, resumeID)
	}
	if got := m.ExtraString("pi_session_id"); got != resumeID {
		t.Fatalf("pi_session_id: got %q, want %q", got, resumeID)
	}
	if _, err := os.Stat(filepath.Join("/tmp", sessionID)); !os.IsNotExist(err) {
		t.Fatalf("runtime dir should be removed, stat err=%v", err)
	}
}

// Cleanup script must NOT delete worker manifests — prune handles that.
// Premature deletion causes the picker to misclassify workers as standalone.
func TestWriteCleanupScript_DoesNotDeleteWorkerManifest(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "cleanup.sh")

	if err := writeCleanupScript(path, "/tmp/state", "party-worker", "party-master"); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	script := string(data)

	if strings.Contains(script, "rm -f \"$SR/$W.json\"") {
		t.Error("cleanup script must not delete worker manifest; prune handles cleanup")
	}
	if strings.Contains(script, "rm -f \"$SR/$W.json.lock\"") {
		t.Error("cleanup script must not delete worker manifest lock")
	}
}

func TestWriteCleanupScript_IgnoresDifferentClosedSession(t *testing.T) {
	storeDir := t.TempDir()
	store, err := state.NewStore(storeDir)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}

	masterID := "party-master-wrong-hook"
	workerID := "party-worker-wrong-hook"
	otherID := "party-other-wrong-hook"
	if err := store.Create(state.Manifest{PartyID: masterID, SessionType: "master", Workers: []string{workerID}}); err != nil {
		t.Fatalf("create master: %v", err)
	}
	if err := store.Create(state.Manifest{PartyID: workerID}); err != nil {
		t.Fatalf("create worker: %v", err)
	}
	if err := store.Update(workerID, func(m *state.Manifest) {
		m.SetExtra("parent_session", masterID)
	}); err != nil {
		t.Fatalf("set parent: %v", err)
	}

	runtime := filepath.Join("/tmp", workerID)
	if err := os.RemoveAll(runtime); err != nil {
		t.Fatalf("remove stale runtime: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(runtime) })
	if err := os.MkdirAll(runtime, 0o755); err != nil {
		t.Fatalf("mkdir runtime: %v", err)
	}

	scriptPath := filepath.Join(runtime, "cleanup.sh")
	if err := writeCleanupScript(scriptPath, store.Root(), workerID, masterID); err != nil {
		t.Fatalf("write cleanup script: %v", err)
	}
	if out, err := exec.Command("/bin/sh", scriptPath, otherID).CombinedOutput(); err != nil {
		t.Fatalf("run cleanup script: %v\n%s", err, out)
	}

	if _, err := os.Stat(runtime); err != nil {
		t.Fatalf("runtime dir should remain for unrelated closed session, stat err=%v", err)
	}

	workers, err := store.GetWorkers(masterID)
	if err != nil {
		t.Fatalf("get workers: %v", err)
	}
	if len(workers) != 1 || workers[0] != workerID {
		t.Fatalf("workers after unrelated close = %v, want [%s]", workers, workerID)
	}
}

func TestWriteCleanupScript_NoParent(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "cleanup.sh")

	if err := writeCleanupScript(path, "/tmp/state", "party-standalone", ""); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	script := string(data)

	// Standalone sessions should still clean up runtime dir.
	if !strings.Contains(script, "rm -rf") {
		t.Error("cleanup script should remove runtime dir for standalone sessions")
	}
}
