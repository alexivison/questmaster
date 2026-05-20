//go:build linux || darwin

package session

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
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
			Primary:   &agent.RoleConfig{Agent: "claude", Window: -1},
			Companion: &agent.RoleConfig{Agent: "codex", Window: 0},
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
	if out, err := exec.Command("/bin/sh", scriptPath).CombinedOutput(); err != nil {
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
