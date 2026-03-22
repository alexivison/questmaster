//go:build linux || darwin

package session

import (
	"context"
	"strings"
	"testing"

	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

// ---------------------------------------------------------------------------
// Mock tmux runner — records all tmux commands
// ---------------------------------------------------------------------------

type callRecord struct {
	args []string
}

type mockRunner struct {
	calls     []callRecord
	fn        func(ctx context.Context, args ...string) (string, error)
	sessions  map[string]bool
	paneRoles map[string]string // target → role
	envVars   map[string]string // session:key → value
}

func newMockRunner() *mockRunner {
	r := &mockRunner{
		sessions:  make(map[string]bool),
		paneRoles: make(map[string]string),
		envVars:   make(map[string]string),
	}
	r.fn = r.defaultHandler
	return r
}

func (m *mockRunner) Run(ctx context.Context, args ...string) (string, error) {
	m.calls = append(m.calls, callRecord{args: args})
	return m.fn(ctx, args...)
}

func (m *mockRunner) defaultHandler(_ context.Context, args ...string) (string, error) {
	if len(args) == 0 {
		return "", nil
	}
	switch args[0] {
	case "has-session":
		session := flagVal(args, "-t")
		if m.sessions[session] {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}

	case "new-session":
		session := flagVal(args, "-s")
		m.sessions[session] = true
		return "", nil

	case "kill-session":
		session := flagVal(args, "-t")
		delete(m.sessions, session)
		return "", nil

	case "list-sessions":
		var names []string
		for s := range m.sessions {
			names = append(names, s)
		}
		if len(names) == 0 {
			return "", &tmux.ExitError{Code: 1}
		}
		return strings.Join(names, "\n"), nil

	case "set-option":
		target := flagVal(args, "-t")
		// Find key and value after flags
		key, val := extractSetOption(args)
		if key == "@party_role" {
			m.paneRoles[target] = val
		}
		return "", nil

	case "set-environment":
		target := flagVal(args, "-t")
		if len(args) >= 4 {
			key := args[len(args)-2]
			val := args[len(args)-1]
			// Check for -u (unset)
			for _, a := range args {
				if a == "-u" {
					delete(m.envVars, target+":"+args[len(args)-1])
					return "", nil
				}
			}
			m.envVars[target+":"+key] = val
		}
		return "", nil

	case "show-environment":
		target := flagVal(args, "-t")
		key := args[len(args)-1]
		val, ok := m.envVars[target+":"+key]
		if !ok {
			return "", &tmux.ExitError{Code: 1}
		}
		return key + "=" + val, nil

	case "list-panes":
		session := flagVal(args, "-t")
		var lines []string
		for target, role := range m.paneRoles {
			if strings.HasPrefix(target, session+":") {
				// Parse "session:W.P"
				rest := target[len(session)+1:]
				parts := strings.SplitN(rest, ".", 2)
				if len(parts) == 2 {
					lines = append(lines, parts[0]+" "+parts[1]+" "+role)
				}
			}
		}
		if len(lines) == 0 {
			return "", &tmux.ExitError{Code: 1}
		}
		return strings.Join(lines, "\n"), nil

	default:
		// All other commands succeed silently
		return "", nil
	}
}

// flagVal extracts the value following a flag.
func flagVal(args []string, flag string) string {
	for i, a := range args {
		if a == flag && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

// extractSetOption extracts key and value from set-option args.
func extractSetOption(args []string) (string, string) {
	// set-option [-p] [-w] [-t target] key value
	nonFlag := make([]string, 0)
	skip := false
	for _, a := range args[1:] {
		if skip {
			skip = false
			continue
		}
		if a == "-t" {
			skip = true
			continue
		}
		if strings.HasPrefix(a, "-") {
			continue
		}
		nonFlag = append(nonFlag, a)
	}
	if len(nonFlag) >= 2 {
		return nonFlag[0], nonFlag[1]
	}
	if len(nonFlag) == 1 {
		return nonFlag[0], ""
	}
	return "", ""
}

// hasCall checks if any tmux call matches the prefix args.
func (m *mockRunner) hasCall(prefix ...string) bool {
	for _, c := range m.calls {
		if len(c.args) >= len(prefix) {
			match := true
			for i, p := range prefix {
				if c.args[i] != p {
					match = false
					break
				}
			}
			if match {
				return true
			}
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

func setupService(t *testing.T) (*Service, *mockRunner) {
	t.Helper()
	dir := t.TempDir()
	store, err := state.NewStore(dir)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	runner := newMockRunner()
	client := tmux.NewClient(runner)
	svc := NewService(store, client, "/fake/repo")
	svc.CLIResolver = func(_ string) (string, error) { return "echo party-cli", nil }
	return svc, runner
}

func createTestManifest(t *testing.T, store *state.Store, id, title, cwd, sessionType string) {
	t.Helper()
	m := state.Manifest{
		PartyID:     id,
		Title:       title,
		Cwd:         cwd,
		SessionType: sessionType,
		ClaudeBin:   "/usr/bin/claude",
		CodexBin:    "/usr/bin/codex",
		AgentPath:   "/usr/bin",
	}
	if err := store.Create(m); err != nil {
		t.Fatalf("create manifest %s: %v", id, err)
	}
}

// ---------------------------------------------------------------------------
// Start tests
// ---------------------------------------------------------------------------

func TestStart_Standalone(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 1234567890 }

	result, err := svc.Start(t.Context(), StartOpts{
		Title: "test-project",
		Cwd:   t.TempDir(),
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	if result.SessionID != "party-1234567890" {
		t.Fatalf("unexpected session ID: %s", result.SessionID)
	}

	// Verify tmux session was created
	if !runner.sessions[result.SessionID] {
		t.Fatal("session not created in tmux")
	}

	// Verify manifest was persisted
	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if m.Title != "test-project" {
		t.Fatalf("expected title 'test-project', got %q", m.Title)
	}

	// Verify cleanup hook was set
	if !runner.hasCall("set-hook") {
		t.Fatal("cleanup hook not set")
	}
}

func TestStart_Master(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 9999 }

	result, err := svc.Start(t.Context(), StartOpts{
		Title:  "orchestrator",
		Cwd:    t.TempDir(),
		Master: true,
	})
	if err != nil {
		t.Fatalf("start master: %v", err)
	}

	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if m.SessionType != "master" {
		t.Fatalf("expected master session type, got %q", m.SessionType)
	}

	// Master layout should have tracker role
	if runner.paneRoles[result.SessionID+":0.0"] != "tracker" {
		t.Fatalf("expected tracker in pane 0.0, got %q", runner.paneRoles[result.SessionID+":0.0"])
	}
}

func TestStart_Worker(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	counter := int64(1000)
	svc.Now = func() int64 { counter++; return counter }

	// Create master first
	masterResult, err := svc.Start(t.Context(), StartOpts{
		Title:  "master",
		Cwd:    t.TempDir(),
		Master: true,
	})
	if err != nil {
		t.Fatalf("start master: %v", err)
	}

	// Start worker with master-id
	workerResult, err := svc.Start(t.Context(), StartOpts{
		Title:    "worker-1",
		Cwd:      t.TempDir(),
		MasterID: masterResult.SessionID,
	})
	if err != nil {
		t.Fatalf("start worker: %v", err)
	}

	// Verify worker registered with master
	workers, err := svc.Store.GetWorkers(masterResult.SessionID)
	if err != nil {
		t.Fatalf("get workers: %v", err)
	}
	if len(workers) != 1 || workers[0] != workerResult.SessionID {
		t.Fatalf("expected worker %s, got %v", workerResult.SessionID, workers)
	}
}

// ---------------------------------------------------------------------------
// Continue tests
// ---------------------------------------------------------------------------

func TestContinue_AlreadyRunning(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["party-existing"] = true

	result, err := svc.Continue(t.Context(), "party-existing")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}
	if !result.Reattach {
		t.Fatal("expected reattach=true for running session")
	}
	if result.SessionID != "party-existing" {
		t.Fatalf("expected party-existing, got %s", result.SessionID)
	}
}

func TestContinue_StoppedRegular(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "party-stopped", "old-work", cwd, "")

	result, err := svc.Continue(t.Context(), "party-stopped")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}
	if result.Reattach {
		t.Fatal("expected reattach=false for stopped session")
	}
	if result.Master {
		t.Fatal("expected master=false for regular session")
	}

	// Session should now be running
	if !runner.sessions["party-stopped"] {
		t.Fatal("session not recreated in tmux")
	}
}

func TestContinue_StoppedMaster(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "party-master", "orchestrator", cwd, "master")

	result, err := svc.Continue(t.Context(), "party-master")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}
	if result.Reattach {
		t.Fatal("expected reattach=false")
	}
	if !result.Master {
		t.Fatal("expected master=true for master session")
	}

	if !runner.sessions["party-master"] {
		t.Fatal("master session not recreated")
	}
	if runner.paneRoles["party-master:0.0"] != "tracker" {
		t.Fatalf("expected tracker in pane 0.0, got %q", runner.paneRoles["party-master:0.0"])
	}
}

func TestContinue_MissingManifest(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	_, err := svc.Continue(t.Context(), "party-ghost")
	if err == nil {
		t.Fatal("expected error for missing manifest")
	}
}

// ---------------------------------------------------------------------------
// Stop tests
// ---------------------------------------------------------------------------

func TestStop_Single(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["party-victim"] = true
	createTestManifest(t, svc.Store, "party-victim", "doomed", t.TempDir(), "")

	stopped, err := svc.Stop(t.Context(), "party-victim")
	if err != nil {
		t.Fatalf("stop: %v", err)
	}
	if len(stopped) != 1 || stopped[0] != "party-victim" {
		t.Fatalf("expected [party-victim], got %v", stopped)
	}
	if runner.sessions["party-victim"] {
		t.Fatal("session still exists after stop")
	}
}

func TestStop_All(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["party-a"] = true
	runner.sessions["party-b"] = true
	runner.sessions["non-party"] = true

	stopped, err := svc.Stop(t.Context(), "")
	if err != nil {
		t.Fatalf("stop all: %v", err)
	}

	// Should only stop party- sessions
	for _, id := range stopped {
		if !strings.HasPrefix(id, "party-") {
			t.Fatalf("stopped non-party session: %s", id)
		}
	}
	if runner.sessions["party-a"] || runner.sessions["party-b"] {
		t.Fatal("party sessions still exist after stop-all")
	}
	if !runner.sessions["non-party"] {
		t.Fatal("non-party session should not be stopped")
	}
}

func TestStop_InvalidName(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	_, err := svc.Stop(t.Context(), "bad-name")
	if err == nil {
		t.Fatal("expected error for invalid session name")
	}
}

// ---------------------------------------------------------------------------
// Delete tests
// ---------------------------------------------------------------------------

func TestDelete_RunningSession(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["party-del"] = true
	createTestManifest(t, svc.Store, "party-del", "deleteme", t.TempDir(), "")

	if err := svc.Delete(t.Context(), "party-del"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if runner.sessions["party-del"] {
		t.Fatal("session still exists after delete")
	}
	if _, err := svc.Store.Read("party-del"); err == nil {
		t.Fatal("manifest still exists after delete")
	}
}

func TestDelete_InvalidName(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	if err := svc.Delete(t.Context(), "invalid"); err == nil {
		t.Fatal("expected error for invalid session name")
	}
}

// ---------------------------------------------------------------------------
// Promote tests
// ---------------------------------------------------------------------------

func TestPromote_Classic(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["party-worker"] = true
	createTestManifest(t, svc.Store, "party-worker", "worker", t.TempDir(), "")

	// Set up classic layout panes
	runner.paneRoles["party-worker:0.0"] = "codex"
	runner.paneRoles["party-worker:0.1"] = "claude"
	runner.paneRoles["party-worker:0.2"] = "shell"

	if err := svc.Promote(t.Context(), "party-worker"); err != nil {
		t.Fatalf("promote: %v", err)
	}

	// Verify manifest updated
	m, err := svc.Store.Read("party-worker")
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if m.SessionType != "master" {
		t.Fatalf("expected master, got %q", m.SessionType)
	}

	// Verify codex pane replaced with tracker
	if runner.paneRoles["party-worker:0.0"] != "tracker" {
		t.Fatalf("expected tracker role in pane 0.0, got %q", runner.paneRoles["party-worker:0.0"])
	}
}

func TestPromote_Sidebar(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["party-side"] = true
	createTestManifest(t, svc.Store, "party-side", "sidebar-worker", t.TempDir(), "")

	// Set sidebar layout env
	runner.envVars["party-side:PARTY_LAYOUT"] = "sidebar"

	// Set up sidebar layout panes
	runner.paneRoles["party-side:0.0"] = "codex"
	runner.paneRoles["party-side:1.0"] = "sidebar"
	runner.paneRoles["party-side:1.1"] = "claude"
	runner.paneRoles["party-side:1.2"] = "shell"

	if err := svc.Promote(t.Context(), "party-side"); err != nil {
		t.Fatalf("promote sidebar: %v", err)
	}

	// Verify manifest updated
	m, err := svc.Store.Read("party-side")
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if m.SessionType != "master" {
		t.Fatalf("expected master, got %q", m.SessionType)
	}

	// Sidebar pane (window 1, pane 0) should now be tracker
	if runner.paneRoles["party-side:1.0"] != "tracker" {
		t.Fatalf("expected tracker in window 1 pane 0, got %q", runner.paneRoles["party-side:1.0"])
	}

	// Window 0 Codex pane should remain untouched
	if runner.paneRoles["party-side:0.0"] != "codex" {
		t.Fatalf("window 0 codex should remain, got %q", runner.paneRoles["party-side:0.0"])
	}
}

func TestPromote_AlreadyMaster(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["party-master"] = true
	createTestManifest(t, svc.Store, "party-master", "orch", t.TempDir(), "master")

	// Should be a no-op
	if err := svc.Promote(t.Context(), "party-master"); err != nil {
		t.Fatalf("promote idempotent: %v", err)
	}
}

func TestPromote_NotRunning(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	createTestManifest(t, svc.Store, "party-dead", "dead", t.TempDir(), "")

	err := svc.Promote(t.Context(), "party-dead")
	if err == nil {
		t.Fatal("expected error for non-running session")
	}
	if !strings.Contains(err.Error(), "not running") {
		t.Fatalf("expected 'not running' error, got: %v", err)
	}
}

// ---------------------------------------------------------------------------
// Spawn tests
// ---------------------------------------------------------------------------

func TestSpawn_FromMaster(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	counter := int64(5000)
	svc.Now = func() int64 { counter++; return counter }

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "party-master", "orch", cwd, "master")

	result, err := svc.Spawn(t.Context(), "party-master", SpawnOpts{
		Title: "worker-1",
	})
	if err != nil {
		t.Fatalf("spawn: %v", err)
	}

	// Verify worker registered
	workers, err := svc.Store.GetWorkers("party-master")
	if err != nil {
		t.Fatalf("get workers: %v", err)
	}
	if len(workers) != 1 || workers[0] != result.SessionID {
		t.Fatalf("expected worker %s, got %v", result.SessionID, workers)
	}

	// Worker inherits master's cwd
	wm, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read worker manifest: %v", err)
	}
	if wm.Cwd != cwd {
		t.Fatalf("expected cwd %s, got %s", cwd, wm.Cwd)
	}
}

func TestSpawn_FromNonMaster(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	createTestManifest(t, svc.Store, "party-worker", "regular", t.TempDir(), "")

	_, err := svc.Spawn(t.Context(), "party-worker", SpawnOpts{Title: "x"})
	if err == nil {
		t.Fatal("expected error spawning from non-master")
	}
	if !strings.Contains(err.Error(), "not a master") {
		t.Fatalf("expected 'not a master' error, got: %v", err)
	}
}

func TestSpawn_InvalidMasterID(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	_, err := svc.Spawn(t.Context(), "invalid", SpawnOpts{Title: "x"})
	if err == nil {
		t.Fatal("expected error for invalid master ID")
	}
}
