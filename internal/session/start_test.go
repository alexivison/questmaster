//go:build linux || darwin

package session

import (
	"context"
	"errors"
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
	if err := store.Create(state.Manifest{SessionID: "qm-100"}); err != nil {
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
	if result.SessionID == "qm-100" {
		t.Error("should have generated a different session ID after collision")
	}
}

func TestStartRollsBackWorkerAfterTmuxCreateFails(t *testing.T) {
	stateRoot := t.TempDir()
	setTestStateRoot(t, stateRoot)

	svc, runner := setupService(t)
	svc.Now = func() int64 { return 203 }
	masterID := "qm-master"
	sessionID := "qm-203"
	createTestManifest(t, svc.Store, masterID, "master", t.TempDir(), "master")

	runner.fn = func(ctx context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "new-session" {
			return "", errors.New("tmux create failed")
		}
		return runner.defaultHandler(ctx, args...)
	}

	result, err := svc.Start(t.Context(), StartOpts{
		Cwd:      t.TempDir(),
		MasterID: masterID,
	})
	if err == nil {
		t.Fatal("Start error = nil, want tmux create failure")
	}
	if !strings.Contains(err.Error(), "tmux create failed") {
		t.Fatalf("Start error %q does not include tmux create failure", err)
	}
	if result.SessionID != "" {
		t.Fatalf("failed Start returned session id %q", result.SessionID)
	}
	workers, err := svc.Store.GetWorkers(masterID)
	if err != nil {
		t.Fatalf("get workers: %v", err)
	}
	if len(workers) != 0 {
		t.Fatalf("master workers after rollback = %v, want empty", workers)
	}
	if _, err := svc.Store.Read(sessionID); err == nil {
		t.Fatalf("worker manifest %s should be removed after rollback", sessionID)
	}
	if _, err := os.Stat(runtimeDir(sessionID)); !os.IsNotExist(err) {
		t.Fatalf("runtime dir should be removed after rollback, stat err=%v", err)
	}
	if _, err := os.Stat(state.SessionStateDir(stateRoot, sessionID)); !os.IsNotExist(err) {
		t.Fatalf("session state dir should be removed after rollback, stat err=%v", err)
	}
	if !runner.hasCall("kill-session", "-t", sessionID) {
		t.Fatalf("rollback should best-effort kill partial tmux session")
	}
}

// #100: a pre-tmux failure (here worker registration, because the parent
// master manifest is missing) must roll back the freshly created manifest,
// runtime dir, and state dir — mirroring the post-tmux rollback so a partial
// Start never leaks a half-registered session.
func TestStartRollsBackManifestWhenWorkerRegistrationFails(t *testing.T) {
	stateRoot := t.TempDir()
	setTestStateRoot(t, stateRoot)

	svc, _ := setupService(t)
	svc.Now = func() int64 { return 207 }
	sessionID := "qm-207"

	_, err := svc.Start(t.Context(), StartOpts{
		Cwd:      t.TempDir(),
		MasterID: "qm-ghost-master", // valid ID, but no manifest on disk
	})
	if err == nil {
		t.Fatal("Start error = nil, want worker registration failure")
	}
	if !strings.Contains(err.Error(), "register worker") {
		t.Fatalf("Start error %q does not mention worker registration", err)
	}
	if _, err := svc.Store.Read(sessionID); err == nil {
		t.Fatalf("manifest %s should be removed after rollback", sessionID)
	}
	if _, err := os.Stat(runtimeDir(sessionID)); !os.IsNotExist(err) {
		t.Fatalf("runtime dir should be removed after rollback, stat err=%v", err)
	}
	if _, err := os.Stat(state.SessionStateDir(stateRoot, sessionID)); !os.IsNotExist(err) {
		t.Fatalf("session state dir should be removed after rollback, stat err=%v", err)
	}
}

func TestStart_MissingAgentBinaryErrorNamesOverrideAndFallback(t *testing.T) {
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
	runner := &testRunner{fn: func(_ context.Context, _ ...string) (string, error) {
		t.Fatal("Start should fail before invoking tmux")
		return "", nil
	}}
	// Now/RandSuffix are set defensively: if resolution ever unexpectedly
	// succeeds, Start fails on a clear assertion instead of a nil-func panic.
	svc := &Service{
		Store:      store,
		Client:     tmux.NewClient(runner),
		Now:        func() int64 { return 128 },
		RandSuffix: func() int64 { return 1 },
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

func TestStart_ResolvesAgentFromInteractiveLoginShellPath(t *testing.T) {
	t.Setenv("PATH", "/nonexistent")
	t.Setenv("HOME", t.TempDir())
	t.Setenv("OMP_BIN", "")

	binDir := t.TempDir()
	ompPath := filepath.Join(binDir, "omp")
	if err := os.WriteFile(ompPath, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write omp fixture: %v", err)
	}

	shellPath := filepath.Join(t.TempDir(), "login-shell")
	shellScript := "#!/bin/sh\n" +
		"PATH=" + shellQuoteForTest(binDir+":/usr/bin:/bin") + "\n" +
		"export PATH\n" +
		"while [ \"$#\" -gt 0 ]; do\n" +
		"  if [ \"$1\" = \"-c\" ]; then\n" +
		"    shift\n" +
		"    exec /bin/sh -c \"$1\"\n" +
		"  fi\n" +
		"  shift\n" +
		"done\n" +
		"exec /bin/sh\n"
	if err := os.WriteFile(shellPath, []byte(shellScript), 0o755); err != nil {
		t.Fatalf("write shell fixture: %v", err)
	}
	t.Setenv("SHELL", shellPath)

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	runner := newMockRunner()
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"omp": {CLI: "omp"},
		},
		Roles: agent.RolesConfig{
			Primary: &agent.RoleConfig{Agent: "omp", Window: -1},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	svc := &Service{
		Store:       store,
		Client:      tmux.NewClient(runner),
		Registry:    registry,
		Now:         func() int64 { return 204 },
		RandSuffix:  func() int64 { return 12 },
		CLIResolver: func(string) (string, error) { return "echo noop", nil },
	}

	result, err := svc.Start(t.Context(), StartOpts{
		Cwd:     t.TempDir(),
		FromApp: true,
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if len(m.Agents) != 1 || m.Agents[0].CLI != ompPath {
		t.Fatalf("manifest agent CLI = %+v, want %q", m.Agents, ompPath)
	}
	if !pathContainsDir(m.AgentPath, binDir) {
		t.Fatalf("manifest agent path %q does not contain %q", m.AgentPath, binDir)
	}
	if got := runner.envVars[result.SessionID+":PATH"]; !pathContainsDir(got, binDir) {
		t.Fatalf("tmux PATH %q does not contain %q", got, binDir)
	}
	launch := findLaunchArgContaining(runner, ompPath)
	if launch == "" {
		t.Fatalf("primary launch command did not include resolved omp path %q", ompPath)
	}
	if !strings.Contains(launch, "export PATH=") || !strings.Contains(launch, binDir) {
		t.Fatalf("primary launch command did not export login-derived PATH: %q", launch)
	}
}

func shellQuoteForTest(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func pathContainsDir(path, dir string) bool {
	for _, part := range filepath.SplitList(path) {
		if part == dir {
			return true
		}
	}
	return false
}

// W4: Cleanup script uses jq without checking availability.
// The parent session ID is now embedded at generation time so jq is only
// used behind availability checks for best-effort JSON rewrites.
func TestWriteCleanupScript_ChecksJqAvailability(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	path := filepath.Join(dir, "cleanup.sh")

	if err := writeCleanupScript(path, "/tmp/state", "qm-test", "qm-master"); err != nil {
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
	if !strings.Contains(script, "qm-master") {
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
	sessionID := "qm-pi-cleanup-resume"
	resumeID := "019dee69-5623-75c9-9317-04bf7f94e92b"
	if err := store.Create(state.Manifest{
		SessionID: sessionID,
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

	if err := writeCleanupScript(path, "/tmp/state", "qm-worker", "qm-master"); err != nil {
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

	masterID := "qm-master-wrong-hook"
	workerID := "qm-worker-wrong-hook"
	otherID := "qm-other-wrong-hook"
	if err := store.Create(state.Manifest{SessionID: masterID, SessionType: "master", Workers: []string{workerID}}); err != nil {
		t.Fatalf("create master: %v", err)
	}
	if err := store.Create(state.Manifest{SessionID: workerID}); err != nil {
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

	if err := writeCleanupScript(path, "/tmp/state", "qm-standalone", ""); err != nil {
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
