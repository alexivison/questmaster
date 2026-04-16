//go:build linux || darwin

package session

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
)

// ---------------------------------------------------------------------------
// Mock tmux runner — records all tmux commands
// ---------------------------------------------------------------------------

// splitBatchArgs splits args on ";" separators into individual command slices.
func splitBatchArgs(args []string) [][]string {
	var cmds [][]string
	var cur []string
	for _, a := range args {
		if a == ";" {
			if len(cur) > 0 {
				cmds = append(cmds, cur)
				cur = nil
			}
			continue
		}
		cur = append(cur, a)
	}
	if len(cur) > 0 {
		cmds = append(cmds, cur)
	}
	return cmds
}

type callRecord struct {
	args []string
}

type mockRunner struct {
	calls       []callRecord
	fn          func(ctx context.Context, args ...string) (string, error)
	sessions    map[string]bool
	paneRoles   map[string]string // target → role
	paneTitles  map[string]string // target → title
	envVars     map[string]string // session:key → value
	windowNames map[string]string // target → name
}

func newMockRunner() *mockRunner {
	r := &mockRunner{
		sessions:    make(map[string]bool),
		paneRoles:   make(map[string]string),
		paneTitles:  make(map[string]string),
		envVars:     make(map[string]string),
		windowNames: make(map[string]string),
	}
	r.fn = r.defaultHandler
	return r
}

func (m *mockRunner) Run(ctx context.Context, args ...string) (string, error) {
	m.calls = append(m.calls, callRecord{args: args})
	return m.fn(ctx, args...)
}

func (m *mockRunner) defaultHandler(ctx context.Context, args ...string) (string, error) {
	if len(args) == 0 {
		return "", nil
	}
	// Handle batched commands separated by ";".
	if cmds := splitBatchArgs(args); len(cmds) > 1 {
		for _, cmd := range cmds {
			if _, err := m.defaultHandler(ctx, cmd...); err != nil {
				return "", err
			}
		}
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

	case "rename-window":
		target := flagVal(args, "-t")
		if len(args) > 0 {
			m.windowNames[target] = args[len(args)-1]
		}
		return "", nil

	case "kill-window":
		target := flagVal(args, "-t")
		// Remove paneRoles whose target starts with this window prefix.
		for k := range m.paneRoles {
			if len(k) > len(target) && k[:len(target)] == target && k[len(target)] == '.' {
				delete(m.paneRoles, k)
			}
		}
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

	case "display-message":
		if len(args) > 0 && args[len(args)-1] == "#{pane_in_mode}" {
			return "0", nil
		}
		return "", nil

	case "select-pane":
		target := flagVal(args, "-t")
		for i, arg := range args {
			if arg == "-T" && i+1 < len(args) {
				m.paneTitles[target] = args[i+1]
				break
			}
		}
		return "", nil

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

func (m *mockRunner) hasSendText(target, text string) bool {
	for _, c := range m.calls {
		if len(c.args) != 6 {
			continue
		}
		if c.args[0] == "send-keys" && c.args[1] == "-t" && c.args[2] == target && c.args[3] == "-l" && c.args[4] == "--" && c.args[5] == text {
			return true
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
		t.Fatalf("NewRegistry: %v", err)
	}
	svc.Registry = registry
	svc.CLIResolver = func(_ string) (string, error) { return "echo party-cli", nil }
	return svc, runner
}

func launchCmds(primary, companion string) map[agent.Role]string {
	cmds := map[agent.Role]string{
		agent.RolePrimary: primary,
	}
	if companion != "" {
		cmds[agent.RoleCompanion] = companion
	}
	return cmds
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

func manifestAgentResumeID(agents []state.AgentManifest, role string) string {
	for _, spec := range agents {
		if spec.Role == role {
			return spec.ResumeID
		}
	}
	return ""
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
	if runner.paneTitles[result.SessionID+":0.0"] != "Tracker" {
		t.Fatalf("expected tracker title in pane 0.0, got %q", runner.paneTitles[result.SessionID+":0.0"])
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

func TestStart_SidebarSetsTrackerPaneTitle(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 4242 }

	result, err := svc.Start(t.Context(), StartOpts{
		Title: "tracker-title",
		Cwd:   t.TempDir(),
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	if runner.paneRoles[result.SessionID+":1.0"] != "tracker" {
		t.Fatalf("expected tracker role in pane 1.0, got %q", runner.paneRoles[result.SessionID+":1.0"])
	}
	if runner.paneTitles[result.SessionID+":1.0"] != "Tracker" {
		t.Fatalf("expected tracker title in pane 1.0, got %q", runner.paneTitles[result.SessionID+":1.0"])
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

func TestContinue_MasterCascadesOrphanedWorkers(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	cwd := t.TempDir()

	// Create master with two workers in its list
	createTestManifest(t, svc.Store, "party-mst", "master", cwd, "master")
	if err := svc.Store.AddWorker("party-mst", "party-w1"); err != nil {
		t.Fatalf("add worker: %v", err)
	}
	if err := svc.Store.AddWorker("party-mst", "party-w2"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	// Create worker manifests (orphaned — have manifest, no tmux session)
	createTestManifest(t, svc.Store, "party-w1", "worker-one", cwd, "")
	if err := svc.Store.Update("party-w1", func(m *state.Manifest) {
		m.SetExtra("parent_session", "party-mst")
	}); err != nil {
		t.Fatalf("set parent: %v", err)
	}
	createTestManifest(t, svc.Store, "party-w2", "worker-two", cwd, "")
	if err := svc.Store.Update("party-w2", func(m *state.Manifest) {
		m.SetExtra("parent_session", "party-mst")
	}); err != nil {
		t.Fatalf("set parent: %v", err)
	}

	result, err := svc.Continue(t.Context(), "party-mst")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}

	if !result.Master {
		t.Fatal("expected master=true")
	}
	if len(result.RevivedWorkers) != 2 {
		t.Fatalf("expected 2 revived workers, got %v", result.RevivedWorkers)
	}
	if len(result.FailedWorkers) != 0 {
		t.Fatalf("expected 0 failed workers, got %v", result.FailedWorkers)
	}

	// Both worker tmux sessions should exist
	if !runner.sessions["party-w1"] {
		t.Error("party-w1 tmux session not created")
	}
	if !runner.sessions["party-w2"] {
		t.Error("party-w2 tmux session not created")
	}
}

func TestContinue_MasterSkipsAliveWorkers(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	cwd := t.TempDir()

	createTestManifest(t, svc.Store, "party-m2", "master", cwd, "master")
	if err := svc.Store.AddWorker("party-m2", "party-alive"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	createTestManifest(t, svc.Store, "party-alive", "alive-worker", cwd, "")
	if err := svc.Store.Update("party-alive", func(m *state.Manifest) {
		m.SetExtra("parent_session", "party-m2")
	}); err != nil {
		t.Fatalf("set parent: %v", err)
	}

	// Mark worker as already running
	runner.sessions["party-alive"] = true

	result, err := svc.Continue(t.Context(), "party-m2")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}

	if len(result.RevivedWorkers) != 0 {
		t.Fatalf("expected 0 revived (worker already alive), got %v", result.RevivedWorkers)
	}
}

func TestContinue_MasterSkipsGhostWorkers(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	cwd := t.TempDir()

	createTestManifest(t, svc.Store, "party-m3", "master", cwd, "master")
	// Add a worker ID but do NOT create a manifest for it (ghost)
	if err := svc.Store.AddWorker("party-m3", "party-ghost"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	result, err := svc.Continue(t.Context(), "party-m3")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}

	if len(result.RevivedWorkers) != 0 {
		t.Fatalf("expected 0 revived (ghost has no manifest), got %v", result.RevivedWorkers)
	}
	if len(result.FailedWorkers) != 0 {
		t.Fatalf("expected 0 failed (ghost should be skipped), got %v", result.FailedWorkers)
	}
}

func TestContinue_RunningMasterCascadesOrphanedWorkers(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	cwd := t.TempDir()

	createTestManifest(t, svc.Store, "party-rm", "master", cwd, "master")
	if err := svc.Store.AddWorker("party-rm", "party-rw1"); err != nil {
		t.Fatalf("add worker: %v", err)
	}
	createTestManifest(t, svc.Store, "party-rw1", "orphan", cwd, "")
	if err := svc.Store.Update("party-rw1", func(m *state.Manifest) {
		m.SetExtra("parent_session", "party-rm")
	}); err != nil {
		t.Fatalf("set parent: %v", err)
	}

	// Master is already alive — reattach path
	runner.sessions["party-rm"] = true

	result, err := svc.Continue(t.Context(), "party-rm")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}
	if !result.Reattach {
		t.Fatal("expected reattach=true for running master")
	}
	if !result.Master {
		t.Fatal("expected master=true")
	}
	if len(result.RevivedWorkers) != 1 || result.RevivedWorkers[0] != "party-rw1" {
		t.Fatalf("expected [party-rw1] revived, got %v", result.RevivedWorkers)
	}
	if !runner.sessions["party-rw1"] {
		t.Error("orphaned worker tmux session not created")
	}
}

func TestContinue_MasterReportsCorruptManifestAsFailure(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	cwd := t.TempDir()

	createTestManifest(t, svc.Store, "party-m4", "master", cwd, "master")
	if err := svc.Store.AddWorker("party-m4", "party-corrupt"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	// Write corrupt JSON as the worker manifest
	corruptPath := filepath.Join(svc.Store.Root(), "party-corrupt.json")
	if err := os.WriteFile(corruptPath, []byte("{bad json"), 0o644); err != nil {
		t.Fatalf("write corrupt manifest: %v", err)
	}

	result, err := svc.Continue(t.Context(), "party-m4")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}

	if len(result.RevivedWorkers) != 0 {
		t.Fatalf("expected 0 revived, got %v", result.RevivedWorkers)
	}
	if len(result.FailedWorkers) != 1 || result.FailedWorkers[0] != "party-corrupt" {
		t.Fatalf("expected [party-corrupt] in failed, got %v", result.FailedWorkers)
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

	// Set up a legacy classic layout to prove companion->codex fallback still works.
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
	if m.WindowName != "party (worker) [master]" {
		t.Fatalf("expected manifest WindowName updated, got %q", m.WindowName)
	}
	if len(m.Agents) != 1 || m.Agents[0].Role != "primary" || m.Agents[0].Name != "claude" {
		t.Fatalf("expected only primary agent kept after promote, got %+v", m.Agents)
	}

	// Verify codex pane replaced with tracker
	if runner.paneRoles["party-worker:0.0"] != "tracker" {
		t.Fatalf("expected tracker role in pane 0.0, got %q", runner.paneRoles["party-worker:0.0"])
	}

	// Verify window renamed with [master] indicator
	if got := runner.windowNames["party-worker:0"]; got != "party (worker) [master]" {
		t.Errorf("expected window renamed to %q, got %q", "party (worker) [master]", got)
	}

	provider, err := svc.Registry.Get("claude")
	if err != nil {
		t.Fatalf("registry get claude: %v", err)
	}
	if !runner.hasSendText("party-worker:0.1", provider.MasterPrompt()) {
		t.Fatalf("expected master prompt sent to primary pane")
	}
}

func TestPromote_Sidebar(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["party-side"] = true
	createTestManifest(t, svc.Store, "party-side", "sidebar-worker", t.TempDir(), "")

	// Add a codex_thread_id to verify it gets cleared on promotion.
	if err := svc.Store.Update("party-side", func(m *state.Manifest) {
		m.SetExtra("codex_thread_id", "codex-stale-123")
	}); err != nil {
		t.Fatalf("set codex_thread_id: %v", err)
	}

	// Set sidebar layout env
	runner.envVars["party-side:PARTY_LAYOUT"] = "sidebar"
	runner.envVars["party-side:CODEX_THREAD_ID"] = "codex-stale-123"

	// Set up sidebar layout panes
	runner.paneRoles["party-side:0.0"] = "companion"
	runner.paneRoles["party-side:1.0"] = "sidebar"
	runner.paneRoles["party-side:1.1"] = "primary"
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
	if m.WindowName != "party (sidebar-worker) [master]" {
		t.Fatalf("expected manifest WindowName updated, got %q", m.WindowName)
	}
	if len(m.Agents) != 1 || m.Agents[0].Role != "primary" || m.Agents[0].Name != "claude" {
		t.Fatalf("expected only primary agent kept after promote, got %+v", m.Agents)
	}

	// codex_thread_id should be cleared — master mode has no Wizard.
	if got := m.ExtraString("codex_thread_id"); got != "" {
		t.Fatalf("expected codex_thread_id cleared, got %q", got)
	}

	// Sidebar pane (window 1, pane 0) should now be tracker
	if runner.paneRoles["party-side:1.0"] != "tracker" {
		t.Fatalf("expected tracker in window 1 pane 0, got %q", runner.paneRoles["party-side:1.0"])
	}

	// Window 0 (Codex) should be killed — master mode has no Wizard.
	if _, exists := runner.paneRoles["party-side:0.0"]; exists {
		t.Fatalf("expected codex window to be killed, but pane 0.0 still has role %q", runner.paneRoles["party-side:0.0"])
	}

	// CODEX_THREAD_ID env var should be unset.
	if _, exists := runner.envVars["party-side:CODEX_THREAD_ID"]; exists {
		t.Fatalf("expected CODEX_THREAD_ID unset")
	}

	// Verify window renamed with [master] indicator (sidebar: window 1)
	if got := runner.windowNames["party-side:1"]; got != "party (sidebar-worker) [master]" {
		t.Errorf("expected window renamed to %q, got %q", "party (sidebar-worker) [master]", got)
	}
}

func TestPromote_ClearsAgentAgnosticCompanionEnv(t *testing.T) {
	t.Parallel()

	svc, runner := setupService(t)
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"claude": {CLI: "/bin/sh"},
			"codex":  {CLI: "/bin/sh"},
		},
		Roles: agent.RolesConfig{
			Primary:   &agent.RoleConfig{Agent: "codex", Window: 1},
			Companion: &agent.RoleConfig{Agent: "claude", Window: 0},
		},
	})
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	svc.Registry = registry

	runner.sessions["party-agnostic"] = true
	createTestManifest(t, svc.Store, "party-agnostic", "agnostic", t.TempDir(), "")
	if err := svc.Store.Update("party-agnostic", func(m *state.Manifest) {
		m.Agents = []state.AgentManifest{
			{Name: "codex", Role: "primary", CLI: "/usr/bin/codex", ResumeID: "codex-primary", Window: 1},
			{Name: "claude", Role: "companion", CLI: "/usr/bin/claude", ResumeID: "claude-companion", Window: 0},
		}
	}); err != nil {
		t.Fatalf("update manifest agents: %v", err)
	}
	runner.envVars["party-agnostic:CLAUDE_SESSION_ID"] = "claude-companion"
	runner.paneRoles["party-agnostic:0.0"] = "companion"
	runner.paneRoles["party-agnostic:0.1"] = "primary"
	runner.paneRoles["party-agnostic:0.2"] = "shell"

	if err := svc.Promote(t.Context(), "party-agnostic"); err != nil {
		t.Fatalf("promote: %v", err)
	}

	if _, exists := runner.envVars["party-agnostic:CLAUDE_SESSION_ID"]; exists {
		t.Fatal("expected CLAUDE_SESSION_ID unset")
	}
	m, err := svc.Store.Read("party-agnostic")
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if len(m.Agents) != 1 || m.Agents[0].Name != "codex" || m.Agents[0].Role != "primary" {
		t.Fatalf("expected only codex primary kept after promote, got %+v", m.Agents)
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

func TestSpawn_FromMasterInheritsPrimaryAgentWithoutCompanion(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	counter := int64(6000)
	svc.Now = func() int64 { counter++; return counter }

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "party-master", "orch", cwd, "master")
	if err := svc.Store.Update("party-master", func(m *state.Manifest) {
		m.Agents = []state.AgentManifest{{
			Name:   "codex",
			Role:   "primary",
			CLI:    "/bin/sh",
			Window: 0,
		}}
		m.ClaudeBin = ""
		m.CodexBin = "/bin/sh"
		m.Extra = nil
	}); err != nil {
		t.Fatalf("update master manifest: %v", err)
	}

	result, err := svc.Spawn(t.Context(), "party-master", SpawnOpts{Title: "wizard-worker"})
	if err != nil {
		t.Fatalf("spawn: %v", err)
	}

	wm, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read worker manifest: %v", err)
	}
	if len(wm.Agents) != 1 {
		t.Fatalf("expected single-agent worker, got %+v", wm.Agents)
	}
	if wm.Agents[0].Role != "primary" || wm.Agents[0].Name != "codex" {
		t.Fatalf("expected codex primary worker, got %+v", wm.Agents[0])
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

// ---------------------------------------------------------------------------
// Service helper tests
// ---------------------------------------------------------------------------

func TestWindowName(t *testing.T) {
	t.Parallel()

	tests := map[string]struct {
		title string
		role  sessionRole
		want  string
	}{
		"with title":        {title: "my-project", role: roleStandalone, want: "party (my-project)"},
		"empty title":       {title: "", role: roleStandalone, want: "work"},
		"master with title": {title: "my-project", role: roleMaster, want: "party (my-project) [master]"},
		"master no title":   {title: "", role: roleMaster, want: "work [master]"},
		"worker with title": {title: "my-project", role: roleWorker, want: "party (my-project) [worker]"},
		"worker no title":   {title: "", role: roleWorker, want: "work [worker]"},
	}
	for name, tc := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			got := windowName(tc.title, tc.role)
			if got != tc.want {
				t.Errorf("windowName(%q, %q): got %q, want %q", tc.title, tc.role, got, tc.want)
			}
		})
	}
}

func TestManifest_SetExtra_NewMap(t *testing.T) {
	t.Parallel()

	m := state.Manifest{}
	m.SetExtra("key", "value")

	if m.Extra == nil {
		t.Fatal("Extra should be initialized")
	}
	got := m.ExtraString("key")
	if got != "value" {
		t.Errorf("ExtraString: got %q, want %q", got, "value")
	}
}

func TestManifest_ExtraString_Missing(t *testing.T) {
	t.Parallel()

	m := state.Manifest{}
	got := m.ExtraString("nonexistent")
	if got != "" {
		t.Errorf("expected empty, got %q", got)
	}
}

func TestManifest_ExtraString_InvalidJSON(t *testing.T) {
	t.Parallel()

	m := state.Manifest{
		Extra: map[string]json.RawMessage{
			"bad": json.RawMessage(`not-json`),
		},
	}
	got := m.ExtraString("bad")
	if got != "" {
		t.Errorf("expected empty for invalid JSON, got %q", got)
	}
}

func TestEnsureRuntimeDir(t *testing.T) {
	t.Parallel()

	dir, err := ensureRuntimeDir("party-test-runtime")
	if err != nil {
		t.Fatalf("ensureRuntimeDir: %v", err)
	}
	defer removeRuntimeDir("party-test-runtime")

	// Verify session-name file was written
	nameFile := dir + "/session-name"
	data, err := os.ReadFile(nameFile)
	if err != nil {
		t.Fatalf("read session-name: %v", err)
	}
	if strings.TrimSpace(string(data)) != "party-test-runtime" {
		t.Errorf("session-name: got %q", string(data))
	}
}

func TestRemoveRuntimeDir(t *testing.T) {
	t.Parallel()

	dir, err := ensureRuntimeDir("party-test-rm")
	if err != nil {
		t.Fatalf("ensureRuntimeDir: %v", err)
	}

	removeRuntimeDir("party-test-rm")

	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Error("runtime dir should be removed")
	}
}

// ---------------------------------------------------------------------------
// Delete with parent deregistration
// ---------------------------------------------------------------------------

func TestDelete_DeregistersFromParent(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	// Create master and worker
	createTestManifest(t, svc.Store, "party-parent", "master", t.TempDir(), "master")
	createTestManifest(t, svc.Store, "party-child", "worker", t.TempDir(), "")

	// Set parent reference and register worker
	if err := svc.Store.Update("party-child", func(m *state.Manifest) {
		m.SetExtra("parent_session", "party-parent")
	}); err != nil {
		t.Fatalf("set parent: %v", err)
	}
	if err := svc.Store.AddWorker("party-parent", "party-child"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	runner.sessions["party-child"] = true

	if err := svc.Delete(t.Context(), "party-child"); err != nil {
		t.Fatalf("delete: %v", err)
	}

	// Verify worker was deregistered from parent
	workers, err := svc.Store.GetWorkers("party-parent")
	if err != nil {
		t.Fatalf("get workers: %v", err)
	}
	if len(workers) != 0 {
		t.Errorf("expected 0 workers, got %v", workers)
	}
}

// ---------------------------------------------------------------------------
// Stop edge cases
// ---------------------------------------------------------------------------

func TestStop_NoPartySessions(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["regular-session"] = true

	stopped, err := svc.Stop(t.Context(), "")
	if err != nil {
		t.Fatalf("stop all: %v", err)
	}
	if len(stopped) != 0 {
		t.Errorf("expected 0 stopped, got %v", stopped)
	}
}

// ---------------------------------------------------------------------------
// Promote edge cases
// ---------------------------------------------------------------------------

func TestPromote_InvalidID(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	if err := svc.Promote(t.Context(), "invalid-id"); err == nil {
		t.Fatal("expected error for invalid ID")
	}
}

func TestPromote_MissingManifest(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	if err := svc.Promote(t.Context(), "party-ghost"); err == nil {
		t.Fatal("expected error for missing manifest")
	}
}

// ---------------------------------------------------------------------------
// Start with sidebar layout
// ---------------------------------------------------------------------------

func TestStart_SidebarLayout(t *testing.T) {
	// Not parallel — t.Setenv mutates process env
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 7777 }

	// Force sidebar layout via env var
	t.Setenv("PARTY_LAYOUT", "sidebar")

	result, err := svc.Start(t.Context(), StartOpts{
		Title: "sidebar-test",
		Cwd:   t.TempDir(),
	})
	if err != nil {
		t.Fatalf("start sidebar: %v", err)
	}

	// Verify session exists
	if !runner.sessions[result.SessionID] {
		t.Fatal("session not created")
	}

	// Sidebar layout should have companion in window 0, tracker in window 1.
	if runner.paneRoles[result.SessionID+":0.0"] != "companion" {
		t.Errorf("expected companion in 0.0, got %q", runner.paneRoles[result.SessionID+":0.0"])
	}
	if runner.paneRoles[result.SessionID+":1.0"] != "tracker" {
		t.Errorf("expected tracker in 1.0, got %q", runner.paneRoles[result.SessionID+":1.0"])
	}
}

// ---------------------------------------------------------------------------
// Fallback helper
// ---------------------------------------------------------------------------

func TestFallback(t *testing.T) {
	t.Parallel()

	if got := fallback("first", "second"); got != "first" {
		t.Errorf("expected 'first', got %q", got)
	}
	if got := fallback("", "second"); got != "second" {
		t.Errorf("expected 'second', got %q", got)
	}
}

// ---------------------------------------------------------------------------
// Continue with parent re-registration
// ---------------------------------------------------------------------------

func TestContinue_ReRegistersWithParent(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "party-master2", "master", cwd, "master")
	createTestManifest(t, svc.Store, "party-worker2", "worker", cwd, "")

	// Set parent reference
	if err := svc.Store.Update("party-worker2", func(m *state.Manifest) {
		m.SetExtra("parent_session", "party-master2")
	}); err != nil {
		t.Fatalf("set parent: %v", err)
	}

	_, err := svc.Continue(t.Context(), "party-worker2")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}

	// Verify worker re-registered with parent
	workers, err := svc.Store.GetWorkers("party-master2")
	if err != nil {
		t.Fatalf("get workers: %v", err)
	}
	if len(workers) != 1 || workers[0] != "party-worker2" {
		t.Errorf("expected [party-worker2], got %v", workers)
	}
}

func TestResolveLayout(t *testing.T) {
	// Not parallel — t.Setenv
	t.Setenv("PARTY_LAYOUT", "sidebar")
	if got := resolveLayout(); got != LayoutSidebar {
		t.Errorf("expected sidebar, got %s", got)
	}

	t.Setenv("PARTY_LAYOUT", "classic")
	if got := resolveLayout(); got != LayoutClassic {
		t.Errorf("expected classic, got %s", got)
	}

	t.Setenv("PARTY_LAYOUT", "")
	if got := resolveLayout(); got != LayoutSidebar {
		t.Errorf("expected sidebar for empty, got %s", got)
	}
}

// ---------------------------------------------------------------------------
// claimSessionID
// ---------------------------------------------------------------------------

func TestClaimSessionID_Unique(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	svc.Now = func() int64 { return 42 }

	id, err := svc.claimSessionID(t.Context(), state.Manifest{Title: "test", Cwd: "/tmp"})
	if err != nil {
		t.Fatalf("claimSessionID: %v", err)
	}
	if id != "party-42" {
		t.Errorf("expected party-42, got %s", id)
	}
}

func TestClaimSessionID_Collision(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	svc.Now = func() int64 { return 42 }
	svc.RandSuffix = func() int64 { return 99 }

	// Pre-create manifest for base ID to force collision
	if err := svc.Store.Create(state.Manifest{PartyID: "party-42"}); err != nil {
		t.Fatalf("create collision manifest: %v", err)
	}

	id, err := svc.claimSessionID(t.Context(), state.Manifest{Title: "test", Cwd: "/tmp"})
	if err != nil {
		t.Fatalf("claimSessionID: %v", err)
	}
	if id != "party-42-99" {
		t.Errorf("expected party-42-99, got %s", id)
	}
}

// ---------------------------------------------------------------------------
// persistResumeIDs
// ---------------------------------------------------------------------------

func TestPersistResumeIDs(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	dir := t.TempDir()
	resume := map[agent.Role]resumeInfo{
		agent.RolePrimary: {
			provider: agent.NewClaude(agent.AgentConfig{}),
			resumeID: "claude-id",
		},
		agent.RoleCompanion: {
			provider: agent.NewCodex(agent.AgentConfig{}),
			resumeID: "codex-id",
		},
	}
	if err := svc.persistResumeIDs(dir, resume); err != nil {
		t.Fatalf("persistResumeIDs: %v", err)
	}

	data, err := os.ReadFile(dir + "/claude-session-id")
	if err != nil {
		t.Fatalf("read claude-session-id: %v", err)
	}
	if strings.TrimSpace(string(data)) != "claude-id" {
		t.Errorf("claude-session-id: got %q", string(data))
	}

	data, err = os.ReadFile(dir + "/codex-thread-id")
	if err != nil {
		t.Fatalf("read codex-thread-id: %v", err)
	}
	if strings.TrimSpace(string(data)) != "codex-id" {
		t.Errorf("codex-thread-id: got %q", string(data))
	}
}

func TestPersistResumeIDs_Empty(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	dir := t.TempDir()
	if err := svc.persistResumeIDs(dir, map[agent.Role]resumeInfo{}); err != nil {
		t.Fatalf("persistResumeIDs: %v", err)
	}

	// Should not create files for empty IDs
	if _, err := os.Stat(dir + "/claude-session-id"); !os.IsNotExist(err) {
		t.Error("claude-session-id should not exist for empty ID")
	}
	if _, err := os.Stat(dir + "/codex-thread-id"); !os.IsNotExist(err) {
		t.Error("codex-thread-id should not exist for empty ID")
	}
}

// ---------------------------------------------------------------------------
// Start with resume IDs and prompt
// ---------------------------------------------------------------------------

func TestStart_WithResumeAndPrompt(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	svc.Now = func() int64 { return 8888 }

	result, err := svc.Start(t.Context(), StartOpts{
		Title:          "test",
		Cwd:            t.TempDir(),
		ClaudeResumeID: "claude-sess-1",
		CodexResumeID:  "codex-thread-1",
		Prompt:         "fix the bug",
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	// Verify resume IDs stored in manifest extra
	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if len(m.Agents) != 2 {
		t.Fatalf("expected 2 manifest agents, got %+v", m.Agents)
	}
	if got := manifestAgentResumeID(m.Agents, "primary"); got != "claude-sess-1" {
		t.Errorf("primary resume_id: got %q", got)
	}
	if got := manifestAgentResumeID(m.Agents, "companion"); got != "codex-thread-1" {
		t.Errorf("companion resume_id: got %q", got)
	}
	if got := m.ExtraString("claude_session_id"); got != "claude-sess-1" {
		t.Errorf("claude_session_id: got %q", got)
	}
	if got := m.ExtraString("codex_thread_id"); got != "codex-thread-1" {
		t.Errorf("codex_thread_id: got %q", got)
	}
	if got := m.ExtraString("initial_prompt"); got != "fix the bug" {
		t.Errorf("initial_prompt: got %q", got)
	}
}

func TestStart_CodexPrimaryRegistry(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 7777 }
	root := t.TempDir()
	codexCLI := filepath.Join(root, "codex-bin")
	claudeCLI := filepath.Join(root, "claude-bin")
	for _, path := range []string{codexCLI, claudeCLI} {
		if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
	}

	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"claude": {CLI: claudeCLI},
			"codex":  {CLI: codexCLI},
		},
		Roles: agent.RolesConfig{
			Primary:   &agent.RoleConfig{Agent: "codex", Window: 0},
			Companion: &agent.RoleConfig{Agent: "claude", Window: 1},
		},
	})
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	svc.Registry = registry

	result, err := svc.Start(t.Context(), StartOpts{
		Title:  "codex-primary",
		Cwd:    t.TempDir(),
		Layout: LayoutClassic,
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if len(m.Agents) != 2 {
		t.Fatalf("expected 2 agents, got %+v", m.Agents)
	}
	if m.Agents[0].Role != "primary" || m.Agents[0].Name != "codex" {
		t.Fatalf("primary agent: got %+v", m.Agents[0])
	}
	if m.Agents[1].Role != "companion" || m.Agents[1].Name != "claude" {
		t.Fatalf("companion agent: got %+v", m.Agents[1])
	}

	foundPrimaryCmd := false
	for _, call := range runner.calls {
		if len(call.args) >= 1 && call.args[0] == "split-window" && strings.Contains(call.args[len(call.args)-1], codexCLI) {
			foundPrimaryCmd = true
			break
		}
	}
	if !foundPrimaryCmd {
		t.Fatal("expected primary pane to launch Codex command")
	}
}

func TestStart_CodexPrimaryMasterIncludesPrompt(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 7788 }
	root := t.TempDir()
	codexCLI := filepath.Join(root, "codex-bin")
	if err := os.WriteFile(codexCLI, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("write %s: %v", codexCLI, err)
	}

	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"codex": {CLI: codexCLI},
		},
		Roles: agent.RolesConfig{
			Primary: &agent.RoleConfig{Agent: "codex", Window: 0},
		},
	})
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	svc.Registry = registry

	if _, err := svc.Start(t.Context(), StartOpts{
		Title:  "codex-master",
		Cwd:    t.TempDir(),
		Master: true,
		Prompt: "triage the backlog",
	}); err != nil {
		t.Fatalf("start master: %v", err)
	}

	wantPrompt := agent.NewCodex(agent.AgentConfig{}).MasterPrompt() + "\n\nTask: triage the backlog"
	foundMasterCmd := false
	for _, call := range runner.calls {
		if len(call.args) >= 1 && call.args[0] == "split-window" && strings.Contains(call.args[len(call.args)-1], codexCLI) {
			foundMasterCmd = true
			if !strings.Contains(call.args[len(call.args)-1], wantPrompt) {
				t.Fatalf("master Codex command missing prompt %q in %q", wantPrompt, call.args[len(call.args)-1])
			}
		}
	}
	if !foundMasterCmd {
		t.Fatal("expected master primary pane to launch Codex command")
	}
}

func TestStart_PromptGoesOnlyToPrimary(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 8899 }

	prompt := "investigate one narrow bug"
	if _, err := svc.Start(t.Context(), StartOpts{
		Title:  "prompted",
		Cwd:    t.TempDir(),
		Layout: LayoutClassic,
		Prompt: prompt,
	}); err != nil {
		t.Fatalf("start: %v", err)
	}

	var hits int
	for _, call := range runner.calls {
		for _, arg := range call.args {
			if strings.Contains(arg, prompt) {
				hits++
			}
		}
	}
	if hits != 1 {
		t.Fatalf("expected prompt to appear exactly once in tmux launch commands, got %d", hits)
	}
}

func TestStart_WorkerPromptIncludesReportContract(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 9901 }
	createTestManifest(t, svc.Store, "party-master", "master", t.TempDir(), "master")

	task := "Deliver a short joke to the master session."
	if _, err := svc.Start(t.Context(), StartOpts{
		Title:    "jester",
		Cwd:      t.TempDir(),
		Layout:   LayoutClassic,
		MasterID: "party-master",
		Prompt:   task,
	}); err != nil {
		t.Fatalf("start worker: %v", err)
	}

	var launch string
	for _, call := range runner.calls {
		for _, arg := range call.args {
			if strings.Contains(arg, task) {
				launch = arg
				break
			}
		}
	}
	if launch == "" {
		t.Fatal("expected worker launch command containing task prompt")
	}
	if !strings.Contains(launch, `party-cli report`) {
		t.Fatalf("expected worker report contract in launch command, got %q", launch)
	}
	if strings.Count(launch, task) != 1 {
		t.Fatalf("expected task prompt once in launch command, got %q", launch)
	}
}

func TestStart_NoCompanionRegistry(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 6666 }
	claudeCLI := filepath.Join(t.TempDir(), "claude-bin")
	if err := os.WriteFile(claudeCLI, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("write %s: %v", claudeCLI, err)
	}

	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"claude": {CLI: claudeCLI},
		},
		Roles: agent.RolesConfig{
			Primary: &agent.RoleConfig{Agent: "claude", Window: 0},
		},
	})
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	svc.Registry = registry

	result, err := svc.Start(t.Context(), StartOpts{
		Title:  "solo",
		Cwd:    t.TempDir(),
		Layout: LayoutClassic,
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if len(m.Agents) != 1 {
		t.Fatalf("expected 1 agent, got %+v", m.Agents)
	}
	if m.Agents[0].Role != "primary" || m.Agents[0].Name != "claude" {
		t.Fatalf("primary agent: got %+v", m.Agents[0])
	}
	if runner.paneRoles[result.SessionID+":0.0"] != "primary" {
		t.Fatalf("expected primary in 0.0, got %q", runner.paneRoles[result.SessionID+":0.0"])
	}
	if runner.paneRoles[result.SessionID+":0.1"] != "shell" {
		t.Fatalf("expected shell in 0.1, got %q", runner.paneRoles[result.SessionID+":0.1"])
	}
	if _, ok := runner.paneRoles[result.SessionID+":0.2"]; ok {
		t.Fatalf("expected 2-pane classic layout, got unexpected pane 0.2 role %q", runner.paneRoles[result.SessionID+":0.2"])
	}
}

// ---------------------------------------------------------------------------
// Delete non-running session
// ---------------------------------------------------------------------------

func TestDelete_NotRunning(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	createTestManifest(t, svc.Store, "party-stopped", "stopped", t.TempDir(), "")

	// Should succeed (KillSession returns nil for absent sessions)
	if err := svc.Delete(t.Context(), "party-stopped"); err != nil {
		t.Fatalf("delete stopped: %v", err)
	}

	// Manifest should be gone
	if _, err := svc.Store.Read("party-stopped"); err == nil {
		t.Error("manifest should be deleted")
	}
}

// ---------------------------------------------------------------------------
// themeCmd (package-level helper, tested via layout integration)
// ---------------------------------------------------------------------------

// Test Continue with bad cwd (falls back to getwd)
func TestContinue_BadCwd(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	createTestManifest(t, svc.Store, "party-badcwd", "test", "/nonexistent/path/definitely", "")

	_, err := svc.Continue(t.Context(), "party-badcwd")
	// Should succeed (falls back to getwd when cwd doesn't exist)
	if err != nil {
		t.Fatalf("continue with bad cwd: %v", err)
	}
}

func TestContinue_UsesAgentManifestResumeIDs(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	cwd := t.TempDir()

	if err := svc.Store.Create(state.Manifest{
		PartyID: "party-agents",
		Title:   "agent-manifest",
		Cwd:     cwd,
		Agents: []state.AgentManifest{
			{Name: "claude", Role: "primary", CLI: "/usr/bin/claude", ResumeID: "claude-resume", Window: 1},
			{Name: "codex", Role: "companion", CLI: "/usr/bin/codex", ResumeID: "codex-resume", Window: 0},
		},
		AgentPath: "/usr/bin",
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	if _, err := svc.Continue(t.Context(), "party-agents"); err != nil {
		t.Fatalf("continue: %v", err)
	}
	if got := runner.envVars["party-agents:CLAUDE_SESSION_ID"]; got != "claude-resume" {
		t.Fatalf("CLAUDE_SESSION_ID: got %q", got)
	}
	if got := runner.envVars["party-agents:CODEX_THREAD_ID"]; got != "codex-resume" {
		t.Fatalf("CODEX_THREAD_ID: got %q", got)
	}
}

func TestContinue_UsesManifestAgentsNotCurrentRegistry(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	cwd := t.TempDir()

	codexCLI := filepath.Join(cwd, "codex-bin")
	claudeCLI := filepath.Join(cwd, "claude-bin")
	for _, path := range []string{codexCLI, claudeCLI} {
		if err := os.WriteFile(path, []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
	}

	swappedRegistry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"claude": {CLI: claudeCLI},
			"codex":  {CLI: codexCLI},
		},
		Roles: agent.RolesConfig{
			Primary:   &agent.RoleConfig{Agent: "claude", Window: -1},
			Companion: &agent.RoleConfig{Agent: "codex", Window: 0},
		},
	})
	if err != nil {
		t.Fatalf("NewRegistry(swapped): %v", err)
	}
	svc.Registry = swappedRegistry

	if err := svc.Store.Create(state.Manifest{
		PartyID: "party-manifest",
		Title:   "manifest-source",
		Cwd:     cwd,
		Agents: []state.AgentManifest{
			{Name: "codex", Role: "primary", CLI: codexCLI, ResumeID: "codex-primary", Window: 1},
			{Name: "claude", Role: "companion", CLI: claudeCLI, ResumeID: "claude-companion", Window: 0},
		},
		AgentPath: "/usr/bin",
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	if _, err := svc.Continue(t.Context(), "party-manifest"); err != nil {
		t.Fatalf("continue: %v", err)
	}

	m, err := svc.Store.Read("party-manifest")
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if len(m.Agents) != 2 {
		t.Fatalf("expected 2 agents, got %+v", m.Agents)
	}
	if m.Agents[0].Role != "primary" || m.Agents[0].Name != "codex" || m.Agents[0].CLI != codexCLI {
		t.Fatalf("primary manifest agent: got %+v", m.Agents[0])
	}
	if m.Agents[1].Role != "companion" || m.Agents[1].Name != "claude" || m.Agents[1].CLI != claudeCLI {
		t.Fatalf("companion manifest agent: got %+v", m.Agents[1])
	}

	var sawCodexPrimary, sawClaudeCompanion bool
	for _, call := range runner.calls {
		if len(call.args) < 2 {
			continue
		}
		if call.args[0] != "split-window" && call.args[0] != "respawn-pane" {
			continue
		}
		cmd := call.args[len(call.args)-1]
		if strings.Contains(cmd, codexCLI) && strings.Contains(cmd, "--dangerously-bypass-approvals-and-sandbox") {
			sawCodexPrimary = true
		}
		if strings.Contains(cmd, claudeCLI) && strings.Contains(cmd, "--permission-mode bypassPermissions") {
			sawClaudeCompanion = true
		}
	}
	if !sawCodexPrimary {
		t.Fatal("expected Codex primary launch command from manifest agent")
	}
	if !sawClaudeCompanion {
		t.Fatal("expected Claude companion launch command from manifest agent")
	}
}

func TestContinue_RejectsSameProviderInBothRoles(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	cwd := t.TempDir()

	if err := svc.Store.Create(state.Manifest{
		PartyID: "party-duplicate",
		Title:   "duplicate-provider",
		Cwd:     cwd,
		Agents: []state.AgentManifest{
			{Name: "codex", Role: "primary", CLI: "/usr/bin/codex", ResumeID: "codex-primary", Window: 1},
			{Name: "codex", Role: "companion", CLI: "/usr/bin/codex", ResumeID: "codex-companion", Window: 0},
		},
		AgentPath: "/usr/bin",
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	_, err := svc.Continue(t.Context(), "party-duplicate")
	if err == nil {
		t.Fatal("expected duplicate provider continue to fail")
	}
	if !strings.Contains(err.Error(), `same agent "codex"`) {
		t.Fatalf("unexpected error: %v", err)
	}
}

// Test NowUTC returns a timestamp
func TestNowUTC(t *testing.T) {
	t.Parallel()
	ts := state.NowUTC()
	if len(ts) < 20 {
		t.Errorf("nowUTC too short: %q", ts)
	}
	if !strings.Contains(ts, "T") || !strings.HasSuffix(ts, "Z") {
		t.Errorf("nowUTC bad format: %q", ts)
	}
}

// Test Continue stopped master with sidebar layout
func TestContinue_StoppedMasterSidebar(t *testing.T) {
	// Not parallel — t.Setenv
	svc, runner := setupService(t)
	t.Setenv("PARTY_LAYOUT", "sidebar")

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "party-msb", "master-sb", cwd, "master")

	result, err := svc.Continue(t.Context(), "party-msb")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}
	if !result.Master {
		t.Fatal("expected master=true")
	}
	if !runner.sessions["party-msb"] {
		t.Fatal("session not recreated")
	}
}

// Test Start creates unique IDs on collision
func TestStart_IDCollision(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	// Pre-create manifest for base ID to force collision via Store.Create.
	if err := svc.Store.Create(state.Manifest{PartyID: "party-42"}); err != nil {
		t.Fatalf("create collision manifest: %v", err)
	}
	svc.Now = func() int64 { return 42 }
	svc.RandSuffix = func() int64 { return 7 }

	result, err := svc.Start(t.Context(), StartOpts{
		Title: "collision-test",
		Cwd:   t.TempDir(),
	})
	if err != nil {
		t.Fatalf("start with collision: %v", err)
	}
	if result.SessionID == "party-42" {
		t.Error("should not reuse existing ID")
	}
}

// Test NewService uses production defaults
func TestNewService_Defaults(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	store, err := state.NewStore(dir)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	runner := newMockRunner()
	client := tmux.NewClient(runner)
	svc := NewService(store, client, "/fake")

	if svc.Store != store {
		t.Error("Store not set")
	}
	if svc.Client != client {
		t.Error("Client not set")
	}
	if svc.RepoRoot != "/fake" {
		t.Error("RepoRoot not set")
	}
	if svc.Now == nil {
		t.Error("Now should have default")
	}
	if svc.RandSuffix == nil {
		t.Error("RandSuffix should have default")
	}
	if svc.CLIResolver == nil {
		t.Error("CLIResolver should have default")
	}
}

// Test runtimeDir
func TestRuntimeDir(t *testing.T) {
	t.Parallel()
	got := runtimeDir("party-test-123")
	if !strings.HasSuffix(got, "party-test-123") {
		t.Errorf("expected path ending in party-test-123, got %q", got)
	}
}

// Test launchMaster successful path directly
func TestLaunchMaster_Success(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	runner.sessions["party-lm"] = true

	if err := svc.launchMaster(t.Context(), "party-lm", "/tmp", launchCmds("echo claude", "echo codex")); err != nil {
		t.Fatalf("launchMaster: %v", err)
	}
	if runner.paneRoles["party-lm:0.0"] != "tracker" {
		t.Errorf("expected tracker in 0.0, got %q", runner.paneRoles["party-lm:0.0"])
	}
	if runner.paneRoles["party-lm:0.1"] != "primary" {
		t.Errorf("expected primary in 0.1, got %q", runner.paneRoles["party-lm:0.1"])
	}
	if runner.paneRoles["party-lm:0.2"] != "shell" {
		t.Errorf("expected shell in 0.2, got %q", runner.paneRoles["party-lm:0.2"])
	}
}

// Test launchClassic successful path directly
func TestLaunchClassic_Success(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	runner.sessions["party-lc"] = true

	if err := svc.launchClassic(t.Context(), "party-lc", "/tmp", launchCmds("echo claude", "echo codex")); err != nil {
		t.Fatalf("launchClassic: %v", err)
	}
	if runner.paneRoles["party-lc:0.0"] != "companion" {
		t.Errorf("expected companion in 0.0, got %q", runner.paneRoles["party-lc:0.0"])
	}
	if runner.paneRoles["party-lc:0.1"] != "primary" {
		t.Errorf("expected primary in 0.1, got %q", runner.paneRoles["party-lc:0.1"])
	}
	if runner.paneRoles["party-lc:0.2"] != "shell" {
		t.Errorf("expected shell in 0.2, got %q", runner.paneRoles["party-lc:0.2"])
	}
}

func TestLaunchClassic_NoCompanion(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	runner.sessions["party-lc2"] = true

	if err := svc.launchClassic(t.Context(), "party-lc2", "/tmp", launchCmds("echo claude", "")); err != nil {
		t.Fatalf("launchClassic: %v", err)
	}
	if runner.paneRoles["party-lc2:0.0"] != "primary" {
		t.Errorf("expected primary in 0.0, got %q", runner.paneRoles["party-lc2:0.0"])
	}
	if runner.paneRoles["party-lc2:0.1"] != "shell" {
		t.Errorf("expected shell in 0.1, got %q", runner.paneRoles["party-lc2:0.1"])
	}
	if _, ok := runner.paneRoles["party-lc2:0.2"]; ok {
		t.Fatalf("expected no pane 0.2 in 2-pane layout, got role %q", runner.paneRoles["party-lc2:0.2"])
	}
}

func TestLaunchSidebar_Success(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	runner.sessions["party-ls"] = true

	if err := svc.launchSidebar(t.Context(), "party-ls", "/tmp", "test", false, launchCmds("echo claude", "echo codex")); err != nil {
		t.Fatalf("launchSidebar: %v", err)
	}
	if runner.paneRoles["party-ls:0.0"] != "companion" {
		t.Errorf("expected companion in 0.0, got %q", runner.paneRoles["party-ls:0.0"])
	}
	if runner.paneRoles["party-ls:1.0"] != "tracker" {
		t.Errorf("expected tracker in 1.0, got %q", runner.paneRoles["party-ls:1.0"])
	}
	if runner.paneRoles["party-ls:1.1"] != "primary" {
		t.Errorf("expected primary in 1.1, got %q", runner.paneRoles["party-ls:1.1"])
	}
	if runner.paneRoles["party-ls:1.2"] != "shell" {
		t.Errorf("expected shell in 1.2, got %q", runner.paneRoles["party-ls:1.2"])
	}
}

func TestLaunchSidebar_NoCompanion(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	runner.sessions["party-ls2"] = true

	if err := svc.launchSidebar(t.Context(), "party-ls2", "/tmp", "test", false, launchCmds("echo claude", "")); err != nil {
		t.Fatalf("launchSidebar: %v", err)
	}
	if runner.paneRoles["party-ls2:0.0"] != "tracker" {
		t.Errorf("expected tracker in 0.0, got %q", runner.paneRoles["party-ls2:0.0"])
	}
	if runner.paneRoles["party-ls2:0.1"] != "primary" {
		t.Errorf("expected primary in 0.1, got %q", runner.paneRoles["party-ls2:0.1"])
	}
	if runner.paneRoles["party-ls2:0.2"] != "shell" {
		t.Errorf("expected shell in 0.2, got %q", runner.paneRoles["party-ls2:0.2"])
	}
	if _, ok := runner.paneRoles["party-ls2:1.0"]; ok {
		t.Fatalf("expected no workspace window 1 without companion, got role %q", runner.paneRoles["party-ls2:1.0"])
	}
}

func TestAgentWindow_NoCompanionSidebarUsesWindowZero(t *testing.T) {
	t.Parallel()

	if got := agentWindow(LayoutSidebar, false, agent.RolePrimary, false); got != 0 {
		t.Fatalf("expected sidebar primary window 0 without companion, got %d", got)
	}
	if got := agentWindow(LayoutSidebar, false, agent.RolePrimary, true); got != 1 {
		t.Fatalf("expected sidebar primary window 1 with companion, got %d", got)
	}
}

func TestResize_UsesCompanionPane(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	runner.paneRoles["party-r:0.0"] = "companion"
	runner.paneRoles["party-r:0.1"] = "primary"
	runner.paneRoles["party-r:0.2"] = "shell"

	if err := svc.Resize(t.Context(), "party-r"); err != nil {
		t.Fatalf("Resize: %v", err)
	}
	if !runner.hasCall("resize-pane", "-t", "party-r:0.0", "-x", leftPaneWidth) {
		t.Fatalf("expected companion pane resize, calls=%v", runner.calls)
	}
	if !runner.hasCall("resize-pane", "-t", "party-r:0.2", "-x", shellPaneWidth) {
		t.Fatalf("expected shell pane resize, calls=%v", runner.calls)
	}
}

func TestApplyLayoutResizes_InstallsRetryAndHooks(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	runner.sessions["party-hooks"] = true

	if err := svc.applyLayoutResizes(t.Context(), "party-hooks", "party-hooks:1.0", "party-hooks:1.2"); err != nil {
		t.Fatalf("applyLayoutResizes: %v", err)
	}

	if !runner.hasCall("run-shell", "-t", "party-hooks", "-b") {
		t.Fatalf("expected background resize retry, calls=%v", runner.calls)
	}
	if !runner.hasCall("set-hook", "-t", "party-hooks", "client-attached") {
		t.Fatalf("expected client-attached resize hook, calls=%v", runner.calls)
	}
	if !runner.hasCall("set-hook", "-t", "party-hooks", "client-resized") {
		t.Fatalf("expected client-resized resize hook, calls=%v", runner.calls)
	}
}

func TestResize_NoLeftPaneInTwoPaneClassic(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	runner.paneRoles["party-r2:0.0"] = "primary"
	runner.paneRoles["party-r2:0.1"] = "shell"

	err := svc.Resize(t.Context(), "party-r2")
	if err == nil {
		t.Fatal("expected resize error for 2-pane layout")
	}
	if !strings.Contains(err.Error(), "2-pane layout") {
		t.Fatalf("expected 2-pane layout error, got %v", err)
	}
}

// ---------------------------------------------------------------------------
// resolveBinary
// ---------------------------------------------------------------------------

func TestResolveBinary_FromEnv(t *testing.T) {
	// Not parallel — t.Setenv
	t.Setenv("TEST_RESOLVE_BIN", "/custom/path/bin")
	got := resolveBinary("TEST_RESOLVE_BIN", "nonexistent-binary", "/fallback")
	if got != "/custom/path/bin" {
		t.Errorf("expected env val, got %q", got)
	}
}

func TestResolveBinary_Fallback(t *testing.T) {
	// Not parallel — t.Setenv
	t.Setenv("TEST_RESOLVE_BIN2", "")
	got := resolveBinary("TEST_RESOLVE_BIN2", "definitelynotabinary9999", "/fallback/path")
	if got != "/fallback/path" {
		t.Errorf("expected fallback, got %q", got)
	}
}

// ---------------------------------------------------------------------------
// setResumeEnv
// ---------------------------------------------------------------------------

func TestSetResumeEnv(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["party-env"] = true

	resume := map[agent.Role]resumeInfo{
		agent.RolePrimary: {
			provider: agent.NewClaude(agent.AgentConfig{}),
			resumeID: "claude-1",
		},
		agent.RoleCompanion: {
			provider: agent.NewCodex(agent.AgentConfig{}),
			resumeID: "codex-1",
		},
	}
	if err := svc.setResumeEnv(t.Context(), "party-env", resume); err != nil {
		t.Fatalf("setResumeEnv: %v", err)
	}

	if runner.envVars["party-env:CLAUDE_SESSION_ID"] != "claude-1" {
		t.Errorf("CLAUDE_SESSION_ID: got %q", runner.envVars["party-env:CLAUDE_SESSION_ID"])
	}
	if runner.envVars["party-env:CODEX_THREAD_ID"] != "codex-1" {
		t.Errorf("CODEX_THREAD_ID: got %q", runner.envVars["party-env:CODEX_THREAD_ID"])
	}
}

func TestSetResumeEnv_Empty(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["party-env2"] = true

	if err := svc.setResumeEnv(t.Context(), "party-env2", map[agent.Role]resumeInfo{}); err != nil {
		t.Fatalf("setResumeEnv: %v", err)
	}

	// Should not set vars for empty IDs
	if _, ok := runner.envVars["party-env2:CLAUDE_SESSION_ID"]; ok {
		t.Error("CLAUDE_SESSION_ID should not be set for empty ID")
	}
}

// ---------------------------------------------------------------------------
// setCleanupHook
// ---------------------------------------------------------------------------

func TestSetCleanupHook(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["party-hook"] = true

	if err := svc.setCleanupHook(t.Context(), "party-hook"); err != nil {
		t.Fatalf("setCleanupHook: %v", err)
	}

	if !runner.hasCall("set-hook") {
		t.Error("expected set-hook call")
	}
}

// TestCleanupHook_VariableVisibility verifies the cleanup script and hook
// are correctly generated. The hook calls a script file (avoiding tmux
// format expansion), and the script contains proper shell logic.
func TestCleanupHook_VariableVisibility(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	runner.sessions["party-vis"] = true

	if err := svc.setCleanupHook(t.Context(), "party-vis"); err != nil {
		t.Fatalf("setCleanupHook: %v", err)
	}

	// Find the set-hook call and extract the hook command
	var hookCmd string
	for _, c := range runner.calls {
		if len(c.args) >= 3 && c.args[0] == "set-hook" {
			hookCmd = c.args[len(c.args)-1]
			break
		}
	}
	if hookCmd == "" {
		t.Fatal("set-hook call not found")
	}

	// Hook must call the cleanup script, not contain inline shell logic.
	// This avoids tmux $NAME format expansion entirely.
	if !strings.Contains(hookCmd, "cleanup.sh") {
		t.Error("hook must call cleanup.sh script")
	}
	// CRITICAL: hook must NOT contain any bare $VAR references that tmux
	// would expand to empty (the original bug that deleted /tmp/).
	if strings.Contains(hookCmd, "$W") || strings.Contains(hookCmd, "$SR") {
		t.Error("hook must not contain $W or $SR — tmux expands them to empty")
	}

	// Read the generated cleanup script and verify its content.
	scriptPath := filepath.Join("/tmp", "party-vis", "cleanup.sh")
	script, err := os.ReadFile(scriptPath)
	if err != nil {
		t.Fatalf("read cleanup script: %v", err)
	}
	s := string(script)

	// Script must reference the session ID in manifest paths and rm -rf.
	if !strings.Contains(s, "party-vis") {
		t.Error("script must contain session ID")
	}
	if !strings.Contains(s, `rm -rf "/tmp/$W"`) {
		t.Error("script must remove runtime dir via rm -rf /tmp/$W")
	}

	// $p must be exported before bash -c so the child shell can see it.
	if !strings.Contains(s, "export p") {
		t.Error("script must export p before bash -c")
	}

	// Perl must use system() not exec() to hold flock during rewrite.
	if strings.Contains(s, "exec @ARGV") {
		t.Error("script must use system() not exec() to hold flock")
	}
	if !strings.Contains(s, "system(@ARGV") {
		t.Error("script must use system() to hold flock while bash -c runs")
	}
}

// TestCleanupHook_SpacesInRoot verifies paths are properly quoted when the
// state root contains spaces (PARTY_STATE_ROOT is user-configurable).
func TestCleanupHook_SpacesInRoot(t *testing.T) {
	t.Parallel()
	root := t.TempDir() + "/party state root"
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	runner := newMockRunner()
	runner.sessions["party-sp"] = true
	client := tmux.NewClient(runner)
	svc := NewService(store, client, "")

	if err := svc.setCleanupHook(t.Context(), "party-sp"); err != nil {
		t.Fatalf("setCleanupHook: %v", err)
	}

	// Read the generated cleanup script and verify the state root is quoted.
	scriptPath := filepath.Join("/tmp", "party-sp", "cleanup.sh")
	script, err := os.ReadFile(scriptPath)
	if err != nil {
		t.Fatalf("read cleanup script: %v", err)
	}
	s := string(script)

	// State root must be single-quoted in the SR= assignment to handle spaces.
	if !strings.Contains(s, "'"+root+"'") {
		t.Errorf("state root with spaces must be single-quoted in script; got:\n%s", s)
	}
}

// TestCleanupHook_ApostropheInRoot verifies paths with apostrophes are safe.
func TestCleanupHook_ApostropheInRoot(t *testing.T) {
	t.Parallel()
	root := t.TempDir() + "/party'root"
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	runner := newMockRunner()
	runner.sessions["party-ap"] = true
	client := tmux.NewClient(runner)
	svc := NewService(store, client, "")

	if err := svc.setCleanupHook(t.Context(), "party-ap"); err != nil {
		t.Fatalf("setCleanupHook: %v", err)
	}

	// Read the script and verify it's syntactically valid shell.
	scriptPath := filepath.Join("/tmp", "party-ap", "cleanup.sh")
	script, err := os.ReadFile(scriptPath)
	if err != nil {
		t.Fatalf("read cleanup script: %v", err)
	}

	// bash -n checks syntax without executing.
	cmd := exec.CommandContext(t.Context(), "bash", "-n", scriptPath)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Errorf("cleanup script has syntax errors: %v\n%s\nscript:\n%s", err, out, script)
	}
}

// ---------------------------------------------------------------------------
// Layout launch error paths
// ---------------------------------------------------------------------------

func TestLaunchClassic_ErrorOnFirstPane(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.fn = func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "respawn-pane" {
			return "", &tmux.ExitError{Code: 1}
		}
		return runner.defaultHandler(t.Context(), args...)
	}
	runner.sessions["party-err"] = true

	err := svc.launchClassic(t.Context(), "party-err", "/tmp", launchCmds("claude", "codex"))
	if err == nil {
		t.Fatal("expected error from launchClassic")
	}
}

func TestLaunchClassic_ErrorOnSecondSplit(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	splitCount := 0
	runner.fn = func(ctx context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "split-window" {
			splitCount++
			if splitCount >= 2 {
				return "", &tmux.ExitError{Code: 1}
			}
		}
		return runner.defaultHandler(ctx, args...)
	}
	runner.sessions["party-err2"] = true

	err := svc.launchClassic(t.Context(), "party-err2", "/tmp", launchCmds("claude", "codex"))
	if err == nil {
		t.Fatal("expected error from launchClassic on second split")
	}
}

func TestLaunchMaster_ErrorOnRespawn(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.fn = func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "respawn-pane" {
			return "", &tmux.ExitError{Code: 1}
		}
		return runner.defaultHandler(t.Context(), args...)
	}

	runner.sessions["party-merr"] = true

	err := svc.launchMaster(t.Context(), "party-merr", "/tmp", launchCmds("claude", "codex"))
	if err == nil {
		t.Fatal("expected error from launchMaster")
	}
}

func TestLaunchMaster_ErrorOnSplit(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	splitCount := 0
	runner.fn = func(ctx context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "split-window" {
			splitCount++
			return "", &tmux.ExitError{Code: 1}
		}
		return runner.defaultHandler(ctx, args...)
	}

	runner.sessions["party-merr2"] = true

	err := svc.launchMaster(t.Context(), "party-merr2", "/tmp", launchCmds("claude", "codex"))
	if err == nil {
		t.Fatal("expected error from launchMaster on split")
	}
}

func TestLaunchSidebar_ErrorOnRename(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.fn = func(ctx context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "rename-window" {
			return "", &tmux.ExitError{Code: 1}
		}
		return runner.defaultHandler(ctx, args...)
	}

	runner.sessions["party-serr2"] = true

	err := svc.launchSidebar(t.Context(), "party-serr2", "/tmp", "test", false, launchCmds("claude", "codex"))
	if err == nil {
		t.Fatal("expected error from launchSidebar on rename")
	}
}

func TestLaunchSidebar_ErrorPropagation(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	callCount := 0
	runner.fn = func(ctx context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "split-window" {
			callCount++
			if callCount >= 2 {
				return "", &tmux.ExitError{Code: 1}
			}
		}
		return runner.defaultHandler(ctx, args...)
	}

	runner.sessions["party-serr"] = true

	err := svc.launchSidebar(t.Context(), "party-serr", "/tmp", "test", false, launchCmds("claude", "codex"))
	if err == nil {
		t.Fatal("expected error from launchSidebar")
	}
}

// ---------------------------------------------------------------------------
// promoteClassic / promoteSidebar direct tests
// ---------------------------------------------------------------------------

func TestPromoteClassic_Success(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["party-pc"] = true
	runner.paneRoles["party-pc:0.0"] = "companion"
	runner.paneRoles["party-pc:0.1"] = "primary"

	if err := svc.promoteClassic(t.Context(), "party-pc", "/tmp", "echo tracker"); err != nil {
		t.Fatalf("promoteClassic: %v", err)
	}
	if runner.paneRoles["party-pc:0.0"] != "tracker" {
		t.Errorf("expected tracker in 0.0, got %q", runner.paneRoles["party-pc:0.0"])
	}
}

func TestPromoteClassic_LegacyCodexFallback(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["party-pc-old"] = true
	runner.paneRoles["party-pc-old:0.0"] = "codex"
	runner.paneRoles["party-pc-old:0.1"] = "claude"

	if err := svc.promoteClassic(t.Context(), "party-pc-old", "/tmp", "echo tracker"); err != nil {
		t.Fatalf("promoteClassic legacy: %v", err)
	}
	if runner.paneRoles["party-pc-old:0.0"] != "tracker" {
		t.Errorf("expected tracker in 0.0, got %q", runner.paneRoles["party-pc-old:0.0"])
	}
}

func TestPromoteSidebar_Success(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["party-ps"] = true
	runner.paneRoles["party-ps:0.0"] = "companion"
	runner.paneRoles["party-ps:1.0"] = "sidebar"

	if err := svc.promoteSidebar(t.Context(), "party-ps", "/tmp", "echo tracker"); err != nil {
		t.Fatalf("promoteSidebar: %v", err)
	}
	if runner.paneRoles["party-ps:1.0"] != "tracker" {
		t.Errorf("expected tracker in 1.0, got %q", runner.paneRoles["party-ps:1.0"])
	}
	// Codex window should be killed — master mode has no Wizard.
	if _, exists := runner.paneRoles["party-ps:0.0"]; exists {
		t.Errorf("expected codex window killed, but pane 0.0 still has role %q", runner.paneRoles["party-ps:0.0"])
	}
}

// ---------------------------------------------------------------------------
// Start with explicit layout
// ---------------------------------------------------------------------------

func TestStart_ClassicExplicit(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 5555 }

	result, err := svc.Start(t.Context(), StartOpts{
		Title:  "classic-test",
		Cwd:    t.TempDir(),
		Layout: LayoutClassic,
	})
	if err != nil {
		t.Fatalf("start classic: %v", err)
	}

	if !runner.sessions[result.SessionID] {
		t.Fatal("session not created")
	}
	if runner.paneRoles[result.SessionID+":0.0"] != "companion" {
		t.Errorf("expected companion in 0.0, got %q", runner.paneRoles[result.SessionID+":0.0"])
	}
}
